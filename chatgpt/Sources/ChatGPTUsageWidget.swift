// ChatGPTUsageWidget.swift
// ChatGPT planındaki Codex kullanım limitlerini (5 saatlik oturum + haftalık)
// canlı gösteren, her zaman üstte duran mini masaüstü widget'ı.
//
// Veri kaynağı: Codex CLI'nin kendi ChatGPT girişi (~/.codex/auth.json) ile
// https://chatgpt.com/backend-api/wham/usage endpoint'i (Codex'in /status ekranının kullandığı).
// Token yalnızca okunur: hiçbir yere yazılmaz, yenilenmez, loglanmaz.
//
// Derleme: ./build.sh
// Teşhis: ChatGPTUsageWidget --once   (özet yazdırır ve çıkar)
//         ChatGPTUsageWidget --raw    (ham JSON yanıtı da yazdırır)
//
// Not: SwiftUI @State macro'su bilerek kullanılmıyor; Command Line Tools'taki
// swiftc SwiftUI macro eklentisini bulamıyor.

import AppKit
import Darwin
import SwiftUI

// MARK: - Models

struct LimitWindow: Identifiable, Sendable {
    let id: String                      // örn. "main.primary_window"
    let title: String
    let percent: Double                 // 0–100
    let resetsAt: Date?
    let windowLength: TimeInterval?     // tempo işareti için pencere uzunluğu
}

struct CreditsInfo: Sendable {
    let balance: String?
    let unlimited: Bool
}

struct UsageSnapshot: Sendable {
    let windows: [LimitWindow]
    let credits: CreditsInfo?
    let resetCredits: Int?              // kullanılabilir "limit sıfırlama" hakkı
    let plan: String?
    let fetchedAt: Date
}

enum UsageError: Error, Sendable {
    case noCredentials
    case apiKeyMode
    case unauthorized
    case rateLimited
    case http(Int)
    case network(String)
    case badResponse

    var message: String {
        switch self {
        case .noCredentials:
            return "Codex girişi bulunamadı. Terminalde `codex login` ile ChatGPT hesabınla giriş yap."
        case .apiKeyMode:
            return "Codex API key ile kullanılıyor; plan limitleri sadece ChatGPT girişiyle görünür. `codex login` ile ChatGPT hesabınla giriş yap."
        case .unauthorized:
            return "Giriş anahtarının süresi dolmuş. Codex'i bir kez açman yeterli, widget kendini toparlar."
        case .rateLimited:
            return "Çok sık istek gönderildi, birkaç dakika sonra tekrar denenecek."
        case .http(let code):
            return "Sunucu hatası (HTTP \(code)). Tekrar denenecek."
        case .network:
            return "Bağlantı yok. Tekrar denenecek."
        case .badResponse:
            return "Yanıt okunamadı, endpoint formatı değişmiş olabilir."
        }
    }
}

// MARK: - Credentials (read-only)

struct Credentials: Sendable {
    let accessToken: String
    let accountId: String?
}

enum CredentialStore {
    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func load() throws -> Credentials {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageError.noCredentials }

        let tokens = root["tokens"] as? [String: Any]
        guard let token = tokens?["access_token"] as? String, !token.isEmpty else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { throw UsageError.apiKeyMode }
            throw UsageError.noCredentials
        }
        var accountId = tokens?["account_id"] as? String
        if accountId?.isEmpty ?? true, let idToken = tokens?["id_token"] as? String {
            accountId = accountIdFromJWT(idToken)
        }
        return Credentials(accessToken: token, accountId: accountId)
    }

    /// id_token içindeki "https://api.openai.com/auth".chatgpt_account_id claim'i.
    private static func accountIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}

// MARK: - API

enum UsageAPI {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetchRaw(_ creds: Credentials) async throws -> Data {
        var request = URLRequest(url: endpoint,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = creds.accountId, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPTUsageWidget/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        switch http.statusCode {
        case 200: return data
        case 401: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
    }

    static func fetch() async throws -> UsageSnapshot {
        // auth.json her seferinde yeniden okunur: Codex token'ı yenilediğinde
        // widget yeni token'ı otomatik alır.
        let creds = try await Task.detached(priority: .utility) { try CredentialStore.load() }.value
        let data = try await fetchRaw(creds)
        guard let snapshot = UsageParser.parse(data) else { throw UsageError.badResponse }
        return snapshot
    }
}

// MARK: - Parsing

enum UsageParser {
    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var windows: [LimitWindow] = []
        if let main = root["rate_limit"] as? [String: Any] {
            windows += windowsFrom(main, idPrefix: "main", name: nil)
        }
        if let extras = root["additional_rate_limits"] as? [[String: Any]] {
            for (index, entry) in extras.enumerated() {
                let name = (entry["limit_name"] as? String)
                    ?? (entry["limit_id"] as? String)
                    ?? "Ek limit"
                let limits = (entry["rate_limit"] as? [String: Any]) ?? entry
                windows += windowsFrom(limits, idPrefix: "extra\(index)", name: name)
            }
        }
        if let review = root["code_review_rate_limit"] as? [String: Any] {
            windows += windowsFrom(review, idPrefix: "review", name: "Code review")
        }

        var credits: CreditsInfo?
        if let c = root["credits"] as? [String: Any] {
            let unlimited = (c["unlimited"] as? Bool) == true
            let hasCredits = (c["has_credits"] as? Bool) == true
            var balance: String?
            if let s = c["balance"] as? String, !s.isEmpty {
                balance = s
            } else if let n = number(c["balance"]) {
                balance = String(format: "%.2f", n)
            }
            if unlimited || hasCredits { credits = CreditsInfo(balance: balance, unlimited: unlimited) }
        }

        var resetCredits: Int?
        if let r = root["rate_limit_reset_credits"] as? [String: Any],
           let count = number(r["available_count"]), count > 0 {
            resetCredits = Int(count)
        }

        if windows.isEmpty && credits == nil { return nil }
        return UsageSnapshot(windows: windows,
                             credits: credits,
                             resetCredits: resetCredits,
                             plan: root["plan_type"] as? String,
                             fetchedAt: Date())
    }

    private static func windowsFrom(_ limits: [String: Any], idPrefix: String, name: String?) -> [LimitWindow] {
        var out: [LimitWindow] = []
        for slot in ["primary_window", "secondary_window"] {
            guard let w = limits[slot] as? [String: Any], let pct = number(w["used_percent"]) else {
                continue
            }
            let isPrimary = slot == "primary_window"
            let length = number(w["limit_window_seconds"]) ?? (isPrimary ? 5 * 3600 : 7 * 24 * 3600)
            var reset = date(w["reset_at"])
            if reset == nil, let after = number(w["reset_after_seconds"]) {
                reset = Date().addingTimeInterval(after)
            }
            out.append(LimitWindow(id: "\(idPrefix).\(slot)",
                                   title: title(name: name, length: length),
                                   percent: pct,
                                   resetsAt: reset,
                                   windowLength: length))
        }
        return out
    }

    private static func title(name: String?, length: Double) -> String {
        let isWeek = abs(length - 7 * 24 * 3600) < 3600
        let span: String
        if isWeek {
            span = "haftalık"
        } else if length < 24 * 3600 {
            span = "\(Int((length / 3600).rounded())) saat"
        } else {
            span = "\(Int((length / 86400).rounded())) gün"
        }
        if let name { return "\(name) · \(span)" }
        return isWeek ? "Haftalık" : "Oturum · \(span)"
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func date(_ any: Any?) -> Date? {
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        guard let s = any as? String else { return nil }
        if let v = Double(s) { return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Activity (yerel, ağ isteği yok)

struct ActivityInfo: Sendable {
    let open: Int          // çalışan CLI süreçleri
    let working: Int       // son 90 sn içinde kaydına yazmış oturumlar
    let agents: Int?       // son 90 sn içinde çalışmış alt agent'lar (yoksa nil)
}

/// Kullanıcının kendi süreçlerini ve argv'lerini okur (ps çalıştırmadan, sysctl ile).
enum ProcessScanner {
    struct Info {
        let execPath: String
        let argv: [String]

        var execName: String { (execPath as NSString).lastPathComponent }
        var arg0Name: String { argv.first.map { ($0 as NSString).lastPathComponent } ?? "" }
    }

    static func ownProcesses() -> [Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / stride
        return procs.prefix(count).compactMap { info(pid: $0.kp_proc.p_pid) }
    }

    private static func info(pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        let execStart = i
        while i < size && buffer[i] != 0 { i += 1 }
        let execPath = String(decoding: buffer[execStart..<i], as: UTF8.self)
        while i < size && buffer[i] == 0 { i += 1 }
        var argv: [String] = []
        while argv.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            argv.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return Info(execPath: execPath, argv: argv)
    }
}

enum ActivityScanner {
    static let workingWindow: TimeInterval = 90

    static func scan() -> ActivityInfo {
        let open = ProcessScanner.ownProcesses().filter(isCodex).count
        let recent = recentRollouts()
        return ActivityInfo(open: open,
                            working: open > 0 ? min(recent, open) : recent,
                            agents: nil)
    }

    /// Native codex süreci. npm kurulumundaki node sarmalayıcısı sayılmaz
    /// (yoksa her oturum iki kez sayılırdı).
    private static func isCodex(_ p: ProcessScanner.Info) -> Bool {
        if p.execName == "node" { return false }
        return p.execName == "codex" || p.arg0Name == "codex"
    }

    /// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — son 7 günün klasörlerinde
    /// son 90 sn içinde değişen kayıtlar (uzun süren oturumlar eski klasöre yazmaya devam eder).
    private static func recentRollouts() -> Int {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current
        let now = Date()
        let cutoff = now.addingTimeInterval(-workingWindow)
        var count = 0
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d))
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, modified > cutoff {
                    count += 1
                }
            }
        }
        return count
    }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var isLoading = false
    @Published private(set) var now = Date()
    @Published private(set) var loginItemEnabled = LoginItem.isEnabled
    @Published private(set) var activity: ActivityInfo?
    private var activityTask: Task<Void, Never>?

    private var loop: Task<Void, Never>?
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?

    static let normalInterval: TimeInterval = 60
    static let errorInterval: TimeInterval = 120
    static let rateLimitInterval: TimeInterval = 300

    func start() {
        startActivityLoop()
        startLoop()
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    func refreshNow() { startLoop() }

    /// Oturum/agent sayıları: yerel tarama, 15 sn'de bir (ağ isteği yok).
    private func startActivityLoop() {
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                let info = await Task.detached(priority: .utility) { ActivityScanner.scan() }.value
                self?.activity = info
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.set(enabled)
        loginItemEnabled = LoginItem.isEnabled
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Bir sonraki denemeye kadar beklenecek süreyi döndürür.
    private func refresh() async -> TimeInterval {
        if isLoading { return Self.normalInterval }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await UsageAPI.fetch()
            error = nil
            now = Date()
            return Self.normalInterval
        } catch let e as UsageError {
            error = e
            if case .rateLimited = e { return Self.rateLimitInterval }
            return Self.errorInterval
        } catch {
            self.error = .network(error.localizedDescription)
            return Self.errorInterval
        }
    }
}

// MARK: - Login item (LaunchAgent)

enum LoginItem {
    static let label = "com.mixedaitape.ChatGPTUsageWidget"

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ enabled: Bool) {
        if enabled {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            _ = (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let clockSeconds: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func reset(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Sıfırlandı, yenileniyor…" }
        let mins = Int(seconds / 60)
        let relative: String
        if mins < 60 {
            relative = "\(max(1, mins)) dk"
        } else if mins < 24 * 60 {
            relative = "\(mins / 60) sa \(mins % 60) dk"
        } else {
            relative = "\(mins / (24 * 60)) gün \((mins % (24 * 60)) / 60) sa"
        }
        if seconds < 24 * 3600 { return "Sıfırlanma: \(relative) sonra" }
        return "Sıfırlanma: \(day.string(from: date)) · \(relative) sonra"
    }

    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
}

func levelColor(_ percent: Double) -> Color {
    switch percent {
    case ..<50: return Color(red: 0.30, green: 0.80, blue: 0.48)
    case ..<80: return Color(red: 0.98, green: 0.73, blue: 0.22)
    default: return Color(red: 0.97, green: 0.38, blue: 0.33)
    }
}

// MARK: - Views

struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    let onSize: (CGSize) -> Void
    let onDragEnd: () -> Void

    @AppStorage("compact") private var compact = false
    @AppStorage("opacity") private var opacity = 1.0
    @AppStorage("mini") private var mini = false
    // Property-wrapper macro'ları kullanılmıyor: Command Line Tools'taki swiftc
    // SwiftUI macro eklentisini bulamıyor.
    private let drag = DragTracker()

    var body: some View {
        Group {
            if mini { miniStrip } else { fullCard }
        }
        .opacity(opacity)
        .gesture(dragGesture)
        .contextMenu { menu }
        .fixedSize()
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { onSize($0) }
        .environment(\.colorScheme, .dark)
    }

    /// Açık ve çalışan Codex oturumu sayıları (yalnızca büyük kartta).
    @ViewBuilder private var activityRows: some View {
        if let a = store.activity {
            VStack(alignment: .leading, spacing: 5) {
                Divider().opacity(0.5)
                ActivityRow(label: "Codex oturumu",
                            value: "\(a.open) açık · \(a.working) çalışıyor")
            }
            .help("Açık: Mac'te çalışan Codex süreçleri.\nÇalışıyor: son 90 sn içinde işlem yapan oturumlar.")
        }
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            header
            content
            activityRows
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: compact ? 210 : 264, alignment: .leading)
        .background(VisualEffectBackground(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Küçültülmüş hali: tek satırlık ince şerit.
    private var miniStrip: some View {
        HStack(spacing: 10) {
            brandIcon
            if let snap = store.snapshot {
                ForEach(mainWindows(snap)) { w in
                    MiniGauge(window: w)
                }
            } else {
                Text(store.error == nil ? "Yükleniyor…" : "Veri yok")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if store.error != nil {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
            }
            Button(action: { mini = false }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Büyüt")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VisualEffectBackground(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(helpText)
    }

    private func mainWindows(_ snap: UsageSnapshot) -> [LimitWindow] {
        snap.windows.filter { $0.id.hasPrefix("main.") }
    }

    private var brandIcon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 0.06, green: 0.68, blue: 0.53))
    }

    // Header: başlık, plan rozeti, son güncelleme / yenile, küçült
    private var header: some View {
        HStack(spacing: 6) {
            brandIcon
            Text("ChatGPT")
                .font(.system(size: 12, weight: .semibold))
            if let plan = store.snapshot?.plan, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.13)))
            }
            Spacer(minLength: 4)
            status
            Button(action: { mini = true }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Küçült")
        }
    }

    private var status: some View {
        Button(action: { store.refreshNow() }) {
            HStack(spacing: 4) {
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(store.error == nil ? Color.green.opacity(0.85) : Color.orange)
                        .frame(width: 5, height: 5)
                }
                if let at = store.snapshot?.fetchedAt {
                    Text(Fmt.clock.string(from: at))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["Yenilemek için tıkla"]
        if let at = store.snapshot?.fetchedAt {
            parts.append("Son güncelleme: \(Fmt.clockSeconds.string(from: at))")
        }
        if let err = store.error { parts.append(err.message) }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder private var content: some View {
        if let snap = store.snapshot {
            let rows = compact
                ? mainWindows(snap)
                : snap.windows
            ForEach(rows) { w in
                LimitRow(window: w, now: store.now, compact: compact)
            }
            if !compact, let credits = snap.credits {
                InfoRow(label: "Kredi",
                        value: credits.unlimited ? "Sınırsız" : (credits.balance ?? "Var"))
            }
            if !compact, let resets = snap.resetCredits {
                InfoRow(label: "Limit sıfırlama hakkı", value: "\(resets)")
            }
            if let err = store.error, !compact {
                Text(err.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let err = store.error {
            Text(err.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Yükleniyor…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Şimdi yenile") { store.refreshNow() }
        Toggle("Kompakt görünüm", isOn: $compact)
        Toggle("Küçük şerit", isOn: $mini)
        Menu("Saydamlık") {
            ForEach([1.0, 0.85, 0.7, 0.5], id: \.self) { value in
                Button(action: { opacity = value }) {
                    Text("%\(Int(value * 100))" + (abs(opacity - value) < 0.01 ? "  ✓" : ""))
                }
            }
        }
        Divider()
        Toggle("Girişte otomatik başlat", isOn: Binding(
            get: { store.loginItemEnabled },
            set: { store.setLoginItem($0) }
        ))
        Button("Kullanım sayfasını aç (chatgpt.com)") {
            if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
                NSWorkspace.shared.open(url)
            }
        }
        Divider()
        Button("Çık") { NSApp.terminate(nil) }
    }

    // Pencereyi sürükleme: ekran koordinatıyla, pencere hareket etse de kaymaz.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let win = NSApp.windows.first(where: { $0 is FloatingPanel }) else { return }
                let mouse = NSEvent.mouseLocation
                if drag.start == nil { drag.start = (mouse, win.frame.origin) }
                guard let start = drag.start else { return }
                win.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                           y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in
                drag.start = nil
                onDragEnd()
            }
    }
}

/// Sürükleme başlangıcını tutan küçük referans tipi (@State yerine).
final class DragTracker {
    var start: (mouse: NSPoint, origin: NSPoint)?
}

/// Etiket – değer satırı (oturum/agent sayıları).
struct ActivityRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }
}

/// Küçük şeritteki tek limit: etiket, mini bar, yüzde.
struct MiniGauge: View {
    let window: LimitWindow

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: shortLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(levelColor(window.percent).gradient)
                    .frame(width: max(3, 36 * min(max(window.percent, 0), 100) / 100))
            }
            .frame(width: 36, height: 4)
            Text(verbatim: "\(Int(window.percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor(window.percent))
        }
    }

    private var shortLabel: String {
        guard let length = window.windowLength else { return "" }
        if length >= 6 * 86400 { return "Hafta" }
        if length < 86400 { return "\(Int((length / 3600).rounded())) sa" }
        return "\(Int((length / 86400).rounded())) gün"
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let now: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(verbatim: "\(Int(window.percent.rounded()))%")
                    .font(.system(size: compact ? 12 : 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(levelColor(window.percent))
            }
            UsageBar(percent: window.percent, pace: pace)
            if !compact, let reset = window.resetsAt {
                Text(Fmt.reset(reset, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Pencerenin ne kadarı geçti (0–1). Bar üstündeki ince çizgi:
    /// doluluk bu çizginin solundaysa limitin gerisindesin, sağındaysa hızlısın.
    private var pace: Double? {
        guard let reset = window.resetsAt, let length = window.windowLength else { return nil }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0, remaining <= length else { return nil }
        return 1 - remaining / length
    }
}

struct UsageBar: View {
    let percent: Double
    let pace: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(percent, 0), 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.11))
                if clamped > 0 {
                    Capsule()
                        .fill(levelColor(percent).gradient)
                        .frame(width: max(5, width * clamped / 100))
                }
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 2, height: 10)
                        .offset(x: min(max(width * pace - 1, 0), width - 2))
                }
            }
        }
        .frame(height: 6)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }
}

/// Pencerenin arkasındaki masaüstünü bulanıklaştıran yuvarlak köşeli zemin.
struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Window

final class FloatingPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 264, height: 150),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol FitsWindow: AnyObject {
    func fitWindow()
}

/// Ekrandaki widget penceresini içeriğine göre boyutlandırır.
@MainActor
func fitFloatingPanel() {
    guard let panel = NSApp.windows.first(where: { $0 is FloatingPanel }) else { return }
    (panel.contentView as? FitsWindow)?.fitWindow()
}

/// - İlk tıklamada da tepki verir (pencere önce odak beklemez).
/// - SwiftUI içeriğinin boyutu değişince pencereyi ona göre büyütür/küçültür;
///   üst kenar sabit kalır.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content>, FitsWindow {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    func fitWindow() {
        guard let window else { return }
        var size = intrinsicContentSize
        if size.width <= 0 || size.height <= 0 { size = fittingSize }
        guard size.width > 0, size.height > 0 else { return }
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        var frame = window.frame
        guard abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 else {
            return
        }
        let top = frame.maxY
        frame.size = target
        frame.origin.y = top - target.height
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private let store = UsageStore()
    private var screenObserver: NSObjectProtocol?
    private var fitTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tek kopya: zaten açıksa yenisini kapat.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }

        panel = FloatingPanel()
        let root = WidgetView(
            store: store,
            onSize: { _ in
                DispatchQueue.main.async { fitFloatingPanel() }
            },
            onDragEnd: { [weak self] in self?.savePosition() }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        restorePosition()
        panel.orderFrontRegardless()
        store.start()
        hosting.fitWindow()
        // Yedek: içerik boyutu bir şekilde kaçırılırsa saniyede bir kontrol (değişiklik yoksa iş yapmaz).
        fitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in fitFloatingPanel() }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }
    }

    private func savePosition() {
        guard let panel else { return }
        let d = UserDefaults.standard
        d.set(panel.frame.minX, forKey: "originX")
        d.set(panel.frame.maxY, forKey: "top")
    }

    private func restorePosition() {
        let d = UserDefaults.standard
        let size = panel.frame.size
        if d.object(forKey: "originX") != nil {
            let x = d.double(forKey: "originX")
            let top = d.double(forKey: "top")
            let probe = NSPoint(x: x + 20, y: top - 10)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(probe) }) {
                panel.setFrameOrigin(NSPoint(x: x, y: top - size.height))
                return
            }
        }
        placeTopRight()
    }

    private func placeTopRight() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        // Claude widget'ının altına yerleşsin diye 210 pt aşağıda başlar.
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16,
                                     y: max(visible.minY + 16, visible.maxY - size.height - 16 - 210)))
        savePosition()
    }

    /// Monitör çıkarılırsa widget görünmez bir yerde kalmasın.
    private func keepOnScreen() {
        guard let panel else { return }
        let probe = NSPoint(x: panel.frame.minX + 20, y: panel.frame.maxY - 10)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(probe) }) {
            placeTopRight()
        }
    }
}

// MARK: - CLI diagnostics

enum CLI {
    static func run(raw: Bool) async {
        let creds: Credentials
        do {
            creds = try CredentialStore.load()
        } catch let e as UsageError {
            print("HATA: \(e.message)")
            exit(2)
        } catch {
            print("HATA: \(error.localizedDescription)")
            exit(2)
        }
        print("Token bulundu · hesap kimliği: \(creds.accountId == nil ? "yok" : "var")")
        do {
            let data = try await UsageAPI.fetchRaw(creds)
            if raw { print(String(decoding: data, as: UTF8.self)) }
            guard let snap = UsageParser.parse(data) else {
                print("HATA: yanıt ayrıştırılamadı.")
                exit(3)
            }
            print("Plan: \(snap.plan ?? "?")")
            for w in snap.windows {
                let reset = w.resetsAt.map { Fmt.reset($0, now: Date()) } ?? "sıfırlanma bilgisi yok"
                print("  \(w.title): \(Int(w.percent.rounded()))%  ·  \(reset)")
            }
            if let c = snap.credits {
                print("  Kredi: \(c.unlimited ? "sınırsız" : (c.balance ?? "var"))")
            }
            if let r = snap.resetCredits { print("  Sıfırlama hakkı: \(r)") }
            exit(0)
        } catch let e as UsageError {
            print("HATA: \(e.message)")
            exit(1)
        } catch {
            print("HATA: \(error.localizedDescription)")
            exit(1)
        }
    }
}

// MARK: - Entry point

@main
struct ChatGPTUsageWidgetMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--once") || args.contains("--raw") {
            let raw = args.contains("--raw")
            Task.detached { await CLI.run(raw: raw) }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

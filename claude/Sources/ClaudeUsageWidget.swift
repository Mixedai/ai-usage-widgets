// ClaudeUsageWidget.swift
// Claude abonelik limitlerini (5 saatlik oturum + haftalık) canlı gösteren,
// her zaman üstte duran mini masaüstü widget'ı.
//
// Veri kaynağı: Claude Code'un kendi OAuth girişi
//   - macOS Keychain: "Claude Code-credentials"
//   - ya da ~/.claude/.credentials.json
// ile https://api.anthropic.com/api/oauth/usage endpoint'i.
// Token yalnızca okunur: hiçbir yere yazılmaz, yenilenmez, loglanmaz.
//
// Derleme: ./build.sh  (ya da)
//   swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
//     -o ClaudeUsageWidget Sources/ClaudeUsageWidget.swift
//
// Teşhis: ClaudeUsageWidget --once   (özet yazdırır ve çıkar)
//         ClaudeUsageWidget --raw    (ham JSON yanıtı da yazdırır)

import AppKit
import Darwin
import SwiftUI

// MARK: - Models

struct LimitWindow: Identifiable, Sendable, Codable {
    let id: String                      // API anahtarı, örn. "five_hour"
    let title: String
    let percent: Double                 // 0–100
    let resetsAt: Date?
    let windowLength: TimeInterval?     // tempo işareti için pencere uzunluğu
}

struct ExtraUsage: Sendable, Codable {
    let used: Double?                   // USD
    let limit: Double?                  // USD
    let percent: Double?
}

struct UsageSnapshot: Sendable, Codable {
    let windows: [LimitWindow]
    let extra: ExtraUsage?
    let plan: String?
    let fetchedAt: Date
}

enum UsageError: Error, Sendable {
    case noCredentials
    case unauthorized(expired: Bool)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case badResponse

    var message: String {
        switch self {
        case .noCredentials:
            return "Claude Code girişi bulunamadı. Terminalde `claude` çalıştırıp giriş yap."
        case .unauthorized(let expired):
            return expired
                ? "Giriş anahtarının süresi dolmuş. Claude Code'u bir kez açman yeterli, widget kendini toparlar."
                : "Yetki reddedildi. Claude Code'da /login ile yeniden giriş yapmayı dene."
        case .rateLimited:
            return "Anthropic istekleri geçici olarak sınırladı (Claude Code oturumların da aynı kotayı kullanıyor). Otomatik olarak tekrar denenecek."
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
    let expiresAt: Date?
    let plan: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
}

enum CredentialStore {
    /// Her iki konumu da okur, süresi en geç dolacak olanı döndürür.
    static func load() -> Credentials? {
        let candidates = [readKeychain(), readFile()]
            .compactMap { $0 }
            .compactMap(parse)
        return candidates.max {
            ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast)
        }
    }

    private static func readFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    /// Claude Code öğeyi `security` aracıyla yazdığı için, aynı araçla okumak
    /// normalde ek bir Keychain onayı istemez.
    private static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        // `security -w` bazı durumlarda veriyi hex olarak basar.
        if !text.hasPrefix("{"), let decoded = hexDecode(text) { return decoded }
        return Data(text.utf8)
    }

    private static func hexDecode(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        return Data(bytes)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48        // 0-9
        case 65...70: return c - 55        // A-F
        case 97...102: return c - 87       // a-f
        default: return nil
        }
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let raw = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expires = Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        }
        return Credentials(accessToken: token,
                           expiresAt: expires,
                           plan: oauth["subscriptionType"] as? String)
    }
}

// MARK: - API

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetchRaw(token: String) async throws -> Data {
        var request = URLRequest(url: endpoint,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageWidget/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

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
        case 401, 403: throw UsageError.unauthorized(expired: false)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: (retryAfter ?? 0) > 0 ? retryAfter : nil)
        default: throw UsageError.http(http.statusCode)
        }
    }

    static func fetch() async throws -> UsageSnapshot {
        // Keychain her seferinde yeniden okunur: Claude Code token'ı yenilediğinde
        // widget yeni token'ı otomatik alır.
        let loaded = await Task.detached(priority: .utility) { CredentialStore.load() }.value
        guard let creds = loaded else { throw UsageError.noCredentials }
        do {
            let data = try await fetchRaw(token: creds.accessToken)
            guard let snapshot = UsageParser.parse(data, plan: creds.plan) else {
                throw UsageError.badResponse
            }
            return snapshot
        } catch UsageError.unauthorized(_) {
            throw UsageError.unauthorized(expired: creds.isExpired)
        }
    }
}

// MARK: - Parsing

enum UsageParser {
    /// Ayrı bir limit olmayan / ana limiti tekrarlayan anahtarlar.
    private static let ignored: Set<String> = ["seven_day_oauth_apps", "seven_day_omelette"]

    static func parse(_ data: Data, plan: String?) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var windows: [LimitWindow] = []
        for (key, value) in root {
            guard key == "five_hour" || key.hasPrefix("seven_day"),
                  !ignored.contains(key),
                  let window = makeWindow(key: key, value: value)
            else { continue }
            windows.append(window)
        }
        // Haftalık ana limit yoksa oauth_apps penceresini yedek olarak kullan.
        if !windows.contains(where: { $0.id == "seven_day" }),
           let fallback = makeWindow(key: "seven_day", value: root["seven_day_oauth_apps"]) {
            windows.append(fallback)
        }
        windows.sort { (rank($0.id), $0.id) < (rank($1.id), $1.id) }

        var extra: ExtraUsage?
        if let e = root["extra_usage"] as? [String: Any], (e["is_enabled"] as? Bool) == true {
            // used_credits / monthly_limit cent cinsinden geliyor.
            extra = ExtraUsage(used: number(e["used_credits"]).map { $0 / 100 },
                               limit: number(e["monthly_limit"]).map { $0 / 100 },
                               percent: number(e["utilization"]))
        }
        if windows.isEmpty && extra == nil { return nil }
        return UsageSnapshot(windows: windows, extra: extra, plan: plan, fetchedAt: Date())
    }

    private static func makeWindow(key: String, value: Any?) -> LimitWindow? {
        guard let dict = value as? [String: Any], let pct = number(dict["utilization"]) else {
            return nil
        }
        return LimitWindow(id: key,
                           title: title(for: key),
                           percent: pct,
                           resetsAt: date(dict["resets_at"]),
                           windowLength: key == "five_hour" ? 5 * 3600 : 7 * 24 * 3600)
    }

    private static func rank(_ key: String) -> Int {
        switch key {
        case "five_hour": return 0
        case "seven_day": return 1
        default: return 2
        }
    }

    private static func title(for key: String) -> String {
        switch key {
        case "five_hour": return "Oturum · 5 saat"
        case "seven_day": return "Haftalık · tüm modeller"
        case "seven_day_opus": return "Haftalık · Opus"
        case "seven_day_sonnet": return "Haftalık · Sonnet"
        case "seven_day_cowork": return "Haftalık · Cowork"
        case "seven_day_routines": return "Haftalık · Rutinler"
        default:
            let suffix = key.replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return "Haftalık · \(suffix)"
        }
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // "…T22:00:00.123456+00:00" gibi mikro saniyeli değerler için kesirli kısmı at.
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return f.date(from: String(s[..<dot]) + String(s[tz...]))
        }
        return nil
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
        let open = ProcessScanner.ownProcesses().filter(isClaudeCode).count
        let recent = recentTranscripts()
        return ActivityInfo(open: open,
                            working: open > 0 ? min(recent.sessions, open) : recent.sessions,
                            agents: recent.agents)
    }

    /// Native kurulum ("claude", ~/.local/share/claude/versions/<sürüm>), Claude masaüstü
    /// uygulamasının paketlediği claude-code ve npm (node …/claude-code/cli.js) kurulumu.
    private static func isClaudeCode(_ p: ProcessScanner.Info) -> Bool {
        if p.execName == "node" {
            guard p.argv.count > 1 else { return false }
            let script = p.argv[1]
            return script.contains("claude-code") || (script as NSString).lastPathComponent == "claude"
        }
        return p.execName == "claude"
            || p.arg0Name == "claude"
            || p.execPath.contains("/.local/share/claude/versions/")
            || p.execPath.contains("/claude-code/")
    }

    /// ~/.claude/projects altında son 90 sn içinde değişen kayıtlar:
    /// <session>.jsonl = ana oturum, …/subagents/agent-*.jsonl = alt agent.
    private static func recentTranscripts() -> (sessions: Int, agents: Int) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])
        else { return (0, 0) }
        let cutoff = Date().addingTimeInterval(-workingWindow)
        var sessions = 0
        var agents = 0
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified > cutoff
            else { continue }
            if url.path.contains("/subagents/") || url.lastPathComponent.hasPrefix("agent-") {
                agents += 1
            } else {
                sessions += 1
            }
        }
        return (sessions, agents)
    }
}

// MARK: - Store

/// Son başarılı veri diskte saklanır: uygulama yeniden açılınca hemen görünür,
/// gereksiz yere yeni istek atılmaz.
enum SnapshotCache {
    private static let key = "lastSnapshot"

    static func save(_ snapshot: UsageSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> UsageSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var isLoading = false
    @Published private(set) var now = Date()
    @Published private(set) var loginItemEnabled = LoginItem.isEnabled
    @Published private(set) var activity: ActivityInfo?
    private var activityTask: Task<Void, Never>?
    @Published private(set) var nextAttempt: Date?

    private var loop: Task<Void, Never>?
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastAttempt: Date?
    private var backoff: TimeInterval = 0          // 0 = sınırlama yok

    /// Endpoint, açık Claude Code oturumlarıyla ortak ve sıkı bir istek kotası kullanıyor.
    /// Limit yüzdeleri yavaş değiştiği için 5 dakikada bir yenilemek yeterli.
    static let normalInterval: TimeInterval = 300
    static let errorInterval: TimeInterval = 120
    static let minManualGap: TimeInterval = 60
    static let minBackoff: TimeInterval = 600       // 429 → 10 dk, sonra 20, en fazla 30 dk
    static let maxBackoff: TimeInterval = 1800

    func start() {
        startActivityLoop()
        if let cached = SnapshotCache.load() {
            snapshot = cached
            let age = Date().timeIntervalSince(cached.fetchedAt)
            startLoop(initialDelay: age < Self.normalInterval ? Self.normalInterval - age : 0)
        } else {
            startLoop()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
    }

    /// Elle yenileme: çok sık tıklamayı ve sınırlama sürerken tekrar denemeyi engeller.
    func refreshNow() {
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.minManualGap { return }
        if backoff > 0, let next = nextAttempt, next > Date() { return }
        startLoop()
    }

    private func refreshIfStale() {
        if let snap = snapshot, Date().timeIntervalSince(snap.fetchedAt) < Self.normalInterval { return }
        refreshNow()
    }

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

    /// Veri varken hata olursa gösterilecek kısa not.
    func staleNote(for error: UsageError, snapshot: UsageSnapshot) -> String {
        let shown = Fmt.clock.string(from: snapshot.fetchedAt)
        let retry = nextAttempt.map { " Tekrar deneme: \(Fmt.clock.string(from: $0))." } ?? ""
        if case .rateLimited = error {
            return "Anthropic istekleri geçici olarak sınırladı; \(shown) verisi gösteriliyor.\(retry)"
        }
        return "\(error.message) \(shown) verisi gösteriliyor."
    }

    private func startLoop(initialDelay: TimeInterval = 0) {
        loop?.cancel()
        nextAttempt = Date().addingTimeInterval(initialDelay)
        loop = Task { [weak self] in
            if initialDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            }
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Bir sonraki denemeye kadar beklenecek süreyi döndürür.
    private func refresh() async -> TimeInterval {
        if isLoading { return schedule(Self.normalInterval) }
        isLoading = true
        lastAttempt = Date()
        defer { isLoading = false }
        do {
            let fresh = try await UsageAPI.fetch()
            snapshot = fresh
            SnapshotCache.save(fresh)
            error = nil
            backoff = 0
            now = Date()
            return schedule(Self.normalInterval)
        } catch let e as UsageError {
            error = e
            if case .rateLimited(let retryAfter) = e {
                backoff = min(max(backoff * 2, Self.minBackoff), Self.maxBackoff)
                return schedule(max(backoff, retryAfter ?? 0))
            }
            return schedule(Self.errorInterval)
        } catch {
            self.error = .network(error.localizedDescription)
            return schedule(Self.errorInterval)
        }
    }

    private func schedule(_ delay: TimeInterval) -> TimeInterval {
        nextAttempt = Date().addingTimeInterval(delay)
        return delay
    }
}

// MARK: - Login item (LaunchAgent)

enum LoginItem {
    static let label = "com.mixedaitape.ClaudeUsageWidget"

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

    /// Açık oturum ve çalışan agent sayıları (yalnızca büyük kartta).
    @ViewBuilder private var activityRows: some View {
        if let a = store.activity {
            VStack(alignment: .leading, spacing: 5) {
                Divider().opacity(0.5)
                ActivityRow(label: "Claude Code oturumu",
                            value: "\(a.open) açık · \(a.working) çalışıyor")
                ActivityRow(label: "Alt agent",
                            value: (a.agents ?? 0) == 0 ? "çalışan yok" : "\(a.agents ?? 0) çalışıyor")
            }
            .help("Açık: Mac'te çalışan Claude Code süreçleri.\nÇalışıyor: son 90 sn içinde işlem yapan oturum ve alt agent'lar.")
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
        snap.windows.filter { $0.id == "five_hour" || $0.id == "seven_day" }
    }

    private var brandIcon: some View {
        Image(systemName: "chart.bar.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
    }

    // Header: başlık, plan rozeti, son güncelleme / yenile, küçült
    private var header: some View {
        HStack(spacing: 6) {
            brandIcon
            Text("Claude")
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
            if !compact, let extra = snap.extra {
                ExtraRow(extra: extra)
            }
            if let err = store.error, !compact {
                Text(store.staleNote(for: err, snapshot: snap))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange.opacity(0.9))
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
        Button("Kullanım sayfasını aç (claude.ai)") {
            if let url = URL(string: "https://claude.ai/settings/usage") {
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

struct ExtraRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Extra usage · bu ay")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(amount)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }

    private var amount: String {
        switch (extra.used, extra.limit) {
        case let (used?, limit?): return "\(Fmt.usd(used)) / \(Fmt.usd(limit))"
        case let (used?, nil): return Fmt.usd(used)
        default: return extra.percent.map { "\(Int($0.rounded()))%" } ?? "açık"
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
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16,
                                     y: visible.maxY - size.height - 16))
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
        guard let creds = CredentialStore.load() else {
            print("HATA: Claude Code girişi bulunamadı (Keychain 'Claude Code-credentials' / ~/.claude/.credentials.json).")
            exit(2)
        }
        let validity: String
        if let exp = creds.expiresAt {
            validity = exp > Date() ? "geçerli (\(Fmt.day.string(from: exp))'a kadar)" : "SÜRESİ DOLMUŞ"
        } else {
            validity = "bilinmiyor"
        }
        print("Token bulundu · plan: \(creds.plan ?? "?") · \(validity)")
        do {
            let data = try await UsageAPI.fetchRaw(token: creds.accessToken)
            if raw { print(String(decoding: data, as: UTF8.self)) }
            guard let snap = UsageParser.parse(data, plan: creds.plan) else {
                print("HATA: yanıt ayrıştırılamadı.")
                exit(3)
            }
            for w in snap.windows {
                let reset = w.resetsAt.map { Fmt.reset($0, now: Date()) } ?? "sıfırlanma bilgisi yok"
                print("  \(w.title): \(Int(w.percent.rounded()))%  ·  \(reset)")
            }
            if let e = snap.extra {
                let used = e.used.map(Fmt.usd) ?? "?"
                let limit = e.limit.map(Fmt.usd) ?? "?"
                print("  Extra usage: \(used) / \(limit)")
            }
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
struct ClaudeUsageWidgetMain {
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

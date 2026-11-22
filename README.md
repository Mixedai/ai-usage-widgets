# AI Usage Widgets

Tiny always-on-top macOS widgets that show your **live Claude (Pro/Max)** and **ChatGPT / Codex** plan limits: the 5-hour session window and the weekly window, with reset countdowns.

No menu bar clutter, no dependencies, no Xcode project. Each widget is a single Swift file you build with one command.

```
┌──────────────────────────────┐
│ ▮ Claude  MAX          17:22 │
│ Oturum · 5 saat          34% │
│ ███████░░░░░│░░░░░░░░░░░░░░░ │
│ Sıfırlanma: 2 sa 14 dk sonra │
│ Haftalık · tüm modeller  61% │
│ ████████████████│░░░░░░░░░░░ │
│ Sıfırlanma: Pzt 14:00 · …    │
└──────────────────────────────┘
```

> The UI is currently in **Turkish** 🇹🇷. English localization PRs are welcome.

## Features

- **Live limits:** session (5 h) and weekly usage %, plus per-model weekly limits when your plan has them
- **Pace marker:** the thin white tick on each bar shows how much of the window has elapsed. If the fill is left of the tick, you're fine. If it's right of the tick, you'll hit the limit before it resets.
- **Extras:** Claude extra-usage spend; Codex credits and available limit resets
- **Activity:** number of open Claude Code / Codex sessions, how many are working right now, and running Claude Code subagents. This is computed locally from your processes and transcript files (`~/.claude/projects`, `~/.codex/sessions`) with no network requests.
- Floats above all windows and on every Space. Drag to move (position is remembered).
- **Minimize** with the – button in the header: the widget collapses into a thin one-line strip (logo + mini bars + %). Click the expand icon to bring the full card back.
- Right-click menu: refresh, compact mode, mini strip, opacity, start at login, open usage page, quit
- Refresh: ChatGPT every 60 s; Claude every 5 min, because Anthropic's usage endpoint shares a strict request quota with your running Claude Code sessions. On HTTP 429 the Claude widget keeps showing the last data and backs off (10 → 20 → 30 min). The last snapshot is cached on disk, so it shows up instantly on relaunch. Click the clock to refresh now.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- **Claude widget:** logged in to [Claude Code](https://docs.claude.com/en/docs/claude-code) with a Pro/Max account
- **ChatGPT widget:** logged in to [Codex CLI](https://github.com/openai/codex) with your ChatGPT account (`codex login`)

## Install

```bash
git clone https://github.com/Mixedai/ai-usage-widgets.git
cd ai-usage-widgets

./claude/build.sh     # Claude widget
./chatgpt/build.sh    # ChatGPT / Codex widget
```

Each script compiles the app, installs it to `~/Applications`, runs a connection test and launches it.

Diagnostics:

```bash
~/Applications/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget --once   # summary
~/Applications/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget --raw    # + raw JSON
```

(Use `ChatGPTUsageWidget` instead for the ChatGPT one.)

## How it works

| | Claude | ChatGPT / Codex |
|---|---|---|
| Credentials (read-only) | macOS Keychain `Claude Code-credentials` or `~/.claude/.credentials.json` | `~/.codex/auth.json` |
| Endpoint | `api.anthropic.com/api/oauth/usage` | `chatgpt.com/backend-api/wham/usage` |

- Tokens are **only read**. They are never written, refreshed, logged or sent anywhere other than the official Anthropic / OpenAI endpoints above.
- If a token expires, open Claude Code or Codex once. The widget picks up the refreshed token automatically.
- Both endpoints are the ones the official CLIs use for their `/usage` and `/status` screens. They are **undocumented** and may change without notice. If that happens, the widget shows a parse error. Please open an issue with the `--raw` output (it contains no secrets).

## Notes for contributors

- SwiftUI's `@State` is intentionally not used: with Command Line Tools only, `swiftc` can't find the SwiftUI macro plugin. Use reference types or `ObservableObject` instead.
- `build.sh` targets `$(uname -m)-apple-macos13.0` and ad-hoc signs the bundle.

## Uninstall

Right-click the widget, turn off "Girişte otomatik başlat" (start at login), then "Çık" (quit). Delete the app from `~/Applications`.

## Disclaimer

Unofficial project, not affiliated with or endorsed by Anthropic or OpenAI. "Claude" and "ChatGPT" are trademarks of their respective owners.

---

## Türkçe

Claude (Pro/Max) ve ChatGPT/Codex plan limitlerini canlı gösteren, her zaman üstte duran mini macOS widget'ları. Kurulum için yukarıdaki iki komutu çalıştırman yeterli: `./claude/build.sh` ve `./chatgpt/build.sh`. Widget'ı sürükleyerek taşı, sağ tıkla menüyü aç. Bardaki ince beyaz çizgi pencerenin ne kadarının geçtiğini gösterir: doluluk çizginin solundaysa rahatsın, sağındaysa limiti erken bitirme yolundasın.

## License

[MIT](LICENSE)

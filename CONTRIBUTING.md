# Contributing

mnml is a personal project, made for my own use. Issues and pull requests
are welcome, but there's no promise of a quick answer.

- **Small, focused changes.** One thing per pull request.
- **No new dependencies.** Foundation, AppKit, SwiftUI and WebKit cover it.
- **Match the existing style.** Comments explain *why*, not what the next
  line does. No force-unwraps on anything that can plausibly fail.
- **Builds clean, tests pass:** `swift build`, `swift test`.
- **No real keys or tokens** anywhere: code, tests, issues, logs.

## Reporting a bug

Open an issue with what you did, what you expected, what happened instead,
and your macOS version. A crash log, if there is one, is at
`~/Library/Application Support/mnml/crash.log`.

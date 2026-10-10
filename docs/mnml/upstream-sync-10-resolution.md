# Upstream sync 10

Branch `upstream-sync-10`, from `main` (9d54fcf). Upstream range `1ec28a0..35aa051` (45 commits, to 1.0.5); picked by the user: clean fixes only.

Replayed by patch with paths mapped to `Sources/mnml` / `Tests/mnmlTests`; CHANGELOG/ROADMAP/NOTES left alone. Each commit names its upstream hash.

Included: extension hardening (file-access sites, folder links, private-tab downloads, unwrapped ports, worker links, external messaging, Chrome id from folder path), full-screen ⌘N, Esc on a question over a panel, small-window failure with Try again, per-port local icons, import offers bookmarks bar, Bookmarks menu stability, Download Linked File.

Adapted: `ExtensionShims.prepare` keeps mnml's `id:` argument (and `preparation` joins the shim version hash); 13f43de keeps mnml's `forgetPreview`; e0395ee's `remove-folder` added to mnml's bench command list; new tests import `mnml`.

Left out: 6aa05df (Open Link in New Tab behind; clashes with mnml's Peek menu item and group-aware insert), 85d8cb9 (pre-macOS 26 popovers), 9dca797 (bench pins.json wait), sidebar/tab UI (a1c846b, 764c52f, 41920f8, ca8e421, 6586825), a1cb16e, Arc folders/pins (3f1d096, 5a96af8), upstream Split View (d8c33c8, 5d819d4, 463e534), AI (643838e), docs.

Validation: `swift build` ok; `swift test` 294 run, only DownloadLifecycleTests fail (network-dependent; also fail on `main`). No hands-on QA yet.

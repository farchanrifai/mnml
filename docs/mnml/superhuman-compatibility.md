Superhuman Mail compatibility — 3 October 2026

The official extension (dcgcnpooblobhncpnddnhoendgbnglpn, 3.1.61001.1906) opened https://mail.superhuman.com correctly. Its public page detected Safari, lacked webkitRequestFileSystem, and showed a Get Started Now link to https://superhuman.com/download. This was a page capability gate, rather than an HTTP redirect or an extension URL rewrite. [Superhuman's public documentation](https://superhuman.com/apps/mail) describes its browser version as requiring the Chrome extension.

The existing Drive user-agent exception now also covers the exact mail.superhuman.com host. Every other navigation restores the Safari identity. Only the official Superhuman extension's externally-connectable script supplies that HTTPS host with mnml's existing OPFS-backed filesystem adapter. The adapter is shared with extension pages and retains its native-API and same-origin guards. Preparation receives the trusted extension ID so the same behavior applies to fresh installation, updates in staging folders, and installed packages.

Superhuman's offscreen document also crashed while awaiting navigator.getBattery(). The shared extension shim supplies a cached promise and native EventTarget with readonly unavailable-data defaults (charging true, chargingTime 0, dischargingTime Infinity, level 1), following the [Battery Status draft's defaults](https://www.w3.org/TR/battery-status/#the-batterymanager-interface). It preserves native implementations and exposes no fallback to websites, content scripts or service workers. It does not measure or publish the Mac's battery state.

Verified in the separate superhuman-login-20261003 profile, build 202610030130:

- Pressing the installed official extension opens Sign in with Google / Sign in with Microsoft; the download link is absent. The actual page screenshot was inspected.
- The real filesystem adapter wrote, read and removed one unique temporary file in that profile.
- Navigating the same tab from Superhuman to example.com restored Safari identity and left the Chrome filesystem/battery APIs absent.
- The extension remained loaded, with no startup or reported errors.
- Four extension scripting checks cover package staging, exact host boundaries, native API preservation and the battery fallback's scope/identity/defaults. The selected app suite passed 126 tests. The previously intermittent DownloadLifecycleTests were excluded.
- Release build and both bundle signatures passed; the development signature was verified with keychain access. SDK 27.0, deployment target 14.0.

Authenticated OAuth completion and mail use remain for the user to validate. No account credentials, cookies or mail content were read. The installed daily app/profile were not changed.

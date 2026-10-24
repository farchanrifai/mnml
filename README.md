# mnml

A minimal web browser for the Mac, built on WebKit.

mnml is a personal project, made for my own use. You're welcome to build it and use it yourself.

mnml began as a fork of [Search](https://github.com/driceroland/Search) by [Office Commun](https://officecommun.com) and now goes its own way. Among what it adds:

- Tab groups in the sidebar, named for you by Apple Intelligence
- Split view: two tabs side by side
- ⌃Tab switches between tabs in the order you last used them
- Tab previews on hover, and peek for links from pinned tabs
- Custom keyboard shortcuts
- Tabs sleep when idle, and a guard for pages that use too much memory
- Touch ID for 1Password
- Close tabs above or below

And fixes and improvements:

- Links from a tab in a group open in the group; links from other apps open like a new tab
- ⌘⇧T puts a tab back in the group it was closed from
- Close Other Tabs leaves pinned tabs alone
- After ⌘-click, ⌃Tab goes to the new tab
- Google Sheets keeps its sideways scroll instead of going back
- Many heavy tabs (Google Docs and Sheets) no longer slow the Mac down
- Group names stay readable on hover

## No paid developer account

mnml is made to be built and signed without a paid Apple Developer account: signed with a free or self-made certificate, and not notarized. Features that need a paid account are replaced with workarounds where there is one:

- **1Password:** its desktop app only trusts browsers with a paid Developer ID, so it can't unlock the extension. mnml keeps the 1Password password in your Mac's keychain instead, behind Touch ID.
- **Passkeys:** the passkey entitlement needs a paid account; passkeys go through password manager extensions.
- **Opening it the first time:** macOS may warn that it can't check the app. Right-click it in Applications and choose Open.
- **Updates:** off; build again to update.

## Build

macOS 14 or later, with the Xcode command-line tools.

```sh
./build.sh release install
```

## Feedback

[Open an issue](https://github.com/farchanrifai/mnml/issues).

## Credit

Search is by Office Commun. mnml keeps its license; see [LICENSE](LICENSE).

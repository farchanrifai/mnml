# Upstream sync 7: conflict choices

The merge is staged on `upstream-sync-7` and deliberately uncommitted pending
the mnml Test pass. These choices follow the handoff's mnml-first rules.

| Conflict | Choice and reason |
| --- | --- |
| `CHANGELOG.md` | Kept both histories, as required for the upstream changelog. |
| `Search.sdef` | Kept upstream's new read-only scripting dictionary, with mnml's public name. |
| `AddressCommands.swift` | Added upstream's address commands, routed through mnml's command and preference model. |
| `App.swift` | Added upstream's multiple-window scene and New Window action; kept mnml's keyboard routing, menus, chat actions, and chrome. |
| `Bench.swift` and `bench` | Combined both command sets so upstream's window probes and mnml's existing probes remain available. |
| `Browser.swift` | Added upstream's window records, shared pins, moves and imports; kept mnml's groups, splits, chats, side panels, key router and session entry builder. Every window row uses that builder. |
| `ExtensionShims.swift` | Kept mnml's external bridge and group -1 contract; added window-aware tab and panel ownership. |
| `Float.swift` | Took upstream's docking and landing improvements while retaining mnml's scroll save and restoration. |
| `History.swift` | Kept mnml's command suggestion identity and added upstream's command constructor. |
| `ImportArc.swift` | Added Arc import for spaces, favourites and tabs; omitted upstream tab groups because mnml has its own group model. |
| `ImportRecord.swift` | Added upstream's import record type for the new import flow. |
| `Keyword.swift` | Added upstream's site keyword support. |
| `Links.swift` | Retained mnml's media cleanup across every window and added upstream's window flush. |
| `Peek.swift` | Kept mnml's peek behavior and shortcut help. |
| `Pins.swift` | Added upstream's shared pin definitions, keeping mnml's pin home behavior. |
| `Prefs.swift` | Retained mnml's appearance, command bar and left sidebar settings; added applicable upstream preferences, including lazy tabs. |
| `Scripting.swift` | Added upstream's read-only AppleScript support, naming the browser mnml. |
| `Session.swift` | Kept the synthesized entry decoder and mnml's group, split and chat fields; added upstream's `pinID` and lenient shape decoding. |
| `Settings.swift` | Kept mnml's controls and added applicable upstream controls; omitted upstream groups and right-sidebar controls. |
| `SiteCard.swift` | Kept mnml's site permissions and added upstream's autoplay sound control, targeting the owning window. |
| `Spaces.swift` | Added upstream's window-aware space handling while retaining mnml's groups. |
| `Stage.swift` | Used upstream's updated comment and kept mnml's page-under padding. |
| `Swipe.swift` | Kept mnml's hold-to-choose history swipe instead of the competing upstream implementation. |
| `Tab.swift` | Added window and shared-pin support, autoplay, and upstream tab changes; retained mnml's reading and pin-home behavior. |
| `TabBar.swift` | Kept mnml's group-aware strip drag; added upstream Move to Window, Put to Sleep, and drag-out behavior. |
| `WhatsNew.swift` | Added upstream's card with mnml branding; removed claims for upstream groups and right sidebar. |
| `Windows.swift` | Added upstream's window registry and persistence with mnml's session data contract. |
| `Sources/Search/{Find,Shortcuts,ShortcutsPage,Side}.swift` | Removed the duplicate upstream-path files and ported applicable changes into mnml's `Find`, `Shortcuts`, `Side` and tab strip: find focus, New Window and Import commands, balanced pins and window-aware drag. |

Packaging check also exposed upstream Icon Composer code that referred to absent
Search mark variables. The asset now draws mnml's Morse mark using its existing
dimensions, and `./build.sh release test` completes with `Assets.car` present.

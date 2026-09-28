import AppKit
import Darwin
import WebKit

// What each tab's page holds in memory, and a guard for the ones that run
// away. A Google Sheet reached ten gigabytes in six minutes one night
// (25 Sep 2026): the Mac swapped, and everything crawled. A page in the
// background past the selected profile's limit is put to sleep, as an idle one would be; the
// page on screen past four is only named — reloading it could lose what you
// are doing there — and named again only if it grows by two more.

extension Tab {
    /// The page's process, while there is one.
    var processID: pid_t? {
        guard let built, built.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (built.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    /// What the page's process holds, as Activity Monitor's Memory column
    /// counts it. Tabs that share a process each show all of it.
    var footprint: UInt64? {
        guard let pid = processID else { return nil }
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        return ok ? info.ri_phys_footprint : nil
    }
}

extension Browser {
    static let foregroundLimit: UInt64 = 4 << 30

    /// Run with the sleep timer, once a minute.
    func watchMemory() {
        for tab in tabs + parkedTabs where !tab.asleep {
            guard let size = tab.footprint else { continue }
            if awake(because: tab) == "on screen" {
                let last = memoryWarned[tab.id] ?? 0
                if size >= Browser.foregroundLimit, size >= last + (2 << 30) {
                    memoryWarned[tab.id] = size
                    announce("This page is using \(Browser.gigabytes(size)) — ⌘R reloads it")
                }
            } else if size >= prefs.tabMemoryProfile.policy.background {
                sleep(tab)
            }
        }
        memoryWarned = memoryWarned.filter { id, _ in tabs.contains { $0.id == id } }
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        bytes >= 1 << 30
            ? String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
            : "\(bytes >> 20) MB"
    }
}

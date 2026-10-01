import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone long enough gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, a tab playing sound, on a call, sending a
// download, holding its video out in the little window, or holding something
// typed and not sent. Pinned tabs wait longer than ordinary tabs.
//
// And however recently used, only the profile's most recent unpinned tabs stay awake: a day of
// heavy pages — Google Sheets at a gigabyte or more each — otherwise piled up
// until the Mac was swapping, and everything, ⌃Tab too, crawled.
//
// When macOS says memory is short, the waits shrink; critical pressure
// sleeps every eligible background tab.

extension Browser {
    /// `sleep.after` and `sleep.awake` are bench overrides.
    var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        return set > 0 ? set : prefs.tabMemoryProfile.policy.idle
    }

    var awakeCap: Int {
        let set = Store.settings.integer(forKey: "sleep.awake")
        return set > 0 ? set : prefs.tabMemoryProfile.policy.awake
    }

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.sleepIdle(within: event.contains(.critical) ? 0 : self.prefs.tabMemoryProfile.policy.warning)
            }
        }
        source.resume()
        pressure = source
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? sleepAfter
        let now = Date()
        // The rows of the other spaces too: parked is not the same as used.
        let free = (tabs + parkedTabs).filter { awake(because: $0) == nil }
        let idle = free
            .filter { now.timeIntervalSince($0.touched) >= ($0.pin != nil && given == nil ? prefs.tabMemoryProfile.policy.pinned : wait) }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab) }
        // Past the cap, the least recently used go too, whatever the clock —
        // though never one left only a minute ago, so going back and forth
        // between a few doesn't reload them.
        let over = free
            .filter { tab in tab.pin == nil && !idle.contains { $0 === tab } && now.timeIntervalSince(tab.touched) >= 60 }
            .sorted { $0.touched > $1.touched }
            .dropFirst(max(0, awakeCap - 1))
        for tab in over { self.sleep(tab) }
        watchMemory()
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        if tab.id == activeID || split(of: activeID)?.has(tab.id) == true { return "on screen" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard tab.built != nil else { return "no page" }
        return activityKeeping(tab)
    }

    func activityKeeping(_ tab: Tab) -> String? {
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if SiteNotifications.keepsAwake(tab) { return "sends notifications" }
        if tab.floating || floating == tab.id || systemPiP == tab.id { return "its video is out" }
        if heldDialogs[tab.id]?.isEmpty == false { return "a question waiting" }
        if window?.attachedSheet != nil { return "a dialog is open" }
        if active?.opener == tab.id { return "the page on screen came from it" }
        guard let web = tab.built else { return nil }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab) {
            done?(reason)
            return
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                self.tabSwitcher.rememberPreview(of: tab)
                done?("asleep")
            }
        }
    }
}

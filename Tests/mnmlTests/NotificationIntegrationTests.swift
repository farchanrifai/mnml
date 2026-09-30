import XCTest
import AppKit
@testable import mnml

@MainActor
final class NotificationIntegrationTests: XCTestCase {
    func testPermissionMigrationResetAndSleepProtection() {
        _ = NSApplication.shared
        let host = "notify-\(UUID().uuidString.lowercased()).example"
        let origin = "https://\(host)"
        let legacy = Notify.key(host)
        let key = SiteNotifications.key(origin)
        let enabled = Shared.prefs.siteNotifications
        defer {
            Store.settings.removeObject(forKey: legacy)
            Store.settings.removeObject(forKey: key)
            Shared.prefs.siteNotifications = enabled
        }
        Store.settings.set(true, forKey: legacy)
        XCTAssertEqual(SiteNotifications.choices[origin], true)
        XCTAssertNil(Store.settings.object(forKey: legacy))
        XCTAssertNil(SiteNotifications.choices["http://\(host)"])
        XCTAssertNil(SiteNotifications.choices["https://\(host):8443"])
        XCTAssertEqual(SiteNotifications.origin(URL(string: origin + ":443/path")!), origin)

        let tab = Tab()
        tab.setAddressOptimistically(URL(string: origin)!)
        Shared.prefs.siteNotifications = true
        XCTAssertTrue(SiteNotifications.keepsAwake(tab))
        Shared.prefs.siteNotifications = false
        XCTAssertFalse(SiteNotifications.keepsAwake(tab))
        Shared.prefs.siteNotifications = true
        let privateTab = Tab(shy: true)
        privateTab.setAddressOptimistically(URL(string: origin)!)
        XCTAssertFalse(SiteNotifications.keepsAwake(privateTab))

        SiteNotifications.set(false, for: origin)
        XCTAssertFalse(SiteNotifications.keepsAwake(tab))
        Store.settings.set(true, forKey: legacy)
        XCTAssertEqual(SiteNotifications.choices[origin], false, "Explicit origin choice wins")
        SiteNotifications.forget(origin)
        XCTAssertNil(SiteNotifications.choices[origin], "Reset must not resurrect legacy permission")
    }
}

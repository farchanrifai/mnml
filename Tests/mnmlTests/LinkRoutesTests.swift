import XCTest
import AppKit
@testable import mnml

@MainActor
final class LinkRoutesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var routes: LinkRoutes!
    private var suite: String!
    private let work = Space(id: UUID(), name: "Work", colour: 0, icon: nil)
    private let personal = Space(id: UUID(), name: "Personal", colour: 0, icon: nil)

    override func setUp() {
        suite = "mnml.routes.test." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        routes = LinkRoutes(defaults: defaults)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func match(_ text: String, enabled: Bool = true) -> UUID? {
        routes.destination(for: URL(string: text)!, spaces: [work, personal], enabled: enabled)
    }

    func testNormalizationAndDomainBoundaries() {
        XCTAssertEqual(LinkRoutes.domain(" HTTPS://Example.COM./ "), "example.com")
        XCTAssertEqual(LinkRoutes.domain("bücher.de"), LinkRoutes.domain("xn--bcher-kva.de"))
        for bad in ["", ".example.com", "example..com", "*.example.com", "https://user@example.com", "example.com:443", "example.com/path", "example.com?q=x", "example.com#x", "-example.com", "file://example.com"] {
            XCTAssertNil(LinkRoutes.domain(bad), bad)
        }
        XCTAssertNil(routes.save(LinkRule(domain: "EXAMPLE.com", destination: work.id)))
        XCTAssertEqual(match("https://a.example.com/x"), work.id)
        XCTAssertEqual(match("https://example.com./x"), work.id)
        XCTAssertNil(match("https://badexample.com"))
        XCTAssertNil(match("https://example.com.evil.test"))
        XCTAssertNil(match("https://evil.test/?url=example.com"))
        XCTAssertNil(match("file:///example.com"))
        XCTAssertNil(match("httpx://example.com"))
        XCTAssertNil(match("https://example.com", enabled: false))
    }

    func testSpecificityDuplicatesAndDisabledRules() {
        let broad = LinkRule(domain: "example.com", destination: work.id)
        XCTAssertNil(routes.save(broad))
        XCTAssertNotNil(routes.save(LinkRule(domain: "example.com", destination: personal.id)))
        var child = LinkRule(domain: "team.example.com", destination: personal.id)
        XCTAssertNil(routes.save(child))
        XCTAssertEqual(match("https://sub.team.example.com"), personal.id)
        XCTAssertNil(routes.save(LinkRule(domain: "sub.team.example.com", includeSubdomains: false, destination: work.id)))
        XCTAssertEqual(match("https://sub.team.example.com"), work.id)
        XCTAssertEqual(match("https://deeper.sub.team.example.com"), personal.id)
        child.enabled = false
        XCTAssertNil(routes.save(child))
        XCTAssertEqual(match("https://deeper.sub.team.example.com"), work.id)
    }

    func testPersistenceStableIDsAndDeletion() {
        XCTAssertNil(routes.save(LinkRule(domain: "example.com", destination: work.id)))
        let reloaded = LinkRoutes(defaults: defaults)
        var renamed = work; renamed.name = "Renamed"
        XCTAssertEqual(reloaded.destination(for: URL(string: "https://example.com")!, spaces: [renamed], enabled: true), work.id)
        XCTAssertNil(reloaded.destination(for: URL(string: "https://example.com")!, spaces: [], enabled: true))
        reloaded.remove(space: work.id)
        XCTAssertTrue(LinkRoutes(defaults: defaults).rules.isEmpty)
    }

    func testDeliveryCreatesNewTabsUsingDestinationStoreAndTypedURLsBypassIt() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let old = browser.prefs.usesSpaces, current = Spaces.current
        defer { browser.closeAll(); browser.prefs.usesSpaces = old; Spaces.current = current }
        browser.prefs.usesSpaces = true
        browser.spaces.append(work)
        XCTAssertNil(routes.save(LinkRule(domain: "127.0.0.1", destination: work.id)))
        let url = URL(string: "http://127.0.0.1:9/routed")!
        let original = browser.spaceID
        let typed = browser.open(url, foreground: true)
        XCTAssertEqual(browser.spaceID, original)
        XCTAssertTrue(typed.store === Spaces.store(for: original))
        XCTAssertTrue(browser.routeExternal(url, using: routes))
        XCTAssertEqual(browser.spaceID, work.id)
        let first = browser.active!
        XCTAssertTrue(first.store === Spaces.store(for: work.id))
        XCTAssertFalse(first.store === typed.store)
        let count = browser.tabs.count
        XCTAssertTrue(browser.routeExternal(url, using: routes))
        XCTAssertEqual(browser.tabs.count, count + 1)
        XCTAssertFalse(browser.active === first)
        AddressCommand.routingSettings.run(on: browser)
        XCTAssertEqual(browser.settingsPage, .links)
        XCTAssertTrue(browser.tuning)
    }
}

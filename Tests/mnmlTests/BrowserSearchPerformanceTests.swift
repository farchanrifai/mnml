import AppKit
import XCTest
@testable import mnml

@MainActor
final class BrowserSearchPerformanceTests: XCTestCase {
    func testOpenPageSuggestionsPreserveRecencyMatchingAndTies() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let actions = browser.prefs.commandActions
        defer { browser.prefs.commandActions = actions; browser.closeAll() }
        let row = (0..<40).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://search-audit.example/\(index)")!, title: index.isMultiple(of: 2) ? "Été Project \(index)" : "Other \(index)")
            tab.touched = Date(timeIntervalSince1970: Double(index / 2))
            return tab
        }
        browser.arrange(row)
        browser.activeID = row[39].id
        browser.summon()
        for fuzzy in [false, true] {
            browser.prefs.commandActions = fuzzy
            for query in ["", "Project", "ÉTÉ", "search-audit", "project été", "missing"] {
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let expected = row.filter { tab in
                    guard tab.id != browser.activeID else { return false }
                    if needle.isEmpty { return true }
                    let address = Address.pretty(tab.address!)
                    if fuzzy {
                        return CommandRank.match(needle, text: tab.label) != nil || CommandRank.match(needle, text: address) != nil
                    }
                    return tab.label.lowercased().contains(needle) || address.lowercased().contains(needle)
                }.sorted { $0.touched > $1.touched }.prefix(needle.isEmpty ? 6 : 3).map(\.id)
                browser.typed = query
                XCTAssertEqual(browser.offers.compactMap(\.tab), expected, "query=\(query), fuzzy=\(fuzzy)")
            }
        }
        XCTAssertTrue(row.filter { $0.id != browser.activeID }.allSatisfy { $0.built == nil }, "Searching must keep background pages lazy")
    }

    func testLargeOpenPageSearchMeasurement() throws {
        guard ProcessInfo.processInfo.environment["MNML_PERFORMANCE_MEASURE"] != nil else { throw XCTSkip("Opt-in release fixture measurement") }
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let actions = browser.prefs.commandActions
        defer { browser.prefs.commandActions = actions; browser.closeAll() }
        browser.prefs.commandActions = true
        let row = (0..<1_000).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://search-audit.example/\(index)")!, title: "Project Page \(index)")
            tab.touched = Date(timeIntervalSince1970: Double((index * 37) % 1_000))
            return tab
        }
        browser.arrange(row)
        browser.activeID = nil
        browser.summon()
        let queries = ["", "Project", "Page", "search-audit", "missing"]
        for query in queries { browser.typed = query }
        var samples: [Double] = []
        for _ in 0..<100 {
            for query in queries {
                let start = CFAbsoluteTimeGetCurrent()
                browser.typed = query
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            }
        }
        samples.sort()
        print("MNML_SEARCH_MEASUREMENT samples=\(samples.count) median_ms=\(samples[samples.count / 2]) p95_ms=\(samples[samples.count * 95 / 100])")
        XCTAssertLessThanOrEqual(browser.offers.count, 6)
        XCTAssertTrue(row.allSatisfy { $0.built == nil })
    }
}

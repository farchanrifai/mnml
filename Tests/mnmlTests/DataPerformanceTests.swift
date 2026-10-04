import Foundation
import Combine
import XCTest
@testable import mnml

final class DiskPerformanceTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testOvertakenSnapshotsAreSkippedBeforeEncodingWithoutDroppingOtherFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); Disk.drain() }
        Disk.write(folder.appendingPathComponent("blocker")) {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return Data()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let stale = Counter()
        let target = folder.appendingPathComponent("target")
        let other = folder.appendingPathComponent("other")
        Disk.write(target) {
            stale.increment()
            return Data("old".utf8)
        }
        Disk.write(other) { Data("independent".utf8) }
        Disk.write(target) { Data("latest".utf8) }
        release.signal()
        Disk.drain()

        XCTAssertEqual(stale.count, 0)
        XCTAssertEqual(try Data(contentsOf: target), Data("latest".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("independent".utf8))
    }

    func testSynchronousCommitStillSupersedesAWriteAlreadyEncoding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("target")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); Disk.drain() }
        Disk.write(file) {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return Data("old".utf8)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        try Disk.commit(file, data: Data("quit".utf8))
        release.signal()
        Disk.drain()

        XCTAssertEqual(try Data(contentsOf: file), Data("quit".utf8))
    }
}

final class BookmarkParserPerformanceTests: XCTestCase {
    func testReusedExpressionsPreserveMixedCaseAttributesMarkupAndEntities() {
        let html = #"""
        <dL><H3 personal_toolbar_folder='true'>Bar</H3><DL>
        <a hReF='https://example.test/?a=1&amp;b=2'><b>One</b> &#65; &amp;lt;</a>
        <A HREF=https://other.test/>Two &#x1F338;</A>
        </DL></dL>
        """#
        for _ in 0..<3 {
            let parsed = BookmarksFile.parse(html)
            XCTAssertEqual(parsed.map(\.title), ["One A &lt;", "Two 🌸"])
            XCTAssertEqual(parsed.map(\.url), ["https://example.test/?a=1&b=2", "https://other.test/"])
        }
    }
}

@MainActor
final class HistoryPerformanceTests: XCTestCase {
    func testRepeatImportDoesNotInvalidateHistoryWhenNothingChanged() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = History(file: file)
        let url = URL(string: "https://example.test/article")!
        let last = Date(timeIntervalSince1970: 100)
        history.take(url, title: "Page", count: 3, last: last)
        var changes = 0
        let watch = history.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        history.take(url, title: "Page", count: 3, last: last)
        history.take(url, title: "Ignored title", count: 2, last: last.addingTimeInterval(-1))
        XCTAssertEqual(changes, 0)

        history.take(url, title: "Page", count: 4, last: last.addingTimeInterval(1))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(history.recent().first?.count, 4)
    }

    func testRecentMatchesFullHistoryForLargeInputAndRefreshesAfterRemoval() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = History(file: file)
        for index in 0..<3_000 {
            history.take(URL(string: "https://site\(index).example/article")!, title: "Page \(index)",
                         count: index + 1, last: Date(timeIntervalSince1970: Double(index)))
        }
        history.take(URL(string: "https://credit.example/")!, title: "", count: 20,
                     last: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(history.recent(), Array(history.everything().prefix(8)))

        let newest = try XCTUnwrap(history.recent().first)
        history.forget(newest.key)
        XCTAssertEqual(history.recent(), Array(history.everything().prefix(8)))
        XCTAssertEqual(history.recent().count, 8)
        history.flush()
    }

    func testRecentSkipsUnreadableURLsBeforeChoosingItsEightRows() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var visits: [[String: Any]] = (0..<10).map { index in
            let url = "https://site\(index).example/article"
            return ["url": url, "key": url, "title": "Page \(index)", "count": 1, "last": index]
        }
        visits.append(["url": "http://[", "key": "broken", "title": "Broken", "count": 1, "last": 100])
        try JSONSerialization.data(withJSONObject: visits).write(to: file)
        let history = History(file: file)

        XCTAssertEqual(history.recent(), Array(history.everything().prefix(8)))
        XCTAssertEqual(history.recent().count, 8)
    }

    func testFlushPersistsTheLatestTitleBeforeTheDebounceFires() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = History(file: file)
        let url = URL(string: "https://example.test/article")!
        history.record(url, title: "First title")
        history.retitle(url, "Final title")
        history.flush()
        Disk.drain()

        let restored = History(file: file)
        XCTAssertEqual(restored.everything().map(\.title), ["Final title"])
        XCTAssertEqual(restored.everything().first?.url, url)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history.json")
    }
}

@MainActor
final class BookmarkPerformanceTests: XCTestCase {
    func testMoveTargetsKeepOrderAndExcludeOnlyTheFoldersOwnSubtree() {
        let leaf = Bookmark.site("Leaf", URL(string: "https://example.test/")!)
        let nested = Bookmark.folder("Nested", [leaf])
        let folder = Bookmark.folder("Folder", [nested])
        let sibling = Bookmark.folder("Sibling", [])
        let ancestor = Bookmark.folder("Ancestor", [folder, sibling])
        let other = Bookmark.folder("Other", [])
        let folders = Bookmarks.folders([ancestor, other])

        XCTAssertEqual(Bookmarks.moveTargets(for: leaf, among: folders).map(\.node.id), folders.map(\.node.id))
        XCTAssertEqual(Bookmarks.moveTargets(for: folder, among: folders).map(\.node.id), [ancestor.id, sibling.id, other.id])
        XCTAssertEqual(Bookmarks.moveTargets(for: folder, among: folders).map(\.depth), [0, 1, 0])
    }
}

@MainActor
final class DownloadProgressPerformanceTests: XCTestCase {
    func testBurstOfProgressChangesQueuesOneRefreshAndCanScheduleAgain() async {
        let refresh = DownloadProgressRefresh()
        var updates = 0
        let first = expectation(description: "First progress refresh")
        for _ in 0..<100 {
            refresh.schedule {
                updates += 1
                first.fulfill()
            }
        }
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(updates, 1)

        let next = expectation(description: "Later progress refresh")
        refresh.schedule {
            updates += 1
            next.fulfill()
        }
        await fulfillment(of: [next], timeout: 5)
        XCTAssertEqual(updates, 2)
    }
}

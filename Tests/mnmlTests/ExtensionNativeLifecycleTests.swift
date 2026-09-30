import XCTest
@testable import mnml

@available(macOS 15.4, *)
final class ExtensionNativeLifecycleTests: XCTestCase {
    private func host(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mnml-host-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRepeatedConnectionsDeliverAndReleaseCallbacks() async throws {
        let program = try host("exec /bin/cat")
        for _ in 0..<20 {
            weak var released: HostPipe?
            let delivered = expectation(description: "message")
            let exited = expectation(description: "exit once")
            do {
                let pipe = HostPipe(program: program, origin: "chrome-extension://fixture/")
                released = pipe
                // Exercise a self-retaining client callback too: stop must clear it.
                pipe.onMessage = { [pipe] message in
                    XCTAssertEqual((message as? [String: Int])?["value"], 42)
                    _ = pipe
                    delivered.fulfill()
                }
                pipe.onExit = { exited.fulfill() }
                try pipe.start()
                try pipe.write(["value": 42])
                await fulfillment(of: [delivered], timeout: 2)
                pipe.stop()
                pipe.stop()
                await fulfillment(of: [exited], timeout: 2)
                XCTAssertNil(pipe.onMessage)
                XCTAssertNil(pipe.onExit)
            }
            XCTAssertNil(released, "old native host must deallocate")
        }
    }

    func testStopResumesPendingAndLateReads() async throws {
        let pipe = HostPipe(program: try host("exec /bin/cat"), origin: "fixture")
        try pipe.start()
        let waiting = Task { try await pipe.readOne() }
        try await Task.sleep(nanoseconds: 20_000_000)
        pipe.stop()
        do { _ = try await waiting.value; XCTFail("pending read should fail") } catch {}
        do { _ = try await pipe.readOne(); XCTFail("read after exit should fail immediately") } catch {}
    }

    func testNaturalExitCleansUpOnce() async throws {
        let exited = expectation(description: "natural exit once")
        let pipe = HostPipe(program: try host("exit 0"), origin: "fixture")
        pipe.onExit = { exited.fulfill() }
        try pipe.start()
        await fulfillment(of: [exited], timeout: 2)
        pipe.stop()
        pipe.stop()
        XCTAssertNil(pipe.onExit)
    }
}

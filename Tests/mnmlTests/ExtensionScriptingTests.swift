import Foundation
import JavaScriptCore
import AppKit
import WebKit
import XCTest
@testable import mnml

@available(macOS 15.4, *)
@MainActor
final class ExtensionScriptingTests: XCTestCase {
    func testSuperhumanShimWorksFromStagingAndKeepsOtherPackagesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "dcgcnpooblobhncpnddnhoendgbnglpn"
        for (name, identity) in [(".staging-\(id)-test", id), (id, id), (".staging-local-test", "local-test")] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"Mail fixture","version":"1.0","externally_connectable":{"matches":["https://mail.superhuman.com/*"]}}"#
                .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try ExtensionShims.prepare(folder, id: identity, fresh: true)
            let page = try String(contentsOf: folder.appendingPathComponent(ExtensionShims.externalFile), encoding: .utf8)
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
            var window = { __mnmlExternal: true };
            var document = {};
            var location = { protocol: "https:", hostname: "mail.superhuman.com", origin: "https://mail.superhuman.com" };
            var navigator = { storage: { getDirectory: () => Promise.reject(new Error("not opened")) } };
            var Element = class { setAttribute() {} };
            var EventTarget = class {};
            """)
            context.evaluateScript(page)
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("typeof webkitRequestFileSystem === 'function'")?.toBool(), identity == id)
        }
    }

    func testSiteUserAgentIsRestrictedToCompatibilityHosts() throws {
        for host in ["drive.google.com", "mail.superhuman.com", "MAIL.SUPERHUMAN.COM"] {
            XCTAssertTrue(try XCTUnwrap(Web.userAgent(for: URL(string: "https://\(host)/")!)).contains("Chrome/"))
        }
        for address in ["https://accounts.google.com/", "https://superhuman.com/", "https://mail.superhuman.com.example/",
                        "https://mail.superhuman.com@example.com/", "about:blank"] {
            XCTAssertNil(Web.userAgent(for: URL(string: address)!))
        }
    }

    func testMissingBatteryAPIStaysInExtensionDocuments() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        for (content, worker, native) in [(false, false, false), (true, false, false),
                                         (false, true, false), (false, false, true)] {
            let body = """
            const inContent = content;
            const navigator = {};
            const original = () => Promise.resolve("native");
            if (native) navigator.getBattery = original;
            const put = (target, key, value) => Object.defineProperty(target, key, { value });
            \(ExtensionShims.battery)
            if (native) return navigator.getBattery === original;
            if (content || worker) return navigator.getBattery === undefined;
            const first = navigator.getBattery();
            const battery = await first;
            battery.charging = false;
            const listener = () => {};
            battery.addEventListener("chargingchange", listener);
            battery.removeEventListener("chargingchange", listener);
            return first === navigator.getBattery() && battery === await navigator.getBattery()
                && battery instanceof EventTarget && battery.charging === true && battery.chargingTime === 0
                && battery.dischargingTime === Infinity && battery.level === 1;
            """
            let result = try await web.callAsyncJavaScript(body, arguments: ["content": content, "worker": worker, "native": native], in: nil, contentWorld: .page)
            XCTAssertEqual(result as? Bool, true)
        }
    }

    func testForwardedFunctionKeepsArgumentsAndResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let path = try ExtensionShims.scriptingFile("(value, amount) => value + amount", arguments: ["clip", 2], in: folder)
        let source = try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        XCTAssertEqual(context.evaluateScript(source)?.toString(), "clip2")
        XCTAssertEqual(try ExtensionShims.scriptingFile("(value, amount) => value + amount", arguments: ["clip", 2], in: folder), path)
        // Past a megabyte of source, refused (Security).
        XCTAssertThrowsError(try ExtensionShims.scriptingFile("() => '" + String(repeating: "x", count: 1_000_001) + "'", arguments: [], in: folder))
    }
}

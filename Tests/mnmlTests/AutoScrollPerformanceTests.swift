import XCTest
import JavaScriptCore
@testable import mnml

final class AutoScrollPerformanceTests: XCTestCase {
    func testIdleDeadZoneDoesNotScheduleFramesAndMovementResumesThem() throws {
        let context = try fixture()
        context.evaluateScript("mouse('mousedown', 100, 100, 1)")
        XCTAssertEqual(number("frames.size", in: context), 0)
        context.evaluateScript("mouse('mousemove', 108, 109)")
        XCTAssertEqual(number("frames.size", in: context), 0)
        context.evaluateScript("mouse('mousemove', 180, 100)")
        XCTAssertEqual(number("frames.size", in: context), 1)
        context.evaluateScript("step(1000 / 60)")
        XCTAssertGreaterThan(number("distance", in: context), 0)
        XCTAssertEqual(number("frames.size", in: context), 1)

        context.evaluateScript("mouse('mousemove', 100, 100); step(2000 / 60)")
        XCTAssertEqual(number("frames.size", in: context), 0)
        let before = number("distance", in: context)
        context.evaluateScript("mouse('mousemove', 180, 100); step(3000 / 60)")
        XCTAssertGreaterThan(number("distance", in: context), before)
        XCTAssertEqual(number("frames.size", in: context), 1)
        context.evaluateScript("handlers.blur({})")
        XCTAssertEqual(number("frames.size", in: context), 0)
        XCTAssertEqual(number("removed", in: context), 1)
        XCTAssertNil(context.exception)
    }

    func testSpeedUsesElapsedTimeAt60And120HzAndCapsDelayedFrames() throws {
        func distance(hz: Double) throws -> Double {
            let context = try fixture()
            context.evaluateScript("mouse('mousedown', 100, 100, 1); mouse('mousemove', 180, 100)")
            for frame in 1...Int(hz) { context.evaluateScript("step(\(Double(frame) * 1000 / hz))") }
            XCTAssertNil(context.exception)
            return number("distance", in: context)
        }
        let at60 = try distance(hz: 60)
        let at120 = try distance(hz: 120)
        let perFrame = pow((80.0 - 12) / 10, 1.4)
        XCTAssertEqual(at60, perFrame * 60, accuracy: 0.0001)
        XCTAssertEqual(at120, at60, accuracy: 0.0001)

        let context = try fixture()
        context.evaluateScript("mouse('mousedown', 100, 100, 1); mouse('mousemove', 180, 100); step(10000)")
        XCTAssertEqual(number("distance", in: context), perFrame * 3, accuracy: 0.0001)
        XCTAssertNil(context.exception)
    }

    private func number(_ source: String, in context: JSContext) -> Double {
        context.evaluateScript(source)?.toDouble() ?? .nan
    }

    private func fixture() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window = {}, handlers = {}, frames = new Map(), serial = 0;
        var now = 0, distance = 0, removed = 0;
        var performance = { now: () => now };
        var root = { style: { cursor: '' }, appendChild() {} };
        var document = {
          documentElement: root,
          scrollingElement: { scrollBy(x, y) { distance += x; } },
          createElement() { return { style: {}, attachShadow() { return {}; }, remove() { removed++; } }; },
          addEventListener(name, fn) { handlers[name] = fn; }
        };
        function getComputedStyle() { return { overflowY: 'visible', overflowX: 'visible' }; }
        function addEventListener(name, fn) { handlers[name] = fn; }
        function removeEventListener(name, fn) { if (handlers[name] === fn) delete handlers[name]; }
        function requestAnimationFrame(fn) { frames.set(++serial, fn); return serial; }
        function cancelAnimationFrame(id) { frames.delete(id); }
        function step(time) {
          now = time;
          var callbacks = Array.from(frames.values()); frames.clear();
          callbacks.forEach(fn => fn(time));
        }
        function mouse(name, x, y, button = 0) {
          handlers[name]({ clientX: x, clientY: y, button, target: {}, preventDefault() {}, stopPropagation() {} });
        }
        """)
        context.evaluateScript(AutoScroll.script)
        XCTAssertNil(context.exception)
        return context
    }
}

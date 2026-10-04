import XCTest
import Darwin
@testable import mnml

@MainActor
final class AntigravityTests: XCTestCase {
    func testPromptAndEvents() throws {
        let input = AIInput(system: "Use supplied context.", turns: [(mine: true, text: "A\n\"quote\""), (mine: false, text: "B")],
                            files: [Attachment(name: "sample.csv", mime: "text/csv", data: Data("one,two".utf8))])
        let data = try Antigravity.prompt(input)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap((json["message"] as? [String: Any])?["content"] as? String)
        XCTAssertTrue(content.contains("USER:\nA\n\"quote\""))
        XCTAssertTrue(content.contains("ASSISTANT:\nB"))
        XCTAssertTrue(content.contains("one,two"))
        XCTAssertThrowsError(try Antigravity.prompt(AIInput(system: "", turns: [], files: [Attachment(name: "a.pdf", mime: "application/pdf", data: Data())])))
        XCTAssertThrowsError(try Antigravity.prompt(AIInput(system: "", turns: [], files: [Attachment(name: "a.txt", mime: "text/plain", data: Data([0xff]))])))
        XCTAssertEqual(try Antigravity.event(#"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Hi"}}"#).text, "Hi")
        XCTAssertNil(try Antigravity.event(#"{"event":"step_update","step_update":{"step_type":"tool","tool_name":"finish"}}"#).text)
        XCTAssertThrowsError(try Antigravity.event(#"{"event":"step_update","step_update":{"step_type":"tool","tool_name":"run_command"}}"#))
        XCTAssertThrowsError(try Antigravity.event(#"{"event":"result","result":{"status":"ERROR","error":"quota"}}"#))
        XCTAssertThrowsError(try Antigravity.event(#"{"event":"result","result":{"status":"SUCCESS"}}"#))
        XCTAssertThrowsError(try Antigravity.event("not-json"))
    }

    func testStreamingAndMissingResult() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: """
            read -r input
            printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Hello"}}'
            printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Hello"}}'
            """)
        let input = AIInput(system: "", turns: [(mine: true, text: "hi")], files: [])
        // Fast exits used to race Foundation's run-loop-based waitUntilExit.
        for _ in 0..<20 {
            var answer = ""
            for try await piece in Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: UUID(), executable: cli,
                                                      workspace: folder, sessions: sessions) { answer += piece }
            XCTAssertEqual(answer, "Hello") // final result must not repeat the streamed answer
        }
        try "#!/bin/sh\nread -r input\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
        do {
            for try await _ in Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: UUID(), executable: cli,
                                                  workspace: folder, sessions: sessions) {}
            XCTFail("An exit without a result must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("complete answer")) }
    }

    func testCancellationStopsHelpers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false)
        let chat = UUID()
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: """
            read -r input
            sleep 60 &
            echo $! > helper.pid
            printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Started"}}'
            wait
            """)
        let began = expectation(description: "response began")
        let ended = expectation(description: "cancelled runtime exited")
        let task = Task {
            defer { ended.fulfill() }
            do {
                let input = AIInput(system: "", turns: [(mine: true, text: "hi")], files: [])
                for try await _ in Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat, executable: cli,
                                                      workspace: folder, sessions: sessions) { began.fulfill() }
            } catch {}
        }
        await fulfillment(of: [began], timeout: 5)
        let helper = try XCTUnwrap(Int32(String(contentsOf: folder.appendingPathComponent("helper.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await fulfillment(of: [ended], timeout: 5)
        for _ in 0..<40 where kill(helper, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(helper, 0), 0, "The CLI's helper must not survive cancellation")
        XCTAssertNil(sessions.session(for: chat), "Cancellation must release the resident CLI slot")
    }

    func testQueueCancellationAndHandoff() async throws {
        let queue = AntigravityQueue()
        try await queue.acquire(UUID())
        try await queue.acquire(UUID())
        let cancelled = expectation(description: "queued cancellation")
        let third = Task {
            do { try await queue.acquire(UUID()); XCTFail("Third request must wait") }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail(error.localizedDescription) }
        }
        try await Task.sleep(for: .milliseconds(50))
        third.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let handed = expectation(description: "slot handed to next request")
        let fourth = Task { try await queue.acquire(UUID()); handed.fulfill() }
        await queue.release()
        await fulfillment(of: [handed], timeout: 2)
        try await fourth.value
        await queue.release()
        await queue.release()
    }

    func testWarmFollowupReusesProcessAndOmitsUnchangedPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try warmStub(in: folder)
        let chat = UUID(), context = "<tab>PAGE MARKER 42</tab>"
        let first = AIInput(system: "Answer from context.", turns: [(mine: true, text: context + "\nfirst")],
                            files: [], context: context, question: "first")
        let firstAnswer = try await answer(Antigravity.stream(first, model: AIProvider.antigravity.models[0],
                                                             chat: chat, executable: cli, workspace: folder, sessions: sessions))
        XCTAssertEqual(firstAnswer, "Hello")
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let second = AIInput(system: first.system,
                             turns: [(mine: true, text: "first"), (mine: false, text: "Hello"),
                                     (mine: true, text: context + "\nfollowup")],
                             files: [], context: context, question: "followup")
        let secondAnswer = try await answer(Antigravity.stream(second, model: AIProvider.antigravity.models[0],
                                                              chat: chat, executable: cli, workspace: folder, sessions: sessions))
        XCTAssertEqual(secondAnswer, "Hello")
        XCTAssertEqual(sessions.session(for: chat)?.pid, pid)
        XCTAssertEqual(sessions.session(for: chat)?.busy, false)
        let sent = try messages(in: folder)
        XCTAssertEqual(sent.map(\.pid), [pid, pid])
        XCTAssertTrue(sent[0].content.contains(context))
        XCTAssertTrue(sent[1].content.contains("followup"))
        XCTAssertFalse(sent[1].content.contains(context), "An unchanged page should not be reinjected into a warm conversation")
        XCTAssertFalse(sent[1].content.contains("Hello"), "The CLI already owns the previous answer")
    }

    func testCumulativeUsageIsReportedOncePerTurn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false)
        let previous = getenv("MNML_AI_METRICS").map { String(cString: $0) }
        let metrics = folder.appendingPathComponent("requests.jsonl")
        setenv("MNML_AI_METRICS", metrics.path, 1)
        defer {
            sessions.stopAll()
            if let previous { setenv("MNML_AI_METRICS", previous, 1) }
            else { unsetenv("MNML_AI_METRICS") }
            try? FileManager.default.removeItem(at: folder)
        }
        let cli = try warmStub(in: folder), chat = UUID()
        let first = AIInput(system: "", turns: [(mine: true, text: "first")], files: [], context: "", question: "first")
        _ = try await answer(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let second = AIInput(system: "", turns: [(mine: true, text: "first"), (mine: false, text: "Hello"),
                                                (mine: true, text: "second")], files: [], context: "", question: "second")
        _ = try await answer(Antigravity.stream(second, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let rows = try String(contentsOf: metrics, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { $0["event"] as? String == "result" && $0["chat"] as? String == chat.uuidString }
        let usage = try rows.map { try XCTUnwrap($0["usage"] as? [String: Any]) }
        XCTAssertEqual(usage.compactMap { $0["input_tokens"] as? Int }, [100, 130])
        XCTAssertEqual(usage.compactMap { $0["output_tokens"] as? Int }, [1, 1])
        XCTAssertEqual(Set(rows.compactMap { $0["request"] as? String }).count, 2)
    }

    func testStaleTimeoutCannotStopTheNextWarmTurn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metrics = folder.appendingPathComponent("requests.jsonl")
        let previous = getenv("MNML_AI_METRICS").map { String(cString: $0) }
        setenv("MNML_AI_METRICS", metrics.path, 1)
        defer {
            if let previous { setenv("MNML_AI_METRICS", previous, 1) }
            else { unsetenv("MNML_AI_METRICS") }
            try? FileManager.default.removeItem(at: folder)
        }
        let cli = try stub(in: folder, script: #"""
            turn=0
            while IFS= read -r input; do
                turn=$((turn + 1))
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                if [ "$turn" -eq 1 ]; then
                    printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"A answer"}}'
                else
                    printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"B "}}'
                    while [ ! -f release ]; do sleep 0.01; done
                    printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"answer"}}'
                    printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"B answer"}}'
                fi
            done
            """#)
        let model = AIProvider.antigravity.models[0], chat = UUID()
        let first = AIInput(system: "", turns: [(mine: true, text: "A")], files: [], context: "", question: "A")
        let run = Antigravity.Run(input: first, model: model, chat: chat, executable: cli, workspace: folder)
        defer { run.stop(); run.reap() }
        try run.start()
        let pid = run.process.processIdentifier
        let firstAnswer = try await answer(run.answer(first, bootstrap: Antigravity.prompt(first)))
        XCTAssertEqual(firstAnswer, "A answer")
        let rows = try String(contentsOf: metrics, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let start = try XCTUnwrap(rows.first { $0["event"] as? String == "start" && $0["chat"] as? String == chat.uuidString })
        let staleRequest = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(start["request"] as? String)))
        let second = AIInput(system: "", turns: [(mine: true, text: "A"), (mine: false, text: "A answer"),
                                                 (mine: true, text: "B")], files: [], context: "", question: "B")
        XCTAssertTrue(run.matches(second, model: model, executable: cli, workspace: folder))
        let secondBootstrap = try Antigravity.prompt(second)
        let began = expectation(description: "next warm turn began")
        let task = Task { () throws -> String in
            var response = ""
            for try await piece in run.answer(second, bootstrap: secondBootstrap) {
                response += piece
                if response == "B " { began.fulfill() }
            }
            return response
        }
        defer { task.cancel() }
        await fulfillment(of: [began], timeout: 5)

        // Simulate A's watchdog arriving after B already owns the runtime.
        run.stop(error: Antigravity.Failure(message: "Stale timeout"), reason: "timeout", onlyRequest: staleRequest)
        XCTAssertTrue(run.process.isRunning)
        try Data().write(to: folder.appendingPathComponent("release"))
        let secondAnswer = try await task.value
        XCTAssertEqual(secondAnswer, "B answer")
        XCTAssertEqual(run.process.processIdentifier, pid)
        XCTAssertEqual(try messages(in: folder).map(\.pid), [pid, pid])
    }

    func testChangedContextRestartsWithBoundedConversation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try warmStub(in: folder), chat = UUID()
        let first = AIInput(system: "Answer from context.", turns: [(mine: true, text: "OLD PAGE\nfirst")],
                            files: [], context: "OLD PAGE", question: "first")
        _ = try await answer(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let old = try XCTUnwrap(sessions.session(for: chat)?.pid)
        let changed = AIInput(system: first.system,
                              turns: [(mine: true, text: "first"), (mine: false, text: "Hello"),
                                      (mine: true, text: "NEW PAGE\nsecond")],
                              files: [], context: "NEW PAGE", question: "second")
        _ = try await answer(Antigravity.stream(changed, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let current = try XCTUnwrap(sessions.session(for: chat)?.pid)
        XCTAssertNotEqual(current, old)
        let sent = try messages(in: folder)
        XCTAssertTrue(sent.last!.content.contains("NEW PAGE"))
        XCTAssertTrue(sent.last!.content.contains("ASSISTANT:\nHello"))
        XCTAssertFalse(sent.last!.content.contains("OLD PAGE"), "Changed source context must not retain an obsolete page")
        await assertExited(old)
    }

    func testTrimmedHistoryRestartsInsteadOfRetainingOlderNativeContext() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try warmStub(in: folder), chat = UUID()
        let first = AIInput(system: "", turns: [(mine: true, text: "old question"),
                                               (mine: false, text: "OLD ANSWER TO DROP"),
                                               (mine: true, text: "SAME PAGE\nfirst")],
                            files: [], context: "SAME PAGE", question: "first")
        _ = try await answer(Antigravity.stream(first, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let oldPID = try XCTUnwrap(sessions.session(for: chat)?.pid)
        // mnml's history budget removed the oldest complete pair of turns.
        let trimmed = AIInput(system: "", turns: [(mine: true, text: "first"), (mine: false, text: "Hello"),
                                                 (mine: true, text: "SAME PAGE\nsecond")],
                              files: [], context: "SAME PAGE", question: "second")
        _ = try await answer(Antigravity.stream(trimmed, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        XCTAssertNotEqual(sessions.session(for: chat)?.pid, oldPID)
        let bootstrap = try XCTUnwrap(messages(in: folder).last?.content)
        XCTAssertTrue(bootstrap.contains("SAME PAGE"))
        XCTAssertTrue(bootstrap.contains("ASSISTANT:\nHello"))
        XCTAssertFalse(bootstrap.contains("OLD ANSWER TO DROP"))
        await assertExited(oldPID)
    }

    func testWarmLimitEvictsLeastRecentlyUsedIdleSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var clock: TimeInterval = 0
        let sessions = AntigravitySessions(maximum: 2, now: { clock }, automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try warmStub(in: folder)
        let first = UUID(), second = UUID(), third = UUID()
        let input = AIInput(system: "", turns: [(mine: true, text: "hi")], files: [], context: "", question: "hi")
        _ = try await answer(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: first,
                                               executable: cli, workspace: folder, sessions: sessions))
        clock = 10
        _ = try await answer(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: second,
                                               executable: cli, workspace: folder, sessions: sessions))
        let evicted = try XCTUnwrap(sessions.session(for: second)?.pid)
        clock = 20
        sessions.keepLive(first)
        clock = 30
        _ = try await answer(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: third,
                                               executable: cli, workspace: folder, sessions: sessions))
        XCTAssertEqual(sessions.sessions.count, 2)
        XCTAssertNotNil(sessions.session(for: first))
        XCTAssertNil(sessions.session(for: second))
        XCTAssertNotNil(sessions.session(for: third))
        await assertExited(evicted)
    }

    func testBusyPoolQueuesAndCancelsWithoutTerminatingActiveChats() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var clock: TimeInterval = 0
        let sessions = AntigravitySessions(maximum: 2, now: { clock }, automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: #"""
            while IFS= read -r input; do
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                case "$input" in
                    *BLOCK*)
                        sleep 60 &
                        echo $! > "helper-$$.pid"
                        printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Started"}}'
                        wait
                        ;;
                    *) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Hello"}}' ;;
                esac
            done
            """#)
        let first = UUID(), second = UUID(), third = UUID()
        let input = AIInput(system: "", turns: [(mine: true, text: "BLOCK")], files: [], context: "", question: "BLOCK")
        let started = expectation(description: "two busy CLI responses began")
        started.expectedFulfillmentCount = 2
        func busy(_ chat: UUID) -> Task<Void, Never> {
            Task {
                do {
                    for try await _ in Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
                                                         executable: cli, workspace: folder, sessions: sessions) { started.fulfill() }
                } catch {}
            }
        }
        let firstTask = busy(first), secondTask = busy(second)
        await fulfillment(of: [started], timeout: 5)
        let firstPID = try XCTUnwrap(sessions.session(for: first)?.pid)
        let secondPID = try XCTUnwrap(sessions.session(for: second)?.pid)
        clock = 1_000
        sessions.tick()
        XCTAssertNil(sessions.session(for: first)?.remaining, "A running answer must not receive an inactivity countdown")
        XCTAssertNil(sessions.session(for: second)?.remaining)
        let thirdInput = AIInput(system: "", turns: [(mine: true, text: "third")], files: [], context: "", question: "third")
        let waiting = Task { () -> Bool in
            do {
                _ = try await answer(Antigravity.stream(thirdInput, model: AIProvider.antigravity.models[0], chat: third,
                                                       executable: cli, workspace: folder, sessions: sessions))
                try Task.checkCancellation()
                return false
            } catch is CancellationError { return true }
            catch { XCTFail(error.localizedDescription); return false }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sessions.sessions.count, 2)
        XCTAssertEqual(try messages(in: folder).count, 2, "A third busy runtime must wait instead of exceeding the memory limit")
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(sessions.session(for: first)?.busy, true)
        XCTAssertEqual(sessions.session(for: second)?.busy, true)
        XCTAssertEqual(kill(firstPID, 0), 0)
        XCTAssertEqual(kill(secondPID, 0), 0)

        sessions.kill(first)
        await firstTask.value
        _ = try await answer(Antigravity.stream(thirdInput, model: AIProvider.antigravity.models[0], chat: third,
                                               executable: cli, workspace: folder, sessions: sessions))
        XCTAssertEqual(sessions.sessions.count, 2)
        XCTAssertNotNil(sessions.session(for: second))
        XCTAssertNotNil(sessions.session(for: third))
        sessions.kill(second)
        await secondTask.value
        await assertExited(firstPID)
        await assertExited(secondPID)
    }

    func testKillReturnsPromptlyAndRetiringProcessStillOccupiesItsSlot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = AntigravitySessions(maximum: 1, automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try stub(in: folder, script: #"""
            trap '' TERM
            while IFS= read -r input; do
                if [ -f old.pid ]; then
                    old=$(cat old.pid)
                    if kill -0 "$old" 2>/dev/null; then printf 'overlap\n' > overlap; fi
                fi
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"Hello"}}'
            done
            # Ignore TERM and remain alive after stdin closes. Only the
            # delayed process-group KILL can finish this runtime and helper.
            sleep 60 &
            echo $! > "helper-$$.pid"
            wait
            """#)
        let first = UUID(), second = UUID()
        let input = AIInput(system: "", turns: [(mine: true, text: "hi")], files: [], context: "", question: "hi")
        _ = try await answer(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: first,
                                               executable: cli, workspace: folder, sessions: sessions))
        let oldPID = try XCTUnwrap(sessions.session(for: first)?.pid)
        try String(oldPID).write(to: folder.appendingPathComponent("old.pid"), atomically: true, encoding: .utf8)
        let began = ProcessInfo.processInfo.systemUptime
        sessions.kill(first)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        XCTAssertLessThan(elapsed, 0.2, "Kill must not block the app's main thread while a stubborn CLI is reaped")
        XCTAssertNil(sessions.session(for: first))

        let replacement = try await answer(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: second,
                                                              executable: cli, workspace: folder, sessions: sessions))
        XCTAssertEqual(replacement, "Hello")
        XCTAssertEqual(try messages(in: folder).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("overlap").path),
                       "A retiring process must occupy its resident slot until it actually exits")
        XCTAssertNotEqual(sessions.session(for: second)?.pid, oldPID)
        await assertExited(oldPID)
        let helperFile = folder.appendingPathComponent("helper-\(oldPID).pid")
        let helper = try XCTUnwrap(Int32(String(contentsOf: helperFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        await assertExited(helper)
    }

    func testInactivityCountdownKeepLiveAndKill() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var clock: TimeInterval = 0
        let sessions = AntigravitySessions(now: { clock }, automaticTimer: false)
        defer { sessions.stopAll(); try? FileManager.default.removeItem(at: folder) }
        let cli = try warmStub(in: folder), chat = UUID()
        let input = AIInput(system: "", turns: [(mine: true, text: "hi")], files: [], context: "", question: "hi")
        _ = try await answer(Antigravity.stream(input, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let pid = try XCTUnwrap(sessions.session(for: chat)?.pid)
        clock = 179
        sessions.tick()
        XCTAssertNil(sessions.session(for: chat)?.remaining)
        clock = 180
        sessions.tick()
        XCTAssertEqual(sessions.session(for: chat)?.remaining, 60)
        clock = 239
        sessions.tick()
        XCTAssertEqual(sessions.session(for: chat)?.remaining, 1)
        sessions.keepLive(chat)
        XCTAssertNil(sessions.session(for: chat)?.remaining)
        clock = 418
        sessions.tick()
        XCTAssertNil(sessions.session(for: chat)?.remaining)
        clock = 419
        sessions.tick()
        XCTAssertEqual(sessions.session(for: chat)?.remaining, 60)
        sessions.kill(chat)
        XCTAssertNil(sessions.session(for: chat))
        await assertExited(pid)

        // A new runtime uses the same mnml conversation ID after a kill.
        let followup = AIInput(system: "", turns: [(mine: true, text: "hi"), (mine: false, text: "Hello"),
                                                  (mine: true, text: "again")], files: [], context: "", question: "again")
        _ = try await answer(Antigravity.stream(followup, model: AIProvider.antigravity.models[0], chat: chat,
                                               executable: cli, workspace: folder, sessions: sessions))
        let restarted = try XCTUnwrap(sessions.session(for: chat)?.pid)
        XCTAssertNotEqual(restarted, pid)
        XCTAssertTrue(try messages(in: folder).last!.content.contains("ASSISTANT:\nHello"),
                      "A killed runtime must bootstrap its next request from the preserved mnml conversation")
        clock = 659
        sessions.tick()
        XCTAssertNil(sessions.session(for: chat), "The countdown should expire at three minutes plus sixty seconds")
        await assertExited(restarted)
    }

    private func stub(in folder: URL, script: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("fake-agy")
        try ("#!/bin/sh\n" + script + "\n").write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    private func answer(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var response = ""
        for try await piece in stream { response += piece }
        return response
    }

    private func assertExited(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(pid, 0), 0, "The CLI should be reaped after termination", file: file, line: line)
    }

    private func messages(in folder: URL) throws -> [(pid: Int32, content: String)] {
        let file = folder.appendingPathComponent("messages.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            let pid = try XCTUnwrap(Int32(parts[0]))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any])
            let message = try XCTUnwrap(json["message"] as? [String: Any])
            return (pid, try XCTUnwrap(message["content"] as? String))
        }
    }

    // Count usage cumulatively like the real headless CLI. Leaving stdin open
    // permits several turns, and logging it verifies which context mnml sends.
    private func warmStub(in folder: URL) throws -> URL {
        try stub(in: folder, script: #"""
            turn=0
            while IFS= read -r input; do
                turn=$((turn + 1))
                printf '%s\t%s\n' "$$" "$input" >> messages.jsonl
                if [ "$turn" -eq 1 ]; then usage=100; else usage=230; fi
                printf '%s\n' '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Hello"}}'
                printf '{"event":"result","result":{"status":"SUCCESS","response":"Hello","usage":{"input_tokens":%s,"output_tokens":%s}}}\n' "$usage" "$turn"
            done
            """#)
    }
}

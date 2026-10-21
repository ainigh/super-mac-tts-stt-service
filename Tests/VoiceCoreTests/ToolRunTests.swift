import XCTest
@testable import VoiceCore

/// Stands in for Tool Mac Tool Run: answers from a script of (status, json), keeping what it was sent.
final class FakeRunner: ScriptRunner {
    var script: [(Int, [String: Any])] = []
    var sent: [(method: String, path: String, body: [String: Any]?)] = []
    var down = false

    func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> (status: Int, json: [String: Any]) {
        sent.append((method, path, body))
        if down { throw ToolRunError.unreachable("http://127.0.0.1:8768") }
        guard !script.isEmpty else { return (200, [:]) }
        return script.removeFirst()
    }
}

final class ToolRunTests: XCTestCase {
    func testTheToolsOverToolMacToolRun() async throws {
        let runner = FakeRunner()
        runner.script = [(200, ["folder": "/Users/sam/Scripts", "scripts": [
            ["name": "hello.sh", "language": "bash", "language_name": "Bash", "summary": "Says hello", "dangers": [String](), "asks_for_input": false],
            ["name": "tidy.py", "language_name": "Python", "summary": "Moves old downloads to the Trash", "dangers": ["deletes files"], "asks_for_input": true],
        ]])]
        let scripts_ = await ToolRunTools.run("list_scripts", [:], via: runner)
        let scripts = try XCTUnwrap(scripts_)
        XCTAssertTrue(scripts.contains("hello.sh"))
        XCTAssertTrue(scripts.contains(#""cannot_be_undone":["deletes files"]"#))
        XCTAssertTrue(scripts.contains(#""asks_for_input":true"#))
        XCTAssertEqual(runner.sent[0].method, "GET")
        XCTAssertEqual(runner.sent[0].path, "/api/scripts")

        runner.script = [(200, ["id": "6C1D", "kind": "script", "name": "hello.sh", "state": "succeeded", "ok": true, "code": 0, "seconds": 0.04,
                                "output": "Hello, world!\n", "stdout": "Hello, world!\n", "stderr": ""])]
        let ran_ = await ToolRunTools.run("run_script", ["script": "hello.sh", "args": ["world"], "stdin": "y"], via: runner)
        let ran = try XCTUnwrap(ran_)
        XCTAssertEqual(ran, "hello.sh: succeeded (exit code 0), 0.04 seconds, run id 6C1D.\nIt printed:\nHello, world!")
        XCTAssertEqual(runner.sent[1].path, "/api/run")
        XCTAssertEqual(runner.sent[1].body?["script"] as? String, "hello.sh")
        XCTAssertEqual(runner.sent[1].body?["args"] as? [String], ["world"])
        XCTAssertEqual(runner.sent[1].body?["stdin"] as? String, "y")
        // A single argument as a string, and a missing script name.
        runner.script = [(200, ["name": "a.sh", "state": "failed", "code": 1, "output": ""])]
        let failed_ = await ToolRunTools.run("run_script", ["script": "a", "args": "--all"], via: runner)
        let failed = try XCTUnwrap(failed_)
        XCTAssertEqual(failed, "a.sh: failed (exit code 1).\nIt printed nothing.")
        XCTAssertEqual(runner.sent[2].body?["args"] as? [String], ["--all"])
        let r1 = await ToolRunTools.run("run_script", [:], via: runner)
        XCTAssertEqual(r1, "Say which script: its name from list_scripts.")

        // Not run: Don't Run, no answer, no such script, a group that's off, no folder.
        runner.script = [(403, ["code": "denied", "error": "the person clicked Don't Run"]),
                         (403, ["code": "not_answered", "error": "no answer"]),
                         (404, ["code": "unknown_script", "error": "no script called x; there are: hello.sh, tidy.py"]),
                         (503, ["code": "endpoint_off", "error": "run scripts is turned off in Tool Mac Tool Run"]),
                         (409, ["code": "no_folder", "error": "no folder"])]
        let r2 = await ToolRunTools.run("run_script", ["script": "x"], via: runner)
        XCTAssertEqual(r2, "It didn't run: the user clicked Don't Run on their Mac.")
        let r3 = await ToolRunTools.run("run_script", ["script": "x"], via: runner)
        XCTAssertEqual(r3, "It didn't run: no one clicked Run on the Mac within two minutes.")
        let r4 = await ToolRunTools.run("run_script", ["script": "x"], via: runner)
        XCTAssertEqual(r4, "no script called x; there are: hello.sh, tidy.py")
        let r5 = await ToolRunTools.run("run_script", ["script": "x"], via: runner)
        XCTAssertTrue(try XCTUnwrap(r5).hasPrefix("That's turned off"))
        let r6 = await ToolRunTools.run("list_scripts", [:], via: runner)
        XCTAssertTrue(try XCTUnwrap(r6).contains("no scripts folder"))

        // Flows: run by name, run code, check code.
        runner.script = [(200, ["flows": [["name": "morning.flow", "summary": "The day's first checks"]]]),
                         (200, ["id": "F1", "kind": "flow", "name": "morning.flow", "state": "succeeded", "code": 0, "seconds": 2,
                                "output": "ok\n", "steps": [["name": "hello.sh", "state": "succeeded"]]]),
                         (200, ["ok": true, "bindings": [["name": "double", "type": "int -> int", "line": 1]]]),
                         (400, ["ok": false, "code": "flow_mistake", "error": "line 2: x", "message": "x isn't defined", "line": 2, "fix": "define x first"]),
                         (200, ["name": "Count them", "state": "failed", "code": 1, "problem": "python3 is missing: brew install python", "output": ""])]
        let r7 = await ToolRunTools.run("list_flows", [:], via: runner)
        XCTAssertTrue(try XCTUnwrap(r7).contains("morning.flow"))
        let flow_ = await ToolRunTools.run("run_flow", ["flow": "morning.flow"], via: runner)
        let flow = try XCTUnwrap(flow_)
        XCTAssertEqual(flow, "morning.flow: succeeded (exit code 0), 2.0 seconds, run id F1.\nSteps: hello.sh succeeded.\nIt printed:\nok")
        XCTAssertEqual(runner.sent.last?.path, "/api/compose")
        XCTAssertEqual(runner.sent.last?.body?["flow"] as? String, "morning.flow")
        let r8 = await ToolRunTools.run("check_flow", ["source": "let double x = x * 2"], via: runner)
        XCTAssertEqual(r8, "The code is fine. It defines double: int -> int.")
        XCTAssertEqual(runner.sent.last?.path, "/api/check")
        let r9 = await ToolRunTools.run("check_flow", ["source": "y"], via: runner)
        XCTAssertEqual(r9, "The Flow code has a mistake on line 2: x isn't defined. Fix: define x first")
        let code_ = await ToolRunTools.run("run_flow_code", ["source": "print 1", "name": "Count them"], via: runner)
        let code = try XCTUnwrap(code_)
        XCTAssertTrue(code.contains("Problem: python3 is missing"))
        XCTAssertEqual(runner.sent.last?.body?["source"] as? String, "print 1")
        XCTAssertEqual(runner.sent.last?.body?["name"] as? String, "Count them")

        // Runs: list, read, stop.
        runner.script = [(200, ["runs": [["id": "6C1D", "name": "hello.sh", "state": "running", "started": "2026-10-18T09:12:03Z"]]]),
                         (200, ["id": "6C1D", "name": "hello.sh", "state": "running", "output": "Copying…\n"]),
                         (200, ["ok": true, "stopping": true]),
                         (200, ["ok": true, "stopping": false])]
        let r10 = await ToolRunTools.run("list_runs", ["limit": 5], via: runner)
        XCTAssertTrue(try XCTUnwrap(r10).contains(#""state":"running""#))
        XCTAssertEqual(runner.sent.last?.path, "/api/runs?limit=5")
        let r11 = await ToolRunTools.run("read_run", ["id": "6C1D"], via: runner)
        XCTAssertEqual(r11, "hello.sh: running, run id 6C1D.\nIt printed:\nCopying…")
        XCTAssertEqual(runner.sent.last?.path, "/api/runs/6C1D")
        let r12 = await ToolRunTools.run("stop_run", ["id": "6C1D"], via: runner)
        XCTAssertEqual(r12, "Stopping it.")
        XCTAssertEqual(runner.sent.last?.path, "/api/runs/6C1D/stop")
        XCTAssertEqual(runner.sent.last?.method, "POST")
        let r13 = await ToolRunTools.run("stop_run", ["id": "6C1D"], via: runner)
        XCTAssertEqual(r13, "It had already ended.")
        // An id is one segment of the path, whatever the model wrote; a limit, whatever number.
        XCTAssertEqual(ToolRunTools.escaped("../x?y z"), "%2E%2E%2Fx%3Fy%20z")
        XCTAssertEqual(AssistantTools.limit(["limit": 1e300], default: 10), 100)
        XCTAssertEqual(AssistantTools.limit(["limit": Double.nan], default: 10), 10)
        XCTAssertEqual(AssistantTools.limit(["limit": 0], default: 10), 1)
        XCTAssertEqual(ToolRunTools.outcome(["name": "a.sh", "state": "failed", "code": 1e300]), "a.sh: failed.\nIt printed nothing.")

        // Not one of these, and the app not running.
        let none = await ToolRunTools.run("list_chats", [:], via: runner)
        XCTAssertNil(none)
        runner.down = true
        let r14 = await ToolRunTools.run("list_scripts", [:], via: runner)
        XCTAssertTrue(try XCTUnwrap(r14).contains("isn't answering at http://127.0.0.1:8768"))
    }

    func testLongOutputIsCutToItsEnd() {
        let long = String(repeating: "x", count: ToolRunTools.maxOutput + 10) + "END"
        let s = ToolRunTools.outcome(["name": "big.sh", "state": "succeeded", "output": long])
        XCTAssertTrue(s.hasSuffix("END"))
        XCTAssertTrue(s.contains("It printed:\n…"))
        XCTAssertLessThan(s.count, ToolRunTools.maxOutput + 100)
    }

    func testTheConversationRunsScriptsWhenItHasARunner() async throws {
        let model = FakeModel()
        let runner = FakeRunner()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        // Without a runner the script tools aren't offered, nor run.
        XCTAssertFalse(chat.systemPrompt().contains("run_script"))
        model.script = [#"{"tool": "run_script", "arguments": {"script": "hello.sh"}}"#, "Done."]
        _ = try await chat.ask("Run hello")
        XCTAssertTrue(((model.sent[1].messages[3]["content"] as? String) ?? "").contains("no tool called run_script"))
        XCTAssertTrue(runner.sent.isEmpty)

        chat.runner = runner
        XCTAssertTrue(chat.systemPrompt().contains("- run_script:"))
        XCTAssertTrue(chat.systemPrompt().contains("Tool Mac Tool Run"))
        XCTAssertEqual(chat.tools.map(\.name), AssistantTools.library.map(\.name) + ToolRunTools.names)
        model.script = [#"{"tool": "run_script", "arguments": {"script": "hello.sh", "args": ["world"]}}"#, "It said hello to the world."]
        runner.script = [(200, ["name": "hello.sh", "state": "succeeded", "code": 0, "output": "Hello, world!\n"])]
        let answer = try await chat.ask("Run hello with world")
        XCTAssertEqual(answer, "It said hello to the world.")
        XCTAssertEqual(runner.sent.count, 1)
        XCTAssertEqual(runner.sent[0].body?["script"] as? String, "hello.sh")
        XCTAssertTrue(((model.sent.last?.messages[7]["content"] as? String) ?? "").contains("Hello, world!"))
        XCTAssertEqual(chat.toolCalls, ["run_script", "run_script"])
    }

    func testTheClientsAddress() {
        XCTAssertEqual(ToolRunClient(baseURL: "localhost:8768/").baseURL.absoluteString, "http://localhost:8768")
        XCTAssertEqual(ToolRunClient(baseURL: "").baseURL.absoluteString, ToolRunClient.defaultURL)
        XCTAssertEqual(ToolRunClient.defaultURL, "http://127.0.0.1:8768")
        XCTAssertEqual(ToolRunError.unreachable("x").errorDescription, "Tool Mac Tool Run isn't answering at x. Is it running, with its API on?")
    }
}

import XCTest
@testable import VoiceCore

/// Tom and Jerry: Tom supervises, Jerry works, the harness keeps the jobs.
final class TeamTests: XCTestCase {
    func testJerryIsStillRecognizedByNameForTheRecord() {
        XCTAssertEqual(Team.addressed("Jerry, what do you think?")?.rest, "What do you think?")
        XCTAssertNil(Team.addressed("What's the weather?"))
        XCTAssertNil(Team.addressed(""))
    }

    func testSilenceIsAnAnswer() {
        XCTAssertTrue(Team.isSilent("(nothing)"))
        XCTAssertTrue(Team.isSilent("Nothing."))
        XCTAssertTrue(Team.isSilent("[silence]"))
        XCTAssertFalse(Team.isSilent("Nothing much, just the weather."))
        XCTAssertFalse(Team.isSilent(""))
    }

    func testTomWithJerryHasOnlyTheJobToolsAndJerryHasTheSkillsAndHisOwn() {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        XCTAssertFalse(chat.activeSkills.contains { $0.id == Skills.team.id })
        XCTAssertFalse(chat.systemPrompt().contains("delegate"))
        XCTAssertTrue(chat.tools.contains { $0.name == "list_chats" })
        chat.team = .lead(teammate: "Jerry")
        XCTAssertEqual(chat.activeSkills.map(\.id), ["team"])
        XCTAssertEqual(chat.tools.map(\.name), ["delegate", "job_status", "message_jerry", "cancel_job"])
        XCTAssertTrue(chat.systemPrompt().contains("- delegate:"))
        XCTAssertTrue(chat.systemPrompt().contains("You are the supervisor"))
        XCTAssertTrue(chat.systemPrompt().hasPrefix("You are Tom,"))
        chat.extraTools = Memory.tools
        XCTAssertTrue(chat.tools.contains { $0.name == "remember" })
        XCTAssertTrue(chat.systemPrompt().contains("- remember:"))
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        XCTAssertFalse(jerry.activeSkills.contains { $0.id == Skills.team.id })
        XCTAssertTrue(jerry.tools.contains { $0.name == "list_chats" })
        XCTAssertTrue(jerry.tools.contains { $0.name == "ask_tom" })
        XCTAssertTrue(jerry.tools.contains { $0.name == "finish" })
        XCTAssertTrue(jerry.systemPrompt().hasPrefix("You are Jerry,"))
        XCTAssertTrue(jerry.systemPrompt().contains("You work for Tom"))
        XCTAssertEqual(Skills.skill(for: "delegate")?.id, "team")
        XCTAssertEqual(Skills.skill(for: "finish")?.id, "team")
        XCTAssertEqual(AssistantTools.canonical("tell_jerry"), "message_jerry")
        XCTAssertEqual(AssistantTools.canonical("create_job"), "delegate")
        XCTAssertEqual(AssistantTools.canonical("done"), "finish")
        XCTAssertEqual(AssistantTools.canonical("memorize"), "remember")
    }

    func testTomDelegatesAndTheCallEndsHisTurn() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = [#"On it. {"tool": "delegate", "arguments": {"goal": "Start focus music on Spotify", "constraints": ["Spotify only", "volume at most 40"], "done_criteria": "Music is playing at volume 40 or less", "return": "what's playing and the volume"}}"#]
        let r = try await tom.reply("Put on something for focus.")
        XCTAssertEqual(r.text, "On it.")
        guard case .delegate(let spec)? = r.action else { return XCTFail("no delegation") }
        XCTAssertEqual(spec.goal, "Start focus music on Spotify")
        XCTAssertEqual(spec.constraints, ["Spotify only", "volume at most 40"])
        XCTAssertEqual(spec.doneCriteria, "Music is playing at volume 40 or less")
        XCTAssertEqual(spec.returns, "what's playing and the volume")
        // One request: the call ends the turn; the job is the app's to make.
        XCTAssertEqual(model.sent.count, 1)
        XCTAssertEqual(tom.toolCalls, ["delegate"])
        XCTAssertEqual(tom.turns.map(\.text), ["Put on something for focus.", "On it.", spec.text])
        XCTAssertEqual(tom.turns[2].to, "Jerry")
        XCTAssertEqual(tom.turns[2].name, "Tom")
        XCTAssertTrue(Assistant.transcript(tom.turns).contains("Tom → Jerry: Goal: Start focus music on Spotify"))

        // The app tells him the job's id with his next turn.
        tom.toolResult("delegate", "Created j1, queued.")
        model.script = ["(nothing)"]
        tom.event("j1 running")
        let quiet = try await tom.wake()
        XCTAssertTrue(quiet.silent)
        let last = model.sent.last!.messages
        XCTAssertEqual(last.map { $0["role"] as? String }, ["system", "user", "assistant", "user", "user", "user"])
        XCTAssertTrue(((last[3]["content"] as? String) ?? "").contains("Created j1"))
        XCTAssertTrue(((last[4]["content"] as? String) ?? "").hasPrefix("Event (from the Mac"))
        // Nothing was said: no user turn for the wake, and silence isn't on the wire.
        XCTAssertEqual(tom.turns.count, 4)
        XCTAssertEqual(tom.turns.last?.text, "(nothing)")
    }

    func testADelegationWithoutAGoalIsRefusedLikeAnyTool() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = [#"{"tool": "delegate", "arguments": {}}"#, "What should I ask him to do?"]
        let r = try await tom.reply("Ask Jerry.")
        XCTAssertNil(r.action)
        XCTAssertEqual(r.text, "What should I ask him to do?")
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("Give the job's goal"))
    }

    func testTomMessagesAndCancelsJobs() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = [#"{"tool": "message_jerry", "arguments": {"job_id": "J1", "message": "Volume is 65; set it to 40 and finish again."}}"#]
        var r = try await tom.wake()
        XCTAssertEqual(r.action, .message(job: "j1", text: "Volume is 65; set it to 40 and finish again."))
        XCTAssertEqual(tom.turns.last?.text, "j1: Volume is 65; set it to 40 and finish again.")
        model.script = [#"Dropping it. {"tool": "cancel", "arguments": {"id": 1}}"#]
        r = try await tom.reply("Never mind the music.")
        XCTAssertEqual(r.action, .cancel(job: "j1"))
        XCTAssertEqual(r.text, "Dropping it.")
    }

    func testJerryWorksAJobWithApprovalAndNarrationAndFinishes() async throws {
        let model = FakeModel()
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        var narrated: [String] = []
        var asked: [String] = []
        var uses: [ToolUse] = []
        jerry.onNarration = { narrated.append($0) }
        jerry.onToolUse = { uses.append($0) }
        jerry.needsApproval = { $0 == "calculate" }
        jerry.approval = { call in
            asked.append(call.name)
            return asked.count == 1            // the first is approved, the second rejected
        }
        jerry.enabled = [Skills.math.id]
        model.script = [
            #"I'll work it out. {"tool": "calculate", "arguments": {"expression": "6 * 7"}}"#,
            #"And once more. {"tool": "calculate", "arguments": {"expression": "1 + 1"}}"#,
            #"{"tool": "finish", "arguments": {"summary": "6 times 7 is 42.", "details": "Worked it out; the second sum was refused."}}"#,
        ]
        let r = try await jerry.reply(JobBoard.briefing(Job(id: "j1", session: UUID(), spec: Job.Spec(goal: "6 times 7")), messages: []), from: "Tom")
        XCTAssertEqual(r.action, .finish(Job.Result(summary: "6 times 7 is 42.", details: "Worked it out; the second sum was refused.")))
        XCTAssertEqual(narrated, ["I'll work it out.", "And once more."])
        XCTAssertEqual(asked, ["calculate", "calculate"])
        XCTAssertEqual(uses.map(\.result), ["6 * 7 = 42", AssistantTools.rejectedMessage])
        XCTAssertEqual(jerry.turns.last?.text, "6 times 7 is 42.")
        XCTAssertEqual(jerry.turns.last?.name, "Jerry")
        XCTAssertNil(jerry.turns.last?.to)
        // What he was told about the rejection.
        let m = model.sent[2].messages
        XCTAssertTrue(((m.last?["content"] as? String) ?? "").contains("Rejected by the user"))
    }

    func testJerryAsksTom() async throws {
        let model = FakeModel()
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        model.script = [#"{"tool": "ask_tom", "arguments": {"question": "Which playlist: Deep Focus or Lo-Fi?"}}"#]
        let r = try await jerry.reply("Job j1 from Tom: pick a playlist.", from: "Tom")
        XCTAssertEqual(r.action, .ask(question: "Which playlist: Deep Focus or Lo-Fi?"))
        XCTAssertEqual(jerry.turns.last?.to, "Tom")
        XCTAssertEqual(jerry.turns.last?.text, "Which playlist: Deep Focus or Lo-Fi?")
    }

    func testCustomToolsAreAnsweredByTheApp() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        var memory = Memory()
        tom.extraTools = Memory.tools
        tom.custom = { name, args in Memory.run(name, args, on: &memory) }
        model.script = [#"{"tool": "remember", "arguments": {"section": "user_prefs", "note": "Uses Spotify, not Apple Music."}}"#, "Noted."]
        let r = try await tom.reply("I use Spotify, by the way.")
        XCTAssertEqual(r.text, "Noted.")
        XCTAssertEqual(memory.sections[0].notes, ["Uses Spotify, not Apple Music."])
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("Noted in user_prefs"))
        // The memory is in the prompt, read afresh each turn.
        tom.extraPrompt = { memory.prompt() }
        XCTAssertTrue(tom.systemPrompt().contains("- Uses Spotify, not Apple Music."))
    }

    func testOverhearingAndNotesRideWithTheNextQuestion() async throws {
        let model = FakeModel()
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        jerry.overhear("What's the time?", from: "the user", to: "Tom")
        jerry.note("Your answer didn't reach Tom.")
        model.script = ["Hi there."]
        _ = try await jerry.reply("Jerry, are you there?")
        let m = model.sent[0].messages
        XCTAssertEqual(m.map { $0["role"] as? String }, ["system", "user", "user", "user"])
        XCTAssertTrue(((m[1]["content"] as? String) ?? "").hasPrefix("(Overheard, no answer wanted: the user said to Tom:"))
        XCTAssertTrue(((m[2]["content"] as? String) ?? "").hasPrefix("Note from the Mac (not the user):"))
        XCTAssertEqual(jerry.turns.last?.name, "Jerry")
        // A failed question takes its turns with it, the teammate's message too.
        model.fail = AssistantError.unreachable("x")
        _ = try? await jerry.reply("Look it up.", from: "Tom")
        XCTAssertEqual(jerry.turns.count, 2)
    }

    func testActivityIsReportedAsItHappens() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        var seen: [Conversation.Activity] = []
        chat.onActivity = { seen.append($0) }
        model.script = [#"{"tool": "list_chats"}"#, "None."]
        _ = try await chat.ask("Any chats?")
        XCTAssertEqual(seen, [.model, .tool("list_chats"), .model, .idle])
    }

    func testRecordsFromBeforeHaveNoNames() throws {
        let data = Data(#"{"role":"assistant","text":"Lima.","time":"2024-01-01T00:00:00Z"}"#.utf8)
        let t = try LibraryStore.decoder.decode(ChatTurn.self, from: data)
        XCTAssertNil(t.name)
        XCTAssertEqual(t.speaker, "Tom")
        XCTAssertEqual(ChatTurn(role: .user, text: "x").speaker, "You")
        XCTAssertEqual(ChatTurn(role: .assistant, text: "x", name: "Jerry").speaker, "Jerry")
        XCTAssertEqual(ChatTurn(role: .system, text: "j1 done").speaker, "Room")
    }
}

/// The job board: the harness's record of what Jerry is asked, and what came of it.
final class JobsTests: XCTestCase {
    let session = UUID()

    func testJobsQueueInOrderAndSentBackOnesGoFirst() {
        var board = JobBoard()
        let a = board.delegate(Job.Spec(goal: "music"), session: session)
        let b = board.delegate(Job.Spec(goal: "timer"), session: session)
        XCTAssertEqual(a.id, "j1")
        XCTAssertEqual(b.id, "j2")
        XCTAssertEqual(board.nextQueued()?.id, "j1")
        XCTAssertNotNil(board.start("j1"))
        XCTAssertNil(board.nextQueued(), "one at a time")
        XCTAssertEqual(board.current?.id, "j1")
        XCTAssertNotNil(board.finish("j1", Job.Result(summary: "Playing at 65.")))
        XCTAssertEqual(board.job("j1")?.status, .done)
        XCTAssertEqual(board.nextQueued()?.id, "j2")
        // Sent back: a revision, and it goes before j2.
        let sent = board.message("j1", "Volume 65; spec says 40. Fix it.")
        XCTAssertEqual(sent.job?.revisions, 1)
        XCTAssertEqual(sent.job?.status, .queued)
        XCTAssertNil(sent.job?.result)
        XCTAssertTrue(sent.result.contains("revision 1"))
        XCTAssertEqual(board.nextQueued()?.id, "j1")
        XCTAssertEqual(board.took("j1"), ["Volume 65; spec says 40. Fix it."])
        XCTAssertEqual(board.took("j1"), [])
        XCTAssertEqual(board.open.map(\.id), ["j1", "j2"])
        XCTAssertEqual(board.job("j1")?.headline, "j1 (revision 1): Queued")
    }

    func testBlockedJobsWaitForTomAndAreUnblockedByHisMessage() {
        var board = JobBoard()
        board.delegate(Job.Spec(goal: "pick a playlist"), session: session)
        board.start("j1")
        XCTAssertNotNil(board.block("j1", question: "Deep Focus or Lo-Fi?"))
        XCTAssertEqual(board.job("j1")?.status, .blocked)
        XCTAssertEqual(board.job("j1")?.blockedOn, "Deep Focus or Lo-Fi?")
        XCTAssertTrue(board.status("j1").contains("Jerry asks: Deep Focus or Lo-Fi?"))
        XCTAssertNil(board.nextQueued())
        let r = board.message("job 1", "Deep Focus.")
        XCTAssertEqual(r.job?.status, .queued)
        XCTAssertNil(r.job?.blockedOn)
        XCTAssertTrue(r.result.contains("unblocked"))
        XCTAssertEqual(board.nextQueued()?.id, "j1")
        let brief = JobBoard.briefing(board.job("j1")!, messages: board.took("j1"))
        XCTAssertTrue(brief.contains("Messages for you (from Tom; and from Jane, the reviewer, when she stepped in: do as she says): Deep Focus."))
        XCTAssertTrue(brief.hasPrefix("Job j1 from Tom:\nGoal: pick a playlist"))
    }

    func testApprovalsAreWrittenByTheHarness() {
        var board = JobBoard()
        board.delegate(Job.Spec(goal: "play"), session: session)
        board.start("j1")
        XCTAssertEqual(board.proposed("j1", tool: "run_script", arguments: #"{"name": "play"}"#)?.status, .awaitingApproval)
        XCTAssertNil(board.nextQueued(), "Jerry doesn't switch jobs while the user holds him")
        XCTAssertEqual(board.decided("j1", tool: "run_script", approved: true)?.status, .running)
        board.ran("j1", ToolUse(name: "run_script", arguments: "{}", result: "ok"))
        XCTAssertEqual(board.job("j1")?.tools.count, 1)
        let kinds = board.job("j1")!.events.map(\.kind)
        XCTAssertTrue(kinds.contains(.toolProposed))
        XCTAssertTrue(kinds.contains(.toolApproved))
        XCTAssertTrue(kinds.contains(.toolResult))
        XCTAssertEqual(JobBoard.line(board.job("j1")!.events.first { $0.kind == .toolProposed }!), "proposed run_script(name: play)")
        XCTAssertEqual(board.decided("j1", tool: "save", approved: false)?.events.last?.kind, .toolRejected)
    }

    func testCancelFailAndTheRevisionLimit() {
        var board = JobBoard()
        board.delegate(Job.Spec(goal: "x"), session: session)
        XCTAssertTrue(board.cancel("j9").result.contains("No job called j9"))
        XCTAssertEqual(board.cancel("j1").job?.status, .failed)
        XCTAssertTrue(board.cancel("j1").result.contains("already failed"))
        XCTAssertTrue(board.message("j1", "hi").result.contains("failed"))
        board.delegate(Job.Spec(goal: "y"), session: session)
        for i in 0..<JobBoard.maxRevisions {
            board.start("j2")
            board.finish("j2", Job.Result(summary: "try \(i)"))
            XCTAssertNotNil(board.message("j2", "again").job)
        }
        board.start("j2")
        board.finish("j2", Job.Result(summary: "last"))
        let refused = board.message("j2", "again")
        XCTAssertNil(refused.job)
        XCTAssertTrue(refused.result.contains("come back 3 times"))
        XCTAssertEqual(board.fail("j2", why: "model gone"), nil, "a done job can't fail")
        board.delegate(Job.Spec(goal: "z"), session: session)
        board.start("j3")
        XCTAssertEqual(board.fail("j3", why: "Ollama gone")?.status, .failed)
    }

    func testOpenJobsAreInTomsPromptAndRecoverAfterARestart() throws {
        var board = JobBoard()
        board.delegate(Job.Spec(goal: "music"), session: session)
        board.start("j1")
        board.proposed("j1", tool: "x", arguments: "{}")
        let other = UUID()
        board.delegate(Job.Spec(goal: "timer"), session: other)
        XCTAssertEqual(JobBoard().prompt(session: other), "")
        let p = board.prompt(session: other)
        XCTAssertTrue(p.contains("- j1: Waiting for your approval (from an earlier chat). music"))
        XCTAssertTrue(p.contains("- j2: Queued. timer"))
        // Round trip, as the app keeps it.
        let data = try LibraryStore.encoder.encode(board)
        var back = try LibraryStore.decoder.decode(JobBoard.self, from: data)
        XCTAssertEqual(back.jobs.map(\.id), ["j1", "j2"])
        XCTAssertEqual(back.jobs.map(\.status), [.awaitingApproval, .queued])
        XCTAssertEqual(back.job("j1")?.events.count, board.job("j1")?.events.count)
        back.recover()
        XCTAssertEqual(back.job("j1")?.status, .queued)
        XCTAssertEqual(back.delegate(Job.Spec(goal: "w"), session: session).id, "j3")
        back.clearFinished()
        XCTAssertEqual(back.jobs.count, 3)
    }

    func testTheToolArgumentsAreReadLoosely() {
        let spec = JobTools.spec(["task": "Do it", "constraints": "a; b\nc", "done": "done", "returns": "r"])
        XCTAssertEqual(spec?.goal, "Do it")
        XCTAssertEqual(spec?.constraints, ["a", "b", "c"])
        XCTAssertEqual(spec?.doneCriteria, "done")
        XCTAssertEqual(spec?.returns, "r")
        XCTAssertNil(JobTools.spec(["goal": "  "]))
        XCTAssertEqual(JobTools.jobID(["job_id": 17.0]), "j17")
        XCTAssertEqual(JobTools.jobID(["id": "J17"]), "J17")
        XCTAssertEqual(JobBoard.normalize("Job 17"), "j17")
        XCTAssertEqual(JobBoard.normalize("17"), "j17")
        XCTAssertEqual(JobTools.result(["result": "Done."])?.summary, "Done.")
        XCTAssertEqual(JobTools.result(["details": "Only details."])?.summary, "Only details.")
        XCTAssertNil(JobTools.result([:]))
    }

    func testWhatTheUserSaysToApprove() {
        XCTAssertEqual(JobTools.approval("Approve."), true)
        XCTAssertEqual(JobTools.approval("Yes, go ahead."), true)
        XCTAssertEqual(JobTools.approval("Okay, do it."), true)
        XCTAssertEqual(JobTools.approval("Go ahead"), true)
        XCTAssertEqual(JobTools.approval("No."), false)
        XCTAssertEqual(JobTools.approval("Reject that."), false)
        XCTAssertEqual(JobTools.approval("Don't."), false)
        XCTAssertNil(JobTools.approval("What time is it?"))
        XCTAssertNil(JobTools.approval("Yes, but first tell me what it does to the file"))
        XCTAssertNil(JobTools.approval(""))
    }
}

/// Tom's memory: a few notes he reads every turn and keeps himself, under the user's eye.
final class MemoryTests: XCTestCase {
    func testRememberAndForget() {
        var m = Memory()
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.remember(section: "user_prefs", note: "Uses Spotify."), "Noted in user_prefs (1 of 60 notes).")
        XCTAssertEqual(m.remember(section: "preferences", note: "Uses Spotify."), "Already noted in user_prefs.")
        XCTAssertEqual(m.remember(section: "playbook", note: "Name set_volume in done_criteria."), "Noted in jerry_playbook (2 of 60 notes).")
        XCTAssertTrue(m.remember(section: "dreams", note: "x").hasPrefix("No section called dreams."))
        XCTAssertEqual(m.remember(section: "failures", note: "  "), "Give the note to remember.")
        XCTAssertEqual(m.forget(section: "user_prefs", note: "spotify"), "Forgotten.")
        XCTAssertEqual(m.forget(section: "user_prefs", note: "spotify"), "No note in user_prefs says that.")
        XCTAssertEqual(m.noteCount, 1)
        XCTAssertTrue(m.prompt().contains("- Name set_volume in done_criteria."))
        XCTAssertTrue(m.prompt().contains("user_prefs (what the user likes"))
        XCTAssertTrue(m.text.hasPrefix("# User preferences\n(nothing yet)"))
    }

    func testTheMemoryIsBounded() {
        var m = Memory()
        for i in 0..<Memory.maxNotes { XCTAssertTrue(m.remember(section: "failures", note: "note \(i)").hasPrefix("Noted")) }
        XCTAssertTrue(m.remember(section: "failures", note: "one more").contains("full"))
        XCTAssertEqual(m.forget(section: "failures", note: "note 1"), "Forgotten.")
        XCTAssertTrue(m.forget(section: "failures", note: "note").contains("More than one"))
        let long = String(repeating: "a", count: 300)
        _ = m.remember(section: "user_prefs", note: long)
        XCTAssertEqual(m.sections[0].notes[0].count, Memory.maxNoteLength)
    }

    func testTheToolsAndTheStore() throws {
        var m = Memory()
        XCTAssertEqual(Memory.run("remember", ["note": "Likes it short."], on: &m), "Noted in user_prefs (1 of 60 notes).")
        XCTAssertEqual(Memory.run("forget", ["section": "user_prefs", "text": "short"], on: &m), "Forgotten.")
        XCTAssertNil(Memory.run("list_chats", [:], on: &m))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)/memory.json")
        let store = MemoryStore(url: url)
        XCTAssertTrue(store.memory.isEmpty)
        m.tomInstructions = "Call me Sam."
        _ = m.remember(section: "failures", note: "j1: said queue, meant play")
        try store.save(m)
        let again = MemoryStore(url: url)
        XCTAssertEqual(again.memory, m)
        XCTAssertEqual(again.memory.tomInstructions, "Call me Sam.")
    }
}

/// Jane, the reviewer, and standing down.
final class ReviewerTests: XCTestCase {
    func testTheReviewerSeesOnlyTheJob() {
        var board = JobBoard()
        board.delegate(Job.Spec(goal: "focus music", doneCriteria: "playing at 40 or less"), session: UUID(), asked: "Put on something for focus.")
        board.start("j1")
        board.said("j1", "Searching.")
        board.ran("j1", ToolUse(name: "web_search", arguments: #"{"query": "focus"}"#, result: "lots"))
        board.finish("j1", Job.Result(summary: "Playing at 65."))
        _ = board.message("j1", "Volume is 65; the spec says 40.")
        let r = JobBoard.review(board.job("j1")!)
        XCTAssertTrue(r.hasPrefix("Job j1, sent back by Tom (revision 1)."))
        XCTAssertTrue(r.contains("What the user said just before Tom delegated it: Put on something for focus."))
        XCTAssertTrue(r.contains("- Jerry: Searching."))
        XCTAssertTrue(r.contains("- web_search ran"))
        XCTAssertFalse(r.contains("lots"), "tool results stay in L3")
        XCTAssertTrue(r.contains("- result: Playing at 65."))
        XCTAssertTrue(r.contains("Tom's message sending it back: Volume is 65; the spec says 40."))
        board.advise("j1", "Set the volume before you finish, and check it.")
        let brief = JobBoard.briefing(board.job("j1")!, messages: board.took("j1"))
        XCTAssertTrue(brief.contains("Jane, the reviewer, says: Set the volume before you finish, and check it."))
        XCTAssertTrue(brief.contains("Volume is 65; the spec says 40."))
        XCTAssertEqual(board.job("j1")?.events.last?.kind, .advice)
        XCTAssertEqual(JobBoard.line(board.job("j1")!.events.last!), "Jane: Set the volume before you finish, and check it.")
        XCTAssertTrue(Team.reviewerPrompt().hasPrefix("You are Jane, the reviewer."))
    }

    func testHoldingOn() {
        XCTAssertTrue(Team.isHold("(hold) The search is still running."))
        XCTAssertTrue(Team.isHold("Hold on: j3 is waiting on your approval."))
        XCTAssertFalse(Team.isHold("(nothing)"))
        XCTAssertFalse(Team.isHold("I'm holding the door."))
        XCTAssertEqual(Team.withoutHold("(hold) The search is still running."), "The search is still running.")
        XCTAssertEqual(Team.withoutHold("Hold on: j3 waits."), "j3 waits.")
        XCTAssertTrue(Team.idleQuestion(minutes: "3 minutes", openJobs: "j3: Running").contains("(hold)"))
    }
}

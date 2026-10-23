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
        XCTAssertEqual(chat.tools.map(\.name), ["delegate", "ask_jane", "job_status", "message_jerry", "cancel_job", "stop_everything"])
        XCTAssertTrue(chat.systemPrompt().contains("- delegate:"))
        XCTAssertTrue(chat.systemPrompt().contains("You are the face"))
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
        jerry.needsApproval = { $0 == "list_library" }
        jerry.approval = { call in
            asked.append(call.name)
            return asked.count == 1            // the first is approved, the second rejected
        }
        jerry.enabled = [Skills.library.id]
        model.script = [
            #"I'll work it out. {"tool": "list_library", "arguments": {"query": "6 * 7"}}"#,
            #"And once more. {"tool": "list_library", "arguments": {"query": "1 + 1"}}"#,
            #"{"tool": "finish", "arguments": {"summary": "6 times 7 is 42.", "details": "Worked it out; the second sum was refused."}}"#,
        ]
        let r = try await jerry.reply(JobBoard.briefing(Job(id: "j1", session: UUID(), spec: Job.Spec(goal: "6 times 7")), messages: []), from: "Tom")
        XCTAssertEqual(r.action, .finish(Job.Result(summary: "6 times 7 is 42.", details: "Worked it out; the second sum was refused.")))
        XCTAssertEqual(narrated, ["I'll work it out.", "And once more."])
        XCTAssertEqual(asked, ["list_library", "list_library"])
        XCTAssertEqual(uses.map(\.result), ["Nothing in the library matches.", AssistantTools.rejectedMessage])
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

/// Keeping small models on track: the prompts show the shape, and a turn that drifts (words
/// where a call was due, a call that didn't parse, too many rounds) is caught and asked again.
final class RecoveryTests: XCTestCase {
    func testThePromptsShowEachOneItsOwnShape() {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        let lead = tom.systemPrompt()
        XCTAssertTrue(lead.contains("1. Every request from the user is a job"))
        XCTAssertTrue(lead.contains("An example, for the shape only."))
        XCTAssertTrue(lead.contains(#"{"tool": "delegate", "arguments": {"goal": "…""#), "the manual's example is his own tool")
        XCTAssertFalse(lead.contains(#"{"tool": "list_chats""#))
        XCTAssertTrue(lead.contains("never the same thing twice while it's open"))
        XCTAssertTrue(lead.contains(#"{"tool": "ask_jane", "arguments": {"goal": "What are the five senses?""#), "the brain is shown too")
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        let member = jerry.systemPrompt()
        XCTAssertTrue(member.contains("1. Every answer of yours is a tool call"))
        XCTAssertTrue(member.contains(#"{"tool": "finish", "arguments": {"summary": "…""#))
        XCTAssertTrue(member.contains("say in a few words what you're doing, then the call as one line of JSON"))
        XCTAssertTrue(member.contains("Never just stop"))
        // Alone: the manual as before.
        XCTAssertTrue(Conversation(llm: model, model: "m", library: { [] }).systemPrompt().contains(#"{"tool": "list_chats", "arguments": {"query": "budget"}}"#))
        // Jerry's briefing from Tom tells him what to do with it, not to answer the user.
        XCTAssertTrue(Team.message("Job j1", from: "Tom", toWorker: true).contains("end with finish or ask_tom"))
        XCTAssertTrue(Team.message("Hi", from: "Jerry").contains("answer him, or the user"))
    }

    func testWhatCountsAsSilenceTalkingToJerryAndABrokenCall() {
        XCTAssertTrue(Team.isSilent("Nothing to add."))
        XCTAssertTrue(Team.isSilent("(no action needed)"))
        XCTAssertTrue(Team.isSilent("nothing to say"))
        XCTAssertFalse(Team.isSilent("Nothing to add, but the timer's set."))
        XCTAssertTrue(Team.speaksToTeammate("Jerry, look up the weather in Lagos."))
        XCTAssertTrue(Team.speaksToTeammate("Hey Jerry: search for focus playlists"))
        XCTAssertFalse(Team.speaksToTeammate("Jerry's on it."))
        XCTAssertFalse(Team.speaksToTeammate("I'll ask Jerry to check."))
        XCTAssertFalse(Team.speaksToTeammate("(nothing)"))
        XCTAssertTrue(Team.looksLikeBrokenCall(#"{"tool": "delegate", "arguments": {"goal": "Weather in"#))
        XCTAssertTrue(Team.looksLikeBrokenCall(#"{'tool': 'finish', 'arguments': {'summary': 'Done'}}"#))
        XCTAssertFalse(Team.looksLikeBrokenCall(#"{"tool": "finish", "arguments": {"summary": "Done"}}"#))
        XCTAssertFalse(Team.looksLikeBrokenCall("The tool's ready."))
    }

    func testJerryWhoStopsInWordsIsAskedForTheCall() async throws {
        let model = FakeModel()
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        model.script = ["It's 42.", #"{"tool": "finish", "arguments": {"summary": "6 times 7 is 42."}}"#]
        let r = try await jerry.reply("Job j1 from Tom: 6 times 7.", from: "Tom")
        XCTAssertEqual(r.action, .finish(Job.Result(summary: "6 times 7 is 42.")))
        XCTAssertEqual(model.sent.count, 2)
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("your answer had no tool call"))
        // Once: words again are his result (the app takes them as such).
        model.script = ["Still 42.", "Really, 42."]
        let again = try await jerry.reply("Job j2 from Tom: 6 times 7, again.", from: "Tom")
        XCTAssertNil(again.action)
        XCTAssertEqual(again.text, "Really, 42.")
        XCTAssertEqual(model.sent.count, 4)
    }

    func testJerryOutOfRoundsIsAskedToFinish() async throws {
        let model = FakeModel()
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        jerry.enabled = [Skills.library.id]
        jerry.maxToolRounds = 2
        model.script = [
            #"One. {"tool": "list_library", "arguments": {"query": "1"}}"#,
            #"Two. {"tool": "list_library", "arguments": {"query": "2"}}"#,
            #"Three. {"tool": "list_library", "arguments": {"query": "3"}}"#,
            #"{"tool": "finish", "arguments": {"summary": "2, 4, and I stopped there."}}"#,
        ]
        let r = try await jerry.reply("Job j1 from Tom: sums.", from: "Tom")
        XCTAssertEqual(r.action, .finish(Job.Result(summary: "2, 4, and I stopped there.")))
        XCTAssertEqual(jerry.toolCalls, ["list_library", "list_library", "finish"], "the third look wasn't run")
        XCTAssertTrue(((model.sent[3].messages.last?["content"] as? String) ?? "").contains("as many tool calls as a job gets"))
    }

    func testTomTalkingToJerryInWordsIsToldToCall() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = ["Jerry, check the weather in Lagos.", #"On it. {"tool": "delegate", "arguments": {"goal": "Weather in Lagos", "done_criteria": "read from a weather page", "return": "temperature"}}"#]
        let r = try await tom.reply("What's the weather in Lagos?")
        XCTAssertEqual(r.text, "On it.")
        guard case .delegate? = r.action else { return XCTFail("no delegation") }
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("he heard nothing"))
    }

    func testACallThatDidntParseIsAskedAgain() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = [#"{"tool": "delegate", "arguments": {"goal": "Weather in"#, #"{"tool": "delegate", "arguments": {"goal": "Weather in Lagos"}}"#]
        let r = try await tom.reply("Weather?")
        guard case .delegate(let spec)? = r.action else { return XCTFail("no delegation") }
        XCTAssertEqual(spec.goal, "Weather in Lagos")
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("couldn't be read"))
    }

    func testOnlyTheFirstMoveInAnAnswerIsMade() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = [#"{"tool": "delegate", "arguments": {"goal": "a"}} {"tool": "delegate", "arguments": {"goal": "b"}}"#, "(nothing)"]
        let r = try await tom.reply("Do a and b.")
        XCTAssertEqual(r.action, .delegate(Job.Spec(goal: "a")))
        _ = try await tom.wake()
        let m = model.sent[1].messages
        XCTAssertTrue(((m[3]["content"] as? String) ?? "").contains("only your first call (delegate) was carried out; delegate wasn't"))
    }

    func testInterjectionsReachTheModelMidTurn() async throws {
        let model = FakeModel()
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        jerry.enabled = [Skills.library.id]
        model.script = [#"{"tool": "list_library", "arguments": {}}"#, #"{"tool": "finish", "arguments": {"summary": "2"}}"#]
        jerry.onToolUse = { _ in jerry.interject("Tom says, about this job: also add 3.") }
        _ = try await jerry.reply("Job j1 from Tom: 1 + 1.", from: "Tom")
        let m = model.sent[1].messages
        XCTAssertEqual(m.map { $0["role"] as? String }, ["system", "user", "assistant", "user", "user"])
        XCTAssertEqual(m[4]["content"] as? String, "Note from the Mac (not the user): Tom says, about this job: also add 3.")
    }

    func testTheSameGoalIsntDelegatedTwice() {
        var board = JobBoard()
        board.delegate(Job.Spec(goal: "Today's weather in Lagos"), session: UUID())
        XCTAssertEqual(board.openJob(withGoal: "today's weather in Lagos.")?.id, "j1")
        XCTAssertNil(board.openJob(withGoal: "Tomorrow's weather in Lagos"))
        board.start("j1")
        board.finish("j1", Job.Result(summary: "Sunny."))
        XCTAssertNil(board.openJob(withGoal: "Today's weather in Lagos"), "a done job can be asked again")
    }
}

/// Tom is the face: every request goes to Jerry (to do) or Jane (to know), he reads where the jobs
/// stand before he answers, and a promise without the call is caught.
final class RouterTests: XCTestCase {
    func testWhatIsARequestAndWhatIsAPromise() {
        XCTAssertTrue(Team.asksForAJob("What are the five senses?"))
        XCTAssertTrue(Team.asksForAJob("Put on some music."))
        XCTAssertFalse(Team.asksForAJob("Thanks, Tom."))
        XCTAssertFalse(Team.asksForAJob("Hi there"))
        XCTAssertFalse(Team.asksForAJob("How is it going?"))
        XCTAssertFalse(Team.asksForAJob("Is it done yet?"))
        XCTAssertFalse(Team.asksForAJob("Any news?"))
        XCTAssertTrue(Team.promisesWork("I'll have Jerry check."))
        XCTAssertTrue(Team.promisesWork("Let me look into that."))
        XCTAssertTrue(Team.promisesWork("Jerry's on it."))
        XCTAssertTrue(Team.promisesWork("One moment."))
        XCTAssertFalse(Team.promisesWork("Lagos is 28 and sunny."))
        XCTAssertFalse(Team.promisesWork("(nothing)"))
        XCTAssertTrue(Team.asksBack("Which city?"))
        XCTAssertFalse(Team.asksBack("Shall I have Jerry check?") && Team.promisesWork("Shall I have Jerry check?"))
    }

    func testAPromiseWithoutTheCallIsCaught() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = ["I'll have Jerry check the weather.", #"On it. {"tool": "delegate", "arguments": {"goal": "Weather in Lagos"}}"#]
        let r = try await tom.reply("What's the weather in Lagos?")
        guard case .delegate(let spec)? = r.action else { return XCTFail("no delegation") }
        XCTAssertEqual(spec.goal, "Weather in Lagos")
        XCTAssertNil(spec.worker)
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("made no job, so nothing is being done"))
    }

    func testKnowledgeGoesToJane() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        // He answers it himself first: told it's a job, he asks Jane.
        model.script = ["Sight, hearing, smell, taste and touch.", #"I'll ask Jane. {"tool": "ask_jane", "arguments": {"goal": "What are the five senses?", "return": "the five"}}"#]
        let r = try await tom.reply("What are the five senses?")
        XCTAssertEqual(r.text, "I'll ask Jane.")
        guard case .delegate(let spec)? = r.action else { return XCTFail("no question") }
        XCTAssertEqual(spec.worker, "Jane")
        XCTAssertTrue(spec.isQuestion)
        XCTAssertEqual(tom.turns.last?.to, "Jane")
        XCTAssertEqual(AssistantTools.canonical("consult_jane"), "ask_jane")
        // A greeting, or a question back, is let be.
        model.script = ["Hi! What can I do?"]
        let hi = try await tom.reply("Hello")
        XCTAssertEqual(hi.text, "Hi! What can I do?")
        model.script = ["Which city?"]
        let back = try await tom.reply("What's the weather?")
        XCTAssertEqual(back.text, "Which city?")
        XCTAssertEqual(model.sent.count, 4)
        // ask_jerry with a job and no goal is a word about that job.
        model.script = [#"{"tool": "ask_jerry", "arguments": {"job_id": "j2", "message": "Use Celsius."}}"#]
        let word = try await tom.reply("Tell him Celsius")
        XCTAssertEqual(word.action, .message(job: "j2", text: "Use Celsius."))
    }

    func testTomReadsWhereTheJobsStandBeforeEachAnswer() async throws {
        var board = JobBoard()
        let session = UUID()
        board.delegate(Job.Spec(goal: "Today's weather in Lagos"), session: session)
        board.delegate(Job.Spec(goal: "The five senses", worker: "Jane"), session: session)
        board.start("j1")
        XCTAssertEqual(board.standing(session: session), "j1 (Jerry): running: Today's weather in Lagos; j2 (Jane): queued: The five senses")
        XCTAssertNil(JobBoard().standing(session: session))
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        let standing = board.standing(session: session)
        tom.situation = { standing }
        model.script = ["Jerry's still on the weather; nothing's back yet."]
        let r = try await tom.reply("How's it going?")
        XCTAssertEqual(r.text, "Jerry's still on the weather; nothing's back yet.")
        let said = (model.sent[0].messages.last?["content"] as? String) ?? ""
        XCTAssertTrue(said.hasPrefix("Where the jobs stand now (from the Mac): j1 (Jerry): running"))
        XCTAssertTrue(said.contains("The user says: How's it going?"))
        XCTAssertEqual(tom.turns.first?.text, "How's it going?", "the room shows what was said, not the note")
    }

    func testJaneHasHerOwnQueueAndBriefing() {
        var board = JobBoard()
        let session = UUID()
        board.delegate(Job.Spec(goal: "Weather"), session: session)
        board.delegate(Job.Spec(goal: "What are the five senses?", returns: "the five", worker: "Jane"), session: session)
        XCTAssertEqual(board.nextQueued()?.id, "j1")
        XCTAssertEqual(board.nextQueued(for: "Jane")?.id, "j2")
        board.start("j1")
        XCTAssertEqual(board.nextQueued(for: "Jane")?.id, "j2", "Jerry's job doesn't hold Jane up")
        board.start("j2")
        XCTAssertEqual(board.current(for: "Jane")?.id, "j2")
        XCTAssertEqual(board.current?.id, "j1")
        let q = JobBoard.question(board.job("j2")!)
        XCTAssertTrue(q.hasPrefix("Question j2 from Tom: What are the five senses?"))
        XCTAssertTrue(q.contains("He wants back: the five"))
        XCTAssertEqual(board.job("j2")?.headline, "j2 (Jane): Running")
        board.requeue("j2")
        XCTAssertEqual(board.job("j2")?.status, .queued)
        XCTAssertEqual(board.job("j1")?.status, .running, "requeue takes one job off, not all")
        XCTAssertTrue(Team.thinkerPrompt().hasPrefix("You are Jane, the brain of the team."))
    }
}

/// Tool Mac Tool Run's scripts and flows, fetched once and told to the models.
final class CatalogTests: XCTestCase {
    func testTheCatalogIsReadAndTold() async {
        let runner = FakeRunner()
        runner.script = [(200, ["folder": "/Users/sam/Scripts", "scripts": [
            ["name": "browser/page-info.sh", "group": "browser", "language_name": "Bash", "summary": "The page in front of your browser", "dangers": [String]()],
            ["name": "tidy.py", "group": "scripts", "language_name": "Python", "summary": "Moves old downloads to the Trash", "dangers": ["deletes files"]],
        ]]), (200, ["flows": [["name": "morning.flow", "summary": "The day's first checks"]]])]
        let c = await ToolRunTools.catalog(via: runner)
        XCTAssertEqual(c?.scripts.map(\.name), ["browser/page-info.sh", "tidy.py"])
        XCTAssertEqual(c?.flows.map(\.name), ["morning.flow"])
        XCTAssertEqual(runner.sent.map(\.path), ["/api/scripts", "/api/flows"])
        let prompt = c?.prompt ?? ""
        XCTAssertTrue(prompt.contains("- browser/page-info.sh (Bash): The page in front of your browser"))
        XCTAssertTrue(prompt.contains("[can't be undone: deletes files]"))
        XCTAssertTrue(prompt.contains("- morning.flow: The day's first checks"))
        XCTAssertTrue((c?.summary ?? "").contains("tidy.py (Moves old downloads to the Trash)"))
        runner.down = true
        let none = await ToolRunTools.catalog(via: runner)
        XCTAssertNil(none)
        XCTAssertEqual(ToolRunTools.Catalog().prompt, "")
    }
}

/// Tom with Jerry never says "I can't": he delegates.
final class DelegationTests: XCTestCase {
    func testSayingHeCantIsCaught() {
        XCTAssertTrue(Team.claimsInability("I don't have access to real-time weather data."))
        XCTAssertTrue(Team.claimsInability("I can't check that for you."))
        XCTAssertTrue(Team.claimsInability("I'm not able to browse the web."))
        XCTAssertTrue(Team.claimsInability("I don't know, sorry."))
        XCTAssertTrue(Team.claimsInability("As an AI, I have no way to see your files."))
        XCTAssertFalse(Team.claimsInability("On it: I'm asking Jerry to check the weather."))
        XCTAssertFalse(Team.claimsInability("A cat's a fine idea."))
        XCTAssertFalse(Team.claimsInability("(nothing)"))
    }

    func testTomIsToldToDelegateWhenHeSaysHeCant() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        tom.enabled = [Skills.library.id, Skills.scripts.id]
        tom.runner = FakeRunner()
        XCTAssertTrue(tom.systemPrompt().contains("Jerry's skills now: library"))
        XCTAssertTrue(tom.systemPrompt().contains("never say \"I can't\""))
        model.script = ["I don't have access to the weather.", #"Let me find out. {"tool": "delegate", "arguments": {"goal": "Today's weather in Lagos", "done_criteria": "the forecast, from a weather site", "return": "temperature and conditions"}}"#]
        let r = try await tom.reply("What's the weather in Lagos?")
        XCTAssertEqual(r.text, "Let me find out.")
        guard case .delegate(let spec)? = r.action else { return XCTFail("no delegation") }
        XCTAssertEqual(spec.goal, "Today's weather in Lagos")
        XCTAssertEqual(model.sent.count, 2)
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("Jerry has the tools for that"))
        // Once a question: an honest "can't" the second time stands.
        model.script = ["I can't know that.", "That isn't something anyone can look up."]
        let again = try await tom.reply("What am I thinking?")
        XCTAssertEqual(again.text, "That isn't something anyone can look up.")
        XCTAssertEqual(model.sent.count, 4)
        // Alone (no Jerry), nothing is said about it.
        let alone = Conversation(llm: model, model: "m", library: { [] })
        model.script = ["I don't have access to that."]
        let said = try await alone.ask("Weather?")
        XCTAssertEqual(said, "I don't have access to that.")
    }
}

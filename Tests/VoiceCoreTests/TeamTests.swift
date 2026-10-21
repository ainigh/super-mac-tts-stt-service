import XCTest
@testable import VoiceCore

/// Tom and Jerry: two assistants in one room with the user.
final class TeamTests: XCTestCase {
    func testJerryIsAddressedByName() {
        XCTAssertEqual(Team.addressed("Jerry, what do you think?")?.rest, "What do you think?")
        XCTAssertEqual(Team.addressed("Jerry, what do you think?")?.to, "Jerry")
        XCTAssertEqual(Team.addressed("Hey Jerry how's it going")?.rest, "How's it going")
        XCTAssertEqual(Team.addressed("Gerry.")?.rest, "")
        XCTAssertNil(Team.addressed("Tell Jerry to look it up."))
        XCTAssertNil(Team.addressed("What's the weather?"))
        XCTAssertNil(Team.addressed(""))
        // "Tom, …" is the wake word, which comes off first; then Jerry's name.
        XCTAssertEqual(Assistant.hear("Tom, Jerry, are you there?", awake: true), .wakeThen("Jerry, are you there?"))
        XCTAssertEqual(Team.addressed("Jerry, are you there?")?.rest, "Are you there?")
        // A command said to him is still a command.
        XCTAssertEqual(Assistant.hear(Team.addressed("Jerry, stop.")!.rest, awake: true), .command(.stop))
    }

    func testSilenceIsAnAnswer() {
        XCTAssertTrue(Team.isSilent("(nothing)"))
        XCTAssertTrue(Team.isSilent("Nothing."))
        XCTAssertTrue(Team.isSilent("[silence]"))
        XCTAssertFalse(Team.isSilent("Nothing much, just the weather."))
        XCTAssertFalse(Team.isSilent(""))
    }

    func testTheTeamToolIsOfferedOnlyToTheLead() {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        XCTAssertFalse(chat.activeSkills.contains { $0.id == Skills.team.id })
        XCTAssertFalse(chat.systemPrompt().contains("tell_jerry"))
        chat.team = .lead(teammate: "Jerry")
        XCTAssertTrue(chat.activeSkills.contains { $0.id == Skills.team.id })
        XCTAssertTrue(chat.systemPrompt().contains("- tell_jerry:"))
        XCTAssertTrue(chat.systemPrompt().contains("You work with Jerry"))
        XCTAssertTrue(chat.systemPrompt().hasPrefix("You are Tom,"))
        let jerry = Conversation(llm: model, model: "m", library: { [] })
        jerry.name = "Jerry"
        jerry.team = .member(lead: "Tom")
        XCTAssertFalse(jerry.activeSkills.contains { $0.id == Skills.team.id })
        XCTAssertTrue(jerry.systemPrompt().hasPrefix("You are Jerry,"))
        XCTAssertTrue(jerry.systemPrompt().contains("You work with Tom"))
        XCTAssertEqual(Skills.skill(for: "tell_jerry")?.id, "team")
        XCTAssertEqual(AssistantTools.canonical("ask_jerry"), "tell_jerry")
        XCTAssertEqual(AssistantTools.canonical("Jerry"), "tell_jerry")
    }

    func testTomHandsOffToJerryAndTheMessageIsNotDeliveredByTheChat() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = [#"Sure, I'll ask him. {"tool": "tell_jerry", "arguments": {"message": "Jerry, what's a good name for a cat?"}}"#]
        let r = try await tom.reply("Ask Jerry for a cat name.")
        XCTAssertEqual(r.text, "Sure, I'll ask him.")
        XCTAssertEqual(r.handoff?.to, "Jerry")
        XCTAssertEqual(r.handoff?.message, "Jerry, what's a good name for a cat?")
        XCTAssertFalse(r.silent)
        // One request: the call ends the turn; delivering it is the app's job, once it's been heard.
        XCTAssertEqual(model.sent.count, 1)
        XCTAssertEqual(tom.toolCalls, ["tell_jerry"])
        XCTAssertEqual(tom.turns.map(\.text), ["Ask Jerry for a cat name.", "Sure, I'll ask him.", "Jerry, what's a good name for a cat?"])
        XCTAssertEqual(tom.turns[2].to, "Jerry")
        XCTAssertEqual(tom.turns[2].name, "Tom")
        XCTAssertEqual(Assistant.transcript(tom.turns), "You: Ask Jerry for a cat name.\n\nTom: Sure, I'll ask him.\n\nTom → Jerry: Jerry, what's a good name for a cat?")

        // Jerry's answer comes to Tom as a message from him, not the user; Tom may stay quiet.
        model.script = ["(nothing)"]
        let back = try await tom.reply("Miso, or Pickle.", from: "Jerry")
        XCTAssertTrue(back.silent)
        XCTAssertEqual(back.text, "")
        XCTAssertNil(back.handoff)
        let last = model.sent.last!.messages
        XCTAssertEqual(last.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertTrue(((last[3]["content"] as? String) ?? "").hasPrefix("Message from Jerry, your teammate"))
        XCTAssertTrue(((last[3]["content"] as? String) ?? "").contains("Miso, or Pickle."))
        XCTAssertEqual(tom.turns.last?.text, "(nothing)")
        XCTAssertEqual(tom.turns[3].name, "Jerry")
        XCTAssertEqual(tom.turns[3].to, "Tom")
        // Silence isn't on the wire: the next question doesn't see an empty answer.
        model.script = ["Okay."]
        _ = try await tom.reply("Thanks.")
        XCTAssertEqual(model.sent.last!.messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user", "user"])
    }

    func testAskStillAnswersInWordsAndSilenceOnlyCountsInATeam() async throws {
        let model = FakeModel()
        let alone = Conversation(llm: model, model: "m", library: { [] })
        model.script = ["(nothing)"]
        let aloneSaid = try await alone.ask("Hi")
        XCTAssertEqual(aloneSaid, "(nothing)")
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        model.script = ["(nothing)"]
        let quiet = try await tom.ask("Hi")
        XCTAssertEqual(quiet, "")
        model.script = ["  "]
        let empty = try await tom.ask("Hi")
        XCTAssertEqual(empty, "I don't have an answer to that.")
    }

    func testTooManyHopsSendTomBackToTheUser() async throws {
        let model = FakeModel()
        let tom = Conversation(llm: model, model: "m", library: { [] })
        tom.team = .lead(teammate: "Jerry")
        tom.hops = Team.maxHops
        model.script = [#"{"tool": "tell_jerry", "arguments": {"message": "And another thing"}}"#, "Jerry and I think Miso."]
        let r = try await tom.reply("Jerry says Pickle.", from: "Jerry")
        XCTAssertNil(r.handoff)
        XCTAssertEqual(r.text, "Jerry and I think Miso.")
        XCTAssertEqual(model.sent.count, 2)
        let told = (model.sent[1].messages.last?["content"] as? String) ?? ""
        XCTAssertTrue(told.contains("gone back and forth"))
        // Without a message, it's asked for one.
        tom.hops = 0
        model.script = [#"{"tool": "tell_jerry"}"#, "Done."]
        _ = try await tom.reply("Ask Jerry.")
        XCTAssertTrue(((model.sent[3].messages.last?["content"] as? String) ?? "").contains("Give the message"))
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
    }
}

final class WavingTests: XCTestCase {
    func testAHandGoingBackAndForthIsAWaveAndAStillOneIsnt() {
        XCTAssertTrue(Waving.isWave([0.5, 0.54, 0.58, 0.55, 0.5, 0.47, 0.52, 0.57, 0.6]))
        XCTAssertTrue(Waving.isWave([0.3, 0.2, 0.3, 0.2, 0.3, 0.2, 0.3]))
        // Held still, shaking a little: not a wave.
        XCTAssertFalse(Waving.isWave([0.5, 0.51, 0.5, 0.49, 0.5, 0.51, 0.5, 0.49]))
        // Moving across once (reaching for the mouse): not a wave.
        XCTAssertFalse(Waving.isWave([0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]))
        // Once there and back: one turn, not enough.
        XCTAssertFalse(Waving.isWave([0.2, 0.3, 0.4, 0.5, 0.4, 0.3, 0.2]))
        XCTAssertFalse(Waving.isWave([0.5, 0.6, 0.5]))
    }
}

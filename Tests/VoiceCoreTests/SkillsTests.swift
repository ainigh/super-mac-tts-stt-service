import XCTest
@testable import VoiceCore

/// Stands in for the Mac: a browser that answers from a script, a clipboard, Spotlight.
final class SkillsTests: XCTestCase {
    // MARK: Hearing

    func testAPauseMidSentenceDoesntEndIt() {
        XCTAssertTrue(TurnEnd.unfinished("What's the weather like in"))
        XCTAssertTrue(TurnEnd.unfinished("I want to go to the."))
        XCTAssertTrue(TurnEnd.unfinished("Remind me to call Sam and."))
        XCTAssertTrue(TurnEnd.unfinished("So the thing is,"))
        XCTAssertTrue(TurnEnd.unfinished("Tell me about the weather"))
        XCTAssertFalse(TurnEnd.unfinished("What's the weather like in Lima?"))
        XCTAssertFalse(TurnEnd.unfinished("Tell me a joke."))
        XCTAssertFalse(TurnEnd.unfinished("Tom."))
        XCTAssertFalse(TurnEnd.unfinished("Stop"))
        XCTAssertFalse(TurnEnd.unfinished("New chat"))
        XCTAssertFalse(TurnEnd.unfinished(""))
    }

    func testTheAnswerHeardBackIsntTakenButTheUserIs() {
        let answer = "Lima is the capital of Peru, and it sits on the Pacific coast."
        XCTAssertNil(Echo.interruption("Lima is the capital of Peru", reading: answer))
        XCTAssertNil(Echo.interruption("the Pacific coast.", reading: answer))
        XCTAssertNil(Echo.interruption("capital of Peru and it sits on a", reading: answer))
        XCTAssertEqual(Echo.interruption("Stop.", reading: answer), "Stop.")
        XCTAssertEqual(Echo.interruption("stop", reading: "Get off at the next stop."), "Stop")
        XCTAssertNil(Echo.interruption("at the next stop", reading: "Get off at the next stop."))
        XCTAssertEqual(Echo.interruption("on the Pacific wait what about Chile", reading: answer), "Wait what about Chile")
        XCTAssertEqual(Echo.interruption("Actually, tell me about Bolivia instead", reading: answer), "Actually, tell me about Bolivia instead")
        XCTAssertNil(Echo.interruption("", reading: answer))
        // Misheard echo with a couple of odd words isn't taken for the user.
        XCTAssertNil(Echo.interruption("Lima is the capitol of Peru and it sits on the pacific toast", reading: answer))
        XCTAssertNil(Echo.interruption("Peru and it fits", reading: answer))
        // Without echo cancellation, only a word like "stop" said first interrupts.
        XCTAssertNil(Echo.interruption("Actually, tell me about Bolivia instead", reading: answer, cancelled: false))
        XCTAssertEqual(Echo.interruption("Wait, tell me about Bolivia", reading: answer, cancelled: false), "Wait, tell me about Bolivia")
        XCTAssertEqual(Echo.interruption("the Pacific coast stop", reading: answer, cancelled: false), "Stop")
        XCTAssertEqual(Echo.interruption("the Pacific coast. Stop talking", reading: answer, cancelled: false), "Stop talking")
    }

    // MARK: Which skills, which tools

    // MARK: The skills

    func testOnlyTheSkillsThatAreOnAndCanBeAreOffered() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        XCTAssertEqual(chat.activeSkills.map(\.id), ["library"])
        chat.save = { _ in }
        chat.runner = FakeRunner()
        XCTAssertEqual(chat.activeSkills.map(\.id), ["library", "edit", "scripts"])
        XCTAssertEqual(Skills.ids, ["library", "edit", "scripts", "team"])
        XCTAssertTrue(chat.systemPrompt().contains("that's how you reach everything else on the Mac"))
        chat.enabled = ["library"]
        XCTAssertEqual(chat.tools.map(\.name), AssistantTools.library.map(\.name))
        // A tool of a skill that's off isn't run.
        model.script = [#"{"tool": "add_note", "arguments": {"text": "x"}}"#, "Nope."]
        _ = try await chat.ask("Note x")
        XCTAssertTrue(((model.sent[1].messages[3]["content"] as? String) ?? "").contains("no tool called add_note"))
        XCTAssertEqual(Skills.skill(for: "run_script")?.id, "scripts")
        XCTAssertEqual(Skills.skill(for: "update_library")?.id, "edit")
        XCTAssertEqual(Skills.skill(for: "delegate")?.id, "team")
        XCTAssertNil(Skills.skill(for: "web_search"), "the browser is Tool Mac Tool Run's now")
        XCTAssertEqual(AssistantTools.canonical("execute"), "run_script")
    }

    func testEachToolUsedIsReported() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        var uses: [ToolUse] = []
        chat.onToolUse = { uses.append($0) }
        model.script = [#"{"tool": "list_library", "arguments": {"query": "budget"}}"#, "Nothing."]
        let answer = try await chat.ask("Anything about the budget?")
        XCTAssertEqual(answer, "Nothing.")
        XCTAssertEqual(uses.map(\.name), ["list_library"])
        XCTAssertEqual(uses[0].summary, "query: budget")
        XCTAssertEqual(uses[0].skill?.id, "library")
        XCTAssertEqual(ToolUse(name: "run_script", arguments: #"{"url": "example.com"}"#, result: "").link?.absoluteString, "https://example.com")
        XCTAssertEqual(ToolUse(name: "run_script", result: "Title: x\nAddress: https://a.com/b\nText:").link?.absoluteString, "https://a.com/b")
    }

    // MARK: Editing the library

    func testTheModelAddsAndChangesLibraryItemsButNeverChats() async throws {
        let note = LibraryRecord(kind: .note, text: "Buy milk.", title: "Shopping")
        let chatRecord = Assistant.record(id: UUID(), created: Date(), turns: [ChatTurn(role: .user, text: "Hi")], existing: nil)
        var transcript = LibraryRecord(kind: .transcript, text: "Hello there.", title: "Call")
        transcript.segments = [TimedText(start: 0, end: 1, text: "Hello there.")]
        let records = [note, chatRecord, transcript]

        let added = try XCTUnwrap(AssistantTools.edit("add_note", ["text": "Call Sam at four", "title": "Calls"], library: records))
        XCTAssertEqual(added.save?.kind, .note)
        XCTAssertEqual(added.save?.title, "Calls")
        XCTAssertTrue(added.result.hasPrefix("Added the note “Calls”"))

        let appended = try XCTUnwrap(AssistantTools.edit("update_library", ["id": String(note.id.uuidString.prefix(6)).lowercased(), "append": "Eggs.", "starred": true], library: records))
        XCTAssertEqual(appended.save?.text, "Buy milk.\nEggs.")
        XCTAssertEqual(appended.save?.starred, true)
        XCTAssertEqual(appended.result, "Done: added to its end, starred it (note “Shopping”).")

        let replaced = try XCTUnwrap(AssistantTools.edit("update_library", ["id": transcript.id.uuidString, "text": "Hi there.", "title": "The call"], library: records))
        XCTAssertEqual(replaced.save?.text, "Hi there.")
        XCTAssertNil(replaced.save?.segments)
        XCTAssertEqual(replaced.save?.title, "The call")

        XCTAssertNil(AssistantTools.edit("update_library", ["id": chatRecord.id.uuidString, "text": "x"], library: records)?.save)
        XCTAssertNil(AssistantTools.edit("update_library", ["id": note.id.uuidString], library: records)?.save)
        XCTAssertNil(AssistantTools.edit("list_chats", [:], library: records))

        // In a chat: saved, and what's read next in the same question sees it.
        let model = FakeModel()
        var saved: [LibraryRecord] = []
        let chat = Conversation(llm: model, model: "m", library: { records })
        chat.save = { saved.append($0) }
        model.script = [#"{"tool": "add_note", "arguments": {"text": "Pick up the cake"}}"#,
                        #"{"tool": "list_library", "arguments": {"query": "cake"}}"#, "Noted."]
        _ = try await chat.ask("Note: pick up the cake")
        XCTAssertEqual(saved.map(\.text), ["Pick up the cake"])
        XCTAssertTrue(((model.sent[2].messages.last?["content"] as? String) ?? "").contains("Pick up the cake"))
    }

    func testSayingItSavedWithoutSavingIsCaught() async throws {
        let model = FakeModel()
        var saved: [LibraryRecord] = []
        let chat = Conversation(llm: model, model: "m", library: { [] })
        chat.save = { saved.append($0) }
        // It claims, is told nothing was saved, and then saves it (under a name it made up).
        model.script = ["Done, I've added that to your library.", #"{"tool": "save_note", "arguments": {"text": "Call Sam"}}"#, "Saved: call Sam."]
        let answer = try await chat.ask("Add call Sam to my library")
        XCTAssertEqual(answer, "Saved: call Sam.")
        XCTAssertEqual(saved.map(\.text), ["Call Sam"])
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").hasPrefix("Note from the Mac (not the user): you said something was added"))
        // Told once: a second claim with nothing saved stands (it's said, not looped on).
        model.script = ["I've noted it in your notes.", "I've noted it in your notes."]
        _ = try await chat.ask("Note that too")
        XCTAssertEqual(model.sent.count, 5)
        XCTAssertTrue(AssistantTools.claimsLibraryChange("I’ve saved it as a note."))
        XCTAssertTrue(AssistantTools.claimsLibraryChange("It's been added to your library."))
        XCTAssertFalse(AssistantTools.claimsLibraryChange("Your library has three notes."))
        XCTAssertFalse(AssistantTools.claimsLibraryChange("I've added the numbers: 42."))
        XCTAssertEqual(AssistantTools.canonical("Save-Note"), "add_note")
        XCTAssertEqual(AssistantTools.canonical("list_chats"), "list_chats")
    }

}

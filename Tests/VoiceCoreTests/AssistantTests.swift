import XCTest
@testable import VoiceCore

/// Stands in for Ollama: answers from a script, and keeps what it was sent.
final class FakeModel: LanguageModel {
    var script: [ModelReply] = []
    var sent: [(model: String, messages: [[String: Any]], tools: [[String: Any]]?)] = []
    var fail: Error?

    func chat(model: String, messages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModelReply {
        sent.append((model, messages, tools))
        if let fail {
            self.fail = nil
            throw fail
        }
        guard !script.isEmpty else { return ModelReply(content: "Sure.") }
        return script.removeFirst()
    }
}

final class AssistantTests: XCTestCase {
    func testTheWakeWordAloneOrFirst() {
        XCTAssertEqual(Assistant.hear("Micky.", awake: false), .wake)
        XCTAssertEqual(Assistant.hear("Hey, Mickey!", awake: false), .wake)
        XCTAssertEqual(Assistant.hear("ollama", awake: false), .wake)
        XCTAssertEqual(Assistant.hear("O llama?", awake: false), .wake)
        XCTAssertEqual(Assistant.hear("Micky, what's the weather like?", awake: false), .wakeThen("What's the weather like?"))
        XCTAssertEqual(Assistant.hear("okay ollama how old is the moon", awake: false), .wakeThen("How old is the moon"))
        XCTAssertEqual(Assistant.hear("Hey Micky stop", awake: false), .command(.stop))
        // Asleep, anything else is only speech, which the caller lets by.
        XCTAssertEqual(Assistant.hear("I told Mickey about it.", awake: false), .speech("I told Mickey about it."))
        XCTAssertEqual(Assistant.hear("Stop.", awake: false), .speech("Stop."))
    }

    func testAwakeEverythingIsSpeechButTheCommands() {
        XCTAssertEqual(Assistant.hear("What's the capital of Peru?", awake: true), .speech("What's the capital of Peru?"))
        XCTAssertEqual(Assistant.hear("Stop.", awake: true), .command(.stop))
        XCTAssertEqual(Assistant.hear("Micky, stop talking.", awake: true), .command(.stop))
        XCTAssertEqual(Assistant.hear("New chat", awake: true), .command(.newChat))
        XCTAssertEqual(Assistant.hear("That's all.", awake: true), .command(.off))
        XCTAssertEqual(Assistant.hear("Goodbye!", awake: true), .command(.off))
        XCTAssertEqual(Assistant.hear("Stop the music", awake: true), .speech("Stop the music"))
        XCTAssertEqual(Assistant.hear("Micky", awake: true), .wake)
    }

    func testAnswersAreReadWithoutMarkdown() {
        XCTAssertEqual(Assistant.spoken("**Lima** is the capital of *Peru*."), "Lima is the capital of Peru.")
        XCTAssertEqual(Assistant.spoken("# Plan\n\n- Buy milk\n- Call Sam\n\n1. First\n2) Second"), "Plan\n\nBuy milk\nCall Sam\n\n1. First\n2. Second")
        XCTAssertEqual(Assistant.spoken("See [the docs](https://example.com) and run `ls`."), "See the docs and run ls.")
        XCTAssertEqual(Assistant.spoken("Here:\n```swift\nprint(1)\n```\nDone."), "Here:\n(some code, left out)\nDone.")
        XCTAssertEqual(Assistant.spoken("<think>hmm</think>Yes."), "Yes.")
        XCTAssertEqual(Assistant.spoken("2 * 3 is 6, and snake_case stays."), "2  3 is 6, and snake_case stays.")
        XCTAssertEqual(Assistant.spoken("| a | b |\n|---|---|\n| 1 | 2 |"), "a, b\n\n1, 2")
    }

    func testAChatIsKeptAsARecord() {
        let turns = [ChatTurn(role: .user, text: "What's the capital of Peru?", time: Date(timeIntervalSince1970: 10)),
                     ChatTurn(role: .assistant, text: "Lima.", time: Date(timeIntervalSince1970: 20))]
        let id = UUID()
        let r = Assistant.record(id: id, created: Date(timeIntervalSince1970: 5), turns: turns, existing: nil)
        XCTAssertEqual(r.id, id)
        XCTAssertEqual(r.kind, .chat)
        XCTAssertEqual(r.title, "What's the capital of Peru")
        XCTAssertEqual(r.text, "You: What's the capital of Peru?\n\nMicky: Lima.")
        XCTAssertEqual(r.turns, turns)
        XCTAssertEqual(r.modified, Date(timeIntervalSince1970: 20))
        var starred = r
        starred.starred = true
        let again = Assistant.record(id: id, created: r.created, turns: turns + [ChatTurn(role: .user, text: "Thanks")], existing: starred)
        XCTAssertTrue(again.starred)
        XCTAssertEqual(again.turns?.count, 3)
        XCTAssertFalse(LibraryRecord.Kind.library.contains(.chat))
    }

    func testAChatRecordRoundTripsThroughTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(folder: folder)
        let r = Assistant.record(id: UUID(), created: Date(), turns: [ChatTurn(role: .user, text: "Hi"), ChatTurn(role: .assistant, text: "Hello!")], existing: nil)
        try store.save(r)
        let back = LibraryStore(folder: folder).items
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].turns?.map(\.text), ["Hi", "Hello!"])
        XCTAssertEqual(back[0].kind, .chat)
    }

    // MARK: Tools

    private func library() -> (records: [LibraryRecord], current: UUID) {
        let current = UUID()
        let old = Assistant.record(id: UUID(), created: Date(timeIntervalSince1970: 1_700_000_000),
                                   turns: [ChatTurn(role: .user, text: "Remind me about the budget meeting"), ChatTurn(role: .assistant, text: "It's on Tuesday.")], existing: nil)
        let mine = Assistant.record(id: current, created: Date(), turns: [ChatTurn(role: .user, text: "Secret, current")], existing: nil)
        let note = LibraryRecord(kind: .note, text: "Buy milk and eggs for the cake.", title: "Shopping", created: Date(timeIntervalSince1970: 1_600_000_000))
        let transcript = LibraryRecord(kind: .transcript, text: "Okay, let's get started with the budget.", title: "Meeting", created: Date(timeIntervalSince1970: 1_650_000_000),
                                       duration: 100, source: "meeting.mp3")
        return ([mine, old, transcript, note], current)
    }

    func testTheToolsListAndReadWhatsKeptButNeverThisChat() throws {
        let (records, current) = library()
        let chats = AssistantTools.run("list_chats", [:], library: records, current: current)
        XCTAssertTrue(chats.contains("Remind me about the budget meeting"))
        XCTAssertFalse(chats.contains("Secret"))
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(chats.utf8)) as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["turns"] as? Int, 2)
        let id = try XCTUnwrap(list[0]["id"] as? String)

        let loaded = AssistantTools.run("load_chats", ["ids": [String(id.prefix(8)).lowercased()]], library: records, current: current)
        XCTAssertTrue(loaded.contains("Micky: It's on Tuesday."))
        XCTAssertTrue(loaded.contains("(chat, 2023-11-14") || loaded.contains("(chat, 2023-11-15"))   // the time zone decides the day
        XCTAssertTrue(AssistantTools.run("load_chats", ["ids": [current.uuidString]], library: records, current: current).contains("No chat has the id"))
        XCTAssertEqual(AssistantTools.run("list_chats", [:], library: [records[0]], current: current), "There are no earlier chats.")

        let items = AssistantTools.run("list_library", ["kind": "note"], library: records, current: current)
        XCTAssertTrue(items.contains("Shopping"))
        XCTAssertFalse(items.contains("Meeting"))
        let found = AssistantTools.run("list_library", ["query": "budget"], library: records, current: current)
        XCTAssertTrue(found.contains("meeting.mp3"))
        XCTAssertFalse(found.contains("Remind me"))                                 // chats aren't library items
        let read = AssistantTools.run("read_library", ["ids": [records[3].id.uuidString]], library: records, current: current)
        XCTAssertTrue(read.hasPrefix("## Shopping (note, "))
        XCTAssertTrue(read.contains("Buy milk and eggs"))
        XCTAssertTrue(AssistantTools.run("read_library", ["ids": [String]()], library: records, current: current).contains("Give the ids"))
        XCTAssertTrue(AssistantTools.run("nothing", [:], library: records, current: current).contains("no tool called"))
        XCTAssertEqual(AssistantTools.definitions.map { ($0["function"] as? [String: Any])?["name"] as? String },
                       ["list_chats", "load_chats", "list_library", "read_library"])
    }

    // MARK: The conversation

    func testAQuestionGoesWithTheChatAndTheToolsAndTheAnswerComesBack() async throws {
        let (records, _) = library()
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "llama3.2", library: { records })
        model.script = [ModelReply(content: "", toolCalls: [.init(name: "list_library", argumentsJSON: #"{"query":"budget"}"#)]),
                        ModelReply(content: "Your meeting transcript mentions the budget.")]
        let answer = try await chat.ask("What did I say about the budget?", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(answer, "Your meeting transcript mentions the budget.")
        XCTAssertEqual(chat.turns.map(\.text), ["What did I say about the budget?", "Your meeting transcript mentions the budget."])
        XCTAssertEqual(chat.toolCalls, ["list_library"])
        XCTAssertEqual(model.sent.count, 2)
        XCTAssertEqual(model.sent[0].model, "llama3.2")
        XCTAssertEqual(model.sent[0].tools?.count, 4)
        XCTAssertEqual(model.sent[0].messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue(((model.sent[0].messages[0]["content"] as? String) ?? "").contains("Micky"))
        XCTAssertEqual(model.sent[1].messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(model.sent[1].messages[3]["tool_name"] as? String, "list_library")
        XCTAssertTrue(((model.sent[1].messages[3]["content"] as? String) ?? "").contains("meeting.mp3"))

        // The next question carries the whole chat.
        _ = try await chat.ask("Thanks.")
        XCTAssertEqual(model.sent[2].messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "assistant", "user"])
        XCTAssertEqual(chat.record(existing: nil).turns?.count, 4)
    }

    func testAModelWithoutToolsIsTalkedToWithoutThem() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "tiny", library: { [] })
        model.fail = AssistantError.server(400, "registry.ollama.ai/library/tiny:latest does not support tools")
        model.script = [ModelReply(content: "Hello!")]
        let answer = try await chat.ask("Hi")
        XCTAssertEqual(answer, "Hello!")
        XCTAssertEqual(model.sent.count, 2)
        XCTAssertNil(model.sent[1].tools)
        XCTAssertFalse(chat.toolsSupported)
        XCTAssertFalse(((model.sent[1].messages[0]["content"] as? String) ?? "").contains("list_chats"))
        _ = try await chat.ask("Again")
        XCTAssertNil(model.sent[2].tools)
    }

    func testAFailedQuestionIsntPartOfTheChat() async {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "llama3.2", library: { [] })
        model.fail = AssistantError.unreachable("http://127.0.0.1:11434")
        do {
            _ = try await chat.ask("Hi")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AssistantError, .unreachable("http://127.0.0.1:11434"))
            XCTAssertTrue((error as? AssistantError)?.errorDescription?.contains("ollama serve") ?? false)
        }
        XCTAssertTrue(chat.isEmpty)
        let noModel = try? await Conversation(llm: model, model: "", library: { [] }).ask("Hi")
        XCTAssertNil(noModel)
    }

    func testAnEmptyAnswerAndTooManyToolRoundsStillAnswer() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        chat.maxToolRounds = 2
        let call = ModelReply(content: "", toolCalls: [.init(name: "list_chats", argumentsJSON: "{}")])
        model.script = [call, call, ModelReply(content: "  ")]
        let answer = try await chat.ask("Loop")
        XCTAssertEqual(answer, "I don't have an answer to that.")
        XCTAssertEqual(model.sent.count, 3)
    }

    func testOllamasWireShape() throws {
        let body = OllamaClient.chatBody(model: "llama3.2", messages: [["role": "user", "content": "hi"]], tools: AssistantTools.definitions)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 4)
        XCTAssertNil(OllamaClient.chatBody(model: "m", messages: [], tools: nil)["tools"])
        XCTAssertNotNil(try JSONSerialization.data(withJSONObject: body))

        let reply = try OllamaClient.reply(Data(#"{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"load_chats","arguments":{"ids":["ABC"]}}}]},"done":true}"#.utf8))
        XCTAssertEqual(reply.toolCalls.map(\.name), ["load_chats"])
        XCTAssertEqual(reply.toolCalls[0].arguments["ids"] as? [String], ["ABC"])
        XCTAssertEqual(try OllamaClient.reply(Data(#"{"message":{"role":"assistant","content":"Lima."}}"#.utf8)), ModelReply(content: "Lima."))
        XCTAssertThrowsError(try OllamaClient.reply(Data("nope".utf8)))

        XCTAssertEqual(OllamaClient(baseURL: "localhost:11434/").baseURL.absoluteString, "http://localhost:11434")
        XCTAssertEqual(OllamaClient(baseURL: "  ").baseURL.absoluteString, OllamaClient.defaultURL)
    }
}

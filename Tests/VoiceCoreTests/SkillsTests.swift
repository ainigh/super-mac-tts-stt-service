import XCTest
@testable import VoiceCore

/// Stands in for the Mac: a browser that answers from a script, a clipboard, Spotlight.
final class FakeMac: MacHost {
    var clip: String? = "copied words"
    var browser: (id: String, name: String)? = ("com.apple.Safari", "Safari")
    /// What each AppleScript answers, in turn (the last one repeats).
    var scripts: [Result<String, HostError>] = []
    var ran: [String] = []
    var opened: [URL] = []
    var fetched: [URL] = []
    var pages: [String: String] = [:]
    var found: [String] = []

    func clipboard() async -> String? { clip }
    func status() async -> [String: Any] { ["front_app": "Notes", "battery": "80%"] }
    func spotlight(_ query: String, limit: Int) async -> [String] { Array(found.prefix(limit)) }
    func documentText(_ url: URL) async -> String? { url.pathExtension == "pdf" ? "PDF words" : nil }
    func defaultBrowser() async -> (id: String, name: String)? { browser }
    var inFront: [Bool] = []
    var forward: [String] = []
    var shown: [(AppWindow, UUID?, String?)] = []
    func open(_ url: URL, inFront front: Bool) async -> Bool { opened.append(url); inFront.append(front); return true }
    func bringForward(_ bundleID: String) async -> Bool { forward.append(bundleID); return true }
    func showApp(_ window: AppWindow, item: UUID?, query: String?) async -> Bool { shown.append((window, item, query)); return true }
    func appleScript(_ source: String) async -> Result<String, HostError> {
        ran.append(source)
        guard !scripts.isEmpty else { return .failure(HostError("no script")) }
        return scripts.count == 1 ? scripts[0] : scripts.removeFirst()
    }
    func fetch(_ url: URL) async -> (status: Int, body: String)? {
        fetched.append(url)
        return pages[url.absoluteString].map { (200, $0) }
    }
}

private func page(_ url: String, _ text: String, ready: String = "complete", title: String = "A page", links: [[String: String]] = [], found: Bool? = nil) -> Result<String, HostError> {
    var o: [String: Any] = ["url": url, "text": text, "ready": ready, "title": title, "links": links]
    if let found { o["found"] = found }
    return .success(String(decoding: JSON.data(o), as: UTF8.self))
}

final class SkillsTests: XCTestCase {
    private func runner(_ mac: FakeMac, home: URL = URL(fileURLWithPath: "/Users/me")) -> SkillRunner {
        let r = SkillRunner(host: mac, home: home)
        r.pollInterval = 0.001
        r.loadWait = 0.2
        return r
    }

    // MARK: Hearing

    func testAPauseMidSentenceDoesntEndIt() {
        XCTAssertTrue(TurnEnd.unfinished("What's the weather like in"))
        XCTAssertTrue(TurnEnd.unfinished("I want to go to the."))
        XCTAssertTrue(TurnEnd.unfinished("Remind me to call Sam and."))
        XCTAssertTrue(TurnEnd.unfinished("So the thing is,"))
        XCTAssertTrue(TurnEnd.unfinished("Tell me about the weather"))
        XCTAssertFalse(TurnEnd.unfinished("What's the weather like in Lima?"))
        XCTAssertFalse(TurnEnd.unfinished("Tell me a joke."))
        XCTAssertFalse(TurnEnd.unfinished("Mouse."))
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

    func testOnlyTheSkillsThatAreOnAndCanBeAreOffered() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        XCTAssertEqual(chat.activeSkills.map(\.id), ["library", "math"])
        chat.skills = runner(FakeMac())
        chat.save = { _ in }
        XCTAssertEqual(chat.activeSkills.map(\.id), ["library", "edit", "browser", "files", "clipboard", "mac", "math", "app"])
        XCTAssertTrue(chat.systemPrompt().contains("- open_page:"))
        XCTAssertTrue(chat.systemPrompt().contains("- search_site:"))
        XCTAssertTrue(chat.systemPrompt().contains("wikipedia (en.wikipedia.org)"))
        chat.enabled = ["math"]
        XCTAssertEqual(chat.tools.map(\.name), ["calculate"])
        XCTAssertFalse(chat.systemPrompt().contains("library"))
        // A tool of a skill that's off isn't run.
        model.script = [#"{"tool": "read_clipboard"}"#, "Nope."]
        _ = try await chat.ask("What did I copy?")
        XCTAssertTrue(((model.sent[1].messages[3]["content"] as? String) ?? "").contains("no tool called read_clipboard"))
        XCTAssertEqual(Skills.skill(for: "find_on_page")?.id, "browser")
        XCTAssertEqual(Skills.skill(for: "search_site")?.id, "browser")
        XCTAssertEqual(Skills.skill(for: "update_library")?.id, "edit")
        XCTAssertNil(Skills.skill(for: "nope"))
    }

    func testEachToolUsedIsReported() async throws {
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [] })
        var uses: [ToolUse] = []
        chat.onToolUse = { uses.append($0) }
        model.script = [#"{"tool": "calculate", "arguments": {"expression": "2 + 2 * 10"}}"#, "22."]
        let answer = try await chat.ask("What's 2 plus 2 times 10?")
        XCTAssertEqual(answer, "22.")
        XCTAssertEqual(uses.map(\.name), ["calculate"])
        XCTAssertEqual(uses[0].result, "2 + 2 * 10 = 22")
        XCTAssertEqual(uses[0].summary, "expression: 2 + 2 * 10")
        XCTAssertEqual(uses[0].skill?.id, "math")
        XCTAssertEqual(ToolUse(name: "open_page", arguments: #"{"url": "example.com"}"#, result: "").link?.absoluteString, "https://example.com")
        XCTAssertEqual(ToolUse(name: "read_page", result: "Title: x\nAddress: https://a.com/b\nText:").link?.absoluteString, "https://a.com/b")
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

    // MARK: The browser

    func testAPageOpensInTheBrowserAndIsReadThere() async {
        let mac = FakeMac()
        mac.scripts = [page("https://www.example.com/", "Loading", ready: "loading"),
                       page("https://www.example.com/", "Example Domain\n\n\nThis domain is for examples.", title: "Example")]
        let r = runner(mac)
        let out = await r.run("open_page", ["url": "example.com"])!
        XCTAssertEqual(mac.opened.map(\.absoluteString), ["https://example.com"])
        XCTAssertTrue(out.hasPrefix("Opened in Safari, in front, where the user sees it.\nTitle: Example\nAddress: https://www.example.com/"))
        XCTAssertEqual(mac.inFront, [true])
        XCTAssertEqual(mac.forward, ["com.apple.Safari"])
        XCTAssertTrue(out.hasSuffix("Text:\nExample Domain\n\nThis domain is for examples."))
        XCTAssertTrue(mac.ran[0].hasPrefix(#"tell application id "com.apple.Safari" to do JavaScript "(function(){"#))
        XCTAssertTrue(mac.fetched.isEmpty)
        let bad = await r.run("open_page", ["url": "not a link"])
        XCTAssertEqual(bad, "Give a web address (https://…) to open.")
    }

    func testFindingTextHighlightsItAndSaysWhere() async {
        let mac = FakeMac()
        mac.browser = ("com.google.Chrome", "Chrome")
        mac.scripts = [page("https://a.com/", "Intro. The budget is 40 dollars. Later the budget grows.", found: true)]
        let r = runner(mac)
        let out = await r.run("find_on_page", ["text": "budget"])!
        XCTAssertTrue(mac.ran[0].hasPrefix(#"tell application id "com.google.Chrome" to tell active tab of front window to execute javascript "(function(q){"#))
        XCTAssertTrue(mac.ran[0].contains(#"(\"budget\")"#))
        XCTAssertTrue(out.hasPrefix("Found “budget”, highlighted on the page; where it is:\n1. …"))
        XCTAssertTrue(out.contains("2. …"))
        // Opened with find: the address carries a text fragment, so the browser highlights it too.
        mac.scripts = [page("https://a.com/x", "Some words here.")]
        let opened = await r.run("open_page", ["url": "https://a.com/x", "find": "words here"])!
        XCTAssertEqual(mac.opened.last?.absoluteString, "https://a.com/x#:~:text=words%20here")
        XCTAssertTrue(opened.contains("Found “words here”"))
    }

    func testASearchReadsBackItsResults() async {
        let mac = FakeMac()
        mac.scripts = [page("https://www.google.com/search?q=lima%20weather", "Results…",
                            links: [["title": "Lima weather", "url": "https://weather.example/lima"]])]
        let r = runner(mac)
        let out = await r.run("web_search", ["query": "lima weather"])!
        XCTAssertEqual(mac.opened.last?.absoluteString, "https://www.google.com/search?q=lima%20weather")
        XCTAssertTrue(out.contains("Results:\n1. Lima weather — https://weather.example/lima"))
        _ = await r.run("search_site", ["site": "wiki", "query": "Lima & Peru"])
        XCTAssertEqual(mac.opened.last?.absoluteString, "https://en.wikipedia.org/w/index.php?search=Lima%20%26%20Peru")
        let none = await r.run("search_site", ["site": "nope", "query": "x"])
        XCTAssertEqual(none, "There's no site called nope. The sites: wikipedia, youtube.")
    }

    func testABrowserThatCantBeReadIsFetchedInstead() async {
        let mac = FakeMac()
        mac.browser = ("org.mozilla.firefox", "Firefox")
        mac.pages["https://example.com"] = "<html><head><title>Ex &amp; Co</title><style>x{}</style></head><body><p>Hello&nbsp;there</p><script>bad()</script><p>Bye &#8212; now</p></body></html>"
        let r = runner(mac)
        let out = await r.run("open_page", ["url": "https://example.com"])!
        XCTAssertTrue(mac.ran.isEmpty)
        XCTAssertTrue(out.contains("Title: Ex & Co"))
        XCTAssertTrue(out.contains("(Read by fetching the page, since Firefox can't be read by other apps."))
        XCTAssertTrue(out.hasSuffix("Text:\nHello there\nBye — now"))
        // Read again: the last page opened, fetched.
        let again = await r.run("read_page", [:])!
        XCTAssertTrue(again.contains("Hello there"))

        // JavaScript from Apple Events off: the same, and it says how to turn it on.
        let safari = FakeMac()
        safari.scripts = [.failure(HostError("You must enable 'Allow JavaScript from Apple Events'"))]
        safari.pages["https://example.com"] = "<p>Fetched</p>"
        let out2 = await runner(safari).run("open_page", ["url": "https://example.com"])!
        XCTAssertTrue(out2.contains("since You must enable 'Allow JavaScript from Apple Events'"))
        XCTAssertTrue(out2.contains("Develop > Allow JavaScript from Apple Events"))
        XCTAssertTrue(out2.hasSuffix("Fetched"))
    }

    func testLongPagesComeInParts() async {
        let mac = FakeMac()
        let text = String(repeating: "a", count: BrowserSkill.partChars) + "THE END"
        mac.scripts = [page("https://a.com/", text)]
        let r = runner(mac)
        let first = await r.run("read_page", [:])!
        XCTAssertTrue(first.contains("Text (part 1 of 2; read_page with part for more):"))
        XCTAssertFalse(first.contains("THE END"))
        let second = await r.run("read_page", ["part": 2])!
        XCTAssertTrue(second.hasSuffix("Text (part 2 of 2; read_page with part for more):\nTHE END"))
    }

    func testScriptStringsAreQuoted() {
        XCTAssertEqual(BrowserSkill.quoted(#"say "hi" \ there"#), #""say \"hi\" \\ there""#)
        XCTAssertEqual(BrowserSkill.jsString("it's \"x\""), #""it's \"x\"""#)
        XCTAssertNil(BrowserSkill.script(running: "1", in: "org.mozilla.firefox"))
        XCTAssertEqual(BrowserSkill.family("company.thebrowser.Browser"), .chromium)
        XCTAssertTrue(BrowserSkill.sameSite("https://www.example.com/x", URL(string: "https://example.com")!))
        XCTAssertFalse(BrowserSkill.sameSite("https://other.com/", URL(string: "https://example.com")!))
    }

    func testSites() {
        XCTAssertEqual(Site.parse("wiki: https://en.wikipedia.org/wiki/{query}"), Site(name: "wiki", template: "https://en.wikipedia.org/wiki/{query}"))
        XCTAssertEqual(Site.parse("Maps maps.apple.com/?q=%s")?.url(for: "a b")?.absoluteString, "https://maps.apple.com/?q=a%20b")
        XCTAssertNil(Site.parse("just words"))
        XCTAssertNil(Site.parse("two words https://x.com"))
        XCTAssertEqual(Site.defaults[0].host, "en.wikipedia.org")
    }

    func testTheBrowserIsShownOrKeptBehind() async {
        let mac = FakeMac()
        mac.scripts = [page("https://a.com/", "Words.")]
        let r = runner(mac)
        r.showBrowser = false
        let behind = await r.run("open_page", ["url": "https://a.com/"])!
        XCTAssertTrue(behind.hasPrefix("Opened in Safari, behind (show_browser brings it to the front)."))
        XCTAssertEqual(mac.inFront, [false])
        XCTAssertTrue(mac.forward.isEmpty)
        // Asked to show it: in front.
        _ = await r.run("web_search", ["query": "a", "show": true])
        XCTAssertEqual(mac.inFront.last, true)
        XCTAssertEqual(mac.forward, ["com.apple.Safari"])
        let shown = await r.run("show_browser", [:])!
        XCTAssertTrue(shown.hasPrefix("Safari is in front now"))
        XCTAssertEqual(mac.forward.count, 2)
    }

    func testTheModelOpensTheAppsWindows() async throws {
        let note = LibraryRecord(kind: .note, text: "Buy milk.", title: "Shopping")
        let old = Assistant.record(id: UUID(), created: Date(), turns: [ChatTurn(role: .user, text: "Hi")], existing: nil)
        let mac = FakeMac()
        let model = FakeModel()
        let chat = Conversation(llm: model, model: "m", library: { [note, old] })
        chat.skills = runner(mac)
        XCTAssertTrue(chat.systemPrompt().contains("- show_app:"))
        model.script = [#"{"tool": "show_app", "arguments": {"window": "library", "item": "\#(note.id.uuidString.prefix(8))"}}"#,
                        #"{"tool": "open_window", "arguments": {"window": "chats", "query": "budget"}}"#,
                        #"{"tool": "show_app", "arguments": {"item": "\#(old.id.uuidString)"}}"#,
                        #"{"tool": "show_app", "arguments": {"window": "kitchen"}}"#, "There."]
        _ = try await chat.ask("Show me my shopping note")
        XCTAssertEqual(mac.shown.map(\.0), [.library, .ai_library, .ai_library])
        XCTAssertEqual(mac.shown[0].1, note.id)
        XCTAssertEqual(mac.shown[1].2, "budget")
        XCTAssertEqual(mac.shown[2].1, old.id)
        XCTAssertTrue(((model.sent[1].messages.last?["content"] as? String) ?? "").contains("Opened library for the user, at “Shopping”."))
        XCTAssertTrue(((model.sent[4].messages.last?["content"] as? String) ?? "").contains("Say which window: library, ai_library"))
        XCTAssertEqual(AppWindow(said: "Read aloud"), .read_aloud)
        XCTAssertNil(AppWindow(said: "kitchen"))
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

    // MARK: The rest

    func testClipboardAndTheMac() async {
        let mac = FakeMac()
        let r = runner(mac)
        let clip = await r.run("read_clipboard", [:])
        XCTAssertEqual(clip, "copied words")
        mac.clip = "  "
        let empty = await r.run("read_clipboard", [:])
        XCTAssertEqual(empty, "The clipboard has no text.")
        let status = await r.run("mac_status", [:])
        XCTAssertEqual(status, #"{"battery":"80%","front_app":"Notes"}"#)
        let other = await r.run("list_chats", [:])
        XCTAssertNil(other)
    }

    func testFilesAreOnlyLookedAtWhereTheyMayBe() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents"), withIntermediateDirectories: true)
        try "hello notes".write(to: home.appendingPathComponent("Documents/notes.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: home.appendingPathComponent(".ssh/id"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: home.appendingPathComponent("Documents/blob.bin"))
        try Data("%PDF".utf8).write(to: home.appendingPathComponent("Documents/a.pdf"))

        let mac = FakeMac()
        mac.found = [home.appendingPathComponent("Documents/notes.txt").path, home.appendingPathComponent(".ssh/id").path, "/etc/passwd"]
        let r = runner(mac, home: home)
        let listed = await r.run("list_folder", ["path": "~/Documents"])!
        XCTAssertTrue(listed.contains("notes.txt  (11 bytes"))
        let read = await r.run("read_file", ["path": "Documents/notes.txt"])
        XCTAssertEqual(read, "notes.txt:\nhello notes")
        let pdf = await r.run("read_file", ["path": "~/Documents/a.pdf"])
        XCTAssertEqual(pdf, "a.pdf:\nPDF words")
        let blob = await r.run("read_file", ["path": "~/Documents/blob.bin"])!
        XCTAssertTrue(blob.contains("isn't text"))
        let hidden = await r.run("read_file", ["path": "~/.ssh/id"])!
        XCTAssertTrue(hidden.contains("off limits"))
        let outside = await r.run("read_file", ["path": "/etc/passwd"])!
        XCTAssertTrue(outside.contains("off limits"))
        let library = await r.run("list_folder", ["path": "~/Library"])!
        XCTAssertTrue(library.contains("off limits"))
        XCTAssertTrue(FileSkill.allowed(home.appendingPathComponent("Library/Mobile Documents/x.txt"), home: home))
        let found = await r.run("find_files", ["query": "notes"])
        XCTAssertEqual(found, "~/Documents/notes.txt")
        let missing = await r.run("read_file", ["path": "~/nope.txt"])!
        XCTAssertTrue(missing.hasPrefix("There's no file at"))
    }

    func testTheCalculator() throws {
        XCTAssertEqual(try Calculator.evaluate("2 + 3 * 4"), 14)
        XCTAssertEqual(try Calculator.evaluate("(2 + 3) * 4"), 20)
        XCTAssertEqual(try Calculator.evaluate("2 ^ 3 ^ 2"), 512)
        XCTAssertEqual(try Calculator.evaluate("2 ** 10"), 1024)
        XCTAssertEqual(try Calculator.evaluate("-3 + 10 % 4"), -1)
        XCTAssertEqual(try Calculator.evaluate("sqrt(16) + abs(-2)"), 6)
        XCTAssertEqual(try Calculator.evaluate("1,250 × 2"), 2500)
        XCTAssertEqual(try Calculator.evaluate("1.5e3 / 3"), 500)
        XCTAssertEqual(Calculator.format(try Calculator.evaluate("pi")), "3.1415926536")
        XCTAssertEqual(Calculator.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(Calculator.format(1 / 0), "infinity")
        XCTAssertThrowsError(try Calculator.evaluate("2 +"))
        XCTAssertThrowsError(try Calculator.evaluate("(2"))
        XCTAssertThrowsError(try Calculator.evaluate("foo(2)"))
        XCTAssertEqual(Calculator.run(["expression": "2 +"]), "Couldn't work out 2 +: it ends too soon.")
    }
}

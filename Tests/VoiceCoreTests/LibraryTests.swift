import XCTest
@testable import VoiceCore

final class LibraryTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSavesLoadsFiltersAndDeletes() throws {
        let store = LibraryStore(folder: folder)
        var old = LibraryRecord(kind: .dictation, text: "Remind me to call Sam at four about the café.",
                              created: Date(timeIntervalSince1970: 1000))
        let new = LibraryRecord(kind: .transcript, text: "Okay, let's get started.", title: "Meeting", created: Date(timeIntervalSince1970: 2000),
                              duration: 1834, source: "meeting.mp3", segments: [TimedText(start: 0, end: 1.5, text: "Okay, let's get started.")])
        try store.save(old)
        try store.save(new)
        XCTAssertEqual(store.items.map(\.title), ["Meeting", "Remind me to call Sam at four…"])

        let again = LibraryStore(folder: folder)
        XCTAssertEqual(again.items, store.items)
        XCTAssertEqual(again.filter(kind: .transcript).map(\.id), [new.id])
        XCTAssertEqual(again.filter(query: "sam CAFE").map(\.id), [old.id])
        XCTAssertEqual(again.filter(query: "meeting.mp3").map(\.id), [new.id])
        XCTAssertEqual(again.filter(query: "nothing like it"), [])

        old.starred = true
        old.text = "Edited."
        try again.save(old)
        XCTAssertEqual(again.items.count, 2)
        XCTAssertEqual(again.filter(starredOnly: true).map(\.text), ["Edited."])

        try again.delete(new.id)
        XCTAssertEqual(LibraryStore(folder: folder).items.map(\.id), [old.id])
    }

    func testABadFileDoesntLoseTheRest() throws {
        let store = LibraryStore(folder: folder)
        try store.save(LibraryRecord(kind: .note, text: "Kept."))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("broken.json"))
        XCTAssertEqual(LibraryStore(folder: folder).items.map(\.text), ["Kept."])
    }

    func testTitles() {
        XCTAssertEqual(LibraryRecord.title(for: "  "), "Untitled")
        XCTAssertEqual(LibraryRecord.title(for: "Short one."), "Short one")
        XCTAssertEqual(LibraryRecord(kind: .note, text: "one two three").wordCount, 3)
    }
}

final class ReleaseTests: XCTestCase {
    func testDecodesWhatTheUpdaterNeeds() throws {
        let r = try Release.decode(Data(#"{"tag_name":"v0.1.7","target_commitish":"abc123","body":"x","html_url":"https://github.com/x","assets":[{"name":"SuperVoice.zip","browser_download_url":"https://github.com/a.zip"}]}"#.utf8))
        XCTAssertEqual(r.tag, "v0.1.7")
        XCTAssertEqual(r.target, "abc123")
        XCTAssertNotNil(r.asset(named: "SuperVoice.zip"))
        let c = try Commit.decode(Data(#"{"sha":"0123456789abcdef","commit":{"message":"Title\n\nBody"}}"#.utf8))
        XCTAssertEqual(c.short, "0123456")
        XCTAssertEqual(c.title, "Title")
    }
}

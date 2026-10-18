import XCTest
@testable import VoiceCore

final class BoardTests: XCTestCase {
    func testTheWakeWordAndOptionsAreSaidAlone() {
        XCTAssertTrue(Board.isWake("Mouse."))
        XCTAssertTrue(Board.isWake(" mouse "))
        XCTAssertFalse(Board.isWake("The mouse ran."))
        XCTAssertEqual(Board.option("Add."), .add)
        XCTAssertEqual(Board.option("copy"), .copy)
        XCTAssertEqual(Board.option("No!"), .no)
        XCTAssertEqual(Board.option("Cancel."), .no)
        XCTAssertNil(Board.option("add milk"))
    }

    func testAFirstWordThatsACommandFilesIt() {
        let commands = ["notes", "links"]
        XCTAssertEqual(Board.parse("Notes, buy milk tomorrow.", commands: commands),
                       Board.Heard(command: "notes", tag: "notes", text: "Buy milk tomorrow."))
        XCTAssertEqual(Board.parse("note call Sam", commands: commands),           // singular matches too
                       Board.Heard(command: "notes", tag: "notes", text: "Call Sam"))
        XCTAssertEqual(Board.parse("Links.", commands: commands),
                       Board.Heard(command: "links", tag: "links", text: ""))
        XCTAssertEqual(Board.parse("Buy milk.", commands: commands),
                       Board.Heard(command: nil, tag: "note", text: "Buy milk."))
        XCTAssertEqual(Board.parse("Notebook is on the desk", commands: commands).command, nil)
    }

    func testRankingFindsSharedWordsBestFirst() {
        func r(_ text: String, _ tag: String?, _ t: Double) -> LibraryRecord {
            LibraryRecord(kind: .note, text: text, created: Date(timeIntervalSince1970: t), tag: tag)
        }
        let milk = r("Buy milk and eggs", "notes", 1)
        let eggs = r("Eggs for the cake", "note", 2)
        let sam = r("Call Sam about milk prices", "notes", 3)
        let untagged = r("Milk dictation", nil, 4)
        let all = [milk, eggs, sam, untagged]
        XCTAssertEqual(Board.rank(all, query: "milk eggs", tag: nil).map(\.text),
                       ["Buy milk and eggs", "Call Sam about milk prices", "Eggs for the cake"])
        XCTAssertEqual(Board.rank(all, query: "milk", tag: "note").map(\.text),
                       ["Call Sam about milk prices", "Buy milk and eggs"])         // note ~ notes; newest first on a tie
        XCTAssertEqual(Board.rank(all, query: "the", tag: nil).map(\.text),        // nothing to search with: all, newest first
                       ["Call Sam about milk prices", "Eggs for the cake", "Buy milk and eggs"])
        XCTAssertEqual(Board.rank(all, query: "zebra", tag: nil), [])
        XCTAssertEqual(Board.rank(all, query: "cak", tag: nil).map(\.text), ["Eggs for the cake"])  // a word's start
    }

    func testWhatOpeningDoes() {
        XCTAssertEqual(Board.action(for: "https://example.com/a?b=1"), .browse(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(Board.action(for: "example.com/docs"), .browse(URL(string: "https://example.com/docs")!))
        XCTAssertEqual(Board.action(for: "GET https://api.example.com/x"),
                       .http(method: "GET", url: URL(string: "https://api.example.com/x")!, body: nil))
        XCTAssertEqual(Board.action(for: "post http://localhost:8767/api/say {\"text\": \"hi\"}"),
                       .http(method: "POST", url: URL(string: "http://localhost:8767/api/say")!, body: "{\"text\": \"hi\"}"))
        XCTAssertEqual(Board.action(for: "Buy milk"), .show)
        XCTAssertEqual(Board.action(for: "see https://example.com"), .show)
        XCTAssertEqual(Board.action(for: "GET nothing"), .show)
    }

    func testOldRecordsWithoutATagStillLoad() throws {
        let old = #"{"id":"6F2C3B1A-0000-4000-8000-000000000001","kind":"note","title":"t","text":"x","created":"2026-01-01T00:00:00Z","modified":"2026-01-01T00:00:00Z","starred":false}"#
        let r = try LibraryStore.decoder.decode(LibraryRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.tag)
    }
}

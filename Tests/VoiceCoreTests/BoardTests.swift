import XCTest
@testable import VoiceCore

final class BoardTests: XCTestCase {
    func testTheWakeWordAndOptionsAreSaidAlone() {
        XCTAssertTrue(Board.isWake("Mouse."))
        XCTAssertTrue(Board.isWake(" mouse "))
        XCTAssertFalse(Board.isWake("The mouse ran."))
        XCTAssertEqual(Board.option("Open."), .open)
        XCTAssertEqual(Board.option("copy"), .copy)
        XCTAssertEqual(Board.option("No!"), .no)
        XCTAssertEqual(Board.option("Undo."), .no)
        XCTAssertNil(Board.option("open milk"))
        XCTAssertNil(Board.option("add"))
    }

    func testTheWakeWordSaidFirstTakesWhatFollows() {
        XCTAssertEqual(Board.afterWake("Mouse, note buy milk."), "Note buy milk.")
        XCTAssertEqual(Board.afterWake("mouse where are my keys"), "Where are my keys")
        XCTAssertNil(Board.afterWake("Mouse."))
        XCTAssertNil(Board.afterWake("The mouse ran."))
        XCTAssertNil(Board.afterWake("Mousetrap on the shelf"))
    }

    func testAFirstWordThatsACommandIsTheSubtitleElseItsASearch() {
        let commands = ["notes", "links"]
        XCTAssertEqual(Board.parse("Notes, buy milk tomorrow.", commands: commands),
                       Board.Heard(command: "notes", subtitle: "notes", text: "Buy milk tomorrow."))
        XCTAssertEqual(Board.parse("note call Sam", commands: commands),           // singular matches too
                       Board.Heard(command: "notes", subtitle: "notes", text: "Call Sam"))
        XCTAssertEqual(Board.parse("Links.", commands: commands),
                       Board.Heard(command: "links", subtitle: "links", text: ""))
        XCTAssertEqual(Board.parse("buy milk.", commands: commands),               // kept as it was said
                       Board.Heard(command: nil, subtitle: "search", text: "buy milk."))
        XCTAssertEqual(Board.parse("Search, milk", commands: commands),            // "search" said first: a search of the rest
                       Board.Heard(command: nil, subtitle: "search", text: "Milk"))
        XCTAssertTrue(Board.parse("Notebook is on the desk", commands: commands).isSearch)
    }

    func testSentences() {
        XCTAssertEqual(Board.sentences("Buy milk. Call Sam! Is it four? ok"), ["Buy milk.", "Call Sam!", "Is it four?", "ok"])
        XCTAssertEqual(Board.sentences("See example.com/a.b today."), ["See example.com/a.b today."])
        XCTAssertEqual(Board.sentences(""), [])
    }

    func testTheNoteKeepsOneSectionPerSubtitle() {
        var note = Board.Note()
        XCTAssertEqual(note.append("Buy milk.", under: "note"), .init(section: 0, line: 0))
        XCTAssertEqual(note.append("where is the milk", under: "search"), .init(section: 1, line: 0))
        XCTAssertEqual(note.append("Call Sam.\nAt four.", under: "notes"), .init(section: 0, line: 1))   // the same section; one line
        XCTAssertEqual(note.text, "## note\nBuy milk.\nCall Sam. At four.\n\n## search\nwhere is the milk")
        XCTAssertEqual(Board.Note(text: note.text), note)
        XCTAssertEqual(note.lines(under: "note").map(\.line), ["Call Sam. At four.", "Buy milk."])     // newest first
        XCTAssertEqual(note.lines(under: nil).count, 3)

        // Taken back only while it's still there as it was; a section left empty goes.
        XCTAssertFalse(note.remove("something else", at: .init(section: 1, line: 0)))
        XCTAssertTrue(note.remove("where is the milk", at: .init(section: 1, line: 0)))
        XCTAssertEqual(note.sections.map(\.subtitle), ["note"])
    }

    func testANoteEditedByHandReadsBack() {
        let note = Board.Note(text: "Written first\n\n## note\n  Buy milk.  \n\n\n## ideas\n")
        XCTAssertEqual(note.sections, [.init(subtitle: "", lines: ["Written first"]),
                                       .init(subtitle: "note", lines: ["Buy milk."]),
                                       .init(subtitle: "ideas", lines: [])])
        XCTAssertEqual(note.text, "Written first\n\n## note\nBuy milk.\n\n## ideas")
        var typed = note
        let spot = typed.append("## not a subtitle", under: "note")
        XCTAssertEqual(typed[spot], "not a subtitle")
    }

    func testASearchSurfacesTheMatchingSentences() {
        var note = Board.Note()
        note.append("Buy milk and eggs. Then call Sam.", under: "note")
        note.append("Eggs for the cake", under: "note")
        note.append("Sam's milk prices are up", under: "search")
        let search = note.append("milk eggs", under: "search")
        XCTAssertEqual(note.search("milk eggs", skipping: search).map(\.sentence),
                       ["Buy milk and eggs.", "Eggs for the cake", "Sam's milk prices are up"])
        XCTAssertEqual(note.search("cak").map(\.sentence), ["Eggs for the cake"])            // a word's start
        XCTAssertEqual(note.search("milk eggs").map(\.sentence).first, "Buy milk and eggs.")   // the search itself never shows
        XCTAssertEqual(note.search("Sam").map(\.sentence), ["Sam's milk prices are up", "Then call Sam."])   // a tie: the later first
        XCTAssertEqual(note.search("the"), [])                                                 // nothing to search with
        XCTAssertEqual(note.search("zebra"), [])
        let hit = note.search("call sam")[0]
        XCTAssertEqual(hit.spot, .init(section: 0, line: 0))
        XCTAssertEqual(hit.subtitle, "note")
        XCTAssertEqual(hit.line, "Buy milk and eggs. Then call Sam.")
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

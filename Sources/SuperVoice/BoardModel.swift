import AppKit
import Combine
import Foundation
import VoiceCore

/// The board beside the panel: voice commands (column 2), the note (column 3: what was just added,
/// and what a search found), and the options for it, or the note opened where it matched (column 4).
/// With always listen on and the panel open ("mouse" opens it), each thing said goes in the note:
/// under its first word when that's a command, else under "search", and then it's searched with.
/// "mouse" said alone opens or closes the panel; "open", "copy" or "no" said alone answers what
/// was just added. "Micky" starts AI Listen instead (awake: what follows is the first question).
/// On the main thread.
final class BoardModel: ObservableObject {
    static let shared = BoardModel()

    /// The voice commands: a first word that's the subtitle what follows goes under.
    @Published private(set) var commands: [String]
    /// Always listening (and wanted so across launches).
    @Published private(set) var listening: Bool
    /// The columns stay out even when not listening.
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "boardPinned") } }
    /// Little sounds when something's heard and added.
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "boardSounds") } }
    /// What's being typed (Return adds it, the same as saying it).
    @Published var entry = "" { didSet { if entry != oldValue { activity() } } }
    /// A subtitle clicked in column 2: column 3 shows only what's under it.
    @Published var selectedSubtitle: String?
    /// What was just added, until it's answered or something else is.
    @Published private(set) var added: Added?
    /// What's open in column 4.
    @Published var opened: Opened?
    /// A line saying what just happened ("Copied", "Added under note").
    @Published private(set) var notice: String?
    /// What the always-listener is hearing right now, before the pause that ends it.
    @Published private(set) var hearing = ""

    struct Added: Equatable {
        var heard: Board.Heard
        /// Where it went in the note, and as it was written there.
        var spot: Board.Note.Spot
        var line: String
    }

    enum Opened: Equatable {
        /// The note, scrolled to a line (with the sentence that matched picked out).
        case note(focus: Board.Hit?)
        case http(HTTPCall)
    }

    struct HTTPCall: Equatable {
        var method: String
        var url: URL
        var body: String?
        var status: Int?
        var response = ""
        var error: String?
        var running = true

        var request: String { "\(method) \(url.absoluteString)" }
    }

    let listener = Recorder(pauseToEnd: 1.0)
    private let defaults = UserDefaults.standard
    private var watching: Set<AnyCancellable> = []
    private var noticeClear: DispatchWorkItem?

    private init() {
        let saved = UserDefaults.standard
        commands = saved.stringArray(forKey: "boardCommands") ?? Board.defaultCommands
        listening = saved.bool(forKey: "alwaysListen")
        pinned = saved.bool(forKey: "boardPinned")
        sounds = saved.object(forKey: "boardSounds") as? Bool ?? true
        listener.onUtterance = { [weak self] said in self?.heard(said) }
        listener.$text.receive(on: DispatchQueue.main).sink { [weak self] t in self?.hearing = t }.store(in: &watching)
        // Dictating takes the microphone, and what the Mac says itself isn't to be heard, and AI
        // Listen has the microphone while it's on: always listen waits meanwhile (dropping what it
        // half heard), then carries on.
        let service = Service.shared
        Recorder.shared.$on.removeDuplicates()
            .combineLatest(service.reader.$speaking.removeDuplicates(), service.speaker.$speaking.removeDuplicates(),
                           AssistantModel.shared.$on.removeDuplicates())
            .map { $0 || $1 || $2 || $3 }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                guard let self, self.listening else { return }
                if busy {
                    self.listener.stop()
                    self.listener.clear()
                } else {
                    self.resume()
                }
            }.store(in: &watching)
        Library.shared.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &watching)
        listener.$problem.receive(on: DispatchQueue.main).sink { [weak self] p in
            if let p { self?.say(p) }
        }.store(in: &watching)
    }

    /// At launch: listen if it was listening.
    func launch() {
        foldOldEntries()
        if listening { resume() }
    }

    /// Listens, unless dictation or the Mac's own voice has the floor.
    private func resume() {
        let service = Service.shared
        guard listening, !Recorder.shared.on, !service.reader.speaking, !service.speaker.speaking, !AssistantModel.shared.on else { return }
        listener.start()
    }

    /// The panel closed: what was just added isn't waiting for an answer any more.
    func panelClosed() {
        added = nil
    }

    /// Columns 2 and 3 show.
    var showsColumns: Bool { listening || pinned }
    /// Column 4 shows.
    var showsOptions: Bool { added != nil || opened != nil }

    // MARK: The note

    /// The library record that holds the note (none until something's added).
    private var noteRecord: LibraryRecord? { Library.shared.items.first { $0.tag == Board.noteTag } }

    var note: Board.Note { noteRecord.map { Board.Note(text: $0.text) } ?? Board.Note() }

    private func save(_ note: Board.Note) {
        var record = noteRecord ?? LibraryRecord(kind: .note, text: "", title: Board.noteTitle, tag: Board.noteTag)
        record.text = note.text
        Library.shared.save(record)
    }

    /// Entries from before the board kept one note go into it once, oldest first, under what they
    /// were filed under; they stay in the library as notes of their own.
    private func foldOldEntries() {
        let old = Library.shared.items.filter { $0.tag != nil && $0.tag != Board.noteTag }.sorted { $0.created < $1.created }
        guard !old.isEmpty else { return }
        var note = self.note
        for r in old where !r.text.isEmpty { note.append(r.text, under: r.tag ?? Board.defaultCommands[0]) }
        save(note)
        for var r in old {
            r.tag = nil
            Library.shared.save(r)
        }
    }

    /// What's being typed, read against the commands.
    var typed: Board.Heard? {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Board.parse(entry, commands: commands)
    }

    /// What a search just added found in the note, best first.
    var hits: [Board.Hit] {
        guard let a = added, a.heard.isSearch else { return [] }
        return note.search(a.heard.text, skipping: a.spot)
    }

    /// Column 3: what a search found, else the lines under the subtitle just added to (or the one
    /// clicked), else the whole note.
    var results: [Board.Hit] {
        if let a = added { return a.heard.isSearch ? hits : note.lines(under: a.heard.subtitle).filter { $0.spot != a.spot } }
        return note.lines(under: selectedSubtitle)
    }

    /// How many lines are under `subtitle`.
    func count(_ subtitle: String) -> Int {
        note.lines(under: subtitle).count
    }

    /// The subtitles column 2 lists: the commands, and "search".
    var subtitles: [String] { commands + [Board.searchSubtitle] }

    // MARK: Hearing

    func heard(_ utterance: String) {
        // Not what the Mac itself is saying, and not while dictating or talking to the assistant.
        let service = Service.shared
        guard !service.reader.speaking, !service.speaker.speaking, !Recorder.shared.on, !AssistantModel.shared.on else { return }
        // "Micky" (or "Ollama"), alone or first: AI Listen starts, awake, and takes what follows.
        // (It has the microphone from then on; always listen carries on when it turns off.)
        switch Assistant.hear(utterance, awake: false) {
        case .wake:
            activity()
            AssistantModel.shared.start(awake: true)
            return
        case .wakeThen(let question):
            activity()
            AssistantModel.shared.start(awake: true, question: question)
            return
        default:
            break
        }
        if Board.isWake(utterance) {
            activity()
            Main.delegate.togglePanel(byVoice: true)
            return
        }
        var said = utterance
        if let rest = Board.afterWake(utterance) {
            if !Main.delegate.panelShown { Main.delegate.togglePanel(byVoice: true) }
            said = rest
        }
        // Only what's said to it: while the panel is open.
        guard Main.delegate.panelShown else { return }
        if let option = Board.option(said) {
            // An option word is never added: it answers what was just added, or what's open.
            choose(option)
            return
        }
        take(said)
    }

    /// Said or typed: it goes in the note, under its subtitle; a search is then searched with.
    func take(_ utterance: String) {
        activity()
        let heard = Board.parse(utterance, commands: commands)
        guard !heard.text.isEmpty else {
            say("Say something after “\(heard.subtitle)”")
            return
        }
        var note = self.note
        let spot = note.append(heard.text, under: heard.subtitle)
        save(note)
        added = Added(heard: heard, spot: spot, line: note[spot] ?? heard.text)
        entry = ""
        opened = nil
        selectedSubtitle = nil
        play("Pop")
        if heard.isSearch {
            let n = hits.count
            say(n == 0 ? "Kept under search; nothing else matches" : "Kept under search; \(n) matching")
        } else {
            say("Added under \(heard.subtitle)")
        }
    }

    func choose(_ option: Board.Option) {
        switch option {
        case .open: openTop()
        case .copy: copyTop()
        case .no: no()
        }
    }

    /// The best match, or (nothing matching, or not a search) the note where it was just added.
    func openTop() {
        guard let a = added else { return }
        let focus = hits.first ?? Board.Hit(spot: a.spot, subtitle: a.heard.subtitle, line: a.line, sentence: a.line)
        open(focus)
    }

    /// Takes back what was just added; else closes what's open.
    func no() {
        if let a = added {
            var note = self.note
            if note.remove(a.line, at: a.spot) {
                save(note)
                say("Taken back out")
            }
            added = nil
        } else if opened != nil {
            opened = nil
        }
    }

    /// The best match, or what was just added; else the sentence (or the answer) that's open.
    func copyTop() {
        if let a = added {
            copyText(hits.first?.sentence ?? a.line)
            return
        }
        switch opened {
        case .note(let focus?)?: copyText(focus.sentence)
        case .note(nil)?: copyText(note.text)
        case .http(let c)?: copyText(c.response)
        case nil: break
        }
    }

    func copyText(_ text: String) {
        Service.shared.copy(text)
        say("Copied")
    }

    /// A line that's a link opens in the browser; "GET …" or "POST …" is called; anything else
    /// opens the note, scrolled to it.
    func open(_ hit: Board.Hit?) {
        activity()
        added = nil
        switch hit.map({ Board.action(for: $0.line) }) ?? .show {
        case .browse(let url):
            NSWorkspace.shared.open(url)
            opened = nil
            say("Opened \(url.host ?? url.absoluteString) in your browser")
        case .http(let method, let url, let body):
            call(HTTPCall(method: method, url: url, body: body))
        case .show:
            opened = .note(focus: hit)
        }
    }

    /// Takes a line out of the note.
    func delete(_ hit: Board.Hit) {
        var note = self.note
        guard note.remove(hit.line, at: hit.spot) else { return }
        save(note)
        if added?.spot == hit.spot { added = nil }
        // Lines after it have moved: what's open isn't where it was.
        if case .note? = opened { opened = .note(focus: nil) }
    }

    private func call(_ start: HTTPCall) {
        opened = .http(start)
        var req = URLRequest(url: start.url, timeoutInterval: 20)
        req.httpMethod = start.method
        if let body = start.body {
            req.httpBody = Data(body.utf8)
            let isJSON = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) != nil
            req.setValue(isJSON ? "application/json" : "text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            var done = start
            done.running = false
            done.status = (response as? HTTPURLResponse)?.statusCode
            if let error { done.error = error.localizedDescription }
            if let data { done.response = Self.readable(data) }
            let result = done
            DispatchQueue.main.async {
                guard let self, case .http(let now) = self.opened, now.request == start.request else { return }
                self.opened = .http(result)
                self.activity()
            }
        }.resume()
    }

    /// A response body for reading: pretty JSON, else text (cut short when it's huge).
    static func readable(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let text = String(data: pretty, encoding: .utf8) {
            return String(text.prefix(50_000))
        }
        guard let text = String(data: data, encoding: .utf8) else { return "(\(data.count) bytes)" }
        return String(text.prefix(50_000))
    }

    // MARK: Commands

    func addCommand(_ word: String) {
        let ws = Board.words(word)
        guard ws.count == 1, let w = ws.first else {
            say(word.isEmpty ? nil : "A command is one word")
            return
        }
        guard w != Board.wakeWord, Board.option(w) == nil, !Board.sameWord(w, Board.searchSubtitle),
              !commands.contains(where: { Board.sameWord($0, w) }) else {
            say("“\(w)” can't be a command (it's taken)")
            return
        }
        commands.append(w)
        defaults.set(commands, forKey: "boardCommands")
    }

    func removeCommand(_ word: String) {
        commands.removeAll { $0 == word }
        defaults.set(commands, forKey: "boardCommands")
        if selectedSubtitle == word { selectedSubtitle = nil }
    }

    // MARK: Listening

    func setListening(_ on: Bool) {
        listening = on
        defaults.set(on, forKey: "alwaysListen")
        if on {
            resume()
        } else {
            listener.stop()
            listener.clear()
        }
    }

    // MARK: Helpers

    private func say(_ s: String?) {
        noticeClear?.cancel()
        notice = s
        guard let s else { return }
        let clear = DispatchWorkItem { [weak self] in if self?.notice == s { self?.notice = nil } }
        noticeClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
    }

    private func play(_ name: String) {
        guard sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func activity() {
        Main.delegate.noteActivity()
    }
}

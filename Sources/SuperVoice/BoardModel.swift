import AppKit
import Combine
import Foundation
import VoiceCore

/// The board beside the panel: voice commands (column 2), entries with the pending one on top
/// (column 3), and the options for it, or what was opened (column 4). With always listen on, each
/// thing said becomes the pending entry; "mouse" said alone opens or closes the panel; while an
/// entry is pending, "add", "open", "no" or "copy" said alone picks that option.
/// On the main thread.
final class BoardModel: ObservableObject {
    static let shared = BoardModel()

    /// The voice commands: a first word that files what follows under it.
    @Published private(set) var commands: [String]
    /// Always listening (and wanted so across launches).
    @Published private(set) var listening: Bool
    /// The columns stay out even when not listening.
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "boardPinned") } }
    /// Little sounds when something's heard and added.
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "boardSounds") } }
    /// The pending entry, as said or typed (with its command word, if any). Empty: nothing pending.
    @Published var entry = "" { didSet { if entry != oldValue { activity() } } }
    /// A command clicked in column 2: the entries are filtered to it while nothing is pending.
    @Published var selectedTag: String?
    /// What's open in column 4.
    @Published var opened: Opened?
    /// A line saying what just happened ("Copied", "Added under #notes").
    @Published private(set) var notice: String?
    /// What the always-listener is hearing right now, before the pause that ends it.
    @Published private(set) var hearing = ""

    enum Opened: Equatable {
        case record(LibraryRecord)
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
        // Dictating takes the microphone, and what the Mac says itself isn't to be heard: always
        // listen waits meanwhile (dropping what it half heard), then carries on.
        let service = Service.shared
        Recorder.shared.$on.removeDuplicates()
            .combineLatest(service.reader.$speaking.removeDuplicates(), service.speaker.$speaking.removeDuplicates())
            .map { $0 || $1 || $2 }
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
        if listening { resume() }
    }

    /// Listens, unless dictation or the Mac's own voice has the floor.
    private func resume() {
        let service = Service.shared
        guard listening, !Recorder.shared.on, !service.reader.speaking, !service.speaker.speaking else { return }
        listener.start()
    }

    /// Columns 2 and 3 show.
    var showsColumns: Bool { listening || pinned }
    /// Column 4 shows.
    var showsOptions: Bool { pending != nil || opened != nil }

    // MARK: The pending entry and the search

    /// The pending entry, read against the commands.
    var pending: Board.Heard? {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Board.parse(entry, commands: commands)
    }

    /// The entries, searched with the pending one (or filtered to the clicked command).
    var results: [LibraryRecord] {
        if let p = pending { return Board.rank(Library.shared.items, query: p.text, tag: p.command) }
        return Board.rank(Library.shared.items, query: "", tag: selectedTag)
    }

    var top: LibraryRecord? { pending == nil ? nil : results.first }

    /// How many entries are filed under `tag`.
    func count(_ tag: String) -> Int {
        Library.shared.items.filter { r in r.tag.map { Board.sameWord($0, tag) } ?? false }.count
    }

    // MARK: Hearing

    func heard(_ utterance: String) {
        // Not what the Mac itself is saying, and not while dictating.
        let service = Service.shared
        guard !service.reader.speaking, !service.speaker.speaking, !Recorder.shared.on else { return }
        if Board.isWake(utterance) {
            activity()
            Main.delegate.togglePanel(byVoice: true)
            return
        }
        if let option = Board.option(utterance) {
            // An option word is never an entry: it answers what's pending, or what's open.
            if pending != nil {
                choose(option)
                return
            }
            switch (option, opened) {
            case (.copy, .record(let r)?): copyText(r.text)
            case (.copy, .http(let c)?): copyText(c.response)
            case (.no, _?): opened = nil
            default: break
            }
            return
        }
        entry = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        opened = nil
        play("Tink")
    }

    func choose(_ option: Board.Option) {
        switch option {
        case .add: add()
        case .open: openTop()
        case .no: no()
        case .copy: copyTop()
        }
    }

    /// The pending entry joins the entries, on top.
    func add() {
        guard let p = pending, !p.text.isEmpty else { return }
        Library.shared.add(LibraryRecord(kind: .note, text: p.text, tag: p.tag))
        entry = ""
        selectedTag = nil
        play("Pop")
        say("Added under #\(p.tag)")
    }

    func openTop() {
        guard let r = top else { return }
        entry = ""
        open(r)
    }

    func no() {
        entry = ""
        say(nil)
    }

    /// The best match, or the pending entry itself when nothing matches.
    func copyTop() {
        guard let p = pending else { return }
        copyText(top?.text ?? p.text)
        entry = ""
    }

    func copyText(_ text: String) {
        Service.shared.copy(text)
        say("Copied")
    }

    /// A link opens in the browser; "GET …" or "POST …" is called; anything else is shown.
    func open(_ record: LibraryRecord) {
        activity()
        switch Board.action(for: record.text) {
        case .browse(let url):
            NSWorkspace.shared.open(url)
            opened = nil
            say("Opened \(url.host ?? url.absoluteString) in your browser")
        case .http(let method, let url, let body):
            call(HTTPCall(method: method, url: url, body: body))
        case .show:
            opened = .record(record)
        }
    }

    func delete(_ record: LibraryRecord) {
        Library.shared.delete(record.id)
        if case .record(let r) = opened, r.id == record.id { opened = nil }
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
        guard w != Board.wakeWord, Board.option(w) == nil, !commands.contains(where: { Board.sameWord($0, w) }) else {
            say("“\(w)” can't be a command (it's taken)")
            return
        }
        commands.append(w)
        defaults.set(commands, forKey: "boardCommands")
    }

    func removeCommand(_ word: String) {
        commands.removeAll { $0 == word }
        defaults.set(commands, forKey: "boardCommands")
        if selectedTag == word { selectedTag = nil }
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

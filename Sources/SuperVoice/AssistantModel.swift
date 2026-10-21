import AppKit
import Combine
import Foundation
import VoiceCore

/// What the assistant is set to: where Ollama is, which model, how long with nothing said before
/// it turns off.
struct AssistantSettings: Codable, Equatable {
    var ollamaURL = OllamaClient.defaultURL
    /// Ollama's name for it ("llama3.2:latest"); empty: the first one Ollama has.
    var model = ""
    var idleSeconds: Double = 180
    /// Tool Mac Tool Run, which runs the user's scripts for the model; empty: not offered.
    var toolRunURL = ToolRunClient.defaultURL
    /// Let the model think before answering (slower). Off: turned off as far as it goes.
    var thinking = false
    /// Talking over the answer stops it and is heard (barge in); off, it doesn't listen while it talks.
    var bargeIn = true
    /// Its voice is taken out of what the microphone hears (Apple's voice processing).
    var echoCancel = true
    /// 2: the turn-off went from a minute to three by default.
    var version = 2

    init() {}

    // Settings saved before a field existed still load, taking its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistantSettings()
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        idleSeconds = try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? d.idleSeconds
        toolRunURL = try c.decodeIfPresent(String.self, forKey: .toolRunURL) ?? d.toolRunURL
        thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking) ?? d.thinking
        bargeIn = try c.decodeIfPresent(Bool.self, forKey: .bargeIn) ?? d.bargeIn
        echoCancel = try c.decodeIfPresent(Bool.self, forKey: .echoCancel) ?? d.echoCancel
        // Saved when a minute was the default: it's three now.
        if (try c.decodeIfPresent(Int.self, forKey: .version) ?? 1) < 2, idleSeconds == 60 { idleSeconds = d.idleSeconds }
    }
}

/// AI Listen: a conversation with Ollama by voice. With always listen on, it hears only "Tom",
/// which starts it ("Tom, what's…" asks straight away); clicking the panel's tile starts it too.
/// On, everything said goes to the model and the answer is read back, until three minutes (by
/// default) pass with nothing said, when it plays its off sound and turns itself off. Talking over
/// the answer stops it (barge in). Each start is a new chat, kept in the AI library as it goes; the
/// model sees only this chat, and uses its skills (the library, the browser, files, …) when asked.
/// On the main thread.
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    enum Phase: Equatable {
        case off
        /// Listening for the next thing to say to the model.
        case listening
        /// Waiting for the model.
        case thinking
        /// Reading the answer.
        case speaking
    }

    @Published private(set) var on = false
    /// While it's off, listening for "Tom" (and wanted so across launches).
    @Published private(set) var alwaysListen: Bool
    @Published private(set) var thinking = false
    /// What the listener is hearing right now, before the pause that ends it.
    @Published private(set) var hearing = ""
    /// What the always-listener is hearing (only "Tom" is acted on).
    @Published private(set) var wakeHearing = ""
    /// This chat, as it stands (a question shows as soon as it's asked).
    @Published private(set) var turns: [ChatTurn] = []
    /// A line saying what just happened.
    @Published private(set) var notice: String?
    @Published var problem: String?
    /// The models Ollama has.
    @Published private(set) var models: [String] = []
    @Published private(set) var settings: AssistantSettings
    /// Seconds left before it turns off (nil when off).
    @Published private(set) var idleLeft: Double?
    /// The tools the model called for the last answer.
    @Published private(set) var lastToolCalls: [String] = []
    /// Thinking is off but couldn't be turned off all the way: what to do, and the command.
    @Published private(set) var thinkingAdvice: (text: String, command: String?)?
    /// Ollama's version, once asked.
    private var ollamaVersion: String?
    /// Little sounds when it wakes and hears (the off sound always plays).
    @Published var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "assistantSounds") } }

    /// The microphone and the voice share one engine, echo cancelled: what the voice says is taken
    /// back out of what the microphone hears, so it doesn't hear itself.
    static let echo = EchoCancel()
    /// Its own voice, so stopping it stops nothing else.
    let voice = SpeechPlayer(shared: AssistantModel.echo)
    let listener = Recorder(pauseToEnd: 1.2, holdIfUnfinished: TurnEnd.hold, shared: AssistantModel.echo)
    /// Always listen: hears "Tom" while it's off.
    let wakeListener = Recorder(pauseToEnd: 1.0, holdIfUnfinished: TurnEnd.hold)
    /// The sound it makes as it turns off.
    static let offSound = "Submarine"

    private var chat: Conversation?
    /// The chat as it was before the question now running: what a stop goes back to, since the
    /// question's task can't be stopped and keeps its own chat.
    private var settled: Conversation?
    private var client: OllamaClient
    /// Tool Mac Tool Run, when its address is set.
    private var runner: ToolRunClient?
    /// The skills that need the Mac.
    private var skills: SkillRunner
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var watching: Set<AnyCancellable> = []
    /// Counts questions, so an answer to one that was stopped is dropped.
    private var generation = 0
    /// Said while the model was still answering the last thing: asked next.
    private var pending: [String] = []
    /// The question running, and when it was asked: more said soon after, before the answer, is
    /// the rest of it (a pause mid-sentence sent it), so the two are asked as one.
    private var asking: (text: String, at: Date)?
    /// The model changed the library while answering the question running (it isn't asked again).
    private var changedLibrary = false
    /// What the voice is reading, and until when what's heard may still be it coming back.
    private var reading = ""
    private var echoUntil = Date.distantPast
    private var noticeClear: DispatchWorkItem?

    private init() {
        let defaults = UserDefaults.standard
        var loaded = AssistantSettings()
        if let data = defaults.data(forKey: "assistantSettings"), let saved = try? JSONDecoder().decode(AssistantSettings.self, from: data) {
            loaded = saved
        }
        settings = loaded
        Self.echo.wanted = loaded.echoCancel
        alwaysListen = defaults.bool(forKey: "alwaysListen")
        sounds = defaults.object(forKey: "assistantSounds") as? Bool ?? true
        client = OllamaClient(baseURL: loaded.ollamaURL)
        client.thinking = loaded.thinking
        runner = Self.runner(for: loaded)
        let board = SkillsModel.shared
        skills = SkillRunner(host: MacSkills.shared, sites: board.sites, searchTemplate: board.searchTemplate)
        listener.onUtterance = { [weak self] said in self?.heard(said) }
        wakeListener.onUtterance = { [weak self] said in self?.wakeHeard(said) }
        listener.$text.receive(on: DispatchQueue.main).sink { [weak self] t in
            guard let self else { return }
            self.hearing = t
            if !t.isEmpty { self.activity() }
            self.bargeIn(t)
        }.store(in: &watching)
        wakeListener.$text.receive(on: DispatchQueue.main).sink { [weak self] t in self?.wakeHearing = t }.store(in: &watching)
        for recorder in [listener, wakeListener] {
            recorder.$problem.receive(on: DispatchQueue.main).sink { [weak self] p in
                if let p { self?.problem = p }
            }.store(in: &watching)
        }
        voice.$problem.receive(on: DispatchQueue.main).sink { [weak self] p in
            if let p { self?.problem = p }
        }.store(in: &watching)
        // The phase shows the voice's state too.
        voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &watching)
        voice.onDone = { [weak self] in self?.spoke() }
        // Dictating takes the microphone, and what the Mac says itself isn't to be heard: the
        // listeners wait meanwhile, dropping what they half heard, then carry on. Its own voice
        // is listened over (barge in), unless that's off.
        let service = Service.shared
        Publishers.Merge4(Recorder.shared.$on.map { _ in () }, service.reader.$speaking.map { _ in () },
                          service.speaker.$speaking.map { _ in () }, voice.$speaking.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshListening() }
            .store(in: &watching)
    }

    /// At launch: listen for "Tom" if it was.
    func launch() {
        refreshListening()
    }

    var phase: Phase {
        if !on { return .off }
        if voice.speaking { return .speaking }
        if thinking { return .thinking }
        return .listening
    }

    /// The model it's talking to, as shown.
    var modelName: String { settings.model.isEmpty ? "(none yet)" : settings.model }

    // MARK: On and off

    /// Starts talking (a new chat): just talk. `question`: asked right away. It doesn't open the
    /// window: it works all the same without it.
    func start(question: String? = nil) {
        if on {
            if let question { ask(question) }
            return
        }
        on = true
        problem = nil
        newChat(say: false)
        activity()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkIdle() }
        refreshListening()
        refreshModels()
        play("Pop")
        say("Listening: just talk")
        if let question { ask(question) }
    }

    /// Stops, with its off sound first: the microphone closes and the voice stops. The chat stays
    /// in the AI library. Always listen carries on listening for "Tom".
    func stop(reason: String? = nil) {
        guard on else { return }
        NSSound(named: NSSound.Name(Self.offSound))?.play()
        on = false
        generation += 1
        if thinking, let settled { chat = settled }
        settled = nil
        thinking = false
        pending = []
        asking = nil
        listener.stop()
        listener.clear()
        voice.stop()
        idleTimer?.invalidate()
        idleTimer = nil
        idleLeft = nil
        hearing = ""
        if let reason { say(reason) }
        refreshListening()
    }

    func toggle() {
        on ? stop(reason: "Turned off") : start()
    }

    /// Always listen for "Tom" (the ear on the panel).
    func setAlwaysListen(_ want: Bool) {
        alwaysListen = want
        UserDefaults.standard.set(want, forKey: "alwaysListen")
        refreshListening()
    }

    private var micBusy: Bool {
        let service = Service.shared
        return Recorder.shared.on || service.reader.speaking || service.speaker.speaking
    }

    /// Each listener on or off, as things are: AI Listen's while it's on (but not over dictation,
    /// the Mac's other voices, or its own when barge in is off), the wake listener while it's off.
    private func refreshListening() {
        let talk = on && !micBusy && !(voice.speaking && !settings.bargeIn)
        if talk {
            listener.start()
        } else if listener.on {
            listener.stop()
            listener.clear()
        }
        if alwaysListen && !on && !micBusy {
            wakeListener.start()
        } else if wakeListener.on {
            wakeListener.stop()
            wakeListener.clear()
            wakeHearing = ""
        }
    }

    // MARK: Hearing

    /// Always listening, while off: only "Tom" counts, alone or first.
    private func wakeHeard(_ utterance: String) {
        guard !on, alwaysListen, !micBusy else { return }
        switch Assistant.hear(utterance, awake: false) {
        case .wake, .command(.newChat): start()
        case .wakeThen(let question): start(question: question)
        default: break
        }
    }

    func heard(_ utterance: String) {
        guard on, !micBusy else { return }
        var said = utterance
        if settings.bargeIn, voice.speaking || Date() < echoUntil {
            // While it reads (or just after), what's heard may be the answer coming back.
            guard let mine = Echo.interruption(utterance, reading: reading, cancelled: Self.echo.cancelsEcho) else { return }
            if voice.speaking { voice.stop() }
            said = mine
        }
        switch Assistant.hear(said, awake: true) {
        case .wake:
            activity()
            play("Pop")
            say("Listening")
        case .wakeThen(let question), .speech(let question):
            activity()
            ask(question)
        case .command(let command):
            activity()
            run(command)
        }
    }

    /// Talked over the answer: it stops reading, so the rest is heard.
    private func bargeIn(_ live: String) {
        guard on, settings.bargeIn, voice.speaking, !live.isEmpty, Echo.interruption(live, reading: reading, cancelled: Self.echo.cancelsEcho) != nil else { return }
        voice.stop()
        echoUntil = Date().addingTimeInterval(2)
        say("Listening")
    }

    private func run(_ command: Assistant.Command) {
        switch command {
        case .stop:
            voice.stop()
            if thinking {
                generation += 1
                thinking = false
                pending = []
                asking = nil
                if let settled { chat = settled }
                settled = nil
                turns = chat?.turns ?? []
            }
            say("Stopped")
        case .newChat:
            newChat(say: true)
        case .off:
            stop(reason: "Turned off")
            talk("Bye.")
        }
    }

    /// Typed in the window: the same as saying it (and it starts it, if it's off).
    func type(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !on { start() }
        activity()
        ask(t)
    }

    // MARK: Asking

    /// Forgets this chat (it stays in the AI library) and starts another.
    func newChat(say announce: Bool = true) {
        generation += 1
        thinking = false
        pending = []
        asking = nil
        let c = Conversation(llm: client, model: settings.model, library: { [] })
        configure(c)
        chat = c
        turns = []
        lastToolCalls = []
        if announce {
            say("New chat")
            if on { talk("Okay, a new chat.") }
        }
    }

    /// What the chat may use: the skills that are on, scripts, editing the library.
    private func configure(_ c: Conversation) {
        let board = SkillsModel.shared
        skills.sites = board.sites
        skills.searchTemplate = board.searchTemplate
        skills.showBrowser = board.showBrowser
        c.runner = runner
        c.skills = skills
        c.enabled = board.enabled
        c.quick = !settings.thinking
        c.save = { [weak self] record in
            DispatchQueue.main.async {
                let new = Library.shared.item(record.id) == nil
                Library.shared.save(record)
                self?.changedLibrary = true
                self?.say((new ? "Saved in the library: " : "Changed in the library: ") + record.title)
            }
        }
        c.onToolUse = { use in DispatchQueue.main.async { SkillsModel.shared.record(use) } }
    }

    /// The skills changed on the board: the chat (and the one to go back to) uses them from now on.
    func skillsChanged() {
        if let chat { configure(chat) }
        if let settled { configure(settled) }
    }

    private func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if thinking {
            if let a = asking, Date().timeIntervalSince(a.at) < 20, !changedLibrary, let settled {
                // The rest of what's being asked: ask it whole instead.
                generation += 1
                thinking = false
                chat = settled
                self.settled = nil
                asking = nil
                ask(a.text + " " + q)
                return
            }
            pending.append(q)
            return
        }
        guard let chat else { return }
        voice.stop()
        thinking = true
        changedLibrary = false
        asking = (q, Date())
        settled = chat.copy()
        turns = chat.turns + [ChatTurn(role: .user, text: q)]
        play("Tink")
        // The library as it is now, for the tools (read off the main thread while the model thinks).
        let items = Library.shared.items
        chat.library = { items }
        chat.model = settings.model
        generation += 1
        let mine = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error>
            do {
                let answer = try await chat.ask(q)
                result = .success(answer)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, mine == self.generation else { return }
                self.thinking = false
                self.asking = nil
                self.turns = chat.turns
                self.lastToolCalls = chat.toolCalls
                self.activity()
                self.adviseOnThinking()
                switch result {
                case .success(let answer):
                    self.save(chat)
                    self.speak(answer)
                case .failure(let error):
                    self.problem = error.localizedDescription
                    self.speak(Self.spokenProblem(error))
                }
            }
        }
    }

    /// What it says when the model couldn't answer.
    static func spokenProblem(_ error: Error) -> String {
        guard let e = error as? AssistantError else { return "Something went wrong talking to Ollama." }
        switch e {
        case .unreachable: return "I can't reach Ollama. Is it running?"
        case .noModel: return "Ollama has no model for me to talk to."
        case .server: return "Ollama couldn't answer that."
        case .badReply: return "Something went wrong talking to Ollama."
        }
    }

    private func speak(_ text: String) {
        let spoken = Assistant.spoken(text)
        guard !spoken.isEmpty else {
            spoke()
            return
        }
        talk(spoken)
    }

    /// Says `text` in its voice (what's heard meanwhile is checked against it).
    private func talk(_ text: String) {
        reading = text
        voice.say(text, voice: Service.shared.voice, speed: Service.shared.settings.speed)
    }

    /// Done reading: the countdown starts again, and anything said meanwhile is asked.
    private func spoke() {
        echoUntil = Date().addingTimeInterval(1.5)
        guard on else { return }
        activity()
        if !pending.isEmpty { ask(pending.removeFirst()) }
    }

    private func save(_ chat: Conversation) {
        guard !chat.isEmpty else { return }
        Library.shared.save(chat.record(existing: Library.shared.item(chat.id)))
    }

    // MARK: Settings and models

    func change(_ edit: (inout AssistantSettings) -> Void) {
        var s = settings
        edit(&s)
        guard s != settings else { return }
        let moved = s.ollamaURL != settings.ollamaURL
        let newModel = s.model != settings.model
        settings = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "assistantSettings") }
        if moved {
            client = OllamaClient(baseURL: s.ollamaURL)
            ollamaVersion = nil
            chat?.llm = client
            models = []
            refreshModels()
        }
        runner = Self.runner(for: s)
        chat?.runner = runner
        chat?.model = s.model
        chat?.quick = !s.thinking
        client.thinking = s.thinking
        Self.echo.wanted = s.echoCancel
        adviseOnThinking()
        refreshListening()
        if newModel, on { warmUp() }
    }

    /// Gets the model loaded in Ollama now, so the first answer doesn't wait for it.
    private func warmUp() {
        let client = self.client, model = settings.model
        Task.detached { await client.warm(model) }
    }

    /// Turns thinking on or off (the toggle in AI Listen).
    func setThinking(_ on: Bool) {
        change { $0.thinking = on }
        say(on ? "Thinking on: slower, more careful answers" : "Thinking off")
    }

    /// With thinking off, says what's left to do when it can't be turned off all the way.
    private func adviseOnThinking() {
        thinkingAdvice = settings.thinking ? nil
            : ThinkingAdvice.advice(model: settings.model, version: ollamaVersion, thoughtAnyway: client.thoughtAnyway)
    }

    static func runner(for s: AssistantSettings) -> ToolRunClient? {
        let url = s.toolRunURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : ToolRunClient(baseURL: url)
    }

    /// Asks Ollama which models it has; with none chosen (or the chosen one gone), takes the first.
    func refreshModels() {
        let client = self.client
        Task.detached { [weak self] in
            let result: Result<[String], Error>
            do {
                let names = try await client.models()
                result = .success(names)
                let version = try? await client.version()
                DispatchQueue.main.async { [weak self] in
                    guard let self, client === self.client else { return }
                    self.ollamaVersion = version
                    self.adviseOnThinking()
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, client === self.client else { return }
                switch result {
                case .success(let names):
                    self.models = names
                    if names.isEmpty {
                        self.problem = AssistantError.noModel.errorDescription
                    } else {
                        if self.problem?.contains("Ollama") == true { self.problem = nil }
                        if !names.contains(self.settings.model), let first = names.first {
                            self.change { $0.model = first }
                        }
                        if self.on { self.warmUp() }
                    }
                case .failure(let error):
                    self.problem = error.localizedDescription
                }
            }
        }
    }

    // MARK: Idle

    private func activity() {
        lastActivity = Date()
    }

    private func checkIdle() {
        guard on else { return }
        // Thinking and talking aren't idleness.
        if thinking || voice.speaking { activity() }
        let idle = Date().timeIntervalSince(lastActivity)
        idleLeft = max(0, settings.idleSeconds - idle)
        if idle >= settings.idleSeconds {
            stop(reason: "Turned off: nothing said for \(Self.clock(settings.idleSeconds))")
        }
    }

    /// "1 minute", "90 seconds", "5 minutes".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return "\(s) seconds"
    }

    // MARK: Helpers

    private func say(_ s: String?) {
        noticeClear?.cancel()
        notice = s
        guard let s else { return }
        let clear = DispatchWorkItem { [weak self] in if self?.notice == s { self?.notice = nil } }
        noticeClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: clear)
    }

    private func play(_ name: String) {
        guard sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

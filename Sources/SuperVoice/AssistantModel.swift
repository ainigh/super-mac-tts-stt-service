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
    var idleSeconds: Double = 60
    /// Tool Mac Tool Run, which runs the user's scripts for the model; empty: not offered.
    var toolRunURL = ToolRunClient.defaultURL
    /// Let the model think before answering (slower). Off: turned off as far as it goes.
    var thinking = false

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
    }
}

/// AI Listen: a conversation with Ollama by voice. Started, it listens for "Micky" or "Ollama";
/// from then on everything said goes to the model and the answer is read back, until a minute (by
/// default) passes with nothing said, when it turns itself off. Each start is a new chat, kept in
/// the AI library as it goes; the model sees only this chat, and looks earlier ones (and the
/// library) up with its tools when asked. On the main thread.
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    enum Phase: Equatable {
        case off
        /// Listening for the wake word.
        case waiting
        /// Awake: listening for the next thing to say to the model.
        case listening
        /// Waiting for the model.
        case thinking
        /// Reading the answer.
        case speaking
    }

    @Published private(set) var on = false
    @Published private(set) var awake = false
    @Published private(set) var thinking = false
    /// What the listener is hearing right now, before the pause that ends it.
    @Published private(set) var hearing = ""
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
    /// Little sounds when it wakes and hears.
    @Published var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "assistantSounds") } }

    /// Its own voice, so stopping it stops nothing else.
    let voice = SpeechPlayer()
    let listener = Recorder(pauseToEnd: 1.2)

    private var chat: Conversation?
    /// The chat as it was before the question now running: what a stop goes back to, since the
    /// question's task can't be stopped and keeps its own chat.
    private var settled: Conversation?
    private var client: OllamaClient
    /// Tool Mac Tool Run, when its address is set.
    private var runner: ToolRunClient?
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var watching: Set<AnyCancellable> = []
    /// Counts questions, so an answer to one that was stopped is dropped.
    private var generation = 0
    /// Said while the model was still answering the last thing: asked next.
    private var pending: [String] = []
    private var noticeClear: DispatchWorkItem?

    private init() {
        let defaults = UserDefaults.standard
        var loaded = AssistantSettings()
        if let data = defaults.data(forKey: "assistantSettings"), let saved = try? JSONDecoder().decode(AssistantSettings.self, from: data) {
            loaded = saved
        }
        settings = loaded
        sounds = defaults.object(forKey: "assistantSounds") as? Bool ?? true
        client = OllamaClient(baseURL: loaded.ollamaURL)
        client.thinking = loaded.thinking
        runner = Self.runner(for: loaded)
        listener.onUtterance = { [weak self] said in self?.heard(said) }
        listener.$text.receive(on: DispatchQueue.main).sink { [weak self] t in
            self?.hearing = t
            if !t.isEmpty { self?.activity() }
        }.store(in: &watching)
        listener.$problem.receive(on: DispatchQueue.main).sink { [weak self] p in
            if let p { self?.problem = p }
        }.store(in: &watching)
        voice.$problem.receive(on: DispatchQueue.main).sink { [weak self] p in
            if let p { self?.problem = p }
        }.store(in: &watching)
        // The phase shows the voice's state too.
        voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &watching)
        voice.onDone = { [weak self] in self?.spoke() }
        // Dictating takes the microphone, and what the Mac says itself (its own answers included)
        // isn't to be heard: it waits meanwhile, dropping what it half heard, then carries on.
        let service = Service.shared
        Recorder.shared.$on.removeDuplicates()
            .combineLatest(service.reader.$speaking.removeDuplicates(), service.speaker.$speaking.removeDuplicates(),
                           voice.$speaking.removeDuplicates())
            .map { $0 || $1 || $2 || $3 }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                guard let self, self.on else { return }
                if busy {
                    self.listener.stop()
                    self.listener.clear()
                } else {
                    self.resume()
                }
            }.store(in: &watching)
    }

    var phase: Phase {
        if !on { return .off }
        if voice.speaking { return .speaking }
        if thinking { return .thinking }
        return awake ? .listening : .waiting
    }

    /// The model it's talking to, as shown.
    var modelName: String { settings.model.isEmpty ? "(none yet)" : settings.model }

    // MARK: On and off

    /// Starts listening (a new chat). `awake`: no wake word needed, just talk; `question`: asked
    /// right away. Neither opens the window: it works all the same without it.
    func start(awake wakeNow: Bool = false, question: String? = nil) {
        if on {
            if wakeNow, !awake { wake() }
            if let question { ask(question) }
            return
        }
        on = true
        awake = wakeNow
        problem = nil
        newChat(say: false)
        activity()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkIdle() }
        resume()
        refreshModels()
        if wakeNow {
            play("Pop")
            say("Listening: just talk")
        } else {
            say("Say “\(Assistant.name)” or “Ollama”, then talk")
        }
        if let question { ask(question) }
    }

    /// Stops: the microphone closes and the voice stops. The chat stays in the AI library.
    func stop(reason: String? = nil) {
        guard on else { return }
        on = false
        awake = false
        generation += 1
        if thinking, let settled { chat = settled }
        settled = nil
        thinking = false
        pending = []
        listener.stop()
        listener.clear()
        voice.stop()
        idleTimer?.invalidate()
        idleTimer = nil
        idleLeft = nil
        hearing = ""
        if let reason { say(reason) }
    }

    func toggle() {
        on ? stop(reason: "Turned off") : start()
    }

    /// The panel's tile: talk with Ollama now, no wake word; again to stop.
    func toggleTalking() {
        on ? stop(reason: "Turned off") : start(awake: true)
    }

    /// Listens, unless dictation or a voice has the floor.
    private func resume() {
        let service = Service.shared
        guard on, !Recorder.shared.on, !service.reader.speaking, !service.speaker.speaking, !voice.speaking else { return }
        listener.start()
    }

    private var othersBusy: Bool {
        let service = Service.shared
        return Recorder.shared.on || service.reader.speaking || service.speaker.speaking || voice.speaking
    }

    // MARK: Hearing

    func heard(_ utterance: String) {
        guard on, !othersBusy else { return }
        switch Assistant.hear(utterance, awake: awake) {
        case .wake:
            activity()
            wake()
        case .wakeThen(let question):
            activity()
            if !awake { wake() }
            ask(question)
        case .command(let command):
            activity()
            run(command)
        case .speech(let text):
            guard awake else { return }
            activity()
            ask(text)
        }
    }

    private func wake() {
        awake = true
        play("Pop")
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
                if let settled { chat = settled }
                settled = nil
                turns = chat?.turns ?? []
            }
            say("Stopped")
        case .newChat:
            newChat(say: true)
        case .off:
            stop(reason: "Turned off")
            voice.say("Bye.", voice: Service.shared.voice, speed: Service.shared.settings.speed)
        }
    }

    /// Typed in the window: the same as saying it (and it wakes it, or starts it).
    func type(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !on { start() }
        activity()
        if !awake { awake = true }
        ask(t)
    }

    // MARK: Asking

    /// Forgets this chat (it stays in the AI library) and starts another.
    func newChat(say announce: Bool = true) {
        generation += 1
        thinking = false
        pending = []
        chat = Conversation(llm: client, model: settings.model, library: { [] })
        chat?.runner = runner
        turns = []
        lastToolCalls = []
        if announce {
            say("New chat")
            if on { voice.say("Okay, a new chat.", voice: Service.shared.voice, speed: Service.shared.settings.speed) }
        }
    }

    private func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if thinking {
            pending.append(q)
            return
        }
        guard let chat else { return }
        voice.stop()
        thinking = true
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
        voice.say(spoken, voice: Service.shared.voice, speed: Service.shared.settings.speed)
    }

    /// Done reading: the minute starts again, and anything said meanwhile is asked.
    private func spoke() {
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
        client.thinking = s.thinking
        adviseOnThinking()
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

import AppKit
import Combine
import Foundation
import VoiceCore

/// What the assistant is set to: where Ollama is, which model, how long with nothing said before
/// it turns off, and Jerry's model and voice.
struct AssistantSettings: Codable, Equatable {
    var ollamaURL = OllamaClient.defaultURL
    /// Ollama's name for it ("llama3.2:latest"); empty: the first one Ollama has.
    var model = ""
    var idleSeconds: Double = 180
    /// Tool Mac Tool Run, which runs the user's scripts for the model; empty: not offered.
    var toolRunURL = ToolRunClient.defaultURL
    /// Let the model think before answering (slower). Off: turned off as far as it goes.
    var thinking = false
    /// Talking over the answer stops it and is heard (barge in); off, it doesn't listen while it
    /// talks. Off unless asked for: without echo cancellation, what's heard while it talks is kept
    /// only if it's "stop", "wait" or "Tom", and the rest is thrown away, which gets in the way.
    var bargeIn = false
    /// Its voice is taken out of what the microphone hears (Apple's voice processing). Off unless
    /// asked for: with it on, the microphone it gives has been heard but not understood on some
    /// Macs, while the plain microphone is heard everywhere.
    var echoCancel = false
    /// Jerry's model; empty: the same as Tom's.
    var jerryModel = ""
    /// Jerry's voice (its id); empty: the first voice of the other kind from Tom's.
    var jerryVoice = ""
    /// With Listen on, a wave at the camera starts it.
    var wave = true
    /// A soft sound every few seconds while it works, different for each kind of work.
    var workingSounds = true
    /// Its voices are told from yours by how they sound (voice prints), not only by the words.
    var voicePrints = true
    /// 2: the turn-off went from a minute to three by default. 3: voice processing went from on to
    /// off by default. 4: so did barge in.
    var version = 4

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
        jerryModel = try c.decodeIfPresent(String.self, forKey: .jerryModel) ?? d.jerryModel
        jerryVoice = try c.decodeIfPresent(String.self, forKey: .jerryVoice) ?? d.jerryVoice
        wave = try c.decodeIfPresent(Bool.self, forKey: .wave) ?? d.wave
        workingSounds = try c.decodeIfPresent(Bool.self, forKey: .workingSounds) ?? d.workingSounds
        voicePrints = try c.decodeIfPresent(Bool.self, forKey: .voicePrints) ?? d.voicePrints
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // Saved when a minute was the default: it's three now.
        if version < 2, idleSeconds == 60 { idleSeconds = d.idleSeconds }
        // Saved when voice processing was on by default (so on was never chosen): off, as now.
        if version < 3 { echoCancel = d.echoCancel }
        // The same for barge in.
        if version < 4 { bargeIn = d.bargeIn }
    }
}

/// One of the two assistants as it runs: its chat, whether it's working, what's waiting for it.
final class Agent {
    let name: String
    var chat: Conversation
    /// The chat as it was before the question now running: what a stop goes back to, since the
    /// question's task can't be stopped and keeps its own chat.
    var settled: Conversation?
    var thinking = false
    var activity: Conversation.Activity = .idle
    /// Counts questions, so an answer to one that was stopped is dropped.
    var generation = 0
    /// Said to it while it was still answering: asked next (from whom; nil: the user).
    var pending: [(text: String, from: String?)] = []
    /// The user's question running, and when it was asked: more said soon after, before the
    /// answer, is the rest of it (a pause mid-sentence sent it), so the two are asked as one.
    var asking: (text: String, at: Date)?
    /// The user's question running, as it shows in the room (taken out if it's stopped or fails).
    var questionTurn: ChatTurn?
    /// It changed the library while answering the question running (it isn't asked again).
    var changedLibrary = false
    var lastToolCalls: [String] = []
    /// Things for its chat to know, kept while it's busy (its chat can't be touched meanwhile).
    var later: [(Conversation) -> Void] = []

    init(name: String, chat: Conversation) {
        self.name = name
        self.chat = chat
    }

    /// Tells its chat something now, or once it's free.
    func tell(_ what: @escaping (Conversation) -> Void) {
        if thinking { later.append(what) } else { what(chat) }
    }

    func catchUp() {
        guard !thinking else { return }
        for what in later { what(chat) }
        later = []
    }
}

/// AI Listen: a conversation with Ollama by voice. With always listen on, it hears only "Tom",
/// which starts it ("Tom, what's…" asks straight away), and a wave at the camera starts it too;
/// clicking the panel's tile starts it as well. On, everything said goes to the model and the
/// answer is read back, until three minutes (by default) pass with nothing said, when it plays its
/// off sound and turns itself off. Talking over the answer stops it (barge in). Each start is a new
/// chat, kept in the AI library as it goes; the model sees only this chat, and uses its skills (the
/// library, the browser, files, …) when asked.
///
/// With the Jerry skill on, there are two of them in the room: Tom, who you talk to, and Jerry,
/// with his own model and voice, whom Tom brings in when you ask. What Tom says to Jerry is read
/// out in Tom's voice and reaches Jerry only once it's been heard (cut in, and it doesn't); Jerry's
/// answers come back to Tom the same way, so the two can go back and forth while you listen, and
/// cut in. You can talk to Jerry yourself by name. Jerry can be working while you talk to Tom.
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
    /// Tom is working.
    @Published private(set) var thinking = false
    /// Jerry is working (he may be, while you talk to Tom).
    @Published private(set) var jerryThinking = false
    /// What the listener is hearing right now, before the pause that ends it.
    @Published private(set) var hearing = ""
    /// What the always-listener is hearing (only "Tom" is acted on).
    @Published private(set) var wakeHearing = ""
    /// The room as it stands: you, Tom and Jerry (a question shows as soon as it's asked).
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
    /// Who the voice is reading now: Tom or Jerry (nil: nobody).
    @Published private(set) var speaking: String?
    /// What's being worked on, in words: "Jerry: searching the web".
    @Published private(set) var working: String?
    /// Ollama's version, once asked.
    private var ollamaVersion: String?
    /// Little sounds when it wakes and hears (the off sound always plays).
    @Published var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "assistantSounds") } }

    /// The microphone and the voice share one engine, echo cancelled: what the voice says is taken
    /// back out of what the microphone hears, so it doesn't hear itself.
    static let echo = EchoCancel()
    /// Its own voice (Tom's and Jerry's, one after the other), so stopping it stops nothing else.
    let voice = SpeechPlayer(shared: AssistantModel.echo)
    let listener = Recorder(pauseToEnd: 1.2, holdIfUnfinished: TurnEnd.hold, shared: AssistantModel.echo)
    /// Always listen: hears "Tom" while it's off.
    let wakeListener = Recorder(pauseToEnd: 1.0, holdIfUnfinished: TurnEnd.hold)
    /// The camera, watching for a wave while Listen is on.
    let wave = WaveWatcher()
    /// The sound it makes as it turns off.
    static let offSound = "Submarine"

    private var tom: Agent?
    private var jerry: Agent?
    /// This chat's record in the AI library.
    private var roomID = UUID()
    private var roomCreated = Date()
    /// Messages between Tom and Jerry since the user last spoke.
    private var hops = 0
    private var client: OllamaClient
    /// Tool Mac Tool Run, when its address is set.
    private var runner: ToolRunClient?
    /// The skills that need the Mac.
    private var skills: SkillRunner
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var workTimer: Timer?
    private var watching: Set<AnyCancellable> = []
    /// What's queued to be said, by its number in the voice: who says it, and what to do if the
    /// user cuts in before it's heard (a message that then isn't delivered).
    private var queued: [(item: Int, name: String, cut: (() -> Void)?)] = []
    /// What the voice is reading (everything queued since it last went quiet), and until when
    /// what's heard may still be it coming back.
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
        listener.name = "AI Listen"
        wakeListener.name = "Always listen"
        listener.onUtterance = { [weak self] said in self?.heard(said) }
        wakeListener.onUtterance = { [weak self] said in self?.wakeHeard(said) }
        // Each phrase heard while a voice plays is checked against the voices' prints: theirs is
        // dropped before it's even written down. Heard with nobody talking, it teaches yours.
        listener.screening = { [weak self] in
            guard let self, self.settings.voicePrints else { return nil }
            return self.voice.speaking || Date() < self.echoUntil
        }
        listener.screen = { samples, playing in
            if playing { return await VoicePrints.shared.isTheirs(samples) ?? false }
            // Yours: learned on the side, so writing it down doesn't wait.
            Task.detached(priority: .utility) { await VoicePrints.shared.learnUser(samples) }
            return false
        }
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
        wave.$problem.receive(on: DispatchQueue.main).sink { [weak self] p in
            if let p { self?.problem = p }
        }.store(in: &watching)
        wave.onWave = { [weak self] in self?.waved() }
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

    /// At launch: listen for "Tom" (and watch for a wave) if it was.
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

    /// Jerry's model, as shown.
    var jerryModelName: String { settings.jerryModel.isEmpty ? modelName : settings.jerryModel }

    /// The Jerry skill is on: there are two of them.
    var teamOn: Bool { SkillsModel.shared.enabled.contains(Skills.team.id) }

    /// Jerry's voice: the one chosen, or the first of the other kind from Tom's.
    var jerryVoice: Voice {
        if let v = Voice.all.first(where: { $0.id == settings.jerryVoice }) { return v }
        let tom = Service.shared.voice
        return Voice.all.first { $0.female != tom.female } ?? tom
    }

    private func voiceOf(_ agent: Agent) -> Voice {
        agent === tom ? Service.shared.voice : jerryVoice
    }

    private func model(for agent: Agent) -> String {
        agent === tom || settings.jerryModel.isEmpty ? settings.model : settings.jerryModel
    }

    // MARK: On and off

    /// Starts talking (a new chat): just talk. `question`: asked right away. It doesn't open the
    /// window: it works all the same without it.
    func start(question: String? = nil) {
        if on {
            if let question { route(question) }
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
        enrollVoices()
        play("Pop")
        say(teamOn ? "Listening: just talk (Jerry's here too)" : "Listening: just talk")
        if let question { route(question) }
    }

    /// Stops, with its off sound first: the microphone closes and the voice stops. The chat stays
    /// in the AI library. Always listen carries on listening for "Tom".
    func stop(reason: String? = nil) {
        guard on else { return }
        NSSound(named: NSSound.Name(Self.offSound))?.play()
        on = false
        stopTalking()
        for agent in agents { cancel(agent) }
        refreshThinking()
        listener.stop()
        listener.clear()
        idleTimer?.invalidate()
        idleTimer = nil
        idleLeft = nil
        hearing = ""
        working = nil
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

    /// Watch the camera for a wave (with Listen on).
    func setWave(_ want: Bool) {
        change { $0.wave = want }
        say(want ? "Wave at the camera to start it (with Listen on)" : "The camera's off")
    }

    private var micBusy: Bool {
        let service = Service.shared
        return Recorder.shared.on || service.reader.speaking || service.speaker.speaking
    }

    /// Each listener on or off, as things are: AI Listen's while it's on (but not over dictation,
    /// the Mac's other voices, or its own when barge in is off), the wake listener while it's off,
    /// and the camera while Listen is on and a wave is wanted.
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
        if alwaysListen && settings.wave {
            wave.start()
        } else {
            wave.stop()
        }
    }

    // MARK: Hearing

    /// Always listening, while off: only "Tom" counts, alone or first.
    private func wakeHeard(_ utterance: String) {
        NSLog("Always listen heard: %@ (on: %d, listen: %d, mic busy: %d)", utterance, on ? 1 : 0, alwaysListen ? 1 : 0, micBusy ? 1 : 0)
        guard !on, alwaysListen, !micBusy else { return }
        switch Assistant.hear(utterance, awake: false) {
        case .wake, .command(.newChat): start()
        case .wakeThen(let question): start(question: question)
        default: break
        }
    }

    /// A wave at the camera: starts it, or, while it's talking, stops it talking.
    private func waved() {
        guard alwaysListen, settings.wave, !micBusy else { return }
        if !on {
            start()
            say("Listening: you waved")
        } else if voice.speaking {
            stopTalking()
            say("Stopped: you waved")
        }
    }

    func heard(_ utterance: String) {
        NSLog("AI Listen heard: %@ (on: %d, mic busy: %d, speaking: %d, echo cancelled: %d)", utterance, on ? 1 : 0,
              micBusy ? 1 : 0, voice.speaking ? 1 : 0, Self.echo.cancelsEcho ? 1 : 0)
        guard on, !micBusy else { return }
        var said = utterance
        if settings.bargeIn, voice.speaking || Date() < echoUntil {
            // While it reads (or just after), what's heard may be the answer coming back.
            guard let mine = Echo.interruption(utterance, reading: reading, cancelled: Self.echo.cancelsEcho) else {
                NSLog("AI Listen took that for its own voice coming back (reading: %@)", reading)
                return
            }
            if voice.speaking { stopTalking() }
            said = mine
        }
        switch Assistant.hear(said, awake: true) {
        case .wake:
            activity()
            play("Pop")
            say("Listening")
        case .wakeThen(let question), .speech(let question):
            activity()
            route(question)
        case .command(let command):
            activity()
            run(command)
        }
    }

    /// Talked over the answer: it stops reading, so the rest is heard.
    private func bargeIn(_ live: String) {
        guard on, settings.bargeIn, voice.speaking, !live.isEmpty, Echo.interruption(live, reading: reading, cancelled: Self.echo.cancelsEcho) != nil else { return }
        stopTalking()
        echoUntil = Date().addingTimeInterval(2)
        say("Listening")
    }

    /// Something said in the room, by the user: to Jerry when it's said to him by name, else to Tom.
    private func route(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let tom else { return }
        if let jerry, let said = Team.addressed(q) {
            let rest = said.rest
            if rest.isEmpty {
                play("Pop")
                say("Jerry's listening")
                return
            }
            switch Assistant.hear(rest, awake: true) {
            case .command(let command): run(command)
            case .wake: say("Listening")
            case .wakeThen(let r), .speech(let r): ask(r, of: jerry)
            }
            return
        }
        ask(q, of: tom)
    }

    private func run(_ command: Assistant.Command) {
        switch command {
        case .stop:
            stopTalking()
            for agent in agents where agent.thinking { cancel(agent) }
            refreshThinking()
            say("Stopped")
        case .newChat:
            newChat(say: true)
        case .off:
            stop(reason: "Turned off")
            talk("Bye.", as: nil)
        }
    }

    /// Typed in the window: the same as saying it (and it starts it, if it's off).
    func type(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !on { start() }
        activity()
        route(t)
    }

    // MARK: Asking

    private var agents: [Agent] { [tom, jerry].compactMap { $0 } }

    /// Forgets this chat (it stays in the AI library) and starts another.
    func newChat(say announce: Bool = true) {
        for agent in agents { cancel(agent) }
        roomID = UUID()
        roomCreated = Date()
        hops = 0
        turns = []
        lastToolCalls = []
        let t = Agent(name: Assistant.name, chat: Conversation(llm: client, model: settings.model, library: { [] }, id: roomID, created: roomCreated))
        tom = t
        jerry = nil
        if teamOn { jerry = makeJerry() }
        for agent in agents { configure(agent) }
        refreshThinking()
        if announce {
            say("New chat")
            if on { talk("Okay, a new chat.", as: tom) }
        }
    }

    private func makeJerry() -> Agent {
        let c = Conversation(llm: client, model: model(for: tom!), library: { [] })
        c.name = Team.teammate
        return Agent(name: Team.teammate, chat: c)
    }

    /// What the agent's chat may use: the skills that are on, scripts, editing the library, the team.
    private func configure(_ agent: Agent) {
        let board = SkillsModel.shared
        skills.sites = board.sites
        skills.searchTemplate = board.searchTemplate
        skills.showBrowser = board.showBrowser
        let name = agent.name
        for c in [agent.chat, agent.settled].compactMap({ $0 }) {
            c.runner = runner
            c.skills = skills
            c.enabled = board.enabled
            c.quick = !settings.thinking
            var role: Conversation.TeamRole?
            if agent === tom {
                if jerry != nil { role = .lead(teammate: Team.teammate) }
            } else {
                role = .member(lead: Assistant.name)
            }
            c.team = role
            c.save = { [weak self] record in
                DispatchQueue.main.async {
                    let new = Library.shared.item(record.id) == nil
                    Library.shared.save(record)
                    self?.agents.first { $0.name == name }?.changedLibrary = true
                    self?.say((new ? "Saved in the library: " : "Changed in the library: ") + record.title)
                }
            }
            c.onToolUse = { use in DispatchQueue.main.async { SkillsModel.shared.record(use) } }
            c.onActivity = { [weak self] activity in
                DispatchQueue.main.async {
                    guard let self, let agent = self.agents.first(where: { $0.name == name }) else { return }
                    agent.activity = activity
                    self.refreshWorking()
                }
            }
        }
    }

    /// The skills changed on the board: the chats use them from now on, and Jerry comes or goes.
    func skillsChanged() {
        guard tom != nil else { return }
        if teamOn, jerry == nil {
            jerry = makeJerry()
            if on { say("Jerry's here: ask Tom to bring him in, or talk to him by name") }
        } else if !teamOn, let j = jerry {
            cancel(j)
            jerry = nil
            if on { say("Jerry's gone") }
        }
        for agent in agents { configure(agent) }
        refreshThinking()
        if on { enrollVoices() }
    }

    /// Asks `agent` `text`: from the user (nil), who was just heard (`fresh`: the voice stops,
    /// nothing undelivered goes), or from the other agent, delivered now that it's been heard.
    private func ask(_ text: String, of agent: Agent, from: String? = nil, fresh: Bool = true) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if from == nil {
            hops = 0
            if fresh { stopTalking() }
        }
        if agent.thinking {
            if from == nil, let a = agent.asking, Date().timeIntervalSince(a.at) < 20, !agent.changedLibrary, agent.settled != nil {
                // The rest of what's being asked: ask it whole instead.
                cancel(agent, keepPending: true)
                refreshThinking()
                ask(a.text + " " + q, of: agent, from: nil, fresh: false)
                return
            }
            agent.pending.append((q, from))
            return
        }
        agent.catchUp()
        agent.thinking = true
        agent.changedLibrary = false
        agent.asking = from == nil ? (q, Date()) : nil
        let chat = agent.chat
        agent.settled = chat.copy()
        if from == nil {
            let turn = ChatTurn(role: .user, text: q, to: agent === tom ? nil : agent.name)
            agent.questionTurn = turn
            turns.append(turn)
            play("Tink")
            // The other one hears it too.
            if let other = agents.first(where: { $0 !== agent }) {
                other.tell { $0.overhear(q, from: "the user", to: agent.name) }
            }
        } else {
            agent.questionTurn = nil
        }
        // The library as it is now, for the tools (read off the main thread while the model thinks).
        let items = Library.shared.items
        chat.library = { items }
        chat.model = model(for: agent)
        chat.hops = hops
        agent.generation += 1
        let mine = agent.generation
        refreshThinking()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Conversation.Reply, Error>
            do {
                let reply = try await chat.reply(q, from: from)
                result = .success(reply)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, mine == agent.generation else { return }
                agent.thinking = false
                agent.asking = nil
                agent.activity = .idle
                agent.lastToolCalls = chat.toolCalls
                self.lastToolCalls = self.agents.flatMap(\.lastToolCalls)
                self.activity()
                self.adviseOnThinking()
                agent.catchUp()
                switch result {
                case .success(let reply):
                    agent.questionTurn = nil
                    self.answered(agent, reply, from: from)
                case .failure(let error):
                    if let turn = agent.questionTurn, let i = self.turns.lastIndex(of: turn) { self.turns.remove(at: i) }
                    agent.questionTurn = nil
                    self.problem = error.localizedDescription
                    self.talk(Self.spokenProblem(error), as: agent)
                }
                self.refreshThinking()
                self.next(for: agent)
            }
        }
    }

    /// What an agent answered: said in its voice, and, when it's for the other one, delivered to
    /// him once it's been heard (not if the user cuts in first).
    private func answered(_ agent: Agent, _ reply: Conversation.Reply, from: String?) {
        let other = agents.first { $0 !== agent }
        let toTheUser = from == nil || agent === tom
        if !reply.text.isEmpty {
            if toTheUser {
                turns.append(ChatTurn(role: .assistant, text: reply.text, name: agent.name))
                talk(reply.text, as: agent)
                other?.tell { $0.overhear(reply.text, from: agent.name, to: "the user") }
            } else if let other {
                // Jerry answering Tom: read out, then handed to Tom.
                turns.append(ChatTurn(role: .assistant, text: reply.text, name: agent.name, to: other.name))
                deliver(reply.text, from: agent, to: other)
            }
        }
        if let handoff = reply.handoff, let other, other.name == handoff.to {
            turns.append(ChatTurn(role: .assistant, text: handoff.message, name: agent.name, to: other.name))
            deliver(handoff.message, from: agent, to: other)
        } else if let handoff = reply.handoff {
            // Jerry's gone (the skill was turned off meanwhile): the message is only read out.
            turns.append(ChatTurn(role: .assistant, text: handoff.message, name: agent.name, to: handoff.to))
            talk(handoff.message, as: agent)
            agent.tell { $0.note("\(handoff.to) isn't here any more: your message was only read to the user.") }
        }
        save()
    }

    /// Reads `message` in `agent`'s voice, then, once it's been heard, gives it to `other` to
    /// answer. If the user cuts in first, it isn't delivered, and `agent` is told.
    private func deliver(_ message: String, from agent: Agent, to other: Agent) {
        talk(message, as: agent, then: { [weak self] in
            guard let self, self.on, self.agents.contains(where: { $0 === other }) else { return }
            self.hops += 1
            self.ask(message, of: other, from: agent.name, fresh: false)
        }, cut: {
            agent.tell { $0.note("Your message to \(other.name) wasn't delivered: the user cut in while it was being read. Go on from what the user says next.") }
        })
    }

    /// Asks the agent the next thing waiting for it: a delivery straight away, the user's once
    /// the voice is quiet (so its answer doesn't cut off the one being read).
    private func next(for agent: Agent) {
        guard on, !agent.thinking, !agent.pending.isEmpty else { return }
        if agent.pending[0].from == nil, voice.speaking { return }
        let p = agent.pending.removeFirst()
        ask(p.text, of: agent, from: p.from, fresh: false)
    }

    /// Stops the agent's question running: back to the chat as it was before it.
    private func cancel(_ agent: Agent, keepPending: Bool = false) {
        agent.generation += 1
        if agent.thinking, let settled = agent.settled { agent.chat = settled }
        agent.settled = nil
        agent.thinking = false
        agent.activity = .idle
        if !keepPending { agent.pending = [] }
        agent.asking = nil
        if let turn = agent.questionTurn, let i = turns.lastIndex(of: turn) { turns.remove(at: i) }
        agent.questionTurn = nil
        agent.catchUp()
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

    // MARK: Talking

    /// Says `text` in the agent's voice (Tom's when nil), after whatever is being said. `then`
    /// runs once it's been heard; `cut` if the user cuts in first.
    private func talk(_ text: String, as agent: Agent?, then: (() -> Void)? = nil, cut: (() -> Void)? = nil) {
        let spoken = Assistant.spoken(text)
        guard !spoken.isEmpty else {
            then?()
            return
        }
        let name = agent?.name ?? Assistant.name
        let v = agent.map(voiceOf) ?? Service.shared.voice
        // A voice picked since it started gets its print too (once).
        if settings.voicePrints { VoicePrints.shared.enroll(v) }
        reading = Recorder.join(reading, spoken)
        var item = 0
        item = voice.add(spoken, voice: v, speed: Service.shared.settings.speed) { [weak self] in
            guard let self else { return }
            self.queued.removeAll { $0.item == item }
            self.speaking = self.queued.first?.name
            then?()
        }
        queued.append((item, name, cut))
        if speaking == nil { speaking = name }
    }

    /// The voice stops (the user cut in, or asked to): what was queued isn't said, and what was to
    /// be delivered once heard isn't.
    private func stopTalking() {
        voice.stop()
        let cut = queued
        queued = []
        speaking = nil
        reading = ""
        for q in cut { q.cut?() }
    }

    /// Done reading: the countdown starts again, and what the user said meanwhile is asked.
    private func spoke() {
        echoUntil = Date().addingTimeInterval(1.5)
        reading = ""
        queued = []
        speaking = nil
        guard on else { return }
        activity()
        for agent in agents { next(for: agent) }
    }

    private func save() {
        guard !turns.isEmpty else { return }
        Library.shared.save(Assistant.record(id: roomID, created: roomCreated, turns: turns, existing: Library.shared.item(roomID)))
    }

    // MARK: Working

    private func refreshThinking() {
        let t = tom?.thinking ?? false, j = jerry?.thinking ?? false
        if thinking != t { thinking = t }
        if jerryThinking != j { jerryThinking = j }
        refreshWorking()
        if t || j {
            if workTimer == nil {
                workTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tickWork() }
            }
        } else {
            workTimer?.invalidate()
            workTimer = nil
        }
    }

    private func refreshWorking() {
        let lines = agents.filter(\.thinking).map { "\($0.name): \(Self.describe($0.activity))" }
        let w = lines.isEmpty ? nil : lines.joined(separator: " · ")
        if working != w { working = w }
    }

    /// "thinking", "searching the web".
    static func describe(_ activity: Conversation.Activity) -> String {
        switch activity {
        case .idle, .model: return "thinking"
        case .tool(let name): return "using " + AssistantView.toolName(name)
        }
    }

    /// Every three seconds while either works: a soft sound for what it's doing (a different one
    /// for the model thinking, the browser, files and the library, the scripts; Jerry's own for him).
    private func tickWork() {
        guard on, sounds, settings.workingSounds else { return }
        var delay = 0.0
        for agent in agents where agent.thinking {
            let name = Self.workSound(for: agent.activity, jerry: agent !== tom)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.play(name, volume: 0.25) }
            delay += 0.7
        }
    }

    static func workSound(for activity: Conversation.Activity, jerry: Bool) -> String {
        switch activity {
        case .idle, .model: return jerry ? "Bottle" : "Pop"
        case .tool(let name):
            switch Skills.skill(for: name)?.id ?? "" {
            case Skills.browser.id: return "Ping"
            case Skills.scripts.id: return "Morse"
            case Skills.editing.id: return "Glass"
            case Skills.team.id: return jerry ? "Bottle" : "Pop"
            default: return "Tink"
            }
        }
    }

    // MARK: Settings and models

    func change(_ edit: (inout AssistantSettings) -> Void) {
        var s = settings
        edit(&s)
        guard s != settings else { return }
        let moved = s.ollamaURL != settings.ollamaURL
        let newModel = s.model != settings.model || s.jerryModel != settings.jerryModel
        let newVoice = s.jerryVoice != settings.jerryVoice
        settings = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "assistantSettings") }
        if moved {
            client = OllamaClient(baseURL: s.ollamaURL)
            ollamaVersion = nil
            for agent in agents { agent.chat.llm = client; agent.settled?.llm = client }
            models = []
            refreshModels()
        }
        runner = Self.runner(for: s)
        for agent in agents {
            agent.chat.runner = runner
            agent.chat.model = model(for: agent)
            agent.chat.quick = !s.thinking
        }
        client.thinking = s.thinking
        Self.echo.wanted = s.echoCancel
        adviseOnThinking()
        refreshListening()
        if newModel, on { warmUp() }
        if newVoice, on { enrollVoices() }
    }

    /// Gets the models loaded in Ollama now, so the first answers don't wait for them.
    private func warmUp() {
        let client = self.client, names = Set(agents.map(model(for:)))
        Task.detached { for m in names { await client.warm(m) } }
    }

    /// The voices' prints, so what they say isn't taken for yours.
    private func enrollVoices() {
        guard settings.voicePrints else { return }
        VoicePrints.shared.prepare()
        VoicePrints.shared.enroll(Service.shared.voice)
        if teamOn { VoicePrints.shared.enroll(jerryVoice) }
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
                        if !self.settings.jerryModel.isEmpty, !names.contains(self.settings.jerryModel) {
                            self.change { $0.jerryModel = "" }
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
        if thinking || jerryThinking || voice.speaking { activity() }
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
        Self.play(name, volume: 1)
    }

    /// Plays one of the Mac's sounds, softly if asked (a copy, so one still playing isn't cut).
    static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}

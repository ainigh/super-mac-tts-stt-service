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
    /// How long a pause ends what you said (a pause after something that sounds unfinished waits
    /// longer still). Longer, and it waits for you more; shorter, and it answers sooner.
    var pauseSeconds: Double = 1.8
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
    /// Jane, the reviewer, steps in when Tom sends a job back.
    var reviewer = true
    /// Jane's model; empty: Jerry's.
    var janeModel = ""
    /// Jane's voice (its id); empty: the first one that's neither Tom's nor Jerry's.
    var janeVoice = ""
    /// With Listen on, a wave at the camera starts it.
    var wave = true
    /// A soft sound every few seconds while it works, different for each kind of work.
    var workingSounds = true
    /// Its voices are told from yours by how they sound (voice prints), not only by the words.
    var voicePrints = true
    /// Which of Jerry's tool calls wait for the user's approval.
    var approvals = Approvals.changes
    /// Tom is woken on every tool event of a job (proposed, approved, rejected, ran), not only on
    /// its questions, results and failures.
    var tomWatches = true
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
        pauseSeconds = try c.decodeIfPresent(Double.self, forKey: .pauseSeconds) ?? d.pauseSeconds
        toolRunURL = try c.decodeIfPresent(String.self, forKey: .toolRunURL) ?? d.toolRunURL
        thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking) ?? d.thinking
        bargeIn = try c.decodeIfPresent(Bool.self, forKey: .bargeIn) ?? d.bargeIn
        echoCancel = try c.decodeIfPresent(Bool.self, forKey: .echoCancel) ?? d.echoCancel
        jerryModel = try c.decodeIfPresent(String.self, forKey: .jerryModel) ?? d.jerryModel
        jerryVoice = try c.decodeIfPresent(String.self, forKey: .jerryVoice) ?? d.jerryVoice
        reviewer = try c.decodeIfPresent(Bool.self, forKey: .reviewer) ?? d.reviewer
        janeModel = try c.decodeIfPresent(String.self, forKey: .janeModel) ?? d.janeModel
        janeVoice = try c.decodeIfPresent(String.self, forKey: .janeVoice) ?? d.janeVoice
        wave = try c.decodeIfPresent(Bool.self, forKey: .wave) ?? d.wave
        workingSounds = try c.decodeIfPresent(Bool.self, forKey: .workingSounds) ?? d.workingSounds
        voicePrints = try c.decodeIfPresent(Bool.self, forKey: .voicePrints) ?? d.voicePrints
        approvals = try c.decodeIfPresent(Approvals.self, forKey: .approvals) ?? d.approvals
        tomWatches = try c.decodeIfPresent(Bool.self, forKey: .tomWatches) ?? d.tomWatches
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // Saved when a minute was the default: it's three now.
        if version < 2, idleSeconds == 60 { idleSeconds = d.idleSeconds }
        // Saved when voice processing was on by default (so on was never chosen): off, as now.
        if version < 3 { echoCancel = d.echoCancel }
        // The same for barge in.
        if version < 4 { bargeIn = d.bargeIn }
    }
}

/// Which of Jerry's tool calls wait for the user to approve them.
enum Approvals: String, Codable, CaseIterable {
    /// Only what changes something: library editing, scripts.
    case changes
    /// Every tool, even those that only look.
    case all
    /// None: he just works.
    case none

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .all: return "Everything"
        case .none: return "Nothing"
        }
    }

    var help: String {
        switch self {
        case .changes: return "Jerry asks before anything that changes something (the library, scripts); looking things up just runs"
        case .all: return "Jerry asks before every tool call, even looking things up"
        case .none: return "Jerry never asks; every tool call just runs"
        }
    }

    /// Whether a tool must wait.
    func requires(_ tool: String) -> Bool {
        switch self {
        case .none: return false
        case .all: return true
        case .changes: return Skills.skill(for: tool).map { !$0.readOnly } ?? false
        }
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
    /// Events came for it while it was busy: a turn with nothing new said, once it's free.
    var wakeWanted = false
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
    /// Jane is reviewing a job that came back.
    @Published private(set) var janeThinking = false
    /// What the listener is hearing right now, before the pause that ends it.
    @Published private(set) var hearing = ""
    /// What the always-listener is hearing (only "Tom" is acted on).
    @Published private(set) var wakeHearing = ""
    /// The room as it stands: you, Tom and Jerry (a question shows as soon as it's asked).
    @Published private(set) var turns: [ChatTurn] = []
    /// The jobs Tom has handed Jerry (the harness's record; it persists across chats and launches).
    @Published private(set) var board: JobBoard
    /// Tom's memory: what he's learned, and the standing instructions for both.
    @Published private(set) var memory: Memory
    /// A tool Jerry proposed, waiting for the user to approve or reject it.
    @Published private(set) var pendingApproval: Approval?

    /// A tool call waiting on the user.
    struct Approval: Identifiable {
        let id = UUID()
        let job: String
        let call: AssistantTools.Call
        /// What to do with the answer (true runs it).
        let decide: (Bool) -> Void
    }

    /// ~/Library/Application Support/SuperVoice/jobs.json and memory.json
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SuperVoice", isDirectory: true)
    private let memoryStore = MemoryStore(url: AssistantModel.folder.appendingPathComponent("memory.json"))
    private static let jobsURL = AssistantModel.folder.appendingPathComponent("jobs.json")
    /// The job Jerry is on (his chat is working it).
    private var jerryJob: String?
    /// The job Jane is reviewing (Jerry waits for her word).
    private var reviewing: String?
    private var janeGeneration = 0
    /// Tom was asked whether anything is still owed before the app stands down; his answer decides.
    private var idleAsked = false
    /// "Standing down" is being said; the app stops once it's heard.
    private var standingDown = false
    /// When Tom last gave (or was asked for) status on the open jobs.
    private var lastStatusAt = Date()
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
    let listener = Recorder(pauseToEnd: AssistantSettings().pauseSeconds, holdIfUnfinished: TurnEnd.hold, shared: AssistantModel.echo)
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
    private var client: OllamaClient
    /// Tool Mac Tool Run, when its address is set.
    private var runner: ToolRunClient?
    /// The skills that need the Mac.
    private var skills: SkillRunner
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var workTimer: Timer?
    /// Asks Tool Mac Tool Run where the runs still going are, every couple of seconds while there are any.
    private var requestTimer: Timer?
    private var polling = false
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
        memory = memoryStore.memory
        var jobs = (try? Data(contentsOf: Self.jobsURL)).flatMap { try? LibraryStore.decoder.decode(JobBoard.self, from: $0) } ?? JobBoard()
        // A job left running when the app stopped is queued again (Jerry's chat went with it).
        jobs.recover()
        board = jobs
        Self.echo.wanted = loaded.echoCancel
        listener.setPause(loaded.pauseSeconds)
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

    /// Jane's voice: the one chosen, or the first that's neither Tom's nor Jerry's.
    var janeVoice: Voice {
        if let v = Voice.all.first(where: { $0.id == settings.janeVoice }) { return v }
        let tom = Service.shared.voice, jerry = jerryVoice
        return Voice.all.first { $0.id != tom.id && $0.id != jerry.id && $0.female } ?? Voice.all.first { $0.id != tom.id && $0.id != jerry.id } ?? tom
    }

    /// Jane's model, as shown.
    var janeModelName: String { settings.janeModel.isEmpty ? jerryModelName : settings.janeModel }

    private func voiceOf(_ agent: Agent) -> Voice {
        agent === tom ? Service.shared.voice : jerryVoice
    }

    private func model(for agent: Agent) -> String {
        agent === tom || settings.jerryModel.isEmpty ? settings.model : settings.jerryModel
    }

    // MARK: On and off

    /// Starts talking (a new chat): just talk. `question`: asked right away. It doesn't open the
    /// window: it works all the same without it.
    /// `called`: the user said "Tom" (alone): it answers "Yes?" in his voice, so they know it heard.
    func start(question: String? = nil, called: Bool = false) {
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
        if called { talk(Self.calledAnswer, as: tom) }
        if let question { route(question) }
        runJerry()
        followRequests()
    }

    /// What Tom says when called by name with nothing after it.
    static let calledAnswer = "Yes?"

    /// Stops, with its off sound first: the microphone closes and the voice stops. The chat stays
    /// in the AI library. Always listen carries on listening for "Tom".
    func stop(reason: String? = nil) {
        guard on else { return }
        NSSound(named: NSSound.Name(Self.offSound))?.play()
        on = false
        stopTalking()
        // A tool waiting on the user is refused; Jerry's job goes back in the queue for next time.
        for agent in agents { cancel(agent) }
        pendingApproval?.decide(false)
        pendingApproval = nil
        dismissJane()
        idleAsked = false
        standingDown = false
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
        case .wake, .command(.newChat): start(called: true)
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
        idleAsked = false
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
            // Called by name while on: it answers, so they know it's listening.
            activity()
            play("Pop")
            say("Listening")
            talk(Self.calledAnswer, as: tom)
        case .wakeThen(let question), .speech(let question):
            activity()
            // A tool of Jerry's waiting on the user: "yes", "go ahead", "no" answer that.
            if let approval = pendingApproval, let answer = JobTools.approval(question) {
                decide(approval, answer)
                return
            }
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

    /// Something said in the room, by the user: to Tom, always (Jerry works for Tom, and hears
    /// the user only through him).
    private func route(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let tom else { return }
        ask(q, of: tom)
    }

    private func run(_ command: Assistant.Command) {
        switch command {
        case .stop:
            // Tom stops; Jerry's job carries on (a tool waiting on the user still waits).
            stopTalking()
            if let tom, tom.thinking { cancel(tom) }
            refreshThinking()
            say("Stopped")
        case .newChat:
            newChat(say: true)
        case .off:
            stop(reason: "Turned off")
            talk("Bye.", as: nil)
        case .stopAll:
            stopEverything(by: "the user")
            talk("Stopped everything.", as: nil)
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

    /// Forgets this chat (it stays in the AI library) and starts another: a new session. Jerry's
    /// chat starts empty (he keeps nothing between sessions); the jobs and Tom's memory stay.
    func newChat(say announce: Bool = true) {
        for agent in agents { cancel(agent) }
        pendingApproval?.decide(false)
        pendingApproval = nil
        dismissJane()
        roomID = UUID()
        roomCreated = Date()
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
        if on { runJerry() }
    }

    private func makeJerry() -> Agent {
        Agent(name: Team.teammate, chat: makeJerryChat())
    }

    /// A chat for Jerry: fresh for each job (see `runJerry`).
    private func makeJerryChat() -> Conversation {
        let c = Conversation(llm: client, model: model(for: tom!), library: { [] })
        c.name = Team.teammate
        // A job takes a few more rounds than a question (search, open, read, then finish).
        c.maxToolRounds = 10
        return c
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
            if agent === tom {
                // His memory's tools, and a job's standing; the memory and the open jobs go in his prompt.
                c.extraTools = Memory.tools
                c.custom = { [weak self] name, args in await self?.custom(name, args) }
            } else {
                c.extraTools = []
                c.custom = nil
                // Tool Mac Tool Run's runs put a card on the Mac: that click is their approval (not two clicks for one run).
                c.needsApproval = { [weak self] tool in !ToolRunTools.gated.contains(tool) && (self?.settings.approvals.requires(tool) ?? false) }
                c.approval = { [weak self] call in await self?.approve(call) ?? false }
                c.onNarration = { [weak self] text in DispatchQueue.main.async { self?.narrated(text) } }
            }
            c.save = { [weak self] record in
                DispatchQueue.main.async {
                    let new = Library.shared.item(record.id) == nil
                    Library.shared.save(record)
                    self?.agents.first { $0.name == name }?.changedLibrary = true
                    self?.say((new ? "Saved in the library: " : "Changed in the library: ") + record.title)
                }
            }
            c.onToolUse = { [weak self] use in
                DispatchQueue.main.async {
                    SkillsModel.shared.record(use)
                    if name == Team.teammate { self?.jerryUsed(use) }
                }
            }
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
            if on { say("Jerry's here: Tom hands him the work") }
        } else if !teamOn, let j = jerry {
            cancel(j)
            jerry = nil
            if on { say("Jerry's gone") }
        }
        for agent in agents { configure(agent) }
        refreshThinking()
        if on { enrollVoices() }
    }

    /// Asks `agent` `text`: from the user (nil), who was just heard (`fresh`: the voice stops),
    /// or from the other agent (a job for Jerry, by name). With `text` nil, a wake: nothing new is
    /// said, the agent acts on the events it was given (Tom, as a job moves).
    private func ask(_ text: String?, of agent: Agent, from: String? = nil, fresh: Bool = true) {
        let q = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let q, q.isEmpty { return }
        if q != nil, from == nil, fresh { stopTalking() }
        if agent.thinking {
            if let q, from == nil, let a = agent.asking, Date().timeIntervalSince(a.at) < 20, !agent.changedLibrary, agent.settled != nil {
                // The rest of what's being asked: ask it whole instead.
                cancel(agent, keepPending: true)
                refreshThinking()
                ask(a.text + " " + q, of: agent, from: nil, fresh: false)
                return
            }
            if let q { agent.pending.append((q, from)) } else { agent.wakeWanted = true }
            return
        }
        agent.catchUp()
        agent.thinking = true
        agent.wakeWanted = false
        agent.changedLibrary = false
        agent.asking = q != nil && from == nil ? (q!, Date()) : nil
        let chat = agent.chat
        agent.settled = chat.copy()
        if let q, from == nil {
            let turn = ChatTurn(role: .user, text: q)
            agent.questionTurn = turn
            turns.append(turn)
            play("Tink")
        } else {
            agent.questionTurn = nil
        }
        // The library as it is now, for the tools (read off the main thread while the model thinks),
        // and what goes in the prompt (Tom's memory and the open jobs; Jerry's instructions and job).
        let items = Library.shared.items
        chat.library = { items }
        chat.model = model(for: agent)
        let extra = extraPrompt(for: agent)
        chat.extraPrompt = { extra }
        agent.generation += 1
        let mine = agent.generation
        refreshThinking()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Conversation.Reply, Error>
            do {
                let reply: Conversation.Reply
                if let q { reply = try await chat.reply(q, from: from) } else { reply = try await chat.wake() }
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
                    self.answered(agent, reply, from: from, wake: q == nil)
                case .failure(let error):
                    if let turn = agent.questionTurn, let i = self.turns.lastIndex(of: turn) { self.turns.remove(at: i) }
                    agent.questionTurn = nil
                    self.problem = error.localizedDescription
                    self.talk(Self.spokenProblem(error), as: agent)
                    if agent === self.jerry { self.jerryFailed(error) }
                }
                self.refreshThinking()
                self.next(for: agent)
            }
        }
    }

    /// What Tom and Jerry are told in their prompts besides the fixed part.
    private func extraPrompt(for agent: Agent) -> String {
        var p = ""
        if agent === tom {
            if !memory.tomInstructions.trimmingCharacters(in: .whitespaces).isEmpty {
                p += "\n\nThe user's standing instructions for you: " + memory.tomInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            p += memory.prompt()
            if jerry != nil { p += board.prompt(session: roomID) }
        } else {
            if !memory.jerryInstructions.trimmingCharacters(in: .whitespaces).isEmpty {
                p += "\n\nThe user's standing instructions for you: " + memory.jerryInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let id = jerryJob, let job = board.job(id) {
                p += "\n\nThe job you're on now, \(job.id)" + (job.revisions > 0 ? " (revision \(job.revisions))" : "") + ":\n" + job.spec.text
            }
        }
        return p
    }

    /// What an agent answered: said in its voice, and its job move carried out.
    private func answered(_ agent: Agent, _ reply: Conversation.Reply, from: String?, wake: Bool = false) {
        var text = reply.text
        var verdict: Bool?          // his answer to "is anything still owed?": true holds, false stands down
        if agent === tom, wake, idleAsked {
            idleAsked = false
            let holds = Team.isHold(text) || reply.action != nil
            if holds { text = Team.withoutHold(text) }
            verdict = holds
        }
        if !text.isEmpty {
            turns.append(ChatTurn(role: .assistant, text: text, name: agent.name))
            talk(text, as: agent)
        }
        if agent === tom {
            if let action = reply.action { tomMoved(action) }
            if let verdict {
                if verdict { activity() } else { standDown() }
            }
        } else {
            jerryEnded(reply)
        }
        save()
    }

    /// Asks the agent the next thing waiting for it: a job or a wake straight away, the user's
    /// once the voice is quiet (so its answer doesn't cut off the one being read).
    private func next(for agent: Agent) {
        guard on, !agent.thinking else { return }
        if agent === jerry {
            runJerry()
            return
        }
        if !agent.pending.isEmpty {
            if agent.pending[0].from == nil, voice.speaking { return }
            let p = agent.pending.removeFirst()
            ask(p.text, of: agent, from: p.from, fresh: false)
        } else if agent.wakeWanted {
            ask(nil, of: agent)
        }
    }

    /// Stops the agent's question running: back to the chat as it was before it.
    private func cancel(_ agent: Agent, keepPending: Bool = false) {
        if agent === jerry, let id = jerryJob {
            // His job goes back in the queue (a tool waiting on the user is refused).
            jerryJob = nil
            pendingApproval?.decide(false)
            pendingApproval = nil
            if let job = board.job(id), job.status == .running || job.status == .awaitingApproval {
                board.recover()
                saveBoard()
                roomLine("\(id) queued again")
            }
        }
        agent.generation += 1
        if agent.thinking, let settled = agent.settled { agent.chat = settled }
        agent.settled = nil
        agent.thinking = false
        agent.activity = .idle
        if !keepPending { agent.pending = []; agent.wakeWanted = false }
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

    // MARK: Jobs

    /// Jerry takes up the next queued job, when he's free and there is one (one at a time; a job
    /// sent back or unblocked first). The spec, Tom's messages and the job's past go to him as a
    /// message from Tom; what he says as he works is read out in his voice.
    private func runJerry() {
        guard on, let jerry, !jerry.thinking, jerryJob == nil, reviewing == nil, let next = board.nextQueued() else { return }
        guard board.start(next.id) != nil else { return }
        // Each job starts him fresh: the last job's tool traffic would crowd out this one's spec in
        // a small model's context, and everything he needs of this job's past is in the briefing.
        if !jerry.chat.isEmpty {
            jerry.chat = makeJerryChat()
            configure(jerry)
        }
        jerryJob = next.id
        let messages = board.took(next.id)
        saveBoard()
        roomLine(next.revisions > 0 ? "\(next.id) running again (revision \(next.revisions))" : "\(next.id) running: \(next.spec.goal)")
        if next.revisions > 0 || !messages.isEmpty { wakeTom("\(next.id) running" + (next.revisions > 0 ? " (revision \(next.revisions))" : ""), always: false) }
        ask(JobBoard.briefing(next, messages: messages), of: jerry, from: Assistant.name, fresh: false)
    }

    /// Jerry's turn on his job ended: he finished it, asked Tom, or just stopped (taken as his result).
    private func jerryEnded(_ reply: Conversation.Reply) {
        guard let id = jerryJob else { return }
        jerryJob = nil
        guard let job = board.job(id), job.status.isOpen else {
            // Cancelled meanwhile: whatever he said is only read out.
            saveBoard()
            runJerry()
            return
        }
        switch reply.action {
        case .ask(let question)?:
            board.block(id, question: question)
            roomLine("\(id) blocked: Jerry asks Tom")
            turns.append(ChatTurn(role: .assistant, text: question, name: Team.teammate, to: Assistant.name))
            talk(question, as: jerry)
            wakeTom("\(id) is blocked: Jerry asks: \(question)\nAnswer him with message_jerry (from what you know, or ask the user first).", always: true)
        case .finish(let result)?:
            finished(id, result)
        default:
            // No finish: what he said is his result.
            let said = reply.text.isEmpty ? "(Jerry stopped without a result.)" : reply.text
            finished(id, Job.Result(summary: said), spoken: !reply.text.isEmpty)
        }
        saveBoard()
        runJerry()
    }

    /// A job is done: Jerry's summary is read out in his voice, and Tom checks it against the spec.
    private func finished(_ id: String, _ result: Job.Result, spoken: Bool = false) {
        guard let job = board.finish(id, result) else { return }
        roomLine("\(id) done")
        if !spoken {
            turns.append(ChatTurn(role: .assistant, text: result.summary, name: Team.teammate))
            talk(result.summary, as: jerry)
        }
        play("Glass")
        var event = "\(id) is done" + (job.revisions > 0 ? " (revision \(job.revisions))" : "") + ". Result: \(result.summary)"
        if !result.details.isEmpty { event += "\nDetails: \(result.details)" }
        event += "\nThe spec was:\n\(job.spec.text)\nThe user heard Jerry's result read out. Check it against the spec: send it back with message_jerry if it misses, else say only what the user still needs to know (or (nothing)), and remember what this taught you."
        wakeTom(event, always: true)
    }

    /// Jerry's model failed on his job.
    private func jerryFailed(_ error: Error) {
        guard let id = jerryJob else { return }
        jerryJob = nil
        board.fail(id, why: error.localizedDescription)
        saveBoard()
        roomLine("\(id) failed: \(error.localizedDescription)")
        wakeTom("\(id) failed: \(error.localizedDescription). Tell the user.", always: true)
        runJerry()
    }

    /// Jerry said something while working ("I'll search for it"): read out in his voice.
    private func narrated(_ text: String) {
        guard let id = jerryJob else { return }
        board.said(id, text)
        turns.append(ChatTurn(role: .assistant, text: text, name: Team.teammate))
        talk(text, as: jerry)
    }

    /// A tool Jerry used on his job (L3): kept with the job; Tom hears that it ran, not what it gave.
    private func jerryUsed(_ use: ToolUse) {
        guard let id = jerryJob else { return }
        board.ran(id, use)
        if ToolRunTools.gated.contains(use.name), let rid = ToolRunTools.requestID(in: use.result) {
            // A card is on the Mac: the run is followed from here until it's over (Jerry's turn can end).
            let what = use.name + (use.summary.isEmpty ? "" : " " + use.summary)
            board.requested(id, Job.RunRequest(id: rid, what: what))
            roomLine("\(id): \(what): waiting for you to click Run on the Mac")
            followRequests()
        }
        saveBoard()
        if use.result != AssistantTools.rejectedMessage { wakeTom("\(id): Jerry ran \(use.name)" + (use.summary.isEmpty ? "" : " (\(use.summary))"), always: false) }
    }

    /// Follows the runs asked of Tool Mac Tool Run, every two seconds while any is going: their
    /// state goes onto their jobs (the harness writes it, never a model), Jerry is told when one
    /// ends if he's still on the job, and Tom is told whatever happens.
    private func followRequests() {
        guard !board.pendingRequests.isEmpty else {
            requestTimer?.invalidate()
            requestTimer = nil
            return
        }
        guard requestTimer == nil else { return }
        requestTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollRequests() }
    }

    private func pollRequests() {
        guard !polling else { return }
        guard let runner else {
            requestTimer?.invalidate()
            requestTimer = nil
            return
        }
        let pending = board.pendingRequests
        guard !pending.isEmpty else { return followRequests() }
        polling = true
        Task.detached(priority: .utility) { [weak self] in
            var states: [(job: String, request: String, state: ToolRunTools.RequestState)] = []
            for p in pending {
                let state = await ToolRunTools.status(of: p.request.id, via: runner)
                states.append((p.job.id, p.request.id, state))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                for s in states where s.state.state != "trouble" && s.state.state != "unreachable" {
                    guard let event = self.board.mirror(s.job, request: s.request, state: s.state.state, runID: s.state.runID, over: s.state.over, text: s.state.text) else { continue }
                    let job = self.board.job(s.job)
                    let what = job?.requests.first { $0.id == s.request }?.what ?? s.request
                    switch event.kind {
                    case .toolApproved: self.roomLine("\(s.job): \(what): you clicked Run; it's running")
                    case .toolRejected: self.roomLine("\(s.job): \(what): \(s.state.state == "denied" ? "you clicked Don't Run" : "nobody clicked Run in time")")
                    default: self.roomLine("\(s.job): \(what): \(s.state.state)")
                    }
                    if s.state.over {
                        // Jerry, if he's still on the job, hears how it went; Tom always does.
                        if self.jerryJob == s.job, let jerry = self.jerry {
                            // Mid-turn, it goes with his next call to the model; between turns, with the next question.
                            let note = "The run you asked for (\(what), request \(s.request)) is over: \(s.state.text)"
                            if jerry.thinking { jerry.chat.interject(note) } else { jerry.chat.note(note) }
                        }
                        self.play(s.state.ok == true ? "Glass" : "Basso")
                        var tell = "\(s.job): the run on the Mac (\(what)) is over: \(s.state.text)"
                        if let job, !job.status.isOpen { tell += "\nThe job was already \(job.status.rawValue): tell the user how the run went (or send the job back with message_jerry if the result misses the spec)." }
                        self.wakeTom(tell, always: true)
                    } else if event.kind == .toolApproved || event.kind == .toolRejected {
                        self.wakeTom("\(s.job): \(what): \(s.state.text)", always: false)
                    }
                }
                self.saveBoard()
                self.followRequests()
            }
        }
    }

    /// Everything stops: the voices, Tom's turn, Jerry and his job, Jane, every open job, a tool
    /// waiting on the user, and every run still going on the Mac. What Tom is told.
    @discardableResult
    func stopEverything(by whom: String) -> String {
        stopTalking()
        pendingApproval?.decide(false)
        pendingApproval = nil
        dismissJane()
        let dropped = board.cancelAll(by: whom)
        jerryJob = nil
        if let jerry { cancel(jerry) }
        if whom != Assistant.name, let tom, tom.thinking { cancel(tom) }
        // Runs still going on the Mac are stopped there (those with a run yet; one still waiting
        // for the click can only be declined there).
        let running = board.pendingRequests.filter { $0.request.runID != nil }
        if let runner, !running.isEmpty {
            let ids = running.compactMap(\.request.runID)
            Task.detached { for id in ids { _ = await ToolRunTools.run("stop_run", ["id": id], via: runner) } }
        }
        saveBoard()
        refreshThinking()
        var said = "Stopped everything"
        if !dropped.isEmpty { said += ": " + dropped.map(\.id).joined(separator: ", ") + " dropped" }
        if !running.isEmpty { said += "; \(running.count) run\(running.count == 1 ? "" : "s") on the Mac told to stop" }
        roomLine(said + (whom == Assistant.name ? "" : " (by \(whom))"))
        say(said)
        play("Basso")
        return said + "."
    }

    /// Jerry proposed a tool call that needs the user: it waits here until they approve or reject
    /// it (in the window, or by saying so). Off the main thread, from Jerry's chat.
    private func approve(_ call: AssistantTools.Call) async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.on, let id = self.jerryJob else { return k.resume(returning: false) }
                self.board.proposed(id, tool: call.name, arguments: call.argumentsJSON)
                self.saveBoard()
                let what = AssistantView.toolName(call.name)
                self.roomLine("\(id): Jerry proposes \(what); waiting for you")
                self.pendingApproval = Approval(job: id, call: call) { k.resume(returning: $0) }
                self.play("Purr")
                self.say("Jerry wants to use \(what): approve or reject it (or say yes or no)")
                self.talk("Jerry wants to use \(what). Yes or no?", as: nil)
                self.wakeTom("\(id): Jerry proposed \(call.name)" + (call.argumentsJSON == "{}" ? "" : " with \(call.argumentsJSON)") + "; the user is asked to approve it.", always: false)
            }
        }
    }

    /// The user approved or rejected the tool Jerry proposed.
    func decide(_ approval: Approval, _ approved: Bool) {
        guard pendingApproval?.id == approval.id else { return }
        pendingApproval = nil
        board.decided(approval.job, tool: approval.call.name, approved: approved)
        saveBoard()
        let what = AssistantView.toolName(approval.call.name)
        roomLine("\(approval.job): \(what) \(approved ? "approved" : "rejected")")
        play(approved ? "Tink" : "Basso")
        say(approved ? "Approved: \(what)" : "Rejected: \(what)")
        activity()
        approval.decide(approved)
        wakeTom("\(approval.job): the user \(approved ? "approved" : "rejected") \(approval.call.name).", always: false)
    }

    /// Tom's moves refused in a row (a message to a job that can't take it): the first wakes him
    /// to try again, the next wait for his next turn.
    private var refusedMoves = 0

    /// Tom's job move, carried out: the job is made, messaged or dropped, and Tom is told how it went.
    private func tomMoved(_ action: Conversation.Action) {
        guard let tom else { return }
        let refusedBefore = refusedMoves
        refusedMoves = 0
        switch action {
        case .delegate(let spec):
            if let open = board.openJob(withGoal: spec.goal) {
                // The same job twice (he forgot, or a status check made him): he's told with his next
                // turn (the open job's events bring one), not woken for it, which could go round.
                tom.tell { $0.toolResult("delegate", "Not created: \(open.id) already has that goal and is \(open.status.rawValue). Wait for it (you're told when it's done), message_jerry it to add to it, or tell the user where it stands.") }
                roomLine("Tom delegated \(open.id)'s goal again; not created")
                return
            }
            let job = board.delegate(spec, session: roomID, asked: turns.last { $0.role == .user }?.text)
            lastStatusAt = Date()
            saveBoard()
            turns.append(ChatTurn(role: .assistant, text: "Job \(job.id)\n" + spec.text, name: Assistant.name, to: Team.teammate))
            roomLine("\(job.id) queued: \(spec.goal)")
            tom.tell { $0.toolResult("delegate", "Created \(job.id), queued for Jerry.") }
            if jerry != nil {
                talk("Jerry, job \(job.number): \(spec.goal)", as: tom)
                runJerry()
            } else {
                roomLine("Jerry isn't here (the skill is off): the job waits")
            }
        case .message(let id, let text):
            let r = board.message(id, text)
            saveBoard()
            tom.tell { $0.toolResult("message_jerry", r.result) }
            if let job = r.job {
                turns.append(ChatTurn(role: .assistant, text: "\(job.id): \(text)", name: Assistant.name, to: Team.teammate))
                let sentBack = job.status == .queued && job.revisions > 0
                roomLine(sentBack ? "\(job.id) sent back (revision \(job.revisions))" : "\(job.id): message for Jerry")
                talk("Jerry, about job \(job.number): \(text)", as: tom)
                if jerryJob == job.id, let jerry, job.status == .running || job.status == .awaitingApproval {
                    // He's on it now: it reaches him with his next call to the model (not when the
                    // job is next taken up, which may be never).
                    _ = board.took(job.id)
                    saveBoard()
                    jerry.chat.interject("Tom says, about this job: \(text)")
                }
                if sentBack, settings.reviewer { escalate(job) } else { runJerry() }
            } else {
                // Refused: Tom is told why with his next turn, and takes it up now (once in a row: a
                // model that keeps making the same refused move isn't sent round and round).
                refusedMoves = refusedBefore + 1
                if refusedMoves < 2 {
                    tom.wakeWanted = true
                    next(for: tom)
                }
            }
        case .cancel(let id):
            let r = board.cancel(id)
            saveBoard()
            tom.tell { $0.toolResult("cancel_job", r.result) }
            if let job = r.job {
                turns.append(ChatTurn(role: .assistant, text: "Cancel \(job.id).", name: Assistant.name, to: Team.teammate))
                roomLine("\(job.id) cancelled")
                if jerryJob == job.id, let jerry {
                    jerryJob = nil
                    pendingApproval?.decide(false)
                    pendingApproval = nil
                    cancel(jerry)
                    refreshThinking()
                    runJerry()
                }
            }
        case .stopEverything:
            let said = stopEverything(by: Assistant.name)
            tom.tell { $0.toolResult("stop_everything", said) }
        case .ask, .finish:
            break
        }
    }

    /// An event for Tom: given to his chat (with his next turn, or a turn of its own now). Tool
    /// traffic (`always` false) only while Tom watches every step.
    private func wakeTom(_ event: String, always: Bool) {
        guard let tom, always || settings.tomWatches else { return }
        tom.tell { $0.event(event) }
        tom.wakeWanted = true
        next(for: tom)
    }

    /// A line in the room from the harness itself: a job's status.
    private func roomLine(_ text: String) {
        turns.append(ChatTurn(role: .system, text: text))
        save()
    }

    /// Tom's own tools: his memory, and a job's standing. Off the main thread, from his chat.
    private func custom(_ name: String, _ args: [String: Any]) async -> String? {
        await MainActor.run { () -> String? in
            switch name {
            case "job_status":
                guard let id = JobTools.jobID(args) else { return "Give the job_id. Open jobs: " + (board.open.isEmpty ? "none" : board.open.map(\.id).joined(separator: ", ")) + "." }
                return board.status(id)
            case "remember", "forget":
                var m = memory
                let result = Memory.run(name, args, on: &m)
                if m != memory {
                    setMemory(m)
                    say(name == "remember" ? "Tom remembered something (see his memory)" : "Tom forgot something")
                }
                return result
            default:
                return nil
            }
        }
    }

    /// The memory as edited (by the user in its window, or by Tom).
    func setMemory(_ m: Memory) {
        guard m != memory else { return }
        memory = m
        do { try memoryStore.save(m) } catch { problem = "Couldn't save Tom's memory: \(error.localizedDescription)" }
    }

    /// Forgets the jobs that are over.
    func clearFinishedJobs() {
        board.clearFinished()
        saveBoard()
    }

    private func saveBoard() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try LibraryStore.encoder.encode(board).write(to: Self.jobsURL, options: .atomic)
        } catch {
            problem = "Couldn't save the jobs: \(error.localizedDescription)"
        }
    }

    // MARK: Jane

    /// Tom sent a job back: Jane, the reviewer, reads it (the job alone: what the user said just
    /// before, the spec, and everything between Tom and Jerry on it) and tells Jerry what to do
    /// differently, in her own voice; then she's gone. Jerry waits for her word.
    private func escalate(_ job: Job) {
        guard on else { return }
        reviewing = job.id
        janeGeneration += 1
        let mine = janeGeneration
        janeThinking = true
        refreshThinking()
        roomLine("Tom escalates \(job.id) to \(Team.reviewer)")
        say("\(Team.reviewer) is reviewing \(job.id)")
        let chat = Conversation(llm: client, model: settings.janeModel.isEmpty ? model(for: jerry ?? tom!) : settings.janeModel, library: { [] })
        chat.name = Team.reviewer
        chat.enabled = []
        chat.quick = !settings.thinking
        let instructions = memory.jerryInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.extraPrompt = { " " + Team.reviewerPrompt() + (instructions.isEmpty ? "" : " The user's standing instructions for \(Team.teammate), which he should keep to: \(instructions)") }
        let review = JobBoard.review(job)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await chat.ask(review)) } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self, mine == self.janeGeneration else { return }
                self.janeThinking = false
                self.reviewing = nil
                self.refreshThinking()
                switch result {
                case .success(let advice):
                    let text = advice.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.board.advise(job.id, text)
                    self.saveBoard()
                    self.turns.append(ChatTurn(role: .assistant, text: text, name: Team.reviewer, to: Team.teammate))
                    self.speak(text, name: Team.reviewer, voice: self.janeVoice)
                    self.roomLine("\(Team.reviewer) has told \(Team.teammate) what to do; she leaves")
                case .failure(let error):
                    self.problem = error.localizedDescription
                    self.roomLine("\(Team.reviewer) couldn't review \(job.id): \(error.localizedDescription)")
                }
                self.save()
                self.runJerry()
            }
        }
    }

    /// Jane's review is dropped (the app stopped, or a new chat).
    private func dismissJane() {
        janeGeneration += 1
        if janeThinking { janeThinking = false }
        reviewing = nil
    }

    // MARK: Status and standing down

    /// Work the app can't stand down over: a job of this chat still open, or any job Jerry is on
    /// or about to take up.
    private var workPending: Bool {
        board.open.contains { $0.session == roomID || $0.status == .queued || $0.status == .running || $0.status == .awaitingApproval }
            || !board.pendingRequests.isEmpty || pendingApproval != nil || janeThinking || jerryThinking
    }

    /// Every so often while jobs are open, Tom is asked to say where things stand, if the user
    /// hasn't heard lately.
    private func statusTick() {
        guard let tom, !tom.thinking, !voice.speaking, Date().timeIntervalSince(lastStatusAt) > 90 else { return }
        let open = board.open.filter { $0.session == roomID || $0.status != .blocked } + board.jobs.filter { !$0.status.isOpen && $0.hasPendingRequest }
        guard !open.isEmpty else { return }
        lastStatusAt = Date()
        let list = open.map { "\($0.headline): \($0.spec.goal)" }.joined(separator: "; ")
        wakeTom("Status check (from the Mac). Open jobs: \(list). If the user hasn't heard where things stand in the last minute or two, tell them in one sentence (what's running, what waits on them, what's next); else answer (nothing).", always: true)
    }

    /// Says "standing down" in Tom's voice, then turns off (if the user cuts in, it stays on).
    private func standDown() {
        guard on, !standingDown else { return }
        standingDown = true
        say("Standing down: nothing said for \(Self.clock(settings.idleSeconds))")
        speak("Standing down.", name: Assistant.name, voice: Service.shared.voice, then: { [weak self] in
            guard let self, self.standingDown else { return }
            self.standingDown = false
            self.stop(reason: "Turned off: nothing said for \(Self.clock(self.settings.idleSeconds))")
        }, cut: { [weak self] in
            self?.standingDown = false
            self?.activity()
        })
    }

    // MARK: Talking

    /// Says `text` in the agent's voice (Tom's when nil), after whatever is being said. `then`
    /// runs once it's been heard; `cut` if the user cuts in first.
    private func talk(_ text: String, as agent: Agent?, then: (() -> Void)? = nil, cut: (() -> Void)? = nil) {
        if agent == nil || agent === tom { lastStatusAt = Date() }
        speak(text, name: agent?.name ?? Assistant.name, voice: agent.map(voiceOf) ?? Service.shared.voice, then: then, cut: cut)
    }

    /// Says `text` in `voice`, as `name` (Tom, Jerry or Jane), after whatever is being said.
    private func speak(_ text: String, name: String, voice v: Voice, then: (() -> Void)? = nil, cut: (() -> Void)? = nil) {
        let spoken = Assistant.spoken(text)
        guard !spoken.isEmpty else {
            then?()
            return
        }
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
        if t || j || janeThinking {
            if workTimer == nil {
                workTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tickWork() }
            }
        } else {
            workTimer?.invalidate()
            workTimer = nil
        }
    }

    private func refreshWorking() {
        var lines = agents.filter(\.thinking).map { "\($0.name): \(Self.describe($0.activity))" }
        if janeThinking { lines.append("\(Team.reviewer): reviewing") }
        let w = lines.isEmpty ? nil : lines.joined(separator: " · ")
        if working != w { working = w }
    }

    /// "thinking", "searching the web".
    static func describe(_ activity: Conversation.Activity) -> String {
        switch activity {
        case .idle, .model: return "thinking"
        case .tool(let name): return "using " + AssistantView.toolName(name)
        case .approval(let name): return "waiting for you to approve " + AssistantView.toolName(name)
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
        case .approval: return "Purr"
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
        let newModel = s.model != settings.model || s.jerryModel != settings.jerryModel || s.janeModel != settings.janeModel
        let newVoice = s.jerryVoice != settings.jerryVoice || s.janeVoice != settings.janeVoice
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
        listener.setPause(s.pauseSeconds)
        adviseOnThinking()
        refreshListening()
        if newModel, on { warmUp() }
        if newVoice, on { enrollVoices() }
    }

    /// Gets the models loaded in Ollama now, so the first answers don't wait for them.
    private func warmUp() {
        var names = Set(agents.map(model(for:)))
        if teamOn, settings.reviewer, !settings.janeModel.isEmpty { names.insert(settings.janeModel) }
        let client = self.client
        Task.detached { for m in names { await client.warm(m) } }
    }

    /// The voices' prints, so what they say isn't taken for yours.
    private func enrollVoices() {
        guard settings.voicePrints else { return }
        VoicePrints.shared.prepare()
        VoicePrints.shared.enroll(Service.shared.voice)
        if teamOn { VoicePrints.shared.enroll(jerryVoice) }
        if teamOn, settings.reviewer { VoicePrints.shared.enroll(janeVoice) }
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
                        if !self.settings.janeModel.isEmpty, !names.contains(self.settings.janeModel) {
                            self.change { $0.janeModel = "" }
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
        if thinking || jerryThinking || janeThinking || voice.speaking || pendingApproval != nil { activity() }
        statusTick()
        let idle = Date().timeIntervalSince(lastActivity)
        idleLeft = max(0, settings.idleSeconds - idle)
        guard idle >= settings.idleSeconds, !standingDown else { return }
        if workPending {
            // It can't stand down over work pending: the countdown starts again, and Tom says where it stands.
            activity()
            say("Not standing down: work is pending")
            lastStatusAt = .distantPast
            statusTick()
        } else if !idleAsked, let tom {
            // Tom decides: is anything still owed to the user? (hold), or the app stands down.
            idleAsked = true
            activity()
            let open = board.open.filter { $0.session == roomID }
            let list = open.isEmpty ? "none" : open.map { "\($0.headline): \($0.spec.goal)" }.joined(separator: "; ")
            tom.tell { $0.event(Team.idleQuestion(minutes: Self.clock(self.settings.idleSeconds), openJobs: list)) }
            tom.wakeWanted = true
            next(for: tom)
        } else {
            // Asked a whole period ago and no answer (Ollama gone?): it stands down anyway.
            standDown()
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

import AppKit
import SwiftUI
import VoiceCore

/// AI Listen: start it (or say "Tom", always listening) and talk; the chat as it goes, a box to
/// type in instead, and where Ollama is.
struct AssistantView: View {
    @EnvironmentObject var service: Service
    @ObservedObject var ai = AssistantModel.shared
    @ObservedObject var voice = AssistantModel.shared.voice
    @ObservedObject var listener = AssistantModel.shared.listener
    @ObservedObject var wakeListener = AssistantModel.shared.wakeListener
    @ObservedObject var prints = VoicePrints.shared
    @ObservedObject var board = SkillsModel.shared
    @State private var typed = ""
    @State private var url = AssistantModel.shared.settings.ollamaURL
    @State private var toolRunURL = AssistantModel.shared.settings.toolRunURL
    @State private var showSettings = false

    var body: some View {
        Page(title: "AI Listen", subtitle: "Start it (or say “\(Assistant.name)”), then talk; the answer is read back",
             symbol: "sparkles", colors: [Palette.violet, Palette.pink]) {
            let _ = board.enabled      // redraws as the Jerry skill comes and goes
            if let status = Neural.status(service.neural.ears, what: "speech recognition") {
                Notice(text: status, tint: .blue, symbol: "arrow.down.circle")
            }
            if let problem = ai.problem {
                HStack {
                    Notice(text: problem)
                    if problem.contains("System Settings") {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    } else if problem.contains("Ollama") {
                        Button("Try again") { ai.refreshModels() }
                    }
                }
            }
            controls
            if let advice = ai.thinkingAdvice { ThinkingNotice(advice: advice) }
            transcript
            if !ai.board.jobs.isEmpty { JobsSection() }
            typeBar
            settings
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button { ai.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: ai.on ? "stop.fill" : "sparkles")
                    Text(ai.on ? "Stop" : "Start")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(ai.on ? Palette.red : Palette.violet))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("l", modifiers: .command)
            .help(ai.on ? "Stop listening (the chat stays in the AI library)" : "Start talking (a new chat)")
            phaseLabel
            if ai.on, listener.on, !voice.speaking { LevelMeter(level: listener.level) }
            Spacer()
            if ai.on, let left = ai.idleLeft {
                Text("Off in \(Captions.clock(left))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(left < 10 ? Palette.orange : .secondary)
                    .help("It turns off after \(AssistantModel.clock(ai.settings.idleSeconds)) with nothing said")
            }
            if voice.speaking {
                Button("Stop talking") { voice.stop() }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
            }
            Button { ai.setThinking(!ai.settings.thinking) } label: {
                Label("Thinking", systemImage: "brain")
            }
            .buttonStyle(PillButton(tint: Palette.violet, filled: ai.settings.thinking))
            .help(ai.settings.thinking ? "Thinking is on: the model thinks before it answers (slower). Click to turn it off."
                                       : "Thinking is off: quicker answers. Click to let the model think first.")
            Button("New chat") { ai.newChat() }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                .disabled(ai.turns.isEmpty)
                .help("Start another chat (this one stays in the AI library; the new one doesn't see it unless you ask)")
            Button { Windows.show(.memory) } label: { Label("Memory", systemImage: "brain.head.profile") }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                .help("What Tom has learned (his notes, which he reads every turn), and the standing instructions for Tom and Jerry")
        }
    }

    private var phaseLabel: some View {
        HStack(spacing: 6) {
            switch ai.phase {
            case .off:
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Off").foregroundStyle(.secondary)
            case .listening:
                Image(systemName: "ear.fill").foregroundStyle(Palette.pink)
                    .symbolEffect(.pulse, isActive: true)
                Text("Listening…")
            case .thinking:
                ProgressView().controlSize(.small)
                Text("Thinking…")
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(ai.speaking == Team.teammate ? Palette.teal : ai.speaking == Team.reviewer ? Palette.orange : Palette.violet)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text("\(ai.speaking ?? Assistant.name) speaking…")
            }
            if ai.jerryThinking {
                ProgressView().controlSize(.small).padding(.leading, 6)
                Text("\(Team.teammate) working…").foregroundStyle(Palette.teal)
            }
            if ai.janeThinking {
                ProgressView().controlSize(.small).padding(.leading, 6)
                Text("\(Team.reviewer) reviewing…").foregroundStyle(Palette.orange)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    // MARK: The chat

    private var transcript: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if ai.turns.isEmpty {
                        howTo
                    }
                    ForEach(Array(ai.turns.enumerated()), id: \.offset) { i, turn in
                        ChatBubble(turn: turn).id(i)
                    }
                    if let approval = ai.pendingApproval {
                        ApprovalCard(approval: approval).id("approval")
                    }
                    if let working = ai.working {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(working).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                    if !ai.lastToolCalls.isEmpty, !ai.thinking {
                        Text("Used: " + Self.toolNames(ai.lastToolCalls))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    if !ai.on, ai.alwaysListen {
                        HStack(spacing: 6) {
                            Image(systemName: "ear").foregroundStyle(Palette.pink)
                            Text(wakeListener.on ? (ai.wakeHearing.isEmpty ? "Listening for “\(Assistant.name)”…" : "Listening for “\(Assistant.name)”: “\(ai.wakeHearing)”")
                                                    : "Listen is on, but the microphone isn't open for “\(Assistant.name)” yet")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .id("hearing")
                    }
                    if ai.on, !ai.hearing.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").foregroundStyle(Palette.pink)
                                .symbolEffect(.variableColor.iterative, isActive: true)
                            Text(ai.hearing).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .id("hearing")
                    }
                    if let notice = ai.notice {
                        Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.violet).id("notice")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: ai.turns.count) { _, n in
                withAnimation { scroller.scrollTo(n - 1, anchor: .bottom) }
            }
            .onChange(of: ai.thinking) { _, thinking in
                if thinking { withAnimation { scroller.scrollTo("thinking", anchor: .bottom) } }
            }
            .onChange(of: ai.hearing) { _, h in
                if !h.isEmpty { scroller.scrollTo("hearing", anchor: .bottom) }
            }
            .onChange(of: ai.pendingApproval?.id) { _, id in
                if id != nil { withAnimation { scroller.scrollTo("approval", anchor: .bottom) } }
            }
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.system(size: 13, weight: .semibold))
            HowToLine(symbol: "1.circle", text: "Press Start (or ⌘L), or click the panel's AI listen tile. With Listen on (the ear), just say “\(Assistant.name)”: “Tom, what's a good name for a cat?”")
            HowToLine(symbol: "2.circle", text: "Then just talk: everything you say goes to Ollama, and the answer is read back. A pause mid-sentence doesn't cut you off, and you can talk over an answer to stop it.")
            HowToLine(symbol: "3.circle", text: "“Stop” stops it talking. “New chat” starts over. “Goodbye” turns it off, and so does \(AssistantModel.clock(ai.settings.idleSeconds)) with nothing said; you hear a sound as it does.")
            HowToLine(symbol: "books.vertical", text: "Each chat is kept in the AI library. A new chat starts fresh, but ask about an earlier one, or something in your library, and it looks it up; ask, and it adds notes or changes them.")
            HowToLine(symbol: "safari", text: "Its skills (on the panel, beside it) let it search the web and read pages in your browser, find and read files, read the clipboard, check the Mac, and do sums.")
            HowToLine(symbol: "person.2", text: "With the \(Team.teammate) skill on, there are two of them: Tom, who you talk to, and \(Team.teammate), who does the work. Anything that takes a tool, Tom hands \(Team.teammate) as a job (you hear him brief it); \(Team.teammate) says what he's doing as he goes, in his own voice, and reports back; Tom checks the result against what he asked for and sends it back if it misses. \(Team.teammate)'s tool calls that change something wait for you: Approve or Reject, or say yes or no.")
            HowToLine(symbol: "person.3", text: "When Tom sends a job back, \(Team.reviewer), the reviewer, steps in: she reads the job alone (what you said just before, Tom's spec, what passed between Tom and \(Team.teammate)), says what's wrong with how they went about it and what \(Team.teammate) should do differently, in her own voice, and leaves. You hear her; nobody talks to her. Tom owns every job until you have what you asked for, says where things stand, and the app won't stand down over work pending: with nothing said for a while it asks Tom whether anything is still owed, and says \"standing down\" before it turns off.")
            HowToLine(symbol: "brain.head.profile", text: "Tom learns: after a job he notes what it taught him (your preferences, how to brief \(Team.teammate), what went wrong) in his memory, which he reads every turn. Open it with Memory: read it, edit it, and give Tom and \(Team.teammate) standing instructions.")
            HowToLine(symbol: "hand.wave", text: "With Listen on (the ear), a wave at the camera starts it too, and stops it talking. Soft sounds every few seconds say what it's working on.")
        }
        .padding(.bottom, 6)
    }

    private var typeBar: some View {
        HStack(spacing: 8) {
            TextField("Type instead of talking (it starts it if it's off)", text: $typed)
                .textFieldStyle(.plain)
                .onSubmit {
                    ai.type(typed)
                    typed = ""
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: Capsule())
            Button {
                ai.type(typed)
                typed = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.violet)
            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Ollama

    private var settings: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Ollama").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    TextField(OllamaClient.defaultURL, text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(connect)
                    Button("Connect", action: connect).disabled(url == ai.settings.ollamaURL && !ai.models.isEmpty)
                }
                HStack(spacing: 8) {
                    Text("Model").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    if ai.models.isEmpty {
                        Text(ai.settings.model.isEmpty ? "None found: pull one (ollama pull llama3.2), then Connect" : ai.settings.model)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(get: { ai.settings.model }, set: { m in ai.change { $0.model = m } })) {
                            ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                    Button { ai.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Ask Ollama again which models it has")
                }
                HStack(spacing: 8) {
                    Text("Pause").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    ForEach([1.2, 1.8, 2.5, 3.5], id: \.self) { s in
                        Button(String(format: s == s.rounded() ? "%.0f s" : "%.1f s", s)) { ai.change { $0.pauseSeconds = s } }
                            .buttonStyle(Chip(selected: abs(ai.settings.pauseSeconds - s) < 0.05, tint: Palette.pink))
                    }
                    Text("of quiet ends what you said (longer if it sounds unfinished)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("It doesn't wait for you to finish? Pick a longer pause. It answers too slowly? A shorter one.")
                }
                HStack(spacing: 8) {
                    Text("Off after").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    ForEach([60.0, 180, 300, 600], id: \.self) { s in
                        Button(AssistantModel.clock(s)) { ai.change { $0.idleSeconds = s } }
                            .buttonStyle(Chip(selected: abs(ai.settings.idleSeconds - s) < 0.5, tint: Palette.violet))
                    }
                    Text("with nothing said").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Sounds", isOn: $ai.sounds).toggleStyle(.checkbox).font(.system(size: 11))
                        .help("Little sounds as it starts and hears you (the sound as it turns off always plays)")
                }
                HStack(spacing: 8) {
                    Text("Barge in").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Toggle("Talk over an answer to stop it. Off unless you turn it on: it doesn't listen while it talks, so nothing you say then is taken for its own voice and thrown away.",
                           isOn: Binding(get: { ai.settings.bargeIn }, set: { v in ai.change { $0.bargeIn = v } }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                }
                HStack(spacing: 8) {
                    Text("Echo").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Toggle("Echo cancellation (Apple's voice processing): its own voice is taken out of what the microphone hears. Off unless you turn it on: on some Macs its microphone is heard but not understood. From the next start.",
                           isOn: Binding(get: { ai.settings.echoCancel }, set: { v in ai.change { $0.echoCancel = v } }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                }
                Text(!ai.settings.bargeIn ? "Barge in is off: it doesn't listen while it talks. Stop talking (the button, or a wave) and then talk."
                     : !ai.settings.echoCancel ? "Echo cancellation is off: only “stop”, “wait” or “Tom” said first cut in; anything else said while it talks is dropped. Headphones help."
                     : AssistantModel.echo.failed ? "Echo cancellation gave the microphone only silence here, so it's off until the app starts again: only “stop”, “wait” or “Tom” said first cut in."
                     : "Say “stop”, “wait” or “Tom”, or just talk, to cut in.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Approve").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    ForEach(Approvals.allCases, id: \.self) { a in
                        Button(a.title) { ai.change { $0.approvals = a } }
                            .buttonStyle(Chip(selected: ai.settings.approvals == a, tint: Palette.teal))
                            .help(a.help)
                    }
                    Text("of \(Team.teammate)'s tool calls wait for you").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Tom watches every step", isOn: Binding(get: { ai.settings.tomWatches }, set: { v in ai.change { $0.tomWatches = v } }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .help("Tom is told of every tool \(Team.teammate) proposes and runs (he usually says nothing); off, only of his questions, results and failures (quicker)")
                }
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Text(Team.teammate).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    if !ai.teamOn {
                        Text("Off: turn the \(Team.teammate) skill on (the panel's Skills column) for a second assistant Tom can bring in")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if ai.models.isEmpty {
                        Text("His model: \(ai.jerryModelName)").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(get: { ai.settings.jerryModel }, set: { m in ai.change { $0.jerryModel = m } })) {
                            Text("Same as Tom (\(ai.modelName))").tag("")
                            ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        .help("\(Team.teammate)'s model (Tom's unless you pick another)")
                    }
                }
                if ai.teamOn {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Voice").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            VoicePicker(selected: ai.jerryVoice.id) { v in
                                ai.change { $0.jerryVoice = v.id }
                                SpeechPlayer.preview(v, speed: service.settings.speed)
                            }
                            Text("\(Team.teammate)'s voice (Tom's is the panel's). Unset, it's the first of the other kind from Tom's, so they're told apart.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(Team.reviewer).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        Toggle("\(Team.reviewer), the reviewer: when Tom sends a job back, she reads it (only the job: what you said just before, Tom's spec, and what passed between Tom and \(Team.teammate)) and tells \(Team.teammate) what to do differently, then leaves. You hear her; nobody talks to her.",
                               isOn: Binding(get: { ai.settings.reviewer }, set: { v in ai.change { $0.reviewer = v } }))
                            .toggleStyle(.checkbox).font(.system(size: 11))
                    }
                    if ai.settings.reviewer {
                        HStack(spacing: 8) {
                            Text("Model").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                            if ai.models.isEmpty {
                                Text("Her model: \(ai.janeModelName)").font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Picker("", selection: Binding(get: { ai.settings.janeModel }, set: { m in ai.change { $0.janeModel = m } })) {
                                    Text("Same as \(Team.teammate) (\(ai.jerryModelName))").tag("")
                                    ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280)
                                .help("\(Team.reviewer)'s model (\(Team.teammate)'s unless you pick another)")
                            }
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Text("Voice").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                VoicePicker(selected: ai.janeVoice.id) { v in
                                    ai.change { $0.janeVoice = v.id }
                                    SpeechPlayer.preview(v, speed: service.settings.speed)
                                }
                                Text("\(Team.reviewer)'s voice. Unset, it's the first that's neither Tom's nor \(Team.teammate)'s.")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Text("Wave").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Toggle("With Listen on, watch the camera: a wave starts it (and stops it talking). The camera's light is on while it watches.",
                           isOn: Binding(get: { ai.settings.wave }, set: { v in ai.setWave(v) }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                }
                HStack(spacing: 8) {
                    Text("Working").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Toggle("A soft sound every three seconds while it works: one for thinking (another for \(Team.teammate)), one for the browser, one for files and the library, one for scripts",
                           isOn: Binding(get: { ai.settings.workingSounds }, set: { v in ai.change { $0.workingSounds = v } }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .disabled(!ai.sounds)
                }
                HStack(spacing: 8) {
                    Text("Prints").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Toggle("Tell the voices from yours by how they sound (voice prints): while one talks, what sounds like it is dropped before it's written down, and what sounds like you gets through",
                           isOn: Binding(get: { ai.settings.voicePrints }, set: { v in ai.change { $0.voicePrints = v } }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    if let status = Neural.status(prints.state, what: "the voice prints model") {
                        Text(status).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Text("Scripts").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    TextField(ToolRunClient.defaultURL, text: $toolRunURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(connectToolRun)
                        .help("Tool Mac Tool Run's address: with it, the model can list and run your scripts and flows (each run waits for you to click Run). Empty: it can't.")
                    Button("Set", action: connectToolRun).disabled(toolRunURL == ai.settings.toolRunURL)
                }
                Text("Everything stays on this Mac: Ollama runs here, and so do the voices and the listening. Any model can look things up in the library, and run your scripts through Tool Mac Tool Run when it's running (nothing runs until you click Run on its card).")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Ollama").font(.system(size: 12, weight: .medium))
                Text("\(ai.modelName) at \(ai.settings.ollamaURL)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
        .onAppear { if ai.models.isEmpty { ai.refreshModels() } }
    }

    private func connect() {
        ai.change { $0.ollamaURL = url.trimmingCharacters(in: .whitespacesAndNewlines) }
        url = ai.settings.ollamaURL
        ai.refreshModels()
    }

    private func connectToolRun() {
        ai.change { $0.toolRunURL = toolRunURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        toolRunURL = ai.settings.toolRunURL
    }

    static func toolName(_ tool: String) -> String {
        switch tool {
        case "list_chats": return "earlier chats"
        case "load_chats": return "a chat"
        case "list_library": return "the library"
        case "read_library": return "a library item"
        case "list_scripts": return "your scripts"
        case "run_script": return "a script"
        case "list_flows": return "your flows"
        case "run_flow", "run_flow_code": return "a flow"
        case "check_flow": return "a flow check"
        case "list_runs", "read_run": return "the runs"
        case "stop_run": return "stopping a run"
        case "add_note": return "adding a note"
        case "update_library": return "changing the library"
        case "web_search": return "a web search"
        case "search_site": return "a site search"
        case "open_page": return "a web page"
        case "read_page": return "the page in your browser"
        case "find_on_page": return "finding on the page"
        case "find_files": return "Spotlight"
        case "list_folder": return "a folder"
        case "read_file": return "a file"
        case "read_clipboard": return "the clipboard"
        case "mac_status": return "the Mac"
        case "calculate": return "the calculator"
        case "show_app": return "opening a window"
        case "show_browser": return "showing the browser"
        case "delegate": return "a job for \(Team.teammate)"
        case "message_jerry": return "a message to \(Team.teammate)"
        case "cancel_job": return "cancelling a job"
        case "stop_everything": return "stopping everything"
        case "check_request": return "a run's standing"
        case "job_status": return "a job's standing"
        case "ask_tom": return "asking \(Assistant.name)"
        case "finish": return "finishing a job"
        case "remember": return "remembering"
        case "forget": return "forgetting"
        default: return tool
        }
    }

    /// "earlier chats, a chat": each once, in the order first used.
    static func toolNames(_ tools: [String]) -> String {
        var seen = Set<String>()
        return tools.map(toolName).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

/// Thinking is off but can't be turned off all the way: why, and the command that does the rest.
private struct ThinkingNotice: View {
    var advice: (text: String, command: String?)
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "brain").foregroundStyle(Palette.violet)
                Text(advice.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let command = advice.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button {
                        Service.shared.copy(command)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(PillButton(tint: Palette.violet, filled: true))
                    .help("Copy it, then paste it into Terminal")
                }
            }
        }
        .padding(10)
        .background(Palette.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct HowToLine: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Palette.violet).frame(width: 16)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One thing said in a chat: the user's on the right, the assistant's on the left.
struct ChatBubble: View {
    var turn: ChatTurn

    var body: some View {
        if turn.role == .system {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
                Text(turn.text).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(Self.time.string(from: turn.time)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        let user = turn.role == .user
        let jerry = turn.name == Team.teammate
        let jane = turn.name == Team.reviewer
        return HStack {
            if user { Spacer(minLength: 60) }
            VStack(alignment: user ? .trailing : .leading, spacing: 3) {
                Text(turn.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(user ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(user ? Palette.violet : (jerry ? Palette.teal.opacity(0.14) : jane ? Palette.orange.opacity(0.14) : Color.primary.opacity(0.07))))
                    .overlay(alignment: .leading) {
                        if turn.to != nil, !user {
                            RoundedRectangle(cornerRadius: 2).fill(jerry ? Palette.teal : jane ? Palette.orange : Palette.violet).frame(width: 3).padding(.vertical, 6)
                        }
                    }
                Text(turn.speaker + (turn.to.map { " → \($0)" } ?? "") + " · " + Self.time.string(from: turn.time))
                    .font(.system(size: 10)).foregroundStyle(jerry ? AnyShapeStyle(Palette.teal) : jane ? AnyShapeStyle(Palette.orange) : AnyShapeStyle(.tertiary))
            }
            if !user { Spacer(minLength: 60) }
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}

/// The AI library: every chat with the assistant, by day; open one to read it, hear it, copy or
/// save it, or delete it.
struct ChatsView: View {
    /// Set from elsewhere (the model's show_app): a chat to open, words to search for.
    final class Selection: ObservableObject {
        static let shared = Selection()
        @Published var id: UUID?
        @Published var query: String?
    }

    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var reader = Service.shared.reader
    @State private var query = ""
    @State private var selected: UUID?
    @State private var confirmDelete: LibraryRecord?
    @FocusState private var searching: Bool

    private var chats: [LibraryRecord] {
        library.filter(kind: .chat, query: query, starredOnly: false)
    }

    private struct Day: Identifiable {
        var day: Date
        var chats: [LibraryRecord]
        var id: Date { day }
    }

    /// The chats by day, newest day first.
    private var days: [Day] {
        var out: [Day] = []
        for c in chats {
            let day = Calendar.current.startOfDay(for: c.created)
            if let i = out.firstIndex(where: { $0.day == day }) { out[i].chats.append(c) } else { out.append(Day(day: day, chats: [c])) }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                search
                if let problem = library.problem { Notice(text: problem) }
                if chats.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let id = selected, let chat = library.item(id) {
                Divider()
                ChatDetail(chat: chat, close: { selected = nil }, delete: { confirmDelete = chat })
                    .frame(width: 440)
                    .id(chat.id)
            }
        }
        .animation(.easeOut(duration: 0.18), value: selected)
        .onReceive(Selection.shared.$id) { id in
            guard let id else { return }
            selected = id
            Selection.shared.id = nil
        }
        .onReceive(Selection.shared.$query) { q in
            guard let q else { return }
            query = q
            Selection.shared.query = nil
        }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(get: { confirmDelete != nil },
                                                                                            set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let chat = confirmDelete {
                    if selected == chat.id { selected = nil }
                    library.delete(chat.id)
                }
                confirmDelete = nil
            }
        } message: {
            Text("It can't be brought back.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [Palette.blue, Palette.violet], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Library").font(.system(size: 18, weight: .semibold))
                Text("\(counted(library.items.filter { $0.kind == .chat }.count, "chat")) with \(Assistant.name) · each new chat starts fresh; ask, and it looks these up")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Windows.show(.assistant) } label: { Label("AI listen", systemImage: "sparkles") }
                .buttonStyle(PillButton(tint: Palette.violet, filled: true))
            Button { Windows.show(.library) } label: { Label("Library", systemImage: "square.grid.2x2.fill") }
                .buttonStyle(PillButton(tint: Palette.green, filled: false))
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the chats", text: $query).textFieldStyle(.plain)
                .focused($searching)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .frame(maxWidth: 320)
        .background(Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden())
        .help("Search (⌘F)")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(days) { group in
                    Section {
                        ForEach(group.chats) { chat in
                            ChatRow(chat: chat, selected: chat.id == selected)
                                .onTapGesture { selected = chat.id == selected ? nil : chat.id }
                                .contextMenu {
                                    Button("Open") { selected = chat.id }
                                    Button("Read aloud") { reader.say(chat.text, voice: service.voice, speed: service.settings.speed) }
                                    Button("Copy") { service.copy(chat.text) }
                                    Button(chat.starred ? "Unstar" : "Star") {
                                        var c = chat
                                        c.starred.toggle()
                                        library.save(c)
                                    }
                                    Divider()
                                    Button("Delete…", role: .destructive) { confirmDelete = chat }
                                }
                        }
                    } header: {
                        Text(Self.day.string(from: group.day))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: library.items.contains { $0.kind == .chat } ? "magnifyingglass" : "sparkles")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(library.items.contains { $0.kind == .chat } ? "Nothing matches" : "No chats yet").font(.system(size: 15, weight: .medium))
            Text(library.items.contains { $0.kind == .chat } ? "Try other words." : "Start AI Listen, say “\(Assistant.name)”, and talk. Each chat is kept here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.doesRelativeDateFormatting = true
        return f
    }()
}

private struct ChatRow: View {
    var chat: LibraryRecord
    var selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(selected ? Palette.violet : Palette.violet.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(chat.turns?.last(where: { $0.role == .assistant })?.text ?? chat.text)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if chat.starred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.orange) }
            VStack(alignment: .trailing, spacing: 2) {
                Text(ChatBubble.time.string(from: chat.created))
                Text(counted(chat.turns?.count ?? 0, "turn"))
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(hover || selected ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Palette.violet : Palette.violet.opacity(hover ? 0.4 : 0.1), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// An open chat: read it, hear it, copy it, save it, delete it.
private struct ChatDetail: View {
    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var reader = Service.shared.reader
    var chat: LibraryRecord
    var close: () -> Void
    var delete: () -> Void
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CHAT").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.violet).kerning(0.5)
                Spacer()
                Button {
                    var c = chat
                    c.starred.toggle()
                    library.save(c)
                } label: {
                    Image(systemName: chat.starred ? "star.fill" : "star").foregroundStyle(chat.starred ? .orange : .secondary)
                }
                .buttonStyle(.borderless).help(chat.starred ? "Unstar" : "Star")
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: [])
            }
            Text(chat.title).font(.system(size: 17, weight: .semibold))
            Text("\(Files.dated.string(from: chat.created)) · \(counted(chat.turns?.count ?? 0, "turn")) · \(counted(chat.wordCount, "word"))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if reader.speaking { NowReading(reader: reader) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array((chat.turns ?? []).enumerated()), id: \.offset) { _, turn in
                        ChatBubble(turn: turn)
                    }
                    if chat.turns == nil || chat.turns?.isEmpty == true {
                        Text(chat.text).font(.system(size: 13)).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                if reader.speaking {
                    Button(reader.paused ? "Resume" : "Pause") { reader.paused ? reader.resume() : reader.pause() }
                        .buttonStyle(PillButton(tint: Palette.indigo, filled: true))
                    Button("Stop") { reader.stop() }.buttonStyle(PillButton(tint: .secondary, filled: false))
                } else {
                    Button { reader.say(chat.text, voice: service.voice, speed: service.settings.speed) } label: {
                        Label("Read back", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButton(tint: Palette.indigo, filled: true))
                }
                Button("Copy") {
                    service.copy(chat.text)
                    flash("Copied")
                }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                Button("Save as .txt") { Files.save(chat.text, name: chat.title, ext: "txt") }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button { delete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }

    private func flash(_ s: String) {
        note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if note == s { note = nil } }
    }
}

/// A tool Jerry proposed, waiting for the user: approve it or reject it.
private struct ApprovalCard: View {
    @ObservedObject var ai = AssistantModel.shared
    var approval: AssistantModel.Approval

    var body: some View {
        let use = ToolUse(name: approval.call.name, arguments: approval.call.argumentsJSON, result: "")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Palette.orange)
                Text("\(Team.teammate) wants to use \(AssistantView.toolName(approval.call.name)) (\(approval.job))").font(.system(size: 13, weight: .semibold))
            }
            if !use.summary.isEmpty {
                Text(use.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Approve") { ai.decide(approval, true) }
                    .buttonStyle(PillButton(tint: Palette.green, filled: true))
                    .keyboardShortcut(.return, modifiers: [])
                Button("Reject") { ai.decide(approval, false) }
                    .buttonStyle(PillButton(tint: Palette.red, filled: false))
                Text("or say “yes” or “no”").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.orange.opacity(0.5)))
    }
}

/// The jobs Tom has handed Jerry: each with its status, its spec, its result, and what tools ran.
private struct JobsSection: View {
    @ObservedObject var ai = AssistantModel.shared
    @State private var open = false
    @State private var expanded: Set<String> = []

    var body: some View {
        let jobs = ai.board.jobs.sorted { $0.number > $1.number }
        let openCount = jobs.filter { $0.status.isOpen }.count
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(jobs) { job in
                    JobRow(job: job, expanded: expanded.contains(job.id)) {
                        if expanded.contains(job.id) { expanded.remove(job.id) } else { expanded.insert(job.id) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear finished") { ai.clearFinishedJobs() }
                        .buttonStyle(PillButton(tint: .secondary, filled: false))
                        .disabled(jobs.allSatisfy { $0.status.isOpen })
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(Palette.teal)
                Text("Jobs").font(.system(size: 12, weight: .semibold))
                Text(openCount == 0 ? "\(jobs.count) done" : "\(openCount) open").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JobRow: View {
    var job: Job
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(job.id + (job.revisions > 0 ? " · revision \(job.revisions)" : "")).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(job.status.title).font(.system(size: 11)).foregroundStyle(color)
                    Text(job.spec.goal).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.spec.text).font(.system(size: 12)).textSelection(.enabled)
                    if let q = job.blockedOn {
                        Text("\(Team.teammate) asks: \(q)").font(.system(size: 12)).foregroundStyle(Palette.orange)
                    }
                    ForEach(job.requests) { r in
                        Text("Run on the Mac: " + r.line).font(.system(size: 12)).foregroundStyle(r.over ? .secondary : Palette.orange)
                    }
                    if let r = job.result {
                        Text("Result: \(r.summary)").font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        if !r.details.isEmpty { Text(r.details).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    if !job.tools.isEmpty {
                        Text("Tools (\(job.tools.count))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(job.tools) { use in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AssistantView.toolName(use.name) + (use.summary.isEmpty ? "" : ": " + use.summary))
                                    .font(.system(size: 11, design: .monospaced))
                                Text(String(use.result.prefix(300)) + (use.result.count > 300 ? "…" : "")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Text("Log").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(job.events) { e in
                        Text(ChatBubble.time.string(from: e.time) + "  " + JobBoard.line(e)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var color: Color {
        switch job.status {
        case .queued: return .secondary
        case .running: return Palette.teal
        case .awaitingApproval, .blocked: return Palette.orange
        case .done: return Palette.green
        case .failed: return Palette.red
        }
    }
}

/// Tom's memory: his notes by section (one a line, his to write and yours to edit), and the
/// standing instructions for Tom and Jerry.
struct MemoryView: View {
    @EnvironmentObject var service: Service
    @ObservedObject var ai = AssistantModel.shared
    @State private var notes: [String: String] = [:]
    @State private var tom = ""
    @State private var jerry = ""
    @State private var note: String?

    var body: some View {
        Page(title: "Tom's Memory", subtitle: "What Tom has learned, read at the start of every turn; edit it, he keeps it",
             symbol: "brain.head.profile", colors: [Palette.violet, Palette.teal]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ai.memory.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(section.title).font(.system(size: 13, weight: .semibold))
                                Text(section.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                Spacer()
                                Text(counted(lines(notes[section.id] ?? "").count, "note")).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text(section.about).font(.system(size: 11)).foregroundStyle(.secondary)
                            editor(Binding(get: { notes[section.id] ?? "" }, set: { notes[section.id] = $0 }), height: 90)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Standing instructions for Tom").font(.system(size: 13, weight: .semibold))
                        Text("Your own words, after his system prompt: how to talk to you, what to always do or never do.").font(.system(size: 11)).foregroundStyle(.secondary)
                        editor($tom, height: 70)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Standing instructions for \(Team.teammate)").font(.system(size: 13, weight: .semibold))
                        Text("After his system prompt: how to work, what to check, what to leave alone.").font(.system(size: 11)).foregroundStyle(.secondary)
                        editor($jerry, height: 70)
                    }
                }
                .padding(2)
            }
            HStack(spacing: 8) {
                Button("Save") { save() }
                    .buttonStyle(PillButton(tint: Palette.violet, filled: true))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!changed)
                Button("Revert") { load() }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                    .disabled(!changed)
                Button("Copy") {
                    service.copy(ai.memory.text)
                    flash("Copied")
                }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("\(ai.memory.noteCount) of \(Memory.maxNotes) notes").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .onAppear(perform: load)
        .onChange(of: ai.memory) { _, _ in if !changed { load() } }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: height)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func lines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[-•*]\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    private var edited: Memory {
        var m = ai.memory
        for i in m.sections.indices { m.sections[i].notes = lines(notes[m.sections[i].id] ?? "") }
        m.tomInstructions = tom.trimmingCharacters(in: .whitespacesAndNewlines)
        m.jerryInstructions = jerry.trimmingCharacters(in: .whitespacesAndNewlines)
        return m
    }

    private var changed: Bool { edited != ai.memory }

    private func load() {
        notes = Dictionary(uniqueKeysWithValues: ai.memory.sections.map { ($0.id, $0.notes.joined(separator: "\n")) })
        tom = ai.memory.tomInstructions
        jerry = ai.memory.jerryInstructions
    }

    private func save() {
        let m = edited
        guard m.noteCount <= Memory.maxNotes else {
            flash("At most \(Memory.maxNotes) notes in all")
            return
        }
        ai.setMemory(m)
        load()
        flash("Saved")
    }

    private func flash(_ s: String) {
        note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if note == s { note = nil } }
    }
}

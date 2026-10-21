import AppKit
import SwiftUI
import VoiceCore

/// AI Listen: start it, say "Micky" or "Ollama", talk; the chat as it goes, a box to type in
/// instead, and where Ollama is.
struct AssistantView: View {
    @EnvironmentObject var service: Service
    @ObservedObject var ai = AssistantModel.shared
    @ObservedObject var voice = AssistantModel.shared.voice
    @ObservedObject var listener = AssistantModel.shared.listener
    @State private var typed = ""
    @State private var url = AssistantModel.shared.settings.ollamaURL
    @State private var toolRunURL = AssistantModel.shared.settings.toolRunURL
    @State private var showSettings = false

    var body: some View {
        Page(title: "AI Listen", subtitle: "Say “\(Assistant.name)” or “Ollama”, then talk; the answer is read back",
             symbol: "sparkles", colors: [Palette.violet, Palette.pink]) {
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
            transcript
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
            .help(ai.on ? "Stop listening (the chat stays in the AI library)" : "Start listening for “\(Assistant.name)” (a new chat)")
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
            Button("New chat") { ai.newChat() }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                .disabled(ai.turns.isEmpty)
                .help("Start another chat (this one stays in the AI library; the new one doesn't see it unless you ask)")
        }
    }

    private var phaseLabel: some View {
        HStack(spacing: 6) {
            switch ai.phase {
            case .off:
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Off").foregroundStyle(.secondary)
            case .waiting:
                Image(systemName: "ear").foregroundStyle(Palette.violet)
                Text("Say “\(Assistant.name)”…")
            case .listening:
                Image(systemName: "ear.fill").foregroundStyle(Palette.pink)
                    .symbolEffect(.pulse, isActive: true)
                Text("Listening…")
            case .thinking:
                ProgressView().controlSize(.small)
                Text("Thinking…")
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.violet)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text("Speaking…")
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
                    if ai.thinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("\(ai.modelName) is thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                    if !ai.lastToolCalls.isEmpty, !ai.thinking {
                        Text("Used: " + Self.toolNames(ai.lastToolCalls))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
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
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.system(size: 13, weight: .semibold))
            HowToLine(symbol: "1.circle", text: "Press Start (or ⌘L). It listens for “\(Assistant.name)” or “Ollama”.")
            HowToLine(symbol: "2.circle", text: "Say the word, then talk: “\(Assistant.name), what's a good name for a cat?” From then on everything you say goes to Ollama, and the answer is read back.")
            HowToLine(symbol: "3.circle", text: "“Stop” stops it talking. “New chat” starts over. “Goodbye” turns it off, and so does \(AssistantModel.clock(ai.settings.idleSeconds)) with nothing said.")
            HowToLine(symbol: "books.vertical", text: "Each chat is kept in the AI library. A new chat starts fresh, but ask about an earlier one (“what did we say about the budget last week?”) or about something you dictated, transcribed or noted, and it looks it up.")
        }
        .padding(.bottom, 6)
    }

    private var typeBar: some View {
        HStack(spacing: 8) {
            TextField("Type instead of talking (it wakes it, and starts it if it's off)", text: $typed)
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
                    Text("Off after").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    ForEach([30.0, 60, 120, 300], id: \.self) { s in
                        Button(AssistantModel.clock(s)) { ai.change { $0.idleSeconds = s } }
                            .buttonStyle(Chip(selected: abs(ai.settings.idleSeconds - s) < 0.5, tint: Palette.violet))
                    }
                    Text("with nothing said").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Sounds", isOn: $ai.sounds).toggleStyle(.checkbox).font(.system(size: 11))
                }
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
        default: return tool
        }
    }

    /// "earlier chats, a chat": each once, in the order first used.
    static func toolNames(_ tools: [String]) -> String {
        var seen = Set<String>()
        return tools.map(toolName).filter { seen.insert($0).inserted }.joined(separator: ", ")
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
        let user = turn.role == .user
        HStack {
            if user { Spacer(minLength: 60) }
            VStack(alignment: user ? .trailing : .leading, spacing: 3) {
                Text(turn.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(user ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(user ? Palette.violet : Color.primary.opacity(0.07)))
                Text((user ? "You" : Assistant.name) + " · " + Self.time.string(from: turn.time))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
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
    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var reader = Service.shared.reader
    @State private var query = ""
    @State private var selected: UUID?
    @State private var confirmDelete: LibraryRecord?

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
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .frame(maxWidth: 320)
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

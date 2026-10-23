import AppKit
import SwiftUI
import VoiceCore

/// What drops down from the menu bar icon: whether it's serving, the tools, the voice, each
/// endpoint's switch, and the bottom bar.
struct PanelView: View {
    @EnvironmentObject var service: Service
    @ObservedObject var board = SkillsModel.shared
    @ObservedObject var assistant = AssistantModel.shared
    /// Watched, so the counts on the tiles change while the panel's open.
    @ObservedObject var library = Library.shared
    var close: () -> Void
    /// What was just copied ("url", "docs", "token"), shown as a check for a moment.
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tools
            models
            voices
            Divider().opacity(0.5)
            endpoints
            sharing
            Divider().opacity(0.5)
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.indigo, Palette.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Super Voice").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                assistant.setAlwaysListen(!assistant.alwaysListen)
            } label: {
                Label("Listen", systemImage: assistant.alwaysListen ? "ear.fill" : "ear")
            }
            .buttonStyle(PillButton(tint: Palette.pink, filled: assistant.alwaysListen))
            .help(assistant.alwaysListen ? "Always listening for “\(Assistant.wakeWords[0][0])”: say it, then talk with Ollama. Nothing else is acted on. Click to stop."
                                         : "Always listen for “\(Assistant.wakeWords[0][0])”: say it, then talk with Ollama (nothing else said is acted on)")
            Button {
                assistant.setWave(!assistant.settings.wave)
            } label: {
                Image(systemName: assistant.settings.wave ? "hand.wave.fill" : "hand.wave")
            }
            .buttonStyle(PillButton(tint: Palette.orange, filled: assistant.settings.wave && assistant.alwaysListen))
            .help(assistant.settings.wave ? "With Listen on, a wave at the camera starts AI Listen (the camera's light is on while it watches). Click to turn the camera off."
                                          : "Watch the camera while Listen is on: a wave starts AI Listen")
            Button {
                board.pinned.toggle()
            } label: {
                Image(systemName: board.pinned ? "sidebar.right" : "rectangle.split.3x1")
            }
            .buttonStyle(PillButton(tint: Palette.violet, filled: board.pinned))
            .help(board.pinned ? "Hide the skills" : "Show the skills (what the model can use, and what it used)")
            Button(service.wantsServing ? "Stop" : "Start") {
                service.wantsServing ? service.stopServing() : service.startServing()
            }
            .buttonStyle(PillButton(tint: service.wantsServing ? .secondary : Palette.green, filled: !service.wantsServing))
            .help(service.wantsServing ? "Stop serving the API (the app keeps working)" : "Serve the API at \(service.baseURL)")
        }
    }

    private var statusColor: Color {
        switch service.server {
        case .running: return Palette.green
        case .starting: return .orange
        case .failed: return Palette.red
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        switch service.server {
        case .running: return "Serving at \(service.settings.allowNetwork ? "port \(service.settings.port), on the network" : service.baseURL)"
        case .starting: return "Starting…"
        case .failed(let why): return why
        case .stopped: return "Not serving the API"
        }
    }

    // MARK: Tools

    private var tools: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ToolTile(title: "Read aloud", detail: "Text to speech", symbol: "speaker.wave.2.fill", colors: [Palette.indigo, Palette.violet]) {
                close(); Windows.show(.read)
            }
            ToolTile(title: "Dictate", detail: "Talk, and keep it", symbol: "mic.fill", colors: [Palette.pink, Palette.orange]) {
                close(); Windows.show(.dictate)
            }
            ToolTile(title: "Transcribe", detail: "An audio file to text", symbol: "waveform.badge.plus", colors: [Palette.teal, Palette.blue]) {
                close(); Windows.show(.transcribe)
            }
            ToolTile(title: "Library", detail: kept == 0 ? "Nothing kept yet" : "\(kept) kept", symbol: "square.grid.2x2.fill", colors: [Palette.green, Palette.teal]) {
                close(); Windows.show(.library)
            }
            ToolTile(title: "AI listen", detail: assistant.on ? (assistant.jerryThinking ? "On: \(Team.teammate)'s working (click to stop)" : "On: just talk (click to stop)") : (board.isOn(Skills.team) ? "Talk with Tom and \(Team.teammate)" : "Talk with Ollama"), symbol: assistant.on ? "stop.fill" : "sparkles",
                     colors: [Palette.violet, Palette.pink]) {
                // Talk right away, no wake word, and no window: the chat works without it (AI library shows it).
                assistant.toggle()
            }
            .help(assistant.on ? "Stop talking with Ollama (the chat stays in the AI library). Right-click for its window."
                               : "Talk with Ollama now: just talk, no wake word. Right-click for its window and settings.")
            .contextMenu {
                Button("Open AI Listen window") { close(); Windows.show(.assistant) }
                Button("Open Tom's memory") { close(); Windows.show(.memory) }
                Button(assistant.alwaysListen ? "Stop listening for “\(Assistant.wakeWords[0][0])”" : "Always listen for “\(Assistant.wakeWords[0][0])”") {
                    assistant.setAlwaysListen(!assistant.alwaysListen)
                }
                Toggle("Wave at the camera to start it (with Listen on)", isOn: Binding(get: { assistant.settings.wave }, set: { assistant.setWave($0) }))
                Toggle("\(Team.teammate), a second assistant", isOn: Binding(get: { board.isOn(Skills.team) }, set: { board.set(Skills.team, on: $0) }))
                Toggle("Talk over it to stop it (barge in)", isOn: Binding(get: { assistant.settings.bargeIn }, set: { v in assistant.change { $0.bargeIn = v } }))
                Toggle("Let the model think (slower)", isOn: Binding(get: { assistant.settings.thinking }, set: { assistant.setThinking($0) }))
            }
            ToolTile(title: "AI library", detail: chats == 0 ? "No chats yet" : counted(chats, "chat"), symbol: "bubble.left.and.text.bubble.right.fill", colors: [Palette.blue, Palette.violet]) {
                close(); Windows.show(.chats)
            }
        }
    }

    // MARK: Models

    /// Which of Ollama's models Tom talks with, and Jerry (when he's on).
    private var models: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Models")
                Spacer()
                if assistant.models.isEmpty {
                    Text("None from Ollama yet").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button { assistant.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Ask Ollama again which models it has")
            }
            modelRow(Assistant.name, selection: Binding(get: { assistant.settings.model }, set: { m in assistant.change { $0.model = m } }),
                     shown: assistant.modelName, same: nil)
            if board.isOn(Skills.team) {
                modelRow(Team.teammate, selection: Binding(get: { assistant.settings.jerryModel }, set: { m in assistant.change { $0.jerryModel = m } }),
                         shown: assistant.jerryModelName, same: "Same as \(Assistant.name)")
                if assistant.settings.reviewer {
                    modelRow(Team.reviewer, selection: Binding(get: { assistant.settings.janeModel }, set: { m in assistant.change { $0.janeModel = m } }),
                             shown: assistant.janeModelName, same: "Same as \(Team.teammate)")
                }
            }
        }
        .onAppear { if assistant.models.isEmpty { assistant.refreshModels() } }
    }

    /// One assistant's model: a picker when Ollama has answered, else its name.
    private func modelRow(_ who: String, selection: Binding<String>, shown: String, same: String?) -> some View {
        HStack(spacing: 6) {
            Text(who).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            if assistant.models.isEmpty {
                Text(shown).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Picker("", selection: selection) {
                    if let same { Text(same).tag("") }
                    ForEach(assistant.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            Spacer()
        }
    }

    private var kept: Int { library.items.filter { $0.kind != .chat }.count }
    private var chats: Int { library.items.filter { $0.kind == .chat }.count }

    // MARK: Voice

    private var voices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Voice")
                Spacer()
                ModelBadge(name: "Kokoro", state: service.neural.voices)
                ModelBadge(name: "Parakeet", state: service.neural.ears)
            }
            VoicePicker(selected: service.settings.voice) { v in
                service.change { $0.voice = v.id }
                SpeechPlayer.preview(v, speed: service.settings.speed)
            }
            HStack(spacing: 6) {
                Text("Speed").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach([0.8, 1.0, 1.2, 1.5], id: \.self) { s in
                    Button(s == 1 ? "1×" : String(format: "%.1f×", s)) { service.change { $0.speed = s } }
                        .buttonStyle(Chip(selected: abs(service.settings.speed - s) < 0.01))
                }
                Spacer()
            }
        }
    }

    // MARK: Endpoints

    private var endpoints: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Endpoints")
                Spacer()
                Button {
                    copy(service.baseURL, as: "url")
                } label: {
                    Label(copied == "url" ? "Copied" : "Copy URL", systemImage: copied == "url" ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy \(service.baseURL)")
                Button {
                    copy(APIDoc.markdown(port: service.settings.port), as: "docs")
                } label: {
                    Label(copied == "docs" ? "Copied" : "Copy API docs", systemImage: copied == "docs" ? "checkmark" : "doc.text").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy the whole API documentation (API.md), to hand to another app or an assistant writing a client")
                Button {
                    NSWorkspace.shared.open(URL(string: service.baseURL)!)
                } label: {
                    Label("Try it", systemImage: "safari").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(!service.isServing)
                .help("Open the service's page, with a place to try each endpoint")
            }
            ForEach(Endpoint.allCases, id: \.self) { e in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.system(size: 12, weight: .medium))
                        Text(e.routes).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { service.settings.isOn(e) }, set: { service.setEndpoint(e, on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(service.settings.isOn(e) ? "\(e.routes) is on; switch it off and callers get 503 endpoint_off"
                                                       : "\(e.routes) is off: callers get 503 endpoint_off")
                }
                .opacity(service.wantsServing ? 1 : 0.5)
            }
        }
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Allow other devices").font(.system(size: 12, weight: .medium))
                    Text("Listen on the network; callers need the token").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { service.settings.allowNetwork }, set: { on in service.change { $0.allowNetwork = on } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if service.settings.allowNetwork {
                HStack(spacing: 6) {
                    Text("Token").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(service.settings.token).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { copy(service.settings.token, as: "token") } label: { Image(systemName: copied == "token" ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy the token")
                    Button { service.change { $0.token = ServiceSettings.newToken() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Make a new token (the old one stops working)")
                }
            }
        }
    }

    private func copy(_ text: String, as what: String) {
        service.copy(text)
        copied = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == what { copied = nil } }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            UpdateButton()
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { service.opensAtLogin }, set: { service.setOpensAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
        }
    }
}

/// A big colored button for one of the tools.
struct ToolTile: View {
    var title: String
    var detail: String
    var symbol: String
    var colors: [Color]
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(colors[0].opacity(hover ? 0.5 : 0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// The six voices as pills: women on the first row, men on the second.
struct VoicePicker: View {
    var selected: String
    var pick: (Voice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([true, false], id: \.self) { female in
                HStack(spacing: 6) {
                    ForEach(Voice.all.filter { $0.female == female }, id: \.id) { v in
                        Button {
                            pick(v)
                        } label: {
                            HStack(spacing: 4) {
                                Text(v.name)
                                if v.accent == "uk" { Text("UK").font(.system(size: 8, weight: .bold)).opacity(0.6) }
                            }
                        }
                        .buttonStyle(Chip(selected: v.id == selected, tint: female ? Palette.pink : Palette.blue))
                        .help("\(v.label). Click to hear it.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct ModelBadge: View {
    var name: String
    var state: ModelState

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var label: String {
        if case .downloading(let p) = state, let p { return "\(name) \(Int(p * 100))%" }
        return name
    }

    private var color: Color {
        switch state {
        case .ready: return Palette.green
        case .loading, .downloading: return .orange
        case .failed: return Palette.red
        case .notLoaded: return .gray
        }
    }

    private var help: String {
        switch state {
        case .ready: return "\(name) is ready"
        case .loading: return "Loading \(name)…"
        case .downloading: return "Downloading \(name) (the first time only)…"
        case .failed(let why): return "\(name) couldn't load: \(why)"
        case .notLoaded: return "\(name) loads on first use"
        }
    }
}

/// "1 word", "3 words".
func counted(_ n: Int, _ thing: String) -> String {
    "\(n) \(thing)\(n == 1 ? "" : "s")"
}

struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
    }
}

enum Palette {
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.84)
    static let violet = Color(red: 0.58, green: 0.36, blue: 0.86)
    static let pink = Color(red: 0.93, green: 0.33, blue: 0.55)
    static let orange = Color(red: 0.98, green: 0.58, blue: 0.24)
    static let teal = Color(red: 0.18, green: 0.70, blue: 0.72)
    static let blue = Color(red: 0.23, green: 0.52, blue: 0.95)
    static let green = Color(red: 0.20, green: 0.72, blue: 0.42)
    static let red = Color(red: 0.90, green: 0.30, blue: 0.26)
}

/// A small rounded selectable button.
struct Chip: ButtonStyle {
    var selected: Bool
    var tint: Color = Palette.indigo

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? tint : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
    }
}

/// A capsule button, filled or outlined.
struct PillButton: ButtonStyle {
    var tint: Color
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(Capsule().fill(filled ? tint : Color.primary.opacity(0.07)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Everything the panel holds: the first column, and the skills' columns beside it when they're
/// wanted (AI Listen on, or pinned). Reports its size, so the panel fits it as columns come and go.
struct PanelRoot: View {
    @ObservedObject var board = SkillsModel.shared
    @ObservedObject var assistant = AssistantModel.shared
    var close: () -> Void
    var resized: (CGSize) -> Void
    /// The first column's height, which the others take (nil until it's measured).
    @State private var height: CGFloat?

    static let boardWidth: CGFloat = 380

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            PanelView(close: close)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FirstColumnHeight.self, value: g.size.height)
                })
            if board.showsColumns {
                Divider()
                SkillsColumn().frame(width: Self.boardWidth, height: height)
                Divider()
                ActivityColumn().frame(width: Self.boardWidth, height: height)
                if board.showsDetail {
                    Divider()
                    UseDetailColumn().frame(width: Self.boardWidth, height: height)
                }
            }
        }
        .fixedSize()
        .onContinuousHover { _ in Main.delegate.noteActivity() }      // looking around counts as activity
        .onPreferenceChange(FirstColumnHeight.self) { height = $0 > 0 ? $0 : nil }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { resized(g.size) }
                .onChange(of: g.size) { _, size in resized(size) }
        })
    }
}

private struct FirstColumnHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

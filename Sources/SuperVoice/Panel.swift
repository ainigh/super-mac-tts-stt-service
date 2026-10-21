import AppKit
import SwiftUI
import VoiceCore

/// What drops down from the menu bar icon: whether it's serving, the tools, the voice, each
/// endpoint's switch, and the bottom bar.
struct PanelView: View {
    @EnvironmentObject var service: Service
    @ObservedObject var board = BoardModel.shared
    @ObservedObject var assistant = AssistantModel.shared
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tools
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
                board.setListening(!board.listening)
            } label: {
                Label("Listen", systemImage: board.listening ? "ear.fill" : "ear")
            }
            .buttonStyle(PillButton(tint: Palette.pink, filled: board.listening))
            .help(board.listening ? "Always listening: say “mouse”, then talk, and it goes in the board's note; say “Micky”, then talk, to talk with Ollama. Click to stop."
                                  : "Always listen: say “mouse”, then talk, and it goes in the board's note; say “Micky”, then talk, to talk with Ollama")
            if !board.listening {
                Button {
                    board.pinned.toggle()
                } label: {
                    Image(systemName: board.pinned ? "sidebar.right" : "rectangle.split.3x1")
                }
                .buttonStyle(PillButton(tint: Palette.violet, filled: board.pinned))
                .help(board.pinned ? "Hide the board" : "Show the board (voice commands, the note)")
            }
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
            ToolTile(title: "Library", detail: "\(Library.shared.items.filter { $0.kind != .chat }.count) saved", symbol: "square.grid.2x2.fill", colors: [Palette.green, Palette.teal]) {
                close(); Windows.show(.library)
            }
            ToolTile(title: "AI listen", detail: assistant.on ? "On: just talk (click to stop)" : "Talk with Ollama", symbol: assistant.on ? "stop.fill" : "sparkles",
                     colors: [Palette.violet, Palette.pink]) {
                // Talk right away, no wake word, and no window: the chat works without it (AI library shows it).
                close(); assistant.toggleTalking()
            }
            .help(assistant.on ? "Stop talking with Ollama (the chat stays in the AI library). Right-click for its window."
                               : "Talk with Ollama now: just talk, no wake word. Right-click for its window and settings.")
            .contextMenu {
                Button("Open AI Listen window") { close(); Windows.show(.assistant) }
                Button(assistant.on ? "Stop" : "Start, listening for “\(Assistant.name)”") { close(); assistant.toggle() }
            }
            ToolTile(title: "AI library", detail: "\(Library.shared.items.filter { $0.kind == .chat }.count) chats", symbol: "bubble.left.and.text.bubble.right.fill", colors: [Palette.blue, Palette.violet]) {
                close(); Windows.show(.chats)
            }
        }
    }

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
                    service.copy(service.baseURL)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy \(service.baseURL)")
                Button {
                    service.copy(APIDoc.markdown(port: service.settings.port))
                } label: {
                    Label("Copy API docs", systemImage: "doc.text").font(.system(size: 11))
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
                    Button { service.copy(service.settings.token) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy the token")
                    Button { service.change { $0.token = ServiceSettings.newToken() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Make a new token (the old one stops working)")
                }
            }
        }
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

/// Everything the panel holds: the first column, and the board's columns beside it when they're
/// wanted. Reports its size, so the panel fits it as columns come and go.
struct PanelRoot: View {
    @ObservedObject var board = BoardModel.shared
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
                CommandsColumn().frame(width: Self.boardWidth, height: height)
                Divider()
                EntriesColumn().frame(width: Self.boardWidth, height: height)
                if board.showsOptions {
                    Divider()
                    OptionsColumn().frame(width: Self.boardWidth, height: height)
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

import AppKit
import SwiftUI
import VoiceCore

/// Column 2: the voice commands, the subtitles of the note. Said first, one files what follows
/// under it; anything else goes under "search". Click one to see what's under it.
struct CommandsColumn: View {
    @ObservedObject var board = BoardModel.shared
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Voice commands")
            Text("Say one of these first and what follows goes in the note under it. Anything else goes under search, and is searched with.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Add a word", text: $newWord)
                    .textFieldStyle(.plain)
                    .onSubmit(addWord)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Button(action: addWord) { Image(systemName: "plus.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.violet)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(board.subtitles, id: \.self) { word in
                        let search = word == Board.searchSubtitle
                        CommandRow(word: word, count: board.count(word), active: isActive(word),
                                   symbol: search ? "magnifyingglass" : "text.bubble.fill",
                                   select: { board.selectedSubtitle = board.selectedSubtitle == word ? nil : word },
                                   remove: search ? nil : { board.removeCommand(word) })
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                SectionTitle("Always there")
                Hint(word: Board.wakeWord, does: "opens or closes this panel; then just talk")
                Hint(word: "open · copy · no", does: "answer what was just added")
            }
            Toggle("Sounds", isOn: $board.sounds).toggleStyle(.checkbox).font(.system(size: 11))
        }
        .padding(16)
    }

    private func isActive(_ word: String) -> Bool {
        if let t = board.typed { return t.subtitle == word }
        if let a = board.added { return a.heard.subtitle == word }
        return board.selectedSubtitle == word
    }

    private func addWord() {
        board.addCommand(newWord)
        newWord = ""
    }
}

private struct CommandRow: View {
    var word: String
    var count: Int
    var active: Bool
    var symbol: String
    var select: () -> Void
    /// nil: it can't be removed.
    var remove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(active ? .white : Palette.violet)
            Text(word).font(.system(size: 13, weight: .semibold)).foregroundStyle(active ? .white : .primary)
            Spacer()
            if hover && !active, let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove “\(word)” (what's under it in the note stays)")
            } else {
                Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(active ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(active ? Palette.violet : Color.primary.opacity(hover ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }
}

private struct Hint: View {
    var word: String
    var does: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("“\(word)”").font(.system(size: 11, weight: .semibold))
            Text(does).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Column 3: a box to type in (Return adds it, the same as saying it), what was just added, and
/// then what a search found in the note, or the note's lines.
struct EntriesColumn: View {
    @ObservedObject var board = BoardModel.shared
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title)
                Spacer()
                if let subtitle = board.selectedSubtitle, board.added == nil {
                    Button { board.selectedSubtitle = nil } label: {
                        HStack(spacing: 3) { Text(subtitle); Image(systemName: "xmark") }
                    }
                    .buttonStyle(Chip(selected: true, tint: Palette.violet))
                }
            }
            typeCard
            if board.listening, !board.hearing.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(Palette.pink)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text(board.hearing).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let notice = board.notice {
                Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
            }
            if let a = board.added {
                LineRow(hit: Board.Hit(spot: a.spot, subtitle: a.heard.subtitle, line: a.line, sentence: a.line),
                        badge: "JUST ADDED", tint: Palette.violet,
                        open: { board.openTop() }, copy: { board.copyText(a.line) }, delete: { board.no() })
            }
            let results = board.results
            if results.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(results.prefix(200).enumerated()), id: \.element) { i, hit in
                        LineRow(hit: hit, badge: searching && i == 0 ? "TOP MATCH" : nil, tint: Palette.green,
                                open: { board.open(hit) }, copy: { board.copyText(hit.sentence) }, delete: { board.delete(hit) })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var searching: Bool { board.added?.heard.isSearch == true }

    private var title: String {
        if let a = board.added { return a.heard.isSearch ? "Matches" : "Under \(a.heard.subtitle)" }
        return board.selectedSubtitle.map { "Under \($0)" } ?? "The note"
    }

    private var empty: String {
        if searching { return "Nothing else in the note matches." }
        if board.added != nil { return "Nothing else under it yet." }
        return board.listening ? "Nothing here yet. Say “mouse”, then talk, or type above." : "Nothing here yet. Type above."
    }

    /// The box: what's typed, with the subtitle it'll go under.
    private var typeCard: some View {
        let t = board.typed
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(t?.subtitle ?? Board.searchSubtitle)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(t == nil ? Color.secondary.opacity(0.5) : Palette.violet))
                Text(t == nil ? (board.listening ? "Listening: talk, or type" : "Type, then Return")
                              : "Return adds it to the note")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            TextField("Say or type", text: $board.entry, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1...5)
                .focused($typing)
                .onSubmit { board.take(board.entry) }
                .onExitCommand { board.entry = "" }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.violet.opacity(t == nil ? 0.04 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Palette.violet.opacity(t == nil ? 0.2 : 0.7), style: StrokeStyle(lineWidth: 1.5, dash: t == nil ? [5, 4] : [])))
    }
}

/// A line of the note (or the sentence of it that matched), with its subtitle.
private struct LineRow: View {
    var hit: Board.Hit
    var badge: String?
    var tint: Color
    var open: () -> Void
    var copy: () -> Void
    var delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.subtitle.isEmpty ? "note" : hit.subtitle)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.violet)
                    if let badge { Text(badge).font(.system(size: 9, weight: .bold)).foregroundStyle(tint) }
                    kindBadge
                    Spacer()
                }
                Text(hit.sentence).font(.system(size: 13)).lineLimit(3)
            }
            if hover {
                VStack(spacing: 6) {
                    Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                    Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Take it out of the note")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(badge != nil ? tint.opacity(0.1) : Color.primary.opacity(hover ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(badge != nil ? tint.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .help(help)
    }

    @ViewBuilder private var kindBadge: some View {
        switch Board.action(for: hit.line) {
        case .browse: Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Palette.blue)
        case .http(let method, _, _): Text(method).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Palette.orange)
        case .show: EmptyView()
        }
    }

    private var help: String {
        switch Board.action(for: hit.line) {
        case .browse: return "Click to open in your browser"
        case .http(let method, let url, _): return "Click to call \(method) \(url.absoluteString)"
        case .show: return "Click to open the note here"
        }
    }
}

/// Column 4: the options for what was just added, or what was opened.
struct OptionsColumn: View {
    @ObservedObject var board = BoardModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let opened = board.opened {
                OpenedView(opened: opened)
            } else if let a = board.added {
                options(a)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func options(_ a: BoardModel.Added) -> some View {
        let top = board.hits.first
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("What now?")
            OptionButton(option: .open, title: "Open", detail: top.map { describe($0) } ?? "The note, where this went",
                         symbol: "arrow.up.forward.app.fill", tint: Palette.blue)
            OptionButton(option: .copy, title: "Copy", detail: top.map { "The top match: \(String($0.sentence.prefix(60)))" } ?? "What you said",
                         symbol: "doc.on.doc.fill", tint: Palette.teal)
            OptionButton(option: .no, title: "No", detail: "Take it back out of the note", symbol: "arrow.uturn.backward.circle.fill",
                         tint: .secondary)
            Text(board.listening ? "Say the option, or click it. Or just keep talking." : "Click an option.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func describe(_ hit: Board.Hit) -> String {
        switch Board.action(for: hit.line) {
        case .browse(let url): return "Open \(url.host ?? "the link") in your browser"
        case .http(let method, let url, _): return "Call \(method) \(url.host ?? "")\(url.path)"
        case .show: return "The note, at the top match: \(String(hit.sentence.prefix(60)))"
        }
    }
}

private struct OptionButton: View {
    @ObservedObject var board = BoardModel.shared
    var option: Board.Option
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    @State private var hover = false

    var body: some View {
        Button { board.choose(option) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text("say “\(option.rawValue)”").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(hover ? 0.16 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The note, scrolled to where it matched (with Copy), or the answer to a GET / POST.
private struct OpenedView: View {
    @ObservedObject var board = BoardModel.shared
    @EnvironmentObject var service: Service
    var opened: BoardModel.Opened

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(heading)
                Spacer()
                Button { board.opened = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            switch opened {
            case .note(let focus):
                NoteView(note: board.note, focus: focus)
                HStack(spacing: 8) {
                    Button(focus == nil ? "Copy all" : "Copy") { board.copyText(focus?.sentence ?? board.note.text) }
                        .buttonStyle(PillButton(tint: Palette.teal, filled: true))
                    Button("Read aloud") { service.reader.say(focus?.line ?? board.note.text, voice: service.voice, speed: service.settings.speed) }
                        .buttonStyle(PillButton(tint: .secondary, filled: false))
                    Spacer()
                }
            case .http(let call):
                Text(call.request).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                HStack(spacing: 6) {
                    if call.running {
                        ProgressView().controlSize(.small)
                        Text("Calling…").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let error = call.error {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.red)
                        Text(error).font(.system(size: 12))
                    } else if let status = call.status {
                        Circle().fill((200..<300).contains(status) ? Palette.green : Palette.orange).frame(width: 8, height: 8)
                        Text("HTTP \(status)").font(.system(size: 12, weight: .semibold))
                    }
                }
                ScrollView {
                    Text(call.response.isEmpty && !call.running ? "(no body)" : call.response)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Button("Copy") { board.copyText(call.response) }
                        .buttonStyle(PillButton(tint: Palette.teal, filled: true))
                        .disabled(call.response.isEmpty)
                    Spacer()
                }
            }
        }
    }

    private var heading: String {
        switch opened {
        case .note: return Board.noteTitle
        case .http(let call): return call.method
        }
    }
}

/// The whole note, subtitle by subtitle, scrolled to the focused line with its sentence picked out.
private struct NoteView: View {
    var note: Board.Note
    var focus: Board.Hit?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(note.sections.enumerated()), id: \.offset) { s, section in
                        if !section.subtitle.isEmpty {
                            Text(section.subtitle)
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.violet)
                                .padding(.top, s == 0 ? 0 : 10)
                        }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { l, line in
                            let spot = Board.Note.Spot(section: s, line: l)
                            Text(text(line, focused: focus?.spot == spot))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(focus?.spot == spot ? Palette.orange.opacity(0.12) : .clear))
                                .id(spot)
                        }
                    }
                }
            }
            .onAppear { scroll(proxy) }
            .onChange(of: focus) { _, _ in scroll(proxy) }
        }
    }

    /// The line, with the sentence that matched picked out.
    private func text(_ line: String, focused: Bool) -> AttributedString {
        var a = AttributedString(line)
        if focused, let sentence = focus?.sentence, sentence != line, let r = a.range(of: sentence) {
            a[r].backgroundColor = Palette.orange.opacity(0.35)
        }
        return a
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let spot = focus?.spot else { return }
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(spot, anchor: .center) } }
    }
}

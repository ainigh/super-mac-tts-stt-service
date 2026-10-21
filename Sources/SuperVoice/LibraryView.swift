import AppKit
import SwiftUI
import VoiceCore

/// Everything kept, in a grid: search it, filter it, open one to edit it, hear it read back, copy
/// it, save it as a file or delete it.
struct LibraryView: View {
    /// Which item is open; set from elsewhere to open one.
    final class Selection: ObservableObject {
        static let shared = Selection()
        @Published var id: UUID?
    }

    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var selection = Selection.shared
    @State private var query = ""
    @State private var kind: LibraryRecord.Kind?
    @State private var starredOnly = false
    @State private var confirmDelete: LibraryRecord?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                filters
                if let problem = library.problem { Notice(text: problem) }
                if shown.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 14)], spacing: 14) {
                            ForEach(shown) { item in
                                Card(item: item, selected: item.id == selection.id)
                                    .onTapGesture { selection.id = item.id == selection.id ? nil : item.id }
                                    .contextMenu { menu(item) }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let id = selection.id, let item = library.item(id) {
                Divider()
                Detail(item: item, close: { selection.id = nil }, delete: { confirmDelete = item })
                    .frame(width: 400)
                    .id(item.id)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection.id)
        .confirmationDialog("Delete \(confirmDelete?.title ?? "")?", isPresented: Binding(get: { confirmDelete != nil },
                                                                                         set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = confirmDelete {
                    if selection.id == item.id { selection.id = nil }
                    library.delete(item.id)
                }
                confirmDelete = nil
            }
        } message: {
            Text("It can't be brought back.")
        }
    }

    private var shown: [LibraryRecord] {
        library.filter(kind: kind, query: query, starredOnly: starredOnly).filter { $0.kind != .chat }
    }

    private var kept: Int { library.items.filter { $0.kind != .chat }.count }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [Palette.green, Palette.teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Library").font(.system(size: 18, weight: .semibold))
                Text("\(kept) kept · dictations, transcripts and notes").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Windows.show(.chats) } label: { Label("AI library", systemImage: "sparkles") }
                .buttonStyle(PillButton(tint: Palette.violet, filled: false))
                .help("The chats with the assistant")
            Button { Windows.show(.dictate) } label: { Label("Dictate", systemImage: "mic.fill") }
                .buttonStyle(PillButton(tint: Palette.pink, filled: true))
            Button { Windows.show(.transcribe) } label: { Label("Transcribe", systemImage: "waveform.badge.plus") }
                .buttonStyle(PillButton(tint: Palette.teal, filled: true))
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .frame(maxWidth: 260)
            Button("All") { kind = nil }.buttonStyle(Chip(selected: kind == nil))
            ForEach(LibraryRecord.Kind.library, id: \.self) { k in
                Button(k.title + "s") { kind = k }.buttonStyle(Chip(selected: kind == k, tint: Card.color(k)))
            }
            Button { starredOnly.toggle() } label: { Image(systemName: starredOnly ? "star.fill" : "star") }
                .buttonStyle(Chip(selected: starredOnly, tint: .orange))
                .help("Only starred")
            Spacer()
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: kept == 0 ? "tray" : "magnifyingglass")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(kept == 0 ? "Nothing kept yet" : "Nothing matches").font(.system(size: 15, weight: .medium))
            Text(kept == 0 ? "Dictations, transcripts and notes you keep show up here." : "Try other words, or All.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func menu(_ item: LibraryRecord) -> some View {
        Button("Open") { selection.id = item.id }
        Button("Read aloud") { service.reader.say(item.text, voice: service.voice, speed: service.settings.speed) }
        Button("Copy") { service.copy(item.text) }
        Button(item.starred ? "Unstar" : "Star") {
            var i = item
            i.starred.toggle()
            library.save(i)
        }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = item }
    }
}

/// One item in the grid.
private struct Card: View {
    var item: LibraryRecord
    var selected: Bool
    @State private var hover = false

    static func color(_ k: LibraryRecord.Kind) -> Color {
        switch k {
        case .dictation: return Palette.pink
        case .transcript: return Palette.teal
        case .note: return Palette.indigo
        case .chat: return Palette.violet
        }
    }

    static func symbol(_ k: LibraryRecord.Kind) -> String {
        switch k {
        case .dictation: return "mic.fill"
        case .transcript: return "waveform"
        case .note: return "text.alignleft"
        case .chat: return "sparkles"
        }
    }

    var body: some View {
        let tint = Self.color(item.kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(item.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.kind.title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint).kerning(0.5)
                if let tag = item.tag { Text("#\(tag)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.violet) }
                Spacer()
                if item.starred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Text(item.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(Files.dated.string(from: item.created))
                Spacer()
                if let d = item.duration { Text(Captions.clock(d)) }
                Text("\(item.wordCount) words")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(height: 178)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover || selected ? 0.08 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? tint : tint.opacity(hover ? 0.4 : 0.12), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// An open item: edit its title and text, hear it, copy it, save it as a file, delete it.
private struct Detail: View {
    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var reader = Service.shared.reader
    @State var item: LibraryRecord
    var close: () -> Void
    var delete: () -> Void
    @State private var note: String?
    /// The item as the library last had it: what's edited here is what differs from it.
    @State private var saved: LibraryRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.kind.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Card.color(item.kind)).kerning(0.5)
                Spacer()
                Button { item.starred.toggle(); save() } label: {
                    Image(systemName: item.starred ? "star.fill" : "star").foregroundStyle(item.starred ? .orange : .secondary)
                }
                .buttonStyle(.borderless).help(item.starred ? "Unstar" : "Star")
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: [])
            }
            TextField("Title", text: $item.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .onSubmit(save)
            Text(meta).font(.system(size: 11)).foregroundStyle(.secondary)
            if reader.speaking { NowReading(reader: reader) }
            TextEditor(text: $item.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                if reader.speaking {
                    Button(reader.paused ? "Resume" : "Pause") { reader.paused ? reader.resume() : reader.pause() }
                        .buttonStyle(PillButton(tint: Palette.indigo, filled: true))
                    Button("Stop") { reader.stop() }.buttonStyle(PillButton(tint: .secondary, filled: false))
                } else {
                    Button { reader.say(item.text, voice: service.voice, speed: service.settings.speed) } label: {
                        Label("Read back", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButton(tint: Palette.indigo, filled: true))
                }
                Button("Copy") {
                    service.copy(item.text)
                    flash("Copied")
                }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                Menu("Save as") {
                    Button("Text (.txt)") { Files.save(item.text, name: item.title, ext: "txt") }
                    if let segments = item.segments, !segments.isEmpty {
                        Button("Subtitles (.srt)") { Files.save(Captions.srt(segments), name: item.title, ext: "srt") }
                        Button("Subtitles (.vtt)") { Files.save(Captions.vtt(segments), name: item.title, ext: "vtt") }
                    }
                }
                .fixedSize()
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button { delete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .onChange(of: item.text) { _, _ in saveSoon() }
        .onChange(of: item.title) { _, _ in saveSoon() }
        .onDisappear(perform: save)
        .onAppear { saved = item }
        .onReceive(library.$items) { items in
            // Changed elsewhere (the board adds to its note): taken in, unless it's being edited here.
            guard let fresh = items.first(where: { $0.id == item.id }), let was = saved, fresh != was else { return }
            if item == was { item = fresh }
            saved = fresh
        }
    }

    private var meta: String {
        var parts = [Files.dated.string(from: item.created)]
        if let d = item.duration { parts.append(Captions.clock(d)) }
        if let s = item.source { parts.append(s) }
        parts.append("\(item.wordCount) words")
        return parts.joined(separator: " · ")
    }

    @State private var pending: DispatchWorkItem?

    /// Edits are saved a moment after typing stops.
    private func saveSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { save() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func save() {
        // Deleted (closing it saves on the way out): not brought back.
        guard let current = library.item(item.id), current != item else { return }
        if item.title.trimmingCharacters(in: .whitespaces).isEmpty { item.title = LibraryRecord.title(for: item.text) }
        library.save(item)
        if let fresh = library.item(item.id) {      // its new modified date
            item = fresh
            saved = fresh
        }
    }

    private func flash(_ s: String) {
        note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if note == s { note = nil } }
    }
}

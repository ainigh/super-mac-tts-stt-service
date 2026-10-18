import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

/// Transcribes audio files one after another, saving each to the library when it's done. Keeps
/// going when its window is closed. On the main thread.
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    struct Job: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var queue: [Job] = []
    @Published private(set) var current: Job?
    @Published private(set) var segments: [TimedText] = []
    @Published private(set) var progress = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var started: Date?
    /// The last one finished: its library item.
    @Published private(set) var finished: LibraryRecord?
    @Published var problem: String?

    private var task: Task<Void, Never>?

    func add(_ urls: [URL]) {
        queue += urls.map { Job(url: $0) }
        next()
    }

    func cancel() {
        task?.cancel()
    }

    func remove(_ job: Job) {
        queue.removeAll { $0.id == job.id }
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        segments = []
        progress = 0
        duration = 0
        problem = nil
        started = Date()
        let engine = Service.shared.engine!
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let access = job.url.startAccessingSecurityScopedResource()
            defer { if access { job.url.stopAccessingSecurityScopedResource() } }
            do {
                let reader = try FileAudioReader(url: job.url)
                await MainActor.run { self?.duration = reader.duration }
                let segments = try await LongTranscriber().run(reader, engine: engine) { event in
                    await MainActor.run {
                        switch event {
                        case .progress(let done, let total): self?.progress = total > 0 ? done / total : 0
                        case .segment(let s): self?.segments.append(s)
                        }
                    }
                }
                await MainActor.run { self?.done(job, segments: segments, duration: reader.duration) }
            } catch is CancellationError {
                await MainActor.run { self?.failed(nil) }
            } catch {
                let message = (error as? AudioError).map { _ in "Couldn't read \(job.name) as audio" } ?? error.localizedDescription
                await MainActor.run { self?.failed(message) }
            }
        }
    }

    private func done(_ job: Job, segments: [TimedText], duration: Double) {
        let text = Captions.plain(segments)
        let title = (job.name as NSString).deletingPathExtension
        let item = LibraryRecord(kind: .transcript, text: text.isEmpty ? "(no speech)" : text, title: title,
                               duration: duration, source: job.name, segments: segments)
        Library.shared.add(item)
        finished = item
        current = nil
        task = nil
        next()
    }

    private func failed(_ message: String?) {
        problem = message ?? "Stopped"
        current = nil
        task = nil
        next()
    }
}

/// Drop audio files (or choose them) and get their text, saved to the library.
struct TranscribeView: View {
    @EnvironmentObject var service: Service
    @ObservedObject var job = Transcriber.shared
    @State private var dropping = false

    static let types: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

    var body: some View {
        Page(title: "Transcribe", subtitle: "Audio or video files to text, on this Mac",
             symbol: "waveform.badge.plus", colors: [Palette.teal, Palette.blue]) {
            if let status = Neural.status(service.neural.ears, what: "speech recognition") {
                Notice(text: status, tint: .blue, symbol: "arrow.down.circle")
            }
            if let problem = job.problem, job.current == nil { Notice(text: problem) }
            if let current = job.current {
                working(current)
            } else {
                dropZone
            }
            if !job.queue.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Next")
                    ForEach(job.queue) { j in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(j.name).font(.system(size: 12))
                            Spacer()
                            Button { job.remove(j) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let item = job.finished, job.current == nil { finished(item) }
            Spacer(minLength: 0)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { job.add([url]) } }
                }
            }
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.teal)
            Text("Drop audio or video files here").font(.system(size: 15, weight: .medium))
            Text("mp3, m4a, wav, aiff, flac, mp4, mov…").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Choose files…") { choose() }
                .buttonStyle(PillButton(tint: Palette.teal, filled: true))
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Palette.teal.opacity(dropping ? 0.14 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Palette.teal.opacity(dropping ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }

    private func working(_ current: Transcriber.Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Palette.teal)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(current.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(Int(job.progress * 100))% of \(Captions.clock(job.duration))")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Button("Stop") { job.cancel() }.buttonStyle(PillButton(tint: .secondary, filled: false))
            }
            ProgressView(value: job.progress).tint(Palette.teal)
            Lines(segments: job.segments)
        }
    }

    private func finished(_ item: LibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                Text("\(item.title): saved to the library").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("Open") { Windows.showItem(item.id) }.buttonStyle(PillButton(tint: Palette.teal, filled: true))
                Button("Copy") { service.copy(item.text) }.buttonStyle(PillButton(tint: .secondary, filled: false))
                Menu("Save as") {
                    Button("Text (.txt)") { Files.save(item.text, name: item.title, ext: "txt") }
                    Button("Subtitles (.srt)") { Files.save(Captions.srt(item.segments ?? []), name: item.title, ext: "srt") }
                    Button("Subtitles (.vtt)") { Files.save(Captions.vtt(item.segments ?? []), name: item.title, ext: "vtt") }
                }
                .fixedSize()
            }
            Lines(segments: item.segments ?? [])
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.types
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        job.add(panel.urls)
    }
}

/// Timed lines, newest at the bottom, following along as they come in.
struct Lines: View {
    var segments: [TimedText]

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Captions.clock(s.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                            Text(s.text).font(.system(size: 14)).textSelection(.enabled)
                        }
                        .id(i)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: segments.count) { _, n in
                if n > 0 { withAnimation { scroll.scrollTo(n - 1, anchor: .bottom) } }
            }
        }
    }
}

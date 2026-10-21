import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

/// Paste or type text and hear it, with the word being said lit up. Keep it in the library, or
/// save the audio.
struct ReadAloudView: View {
    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var reader = Service.shared.reader
    @AppStorage("readText") private var text = ""
    @State private var saving = false
    @State private var note: String?

    var body: some View {
        Page(title: "Read Aloud", subtitle: "Text to speech, with \(service.voice.name)'s voice",
             symbol: "speaker.wave.2.fill", colors: [Palette.indigo, Palette.violet]) {
            VoiceBar()
            if let status = Neural.status(service.neural.voices, what: "the voices") {
                Notice(text: status, tint: .blue, symbol: "arrow.down.circle")
            }
            if let problem = reader.problem { Notice(text: problem) }
            if reader.speaking { NowReading(reader: reader) }
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type or paste something to hear it…").foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                if reader.speaking {
                    Button(reader.paused ? "Resume" : "Pause") { reader.paused ? reader.resume() : reader.pause() }
                        .buttonStyle(PillButton(tint: Palette.indigo, filled: true))
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Pause or resume (⌘.)")
                    Button("Stop") { reader.stop() }
                        .buttonStyle(PillButton(tint: .secondary, filled: false))
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Read") { read(text) }
                        .buttonStyle(PillButton(tint: Palette.indigo, filled: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Paste & read") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            text = s
                            read(s)
                        }
                    }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                }
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button("Keep in library") {
                    library.add(LibraryRecord(kind: .note, text: text))
                    flash("Kept in the library")
                }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                .keyboardShortcut("s", modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(saving ? "Saving…" : "Save audio…") { saveAudio() }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func read(_ s: String) {
        reader.say(s, voice: service.voice, speed: service.settings.speed)
    }

    private func flash(_ s: String) {
        note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if note == s { note = nil } }
    }

    /// Writes the speech to a .wav the user picks.
    private func saveAudio() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LibraryRecord.title(for: text, words: 5) + ".wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saving = true
        let words = text, voice = service.voice, speed = service.settings.speed
        Task.detached {
            var problem: String?
            do {
                var samples: [Float] = []
                for sentence in SpokenText.sentences(words) {
                    samples += try await Neural.shared.speak(sentence, voice: voice, speed: speed)
                }
                try PCM.wav(samples, rate: PCM.speakRate).write(to: url, options: .atomic)
            } catch {
                problem = error.localizedDescription
            }
            let outcome = problem.map { "Couldn't save: \($0)" } ?? "Saved \(url.lastPathComponent)"
            await MainActor.run {
                saving = false
                flash(outcome)
            }
        }
    }
}

/// The sentence being read, with the word being said lit up.
struct NowReading: View {
    @ObservedObject var reader: SpeechPlayer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: reader.paused ? "pause.circle.fill" : "waveform")
                .foregroundStyle(Palette.indigo)
                .symbolEffect(.variableColor.iterative, isActive: !reader.paused)
            Text(lit).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Palette.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var lit: AttributedString {
        var s = AttributedString(reader.current)
        if let word = reader.word, let r = Range(word, in: reader.current),
           let lower = AttributedString.Index(r.lowerBound, within: s),
           let upper = AttributedString.Index(r.upperBound, within: s) {
            s[lower..<upper].backgroundColor = Palette.indigo.opacity(0.28)
            s[lower..<upper].font = .system(size: 15, weight: .semibold)
        }
        return s
    }
}

import Foundation
import VoiceCore

/// Super Face, the mouth and the face (a 3D avatar on the desktop, its own app): whether it's
/// running, asked every few seconds. While it is, what AI Listen and /api/say say goes through it
/// (unless that's switched off in the panel), and each phrase heard is checked with it first: was
/// that the avatar's own voice? When it isn't running, the Mac's own Kokoro voice speaks, as before.
/// On the main thread.
final class FaceLink: ObservableObject {
    static let shared = FaceLink()

    @Published private(set) var up = false
    private(set) var client = FaceClient()
    private var url = FaceClient.defaultURL
    private var timer: Timer?
    private var asking = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// What's said goes through the face: it's running, and that's wanted.
    var speaks: Bool { up && Service.shared.settings.speakThroughFace }

    /// Asks whether it's running (and follows a change of address).
    func refresh() {
        let address = Service.shared.settings.face
        if address != url {
            url = address
            client = FaceClient(baseURL: address)
        }
        guard !asking else { return }
        asking = true
        let c = client
        Task.detached { [weak self] in
            let up = await c.isUp()
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                if self.up != up { self.up = up }
            }
        }
    }

    /// The face is told it may be gone (a call to it failed): asked again now.
    func lost() {
        if up { up = false }
        refresh()
    }

    /// Was `heard` the face's voice coming back? Calls `then` on the main thread with what to act
    /// on: nil for its own voice, else what the user said. Without the face, straight away.
    func screen(_ heard: String, then: @escaping (String?) -> Void) {
        guard up else { return then(heard) }
        let c = client
        // How long the phrase was, near enough: what was said from then on is compared.
        let seconds = Double(heard.split(separator: " ").count) / 2.5 + 1.5
        Task.detached {
            let answer = await c.echo(heard, seconds: seconds)
            DispatchQueue.main.async {
                guard let answer else { return then(heard) }
                if answer.echo { return then(nil) }
                let rest = answer.rest.trimmingCharacters(in: .whitespacesAndNewlines)
                then(rest.isEmpty ? heard : rest)
            }
        }
    }
}

import AVFoundation
import Combine
import Foundation
import Vision
import VoiceCore

/// Watches the camera for a wave: a hand going left and right a few times. With Listen on, a
/// wave starts AI Listen like saying "Tom" does (and while it talks, stops it talking). Frames
/// are looked at about ten times a second with Apple's hand pose detection; nothing is kept or
/// sent anywhere, and the camera is only on while it's wanted (its light says so). On the main
/// thread, but for the frames, which come on their own queue.
final class WaveWatcher: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// A wave was seen (on the main thread).
    var onWave: (() -> Void)?
    @Published private(set) var on = false
    @Published var problem: String?
    /// A hand is in view right now.
    @Published private(set) var seesHand = false

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "SuperVoice.wave", qos: .userInitiated)
    private var configured = false
    private var wanted = false
    private var frame = 0
    /// Where the hand was, lately (seconds, and across the frame, 0 to 1), on the frames' queue.
    private var path: [(t: TimeInterval, x: CGFloat)] = []
    private var lastWave: TimeInterval = 0
    private var lastHand: TimeInterval = 0

    /// How far back a wave is looked for, and how long after a wave the next can be.
    static let window: TimeInterval = 1.6
    static let cooldown: TimeInterval = 2.5

    func start() {
        wanted = true
        guard !on else { return }
        problem = nil
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.wanted, !self.on else { return }
                guard granted else {
                    self.problem = "The camera is off for Super Voice (for waving): turn it on in System Settings → Privacy & Security → Camera, or turn Wave off"
                    return
                }
                self.begin()
            }
        }
    }

    func stop() {
        wanted = false
        guard on else { return }
        on = false
        seesHand = false
        queue.async { [session] in session.stopRunning() }
    }

    private func begin() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video) else {
                problem = "No camera found for waving"
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .vga640x480
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw NSError(domain: "wave", code: 1) }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                problem = "Couldn't open the camera: \(error.localizedDescription)"
                return
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                problem = "Couldn't read the camera"
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            configured = true
        }
        on = true
        queue.async { [weak self] in
            self?.path = []
            self?.session.startRunning()
        }
    }

    // MARK: Frames (on the queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frame += 1
        guard frame % 3 == 0 else { return }               // about ten a second is plenty
        let now = Date().timeIntervalSince1970
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let hand = request.results?.first,
              let x = Self.centre(of: hand) else {
            if now - lastHand > 0.5 {
                path = []
                setSeesHand(false)
            }
            return
        }
        lastHand = now
        setSeesHand(true)
        path.append((now, x))
        path.removeAll { now - $0.t > Self.window }
        if now - lastWave > Self.cooldown, Waving.isWave(path.map { Double($0.x) }) {
            lastWave = now
            path = []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.on else { return }
                self.onWave?()
            }
        }
    }

    /// Where the hand is, left to right (0 to 1): the mean of its fingertips and palm points
    /// that are seen clearly; nil when the hand isn't.
    static func centre(of hand: VNHumanHandPoseObservation) -> CGFloat? {
        guard let points = try? hand.recognizedPoints(.all) else { return nil }
        let sure = points.values.filter { $0.confidence > 0.3 }
        guard sure.count >= 5 else { return nil }
        return sure.map(\.location.x).reduce(0, +) / CGFloat(sure.count)
    }

    private func setSeesHand(_ sees: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.seesHand != sees else { return }
            self.seesHand = sees
        }
    }
}

// swift-tools-version:5.9
import PackageDescription

// VoiceCore is the service's logic (the HTTP API, voices, audio formats, the library): Foundation
// only, so it's tested on any machine (swift test).
var targets: [Target] = [
    .target(name: "VoiceCore"),
    .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"]),
]
var dependencies: [Package.Dependency] = []
#if os(macOS)
// The menu bar app: SwiftUI + AppKit, so only on the Mac. FluidAudio runs the speech models
// (Kokoro's voices, Parakeet's listening) on the Neural Engine; it needs Swift 6 to build.
dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"))
targets.append(.executableTarget(name: "SuperVoice", dependencies: [
    "VoiceCore",
    .product(name: "FluidAudio", package: "FluidAudio"),
]))
#endif

let package = Package(name: "SuperVoice", platforms: [.macOS(.v14)], dependencies: dependencies, targets: targets)

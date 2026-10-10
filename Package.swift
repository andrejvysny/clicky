// swift-tools-version: 6.2
import PackageDescription

let appTargetSwiftSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
]

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"]),
        .executable(name: "clicky-text", targets: ["ClickyTextCLI"]),
        .executable(name: "clicky-guide", targets: ["ClickyGuideCLI"]),
        .executable(name: "clicky-fake-worker", targets: ["ClickyFakeWorker"]),
        .executable(name: "clicky-local-bench", targets: ["ClickyLocalBench"]),
    ],
    targets: [
        // Mirror the app target's isolation settings: the app compiles these same files with MainActor default isolation.
        .target(name: "ClickyCore", path: "leanring-buddy/TextInput/Core", swiftSettings: appTargetSwiftSettings),
        .executableTarget(name: "ClickyTextCLI", dependencies: ["ClickyCore"], path: "Tools/ClickyTextCLI"),
        .executableTarget(name: "ClickyGuideCLI", dependencies: ["ClickyCore"], path: "Tools/ClickyGuideCLI"),
        .executableTarget(name: "ClickyFakeWorker", dependencies: ["ClickyCore"], path: "Tools/ClickyFakeWorker"),
        .executableTarget(name: "ClickyLocalBench", dependencies: ["ClickyCore"], path: "Tools/ClickyLocalBench"),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore", "ClickyFakeWorker"], path: "Tests/ClickyCoreTests", resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

#if os(macOS)
// The production walkthrough coordinator and observer, compiled from the app's own sources with injected
// native effects, so coordinator tests exercise the shipped code without a signed build or TCC prompts.
package.targets += [
    .target(name: "ClickyGuideNative", dependencies: ["ClickyCore"], path: "leanring-buddy/TextInput",
            exclude: ["Core"],
            sources: ["VisualGuideController.swift", "VisualGuideController+Turns.swift", "VisualGuideController+Freshness.swift", "VisualGuideController+Verification.swift", "VisualGuideController+Interruptions.swift", "VisualGuideController+Correction.swift", "TargetSelectionPanel.swift",
                      "GuideObserver.swift", "GuideEnvironment.swift", "ScopedAccessibility.swift", "WindowSnapshotCapture.swift",
                      "WritingCoordinator.swift", "WritingEnvironment.swift", "WritingClipboard.swift",
                      "QuickAskHotkey.swift", "VoiceAudioRecorder.swift",
                      "Voice/VoiceEnvironment.swift", "Voice/VoiceTypes.swift", "Voice/VoiceDraft.swift", "Voice/VoiceController.swift", "Voice/VoiceController+Session.swift", "Voice/VoiceController+Delivery.swift",
                      "LocalAI/LocalAIEnvironment.swift", "LocalAI/LocalAIRuntime.swift", "LocalAI/LocalAIRuntime+Models.swift", "LocalAI/LocalAIRuntime+Workers.swift", "LocalAI/LocalAIRuntime+Jobs.swift", "LocalAI/LabText.swift"],
            swiftSettings: appTargetSwiftSettings),
    .testTarget(name: "ClickyGuideNativeTests", dependencies: ["ClickyGuideNative", "ClickyCore", "ClickyFakeWorker"], path: "Tests/ClickyGuideNativeTests",
                swiftSettings: appTargetSwiftSettings),
]
#endif

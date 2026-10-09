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
    ],
    targets: [
        // Mirror the app target's isolation settings: the app compiles these same files with MainActor default isolation.
        .target(name: "ClickyCore", path: "leanring-buddy/TextInput/Core", swiftSettings: appTargetSwiftSettings),
        .executableTarget(name: "ClickyTextCLI", dependencies: ["ClickyCore"], path: "Tools/ClickyTextCLI"),
        .executableTarget(name: "ClickyGuideCLI", dependencies: ["ClickyCore"], path: "Tools/ClickyGuideCLI"),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"], path: "Tests/ClickyCoreTests", resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

#if os(macOS)
// The production walkthrough coordinator and observer, compiled from the app's own sources with injected
// native effects, so coordinator tests exercise the shipped code without a signed build or TCC prompts.
package.targets += [
    .target(name: "ClickyGuideNative", dependencies: ["ClickyCore"], path: "leanring-buddy/TextInput",
            exclude: ["Core"],
            sources: ["VisualGuideController.swift", "VisualGuideController+Turns.swift", "VisualGuideController+Freshness.swift", "VisualGuideController+Verification.swift",
                      "GuideObserver.swift", "GuideEnvironment.swift", "ScopedAccessibility.swift", "WindowSnapshotCapture.swift"],
            swiftSettings: appTargetSwiftSettings),
    .testTarget(name: "ClickyGuideNativeTests", dependencies: ["ClickyGuideNative", "ClickyCore"], path: "Tests/ClickyGuideNativeTests",
                swiftSettings: appTargetSwiftSettings),
]
#endif

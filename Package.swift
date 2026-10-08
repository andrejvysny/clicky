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
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"]),
        .executable(name: "clicky-text", targets: ["ClickyTextCLI"]),
    ],
    targets: [
        // Mirror the app target's isolation settings: the app compiles these same files with MainActor default isolation.
        .target(name: "ClickyCore", path: "leanring-buddy/TextInput/Core", swiftSettings: appTargetSwiftSettings),
        .executableTarget(name: "ClickyTextCLI", dependencies: ["ClickyCore"], path: "Tools/ClickyTextCLI"),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"], path: "Tests/ClickyCoreTests", resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"]),
        .executable(name: "clicky-text", targets: ["ClickyTextCLI"]),
    ],
    targets: [
        .target(name: "ClickyCore", path: "leanring-buddy/TextInput/Core"),
        .executableTarget(name: "ClickyTextCLI", dependencies: ["ClickyCore"], path: "Tools/ClickyTextCLI"),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"], path: "Tests/ClickyCoreTests", resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

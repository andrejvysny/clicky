// swift-tools-version: 6.2
import PackageDescription

// Separate package so the app and ClickyCore never link MLX, Core ML ASR or their dependencies.
// Every dependency is pinned exactly; the worker is a reviewed, reproducible binary.
let package = Package(
    name: "ClickyLocalWorker",
    // ClickyCore (root package) requires 14.2; a dependent package may not declare less.
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "clicky-local-worker", targets: ["ClickyLocalWorker"]),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
        // `traits: []` keeps the NemoTextProcessing prebuilt binary out of the linked worker (checked with nm);
        // SwiftPM still fetches that artifact while resolving packages.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "CSandbox", path: "Sources/CSandbox"),
        .executableTarget(
            name: "ClickyLocalWorker",
            dependencies: [
                "CSandbox",
                .product(name: "ClickyCore", package: "clicky"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/ClickyLocalWorker"
        ),
    ],
    swiftLanguageModes: [.v5]
)

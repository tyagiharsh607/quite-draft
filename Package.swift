// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuietDraft",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CWhisper",
            path: "Sources/CWhisper",
            providers: [.brew(["whisper-cpp"])]
        ),
        .executableTarget(
            name: "QuietDraft",
            dependencies: ["CWhisper"],
            path: "Sources/QuietDraft",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/Cellar/whisper-cpp/1.9.1/include", "-I/opt/homebrew/include"])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/Cellar/whisper-cpp/1.9.1/include", "-Xcc", "-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/Cellar/whisper-cpp/1.9.1/lib",
                    "-L/opt/homebrew/Cellar/ggml/0.16.0/lib",
                    "-lwhisper", "-lggml", "-lggml-base"
                ])
            ]
        )
    ]
)

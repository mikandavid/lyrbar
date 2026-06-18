// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lyrbar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "lyrbar",
            path: "Sources/lyrbar",
            swiftSettings: [
                // Relax to Swift 5 concurrency model: this is a single-process,
                // main-actor-driven menu bar app and full strict-concurrency
                // checking adds noise without real safety benefit here.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

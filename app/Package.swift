// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scoreboard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Scoreboard", targets: ["Scoreboard"]),
        // NOT "scoreboard": macOS filesystems are case-insensitive, so that
        // product would be the same file as the app and one would silently
        // overwrite the other. The Makefile installs it under the short name.
        .executable(name: "scoreboard-cli", targets: ["ScoreboardCLI"]),
    ],
    targets: [
        // Shared by the menu bar app and the CLI.
        .target(name: "ScoreboardCore", path: "Sources/ScoreboardCore"),
        .executableTarget(
            name: "Scoreboard", dependencies: ["ScoreboardCore"], path: "Sources/Scoreboard"),
        .executableTarget(
            name: "ScoreboardCLI", dependencies: ["ScoreboardCore"], path: "Sources/ScoreboardCLI"),
        .testTarget(
            name: "ScoreboardCoreTests", dependencies: ["ScoreboardCore"],
            path: "Tests/ScoreboardCoreTests"),
    ]
)

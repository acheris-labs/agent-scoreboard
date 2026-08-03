// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scoreboard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Scoreboard", path: "Sources/Scoreboard")
    ]
)

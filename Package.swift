// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Smiley",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Smiley",
            path: "Sources/Smiley",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)

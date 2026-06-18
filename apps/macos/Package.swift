// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "voz",
    platforms: [.macOS(.v13)],
    targets: [
        // Two capabilities, each its own module (so their internal types never collide),
        // a tiny Shared module for things both need (e.g. the single Escape-hotkey owner),
        // plus a thin executable that hosts both behind one menu-bar item.
        .target(name: "Shared", path: "Sources/Shared"),
        .target(name: "Speak", dependencies: ["Shared"], path: "Sources/Speak"),
        .target(name: "Dictate", dependencies: ["Shared"], path: "Sources/Dictate"),
        .executableTarget(
            name: "voz",
            dependencies: ["Speak", "Dictate"],
            path: "Sources/voz"
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncClaude", platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncClaude", targets: ["SyncClaude"])],
    targets: [
        .target(name: "SyncCore", linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "SyncClaude", dependencies: ["SyncCore"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"])
    ]
)

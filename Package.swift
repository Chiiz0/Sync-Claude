// swift-tools-version: 5.9
import PackageDescription

#if os(Linux)
let appPath = "Sources/SyncClaudeLinux"
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
]
let coreDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let appPath = "Sources/SyncClaude"
let dependencies: [Package.Dependency] = []
let coreDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "SyncClaude", platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncClaude", targets: ["SyncClaude"])],
    dependencies: dependencies,
    targets: [
        .target(name: "SyncCore", dependencies: coreDependencies,
                linkerSettings: [.linkedFramework("Security", .when(platforms: [.macOS]))]),
        .executableTarget(name: "SyncClaude", dependencies: ["SyncCore"], path: appPath),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"])
    ]
)

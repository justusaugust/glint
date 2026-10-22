// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Glint", targets: ["Glint"])],
    targets: [
        .target(name: "GlintCore"),
        .executableTarget(name: "Glint", dependencies: ["GlintCore"],
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"])
    ]
)

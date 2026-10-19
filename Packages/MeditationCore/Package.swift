// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeditationCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeditationCore", targets: ["MeditationCore"])
    ],
    targets: [
        .target(name: "MeditationCore"),
        .testTarget(name: "MeditationCoreTests", dependencies: ["MeditationCore"])
    ]
)

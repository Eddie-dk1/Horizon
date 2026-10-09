// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Horizon",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HorizonCore", targets: ["HorizonCore"]), .executable(name: "Horizon", targets: ["HorizonApp"])],
    targets: [
        .target(name: "HorizonCore", swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]),
        .executableTarget(name: "HorizonApp", dependencies: ["HorizonCore"]),
        .executableTarget(name: "HorizonChecks", dependencies: ["HorizonCore"], path: "Tests/HorizonCoreTests")
    ]
)

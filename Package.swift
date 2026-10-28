// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacMiniHealthMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacMiniMonitor", targets: ["MacMiniMonitor"])],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "MacMiniMonitor", dependencies: ["MonitorCore"]),
        .executableTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"], path: "Tests/MonitorCoreTests")
    ]
)

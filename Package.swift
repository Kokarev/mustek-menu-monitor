// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MustekMenuMonitor",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MustekMenuMonitor", targets: ["MustekMenuMonitor"])],
    targets: [
        .executableTarget(name: "MustekMenuMonitor", resources: [.process("Resources")]),
        .testTarget(name: "MustekMenuMonitorTests", dependencies: ["MustekMenuMonitor"]),
    ]
)

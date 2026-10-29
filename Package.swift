// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "UPSMenuBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "UPSMenuBar", targets: ["UPSMenuBar"])],
    targets: [
        .executableTarget(name: "UPSMenuBar", resources: [.process("Resources")]),
        .testTarget(name: "UPSMenuBarTests", dependencies: ["UPSMenuBar"]),
    ]
)

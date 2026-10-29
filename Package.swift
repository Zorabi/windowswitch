// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowSwitch", targets: ["WindowSwitch"])],
    targets: [
        .target(name: "WindowFocus", publicHeadersPath: "include", linkerSettings: [.linkedFramework("ApplicationServices")]),
        .executableTarget(name: "WindowSwitch", dependencies: ["WindowFocus"]),
        .testTarget(name: "WindowSwitchTests", dependencies: ["WindowSwitch"])
    ]
)

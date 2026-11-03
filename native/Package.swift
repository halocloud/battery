// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryCore",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "batteryctl", targets: ["BatteryCLI"]),
        .executable(name: "batteryd", targets: ["BatteryDaemon"])
    ],
    targets: [
        .target(name: "CBatterySupport"),
        .target(name: "BatteryCore", dependencies: ["CBatterySupport"], linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("Security")
        ]),
        .executableTarget(name: "BatteryCLI", dependencies: ["BatteryCore"]),
        .executableTarget(name: "BatteryDaemon", dependencies: ["BatteryCore", "CBatterySupport"]),
        .testTarget(name: "BatteryCoreTests", dependencies: ["BatteryCore"])
    ],
    swiftLanguageModes: [.v5]
)

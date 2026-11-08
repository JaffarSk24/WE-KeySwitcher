// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WE-KeySwitcher",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "KeySwitcherCore",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(
            name: "KeySwitcher",
            dependencies: ["KeySwitcherCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "keyswitcher-eval",
            dependencies: ["KeySwitcherCore"]
        ),
        .executableTarget(
            name: "keyswitcher-e2e",
            dependencies: ["KeySwitcherCore"]
        ),
        .testTarget(
            name: "KeySwitcherCoreTests",
            dependencies: ["KeySwitcherCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

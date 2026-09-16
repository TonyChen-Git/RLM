// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumaChat",
    platforms: [.macOS(.v14)],
    products: [
        // The desktop and command-line products deliberately have names that
        // differ by more than letter case. Most macOS APFS volumes are
        // case-insensitive, so `LumaChat` and `lumachat` cannot safely coexist
        // in one SwiftPM products directory.
        .executable(name: "LumaChatDesktop", targets: ["LumaChat"]),
        .executable(name: "lumachat", targets: ["LumaChatCLIShim"]),
        .executable(name: "lumachat-updater", targets: ["LumaChatUpdater"]),
        .library(name: "LumaChatSDK", targets: ["LumaChatSDK"])
    ],
    targets: [
        .target(
            name: "LumaUpdateCore",
            path: "Sources/LumaUpdateCore"
        ),
        .target(
            name: "LumaPTYSupport",
            path: "Sources/LumaPTYSupport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("proc")]
        ),
        .executableTarget(
            name: "LumaChat",
            dependencies: ["LumaPTYSupport", "LumaChatSDK", "LumaUpdateCore"],
            path: "Sources/LumaChat",
            swiftSettings: [
                // Tests and QA builds may opt into an isolated Application
                // Support root. Normal debug runs are unchanged unless the
                // environment variable is explicitly supplied.
                .define("LUMACHAT_TESTING", .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "LumaChatCLIShim",
            path: "Sources/LumaChatCLIShim"
        ),
        .executableTarget(
            name: "LumaChatUpdater",
            dependencies: ["LumaUpdateCore"],
            path: "Sources/LumaChatUpdater"
        ),
        .target(
            name: "LumaChatSDK",
            path: "Sources/LumaChatSDK"
        ),
        .testTarget(
            name: "LumaChatTests",
            dependencies: ["LumaChat", "LumaPTYSupport", "LumaChatSDK", "LumaUpdateCore"],
            path: "Tests/LumaChatTests"
        )
    ]
)

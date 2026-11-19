// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "dotlogI",
    platforms: [.macOS(.v14)],
    targets: [
        // Config, status and key names shared by both processes.
        .target(name: "DotlogiCore", path: "Sources/DotlogiCore"),
        // The resident process: no AppKit, no UI.
        .executableTarget(
            name: "DotlogiAgent",
            dependencies: ["DotlogiCore"],
            path: "Sources/DotlogiAgent",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices")]
        ),
        // The settings window, started only when opened.
        .executableTarget(
            name: "DotlogiSettings",
            dependencies: ["DotlogiCore"],
            path: "Sources/DotlogiSettings"
        ),
    ]
)

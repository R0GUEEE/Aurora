// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aurora",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AuroraCore", targets: ["AuroraCore"]),
        .executable(name: "aurora", targets: ["AuroraCLI"]),
    ],
    targets: [
        // zlib is part of the iOS and macOS SDKs; SwiftPM needs a system library
        // shim to see the headers from a package.
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),
        .target(
            name: "AuroraCore",
            dependencies: ["CZlib"]
        ),
        .executableTarget(
            name: "AuroraCLI",
            dependencies: ["AuroraCore"]
        ),
        .testTarget(
            name: "AuroraCoreTests",
            dependencies: ["AuroraCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

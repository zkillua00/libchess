// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustLibraryDirectory = packageDirectory
    .appendingPathComponent("../../target/release")
    .standardizedFileURL
    .path

let package = Package(
    name: "LibChessMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LibChessMac", targets: ["LibChessMac"]),
        .library(name: "LibChessKit", targets: ["LibChessKit"]),
    ],
    targets: [
        .target(
            name: "CLibChess",
            path: "Sources/CLibChess",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibraryDirectory, "-llibchess_ffi"]),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", rustLibraryDirectory,
                ]),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(
            name: "LibChessKit",
            dependencies: ["CLibChess"]
        ),
        .executableTarget(
            name: "LibChessMac",
            dependencies: ["LibChessKit"]
        ),
    ]
)

// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "RigPoC",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "rig_pocFFI",
            path: "Sources/rig_pocFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RigPoCKit",
            dependencies: ["rig_pocFFI"],
            path: "Sources/RigPoCKit"
        ),
        .executableTarget(
            name: "RigPoC",
            dependencies: ["RigPoCKit"],
            path: "Sources/RigPoC",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "\(packageDir)/artifacts",
                    "-lrig_poc",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(packageDir)/artifacts",
                ])
            ]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoodCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FoodCore", targets: ["FoodCore"]),
        .executable(name: "foodcore-cli", targets: ["foodcore-cli"]),
    ],
    targets: [
        // Built by scripts/build-rig.sh from mobile/ios/Rig. Generated artifacts are gitignored.
        .binaryTarget(name: "RigPoc", path: "Vendor/RigPoc.xcframework"),
        .target(
            name: "rig_pocFFI",
            path: "Sources/rig_pocFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RigPocKit",
            dependencies: ["rig_pocFFI", "RigPoc"],
            path: "Sources/RigPocKit",
            linkerSettings: [
                // Rust's HTTP stack reads the macOS system proxy configuration.
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "FoodCore",
            dependencies: ["RigPocKit", "RigPoc"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(name: "foodcore-cli", dependencies: ["FoodCore"], path: "Sources/foodcore-cli"),
        .testTarget(
            name: "FoodCoreTests",
            dependencies: ["FoodCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

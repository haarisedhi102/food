// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoodCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FoodCore", targets: ["FoodCore"]),
        .executable(name: "foodcore-cli", targets: ["foodcore-cli"]),
    ],
    dependencies: [
        // OpenAI-compatible client. Handles the HTTP/JSON plumbing, tool-calling, structured
        // outputs and embeddings so we don't maintain it. Supports a custom `basePath`, which
        // is why our `/provider/v1` mount works.
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.5.3"),
    ],
    targets: [
        .target(
            name: "FoodCore",
            dependencies: [.product(name: "OpenAI", package: "OpenAI")]
        ),
        .executableTarget(name: "foodcore-cli", dependencies: ["FoodCore"], path: "Sources/foodcore-cli"),
        .testTarget(
            name: "FoodCoreTests",
            dependencies: ["FoodCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

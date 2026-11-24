// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cask",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaskKit", targets: ["CaskKit"]),
        .executable(name: "cask-cli", targets: ["cask-cli"]),
        .executable(name: "CaskApp", targets: ["CaskApp"]),
    ],
    targets: [
        .target(name: "CaskKit"),
        .executableTarget(name: "cask-cli", dependencies: ["CaskKit"]),
        .executableTarget(name: "CaskApp", dependencies: ["CaskKit"]),
    ]
)

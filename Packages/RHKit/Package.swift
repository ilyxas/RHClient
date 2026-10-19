// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RHKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "RHKit", targets: ["RHCrypto", "RHAPI"]),
    ],
    targets: [
        .target(name: "RHCrypto"),
        .target(name: "RHAPI", dependencies: ["RHCrypto"]),
        .testTarget(name: "RHCryptoTests", dependencies: ["RHCrypto"]),
        .testTarget(name: "RHAPITests", dependencies: ["RHAPI", "RHCrypto"]),
    ]
)

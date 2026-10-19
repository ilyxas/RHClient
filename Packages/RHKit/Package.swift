// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RHKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "RHKit", targets: ["RHCrypto"]),
    ],
    targets: [
        .target(name: "RHCrypto"),
        .testTarget(name: "RHCryptoTests", dependencies: ["RHCrypto"]),
    ]
)

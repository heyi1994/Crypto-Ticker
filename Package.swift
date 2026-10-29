// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CryptoTicker",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CryptoTicker", targets: ["CryptoTicker"])],
    targets: [
        .target(name: "CryptoTickerCore", resources: [.process("Resources")]),
        .executableTarget(name: "CryptoTicker", dependencies: ["CryptoTickerCore"]),
        .testTarget(name: "CryptoTickerCoreTests", dependencies: ["CryptoTickerCore"]),
        .testTarget(name: "CryptoTickerTests", dependencies: ["CryptoTicker"])
    ]
)

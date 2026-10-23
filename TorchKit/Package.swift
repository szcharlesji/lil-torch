// swift-tools-version: 6.0
import PackageDescription

// Client for lil-torch agents (see ../agent): models for their JSON and an
// HTTP/WebSocket client. No third-party dependencies.
let package = Package(
    name: "TorchKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TorchKit", targets: ["TorchKit"]),
    ],
    targets: [
        .target(name: "TorchKit"),
        .testTarget(name: "TorchKitTests", dependencies: ["TorchKit"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// The original direct-SSH transport (iPhone → Orin → relay → Torch) and a Mac probe
// for it. The app now talks to lil-torch agents instead; this stays as a reference
// and a way to test the relay path from a Mac.
let package = Package(
    name: "TorchSSH",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TorchSSH", targets: ["TorchSSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Citadel pins this fork of apple/swift-nio-ssh; we import NIOSSH directly for key types.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "TorchSSH",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(name: "torch-ssh-probe", dependencies: ["TorchSSH"]),
        .testTarget(name: "TorchSSHTests", dependencies: ["TorchSSH"]),
    ]
)

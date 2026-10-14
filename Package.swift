// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElginMenuBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ElginMenuBar", targets: ["ElginMenuBar"])],
    targets: [
        .executableTarget(name: "ElginMenuBar", path: "macos/Sources", resources: [.process("Resources")])
    ]
)

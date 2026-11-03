// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArxivLens",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ArxivLens", targets: ["ArxivLens"])],
    targets: [
        .target(name: "PaperCore"),
        .executableTarget(name: "ArxivLens", dependencies: ["PaperCore"])
    ]
)

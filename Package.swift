// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrintStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PrintStatus", targets: ["PrintStatus"])],
    targets: [
        .target(name: "PrinterCore"),
        .executableTarget(name: "PrintStatus", dependencies: ["PrinterCore"]),
        .testTarget(name: "PrinterCoreTests", dependencies: ["PrinterCore"]),
        .testTarget(name: "PrintStatusTests", dependencies: ["PrintStatus"]),
    ]
)

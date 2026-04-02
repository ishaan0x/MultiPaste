// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiPaste",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MultiPaste", targets: ["MultiPaste"])
    ],
    targets: [
        .executableTarget(
            name: "MultiPaste",
            path: "Sources"
        )
    ]
)

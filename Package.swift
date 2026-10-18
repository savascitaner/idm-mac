// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IDMMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "IDMMac", path: "Sources/IDMMac"),
        .executableTarget(name: "IDMMacHost", path: "Sources/IDMMacHost"),
    ]
)

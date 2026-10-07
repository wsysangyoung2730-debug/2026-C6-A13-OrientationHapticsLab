// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrientationCore",
    platforms: [.iOS("26.0"), .macOS(.v13)],
    products: [.library(name: "OrientationCore", targets: ["OrientationCore"])],
    targets: [.target(name: "OrientationCore")]
)

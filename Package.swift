// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UPnPCast",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "UPnPCast", targets: ["UPnPCast"]),
    ],
    targets: [
        .target(
            name: "UPnPCast",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "UPnPCastTests",
            dependencies: ["UPnPCast"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

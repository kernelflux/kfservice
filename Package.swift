// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KFService",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "KFService", targets: ["KFService"]),
    ],
    targets: [
        .target(
            name: "KFService",
            linkerSettings: [.linkedFramework("Network")]
        ),
        .testTarget(
            name: "KFServiceTests",
            dependencies: ["KFService"]
        ),
    ]
)

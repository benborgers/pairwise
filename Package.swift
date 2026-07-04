// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pairwise",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PWShim",
            path: "Sources/PWShim"
        ),
        .executableTarget(
            name: "Pairwise",
            dependencies: ["PWShim"],
            path: "Sources/Pairwise",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .release))
            ]
        )
    ]
)

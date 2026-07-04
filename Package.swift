// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pairwise",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "PWShim",
            path: "Sources/PWShim"
        ),
        .executableTarget(
            name: "Pairwise",
            dependencies: [
                "PWShim",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Pairwise",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .release))
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Pairwise.app/Contents/Frameworks by build.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)

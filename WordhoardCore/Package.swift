// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WordhoardCore",
    // macOS is declared only so `swift test` runs on the host; same major as iOS so the host
    // compiles the same API surface. The app is iPhone only.
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "WordhoardCore", targets: ["WordhoardCore"]),
    ],
    targets: [
        .target(
            name: "WordhoardCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WordhoardCoreTests",
            dependencies: ["WordhoardCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

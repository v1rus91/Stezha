// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stezha",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Stezha",
            path: "Sources/Stezha",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        )
    ]
)

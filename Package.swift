// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CiteStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CiteStudioCore", targets: ["CiteStudioCore"]),
        .executable(name: "CiteStudio", targets: ["CiteStudio"])
    ],
    targets: [
        .target(
            name: "CiteStudioCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit")
            ]
        ),
        .executableTarget(
            name: "CiteStudio",
            dependencies: ["CiteStudioCore"]
        ),
        .testTarget(
            name: "CiteStudioCoreTests",
            dependencies: ["CiteStudioCore"]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StencilCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "StencilCore", targets: ["StencilCore"]),
        .executable(name: "stencil-inspect", targets: ["StencilInspect"])
    ],
    targets: [
        .target(name: "StencilCore", path: "StencilStudio.swiftpm/Core"),
        .executableTarget(name: "StencilInspect", dependencies: ["StencilCore"], path: "Tools/StencilInspect"),
        .testTarget(name: "StencilCoreTests", dependencies: ["StencilCore"])
    ]
)

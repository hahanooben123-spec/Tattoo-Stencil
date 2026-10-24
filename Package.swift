// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StencilCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "StencilCore", targets: ["StencilCore"]),
        .executable(name: "stencil-inspect", targets: ["StencilInspect"]),
        .executable(name: "stencil-preview-bench", targets: ["StencilPreviewBench"])
    ],
    targets: [
        .target(name: "StencilCore", path: "StencilStudio.swiftpm/Core"),
        .executableTarget(name: "StencilInspect", dependencies: ["StencilCore"], path: "Tools/StencilInspect"),
        .executableTarget(name: "StencilPreviewBench", dependencies: ["StencilCore"], path: "Tools/PreviewBench"),
        .testTarget(name: "StencilCoreTests", dependencies: ["StencilCore"])
    ]
)

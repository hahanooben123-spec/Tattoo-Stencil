// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Stencil Studio",
    platforms: [.iOS(.v17)],
    products: [
        .iOSApplication(name: "Stencil Studio", targets: ["StencilApp"],
                        bundleIdentifier: "com.example.stencilstudio",
                        displayVersion: "0.1.0", bundleVersion: "1",
                        appIcon: .placeholder(icon: .star), accentColor: .presetColor(.purple),
                        supportedDeviceFamilies: [.pad],
                        supportedInterfaceOrientations: [.landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown])
    ],
    targets: [
        .target(name: "StencilCore", path: "Core"),
        .executableTarget(name: "StencilApp", dependencies: ["StencilCore"], path: "App")
    ]
)

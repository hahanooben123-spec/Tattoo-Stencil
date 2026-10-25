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
                        supportedDeviceFamilies: [.pad, .phone],
                        supportedInterfaceOrientations: [.landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown(.when(deviceFamilies: [.pad]))],
                        capabilities: [
                            .camera(purposeString: "Scan den private parringskode på din PC."),
                            .localNetwork(purposeString: "Send referencebilleder til din egen Stencil PC og hent stencilen tilbage.")
                        ],
                        additionalInfoPlistContentFilePath: "PCNetwork.plist")
    ],
    targets: [
        // The numeric CV loops must stay optimized when Playgrounds runs a debug UI.
        // This is local to the self-contained app; the reusable root package has no unsafe flags.
        .target(name: "StencilCore", path: "Core",
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .executableTarget(name: "StencilApp", dependencies: ["StencilCore"], path: "App")
    ]
)

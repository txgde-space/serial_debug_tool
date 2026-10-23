// swift-tools-version: 6.0
import PackageDescription

// A dependency-free harness for the serial core; the application builds in Xcode.
let package = Package(
    name: "SerialDebugToolCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SerialDebugToolCore", targets: ["SerialDebugToolCore"])],
    targets: [
        .target(
            name: "SerialDebugToolCore",
            path: "Serial Debug Tool",
            exclude: ["AppSettings.swift", "Assets.xcassets", "ContentView.swift", "DockConnectionIndicator.swift", "MyApp.swift", "PresetCommandRow.swift", "PresetCommandScrollView.swift", "SendTextEditor.swift", "SerialDevicePicker.swift", "TerminalDocument.swift", "TerminalOutputView.swift", "Serial Debug Tool.entitlements"],
            sources: ["CommandPresetStore.swift", "AppLocalization.swift", "AppText.swift", "ProtocolTypes.swift", "SerialTransport.swift", "SerialSession.swift", "TerminalLogRenderer.swift"],
            resources: [.process("en.lproj"), .process("zh-Hans.lproj")]
        ),
        .testTarget(name: "SerialDebugToolCoreTests", dependencies: ["SerialDebugToolCore"], path: "Tests")
    ]
)

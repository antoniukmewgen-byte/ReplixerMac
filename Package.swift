// swift-tools-version:5.9
import PackageDescription

// NOTE: SwiftPM's named platform cases only go up to .v14 ("macOS 14.0+"),
// but AudioHardwareCreateProcessTap/AudioHardwareDestroyProcessTap are
// declared API_AVAILABLE(macos(14.2)) in the SDK, so the deployment target
// must be raised via the string-literal form to avoid an availability
// compile error. Below 14.2, tap creation itself is unavailable (not just
// "returns an empty list" like the process-object properties).
let package = Package(
    name: "ReplixerMacCallPoC",
    platforms: [.macOS("14.2")],
    dependencies: [
        // Phase 4: Telegram login/upload via TDLib. Swift wrapper generated
        // from TDLib's tl-schema; pulls in TDLibFramework as a prebuilt
        // binary xcframework (prebuilt TDLib itself, no local C++ build
        // needed) as its own transitive dependency.
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.66-022d6020")
    ],
    targets: [
        .executableTarget(
            name: "ReplixerMacCallPoC",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit")
            ],
            path: "Sources/ReplixerMacCallPoC"
        )
    ]
)

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
    targets: [
        .executableTarget(
            name: "ReplixerMacCallPoC",
            path: "Sources/ReplixerMacCallPoC"
        )
    ]
)

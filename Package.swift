// swift-tools-version: 5.9
import PackageDescription

// ⚠️  Before building:
//  1. Get api_id / api_hash at https://my.telegram.org/apps
//  2. Enter api_id/api_hash in Setup Wizard on first launch
//  3. Place service_account.json next to the .app for Google Drive
//  4. Grant Screen Recording + Microphone in System Settings on first run

let package = Package(
    name: "ReplixerMac",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibKit", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "ReplixerMac",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
            ],
            path: "Sources/ReplixerMac"
        ),
    ]
)

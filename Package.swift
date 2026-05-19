// swift-tools-version: 5.9
import PackageDescription

// ⚠️  Before building:
//  1. Get api_id / api_hash at https://my.telegram.org/apps
//  2. Replace placeholders in TelegramAuthService.swift
//  3. In Xcode: add ReplixerMac.entitlements + set LSUIElement=YES in Info.plist
//  4. Grant Accessibility permission in System Settings → Privacy → Screen Recording

let package = Package(
    name: "ReplixerMac",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Telegram MTProto client (Swift wrapper for TDLib)
        // Check latest version at: https://github.com/Swiftgram/TDLibKit/releases
        .package(url: "https://github.com/Swiftgram/TDLibKit", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReplixerMac",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
            ],
            path: "Sources/ReplixerMac",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)

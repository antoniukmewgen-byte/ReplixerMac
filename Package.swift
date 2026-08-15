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
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.66-022d6020"),
        // Phase 10.1c: KommoService's "робочий час" processing-speed leg
        // needs to parse a Kommo contact/company phone number well enough to
        // extract a country/region (Windows: libphonenumber-csharp's
        // PhoneNumberUtil). This is the Swift Package Manager successor to
        // the now-archived marmelroy/PhoneNumberKit (moved orgs, same
        // library) — macOS 10.15+/Swift 5.9, well within this package's
        // 14.2 floor.
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit", from: "5.0.0")
    ],
    targets: [
        // Phase 7.1: library target holding all real logic (audio capture,
        // Telegram/Drive upload, settings/history persistence, etc.) — split
        // out of the former single executable so a second executable
        // (ReplixerMacApp) can share it without duplicating code.
        .target(
            name: "ReplixerMacCore",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit")
            ],
            path: "Sources/ReplixerMacCore",
            // AppSecrets.example.swift is a tracked doc-only template (see
            // its own header comment) that happens to declare the same
            // `enum AppSecrets` shape as the git-ignored real AppSecrets
            // .swift sitting right next to it — without this exclude,
            // SwiftPM's recursive `path:` source scan compiles BOTH,
            // producing a duplicate `AppSecrets` declaration and "ambiguous
            // use of telegramApiId/telegramApiHash/googleServiceAccountJson"
            // at every call site. Only the real file should ever build.
            exclude: ["GoogleDrive/AppSecrets.example.swift"]
        ),
        // CLI entry point / smoke-test harness — now just main.swift, with
        // all actual logic living in ReplixerMacCore.
        .executableTarget(
            name: "ReplixerMacCallPoC",
            dependencies: ["ReplixerMacCore"],
            path: "Sources/ReplixerMacCallPoC"
        ),
        // Phase 7.1 scaffolding: minimal SwiftUI app shell, not yet wired up
        // to ReplixerMacCore's functionality.
        .executableTarget(
            name: "ReplixerMacApp",
            dependencies: ["ReplixerMacCore"],
            path: "Sources/ReplixerMacApp",
            // Phase 8.3: embeds Info.plist directly into the executable via
            // a `__TEXT,__info_plist` Mach-O section — the standard trick
            // for a bare SwiftPM executable (no .xcodeproj/.app bundle) to
            // carry real Info.plist keys. Covers LSUIElement (Dock-hiding)
            // and NSMicrophoneUsageDescription even when run straight out
            // of Xcode's debug DerivedData output. Does NOT cover
            // SMAppService login-item registration — that needs an actual
            // Contents/Info.plist inside a real .app bundle, which is what
            // Scripts/build-app-bundle.sh produces separately for testing
            // AutoStartManager. `unsafeFlags` is fine here: nothing else in
            // this package (or outside it) depends on ReplixerMacApp as a
            // library.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ReplixerMacApp/Info.plist"
                ])
            ]
        )
    ]
)

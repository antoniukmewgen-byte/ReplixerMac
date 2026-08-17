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
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit", from: "5.0.0"),
        // Phase 9: auto-update framework (Windows parity: UpdateService.cs's
        // hand-rolled GitHub-manifest updater — Sparkle is the standard
        // off-the-shelf equivalent on macOS). SPM only vends the prebuilt
        // `Sparkle` library product (a binary xcframework target) — the
        // `bin/generate_keys`/`sign_update`/`generate_appcast` command-line
        // tools it also ships are NOT part of this package dependency; those
        // only come from manually downloading a `Sparkle-X.Y.Z.tar.xz` from
        // https://github.com/sparkle-project/Sparkle/releases (see
        // Scripts/release.sh's header comment).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
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
            exclude: ["GoogleDrive/AppSecrets.example.swift"],
            // Phase 10.1c (revision): first bundled resource in the
            // project — the NANP subset of libphonenumber's own
            // prefix->timezone geocoder data (see
            // Kommo/Resources/nanp_timezones.txt's header for provenance),
            // loaded at runtime via the auto-generated `Bundle.module` by
            // `NANPTimeZoneMapper`. `.copy` (not `.process`) because this is
            // a plain data file that must reach the app bundle byte-for-byte,
            // not something SwiftPM's resource-processing pipeline should
            // touch.
            resources: [.copy("Kommo/Resources/nanp_timezones.txt")]
        ),
        // CLI entry point / smoke-test harness — now just main.swift, with
        // all actual logic living in ReplixerMacCore.
        .executableTarget(
            name: "ReplixerMacCallPoC",
            dependencies: ["ReplixerMacCore"],
            path: "Sources/ReplixerMacCallPoC"
        ),
        // The real SwiftUI app — home/recordings/settings/profile screens
        // plus (Phase 7.5+) the live call-detection/recording pipeline
        // itself, wired up in ReplixerMacApp.swift's AppDelegate.
        .executableTarget(
            name: "ReplixerMacApp",
            dependencies: [
                "ReplixerMacCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
                    "-Xlinker", "Sources/ReplixerMacApp/Info.plist",
                    // Phase 9: Sparkle.framework is embedded into
                    // Contents/Frameworks by Scripts/build-app-bundle.sh (SPM
                    // has no "Copy Files" build phase to do this
                    // automatically, unlike an Xcode project) — the binary
                    // needs its own rpath entry to find it there at runtime.
                    // Harmless for the raw Xcode-debug executable case (no
                    // Frameworks dir exists yet then; the app just can't
                    // actually load Sparkle until launched from a real
                    // .app bundle built by that script).
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)

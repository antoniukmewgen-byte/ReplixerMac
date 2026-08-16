#!/bin/bash
set -euo pipefail

# Phase 8.3 groundwork — packages ReplixerMacApp as a real .app bundle.
# `swift build`/Xcode's SPM-executable debug runs never produce one (the
# binary runs straight out of a DerivedData temp path), which is exactly
# why SMAppService.mainApp.register() failed with SMAppServiceErrorDomain
# Code=1 "Operation not permitted" on a real test build — see
# AutoStartManager.swift's doc comment. SMAppService needs a stable, real
# Contents/Info.plist + Contents/MacOS/<exe> bundle to register a login
# item against; the `__info_plist` linker-section trick wired up in
# Package.swift (Sources/ReplixerMacApp/Info.plist) is enough for
# LSUIElement/TCC descriptions — which the OS reads straight off the
# running process's own Mach-O — but not for LaunchServices/launchd
# login-item registration, which resolves against real bundle paths on
# disk.
#
# Ad-hoc signed (`codesign --sign -`) — free, no Apple Developer Program
# needed. Sufficient for everything this script exists to unblock
# (SMAppService registration, LSUIElement Dock-hiding) since none of that
# needs Gatekeeper/notarization on the same Mac that built it — that only
# becomes a hard requirement for auto-updates fetched from the internet
# (Phase 9 / Sparkle), which is a separate, already-discussed tradeoff.
#
# Usage: Scripts/build-app-bundle.sh
# Output: .build/ReplixerMac.app — copy/symlink into /Applications to test
# AutoStartManager's login-item toggle (SettingsView's "Запуск" section)
# against a real, stable bundle location.
#
# Universal (arm64 + x86_64) build — needed because the machine building
# this isn't always the machine running it (e.g. building on an Intel Mac to
# hand the .app to someone on Apple Silicon, or vice versa). SwiftPM builds
# each architecture as its own single-arch slice under `.build/<triple>/
# release/` even when both are requested in one invocation, so each arch is
# built as a separate `swift build` call below and the two slices are welded
# into one Mach-O with `lipo` — same technique Xcode uses under the hood for
# "Build Active Architecture Only = No". `--show-bin-path` (rather than
# hardcoding the `.build/<triple>/release` path) is used to ask SwiftPM
# itself where each slice landed, since that path shape isn't stable API.
#
# Requires the Xcode toolchain (not the open-source swift.org toolchain) to
# have both an x86_64 and an arm64 macOS SDK available for cross-compiling
# the arch that isn't the host's — true for any reasonably recent Xcode.
# If TDLibKit's prebuilt xcframework ever ships an arm64-only or
# x86_64-only slice, the corresponding `swift build` invocation below is
# where that mismatch would surface as a link error.

APP_NAME="ReplixerMac"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_DIR/.build/$APP_NAME.app"

echo "==> Resolving per-arch build output directories"
ARM64_BIN_DIR="$(swift build -c release --arch arm64 --package-path "$REPO_DIR" --show-bin-path)"
X86_64_BIN_DIR="$(swift build -c release --arch x86_64 --package-path "$REPO_DIR" --show-bin-path)"

echo "==> swift build -c release --arch arm64 --product ReplixerMacApp"
swift build -c release --arch arm64 --product ReplixerMacApp --package-path "$REPO_DIR"

echo "==> swift build -c release --arch x86_64 --product ReplixerMacApp"
swift build -c release --arch x86_64 --product ReplixerMacApp --package-path "$REPO_DIR"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
cp "$REPO_DIR/Sources/ReplixerMacApp/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> lipo: merging arm64 + x86_64 into one universal binary"
lipo -create \
    "$ARM64_BIN_DIR/ReplixerMacApp" \
    "$X86_64_BIN_DIR/ReplixerMacApp" \
    -output "$APP_DIR/Contents/MacOS/ReplixerMacApp"
lipo -info "$APP_DIR/Contents/MacOS/ReplixerMacApp"

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Phase 9: Sparkle.xcframework is downloaded by SwiftPM under
# .build/artifacts/ (a binaryTarget, resolved once per `swift build`, same
# for both arch invocations above — not duplicated). Only the macOS slice's
# .framework is copied in, matching the rpath Package.swift's linkerSettings
# added (@executable_path/../Frameworks). `find` (rather than hardcoding the
# exact "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" path) is
# used because that slice-folder name isn't guaranteed stable across Sparkle
# versions — only that it's a macOS slice.
echo "==> Locating Sparkle.framework in SwiftPM artifacts"
SPARKLE_FRAMEWORK="$(find "$REPO_DIR/.build/artifacts" -type d -path "*macos*/Sparkle.framework" -print -quit)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "!! Could not find Sparkle.framework under .build/artifacts — did 'swift build' resolve the Sparkle package dependency?" >&2
    exit 1
fi
echo "    Found: $SPARKLE_FRAMEWORK"
echo "==> Embedding Sparkle.framework into Contents/Frameworks"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

echo "==> Code signing (ad-hoc — see header comment)"
# Sign the leaf bundles Sparkle ships inside its framework (its own
# Autoupdate.app relauncher + Installer.xpc/Downloader.xpc XPC services)
# before the framework and outer app, innermost-out — the order `--deep`
# alone doesn't reliably guarantee, and which Apple's own docs recommend for
# anything beyond a single flat binary. Still ad-hoc (`--sign -`): fine for
# same-Mac testing (Gatekeeper/quarantine don't apply to a locally-built,
# never-downloaded app), but a real Developer ID identity + `--options
# runtime` (hardened runtime) is required before this bundle can be
# notarized — a hard requirement once Sparkle-fetched *updates* need to pass
# Gatekeeper on OTHER Macs, not just run here. See Scripts/release.sh.
find "$APP_DIR/Contents/Frameworks/Sparkle.framework" \
    \( -name "*.app" -o -name "*.xpc" \) -maxdepth 4 \
    -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP_DIR/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR (universal: arm64 + x86_64)"
echo "    Move it into /Applications to test SMAppService/login items, e.g.:"
echo "    rm -rf /Applications/$APP_NAME.app && cp -R \"$APP_DIR\" /Applications/"
echo ""
echo "    To hand off to another Mac, zip it with ditto to preserve the bundle"
echo "    structure/attributes:"
echo "    ditto -c -k --keepParent \"$APP_DIR\" \"$REPO_DIR/.build/$APP_NAME.zip\""

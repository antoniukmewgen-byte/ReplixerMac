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

APP_NAME="ReplixerMac"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_DIR/.build/release"
APP_DIR="$REPO_DIR/.build/$APP_NAME.app"

echo "==> swift build -c release --product ReplixerMacApp"
swift build -c release --product ReplixerMacApp --package-path "$REPO_DIR"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$REPO_DIR/Sources/ReplixerMacApp/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/ReplixerMacApp" "$APP_DIR/Contents/MacOS/ReplixerMacApp"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Move it into /Applications to test SMAppService/login items, e.g.:"
echo "    rm -rf /Applications/$APP_NAME.app && cp -R \"$APP_DIR\" /Applications/"

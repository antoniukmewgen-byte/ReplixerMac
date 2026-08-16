#!/bin/bash
set -euo pipefail

# Phase 9 — local, manual release flow (no CI yet; deliberate first step —
# add GitHub Actions automation later, once signing with a real Developer ID
# identity is in place, mirroring Replixer's release.yml more closely).
# Windows parity in *shape* only: Replixer's release.yml (tag push -> build
# -> sign -> manifest -> GitHub Release) does that sequence automatically on
# GitHub's servers; this script does the same sequence by hand, run locally
# on the Mac that holds Sparkle's private signing key in its login Keychain.
#
# What this deliberately does NOT do yet (per the "спершу лише локально/
# собі" decision — revisit once an Apple Developer Program membership
# exists):
#   - Does not sign with a real Developer ID Application identity — still
#     ad-hoc (`--sign -`, via build-app-bundle.sh). Fine for testing updates
#     between your own Macs; NOT fine for distributing to anyone else — an
#     ad-hoc-signed, non-notarized download gets quarantined and blocked by
#     Gatekeeper on any Mac that isn't the one that built it. Once you have
#     a Developer ID identity: swap `--sign -` for
#     `--sign "Developer ID Application: ..."` + `--options runtime` in
#     build-app-bundle.sh, then add an `xcrun notarytool submit --wait` +
#     `xcrun stapler staple` step into THIS script before the DMG gets
#     signed with sign_update below.
#   - Does not create/push a git tag or GitHub Release itself — prints the
#     exact commands to run (or runs `gh` for you if it's installed and
#     authenticated) so you can review the diff/DMG before anything is
#     public.
#
# One-time setup before the FIRST ever run of this script:
#   1. Download a full Sparkle distribution (NOT the SPM package — SPM only
#      vends the prebuilt .xcframework, not these CLI tools) from
#      https://github.com/sparkle-project/Sparkle/releases — grab the
#      "Sparkle-X.Y.Z.tar.xz" asset and expand it anywhere permanent.
#   2. Run `<extracted>/bin/generate_keys` ONCE. It prints a public key and
#      stores the matching private key in this Mac's login Keychain. Paste
#      the printed public key into Sources/ReplixerMacApp/Info.plist's
#      SUPublicEDKey (see that key's own doc comment there) and commit that
#      change before your first real release.
#   3. Either `export SPARKLE_BIN_DIR=/path/to/extracted/bin` before running
#      this script (it will then sign the DMG and patch appcast.xml for you
#      automatically), or leave it unset — this script still works, it just
#      prints the exact `sign_update` command and <item> block to add by
#      hand instead.
#
# Usage: Scripts/release.sh <version>   e.g. Scripts/release.sh 0.2.0

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>   e.g. $0 0.2.0" >&2
    exit 1
fi

VERSION="$1"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$REPO_DIR/Sources/ReplixerMacApp/Info.plist"
APPCAST="$REPO_DIR/appcast.xml"
APP_DIR="$REPO_DIR/.build/ReplixerMac.app"
DIST_DIR="$REPO_DIR/.build/dist"
DMG_NAME="ReplixerMac-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
# Must match exactly where step 4's `gh release create`/manual upload will
# actually put the DMG (tag "v$VERSION", asset named "$DMG_NAME") — Sparkle
# has no way to discover this URL itself, it just trusts whatever
# <enclosure url="..."> says, so a mismatch here silently produces a 404 for
# every user's update check instead of an error you'd notice immediately.
DOWNLOAD_URL="https://github.com/antoniukmewgen-byte/ReplixerMac/releases/download/v$VERSION/$DMG_NAME"

echo "==> Bumping version to $VERSION"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")"
NEXT_BUILD=$((CURRENT_BUILD + 1))
# NOT PlistBuddy Set here (confirmed the hard way on a real release run) —
# PlistBuddy re-serializes the WHOLE plist through CFPropertyList on any
# Set, and XML comments aren't part of the plist data model, so every doc
# comment in this file (there are a lot) silently vanishes on the very
# first release. Text-splice instead, same reasoning as the appcast.xml
# <item> insertion below: touch only the two specific <string> values,
# byte-for-byte identical everywhere else.
python3 - "$INFO_PLIST" "$VERSION" "$NEXT_BUILD" <<'PY'
import re, sys
path, version, next_build = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
text, n1 = re.subn(
    r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)",
    lambda m: m.group(1) + version + m.group(2),
    text, count=1,
)
text, n2 = re.subn(
    r"(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)",
    lambda m: m.group(1) + next_build + m.group(2),
    text, count=1,
)
if n1 != 1 or n2 != 1:
    sys.exit("release.sh: could not find CFBundleShortVersionString/CFBundleVersion in Info.plist")
open(path, "w", encoding="utf-8").write(text)
PY
echo "    CFBundleShortVersionString = $VERSION, CFBundleVersion = $NEXT_BUILD"

echo "==> Building ReplixerMac.app (universal)"
"$REPO_DIR/Scripts/build-app-bundle.sh"

echo "==> Packaging DMG"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/staging"
cp -R "$APP_DIR" "$DIST_DIR/staging/ReplixerMac.app"
ln -s /Applications "$DIST_DIR/staging/Applications"
hdiutil create -volname "ReplixerMac $VERSION" -srcfolder "$DIST_DIR/staging" -ov -format UDZO "$DMG_PATH"
rm -rf "$DIST_DIR/staging"
echo "    $DMG_PATH"

DMG_LENGTH=$(stat -f%z "$DMG_PATH")
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# Ad-hoc-signing decision (no paid Apple Developer ID for now, see
# release.sh's header comment) means every single new version is, from
# Gatekeeper's point of view, an unrecognized binary — even though Sparkle's
# own EdDSA signature (sign_update below) proves the update wasn't tampered
# with in transit, that's a completely separate check from Gatekeeper's
# quarantine/notarization gate, which Sparkle cannot bypass. Concretely:
# after Sparkle installs this update and relaunches the app, THAT LAUNCH can
# get blocked with "Apple could not verify ... is free of malware" until the
# user manually clicks "Все одно відкрити" in System Settings -> Privacy &
# Security (must be redone per version, per Mac — see release.sh's header).
# Baked into every release's <description> (rather than left as a one-off
# chat explanation) so it reaches whoever installs the update, not just
# whoever ran this script.
GATEKEEPER_NOTE="Якщо після оновлення застосунок не відкриється автоматично: Системні налаштування → Конфіденційність і безпека → прокрутіть вниз до попередження про ReplixerMac → «Все одно відкрити». Це одноразово для кожної версії (поки немає платного Apple Developer ID)."
RELEASE_NOTES_HTML="<![CDATA[<p>Версія $VERSION.</p><p><b>$GATEKEEPER_NOTE</b></p>]]>"

if [ -n "${SPARKLE_BIN_DIR:-}" ] && [ -x "$SPARKLE_BIN_DIR/sign_update" ]; then
    echo "==> Signing DMG with Sparkle's EdDSA key (sign_update)"
    SIGN_OUTPUT="$("$SPARKLE_BIN_DIR/sign_update" "$DMG_PATH")"
    echo "    $SIGN_OUTPUT"
    ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
    if [ -z "$ED_SIGNATURE" ]; then
        echo "!! Could not parse sparkle:edSignature out of sign_update's output — patch appcast.xml by hand." >&2
        exit 1
    fi

    echo "==> Inserting <item> into appcast.xml"
    ITEM=$(cat <<EOF
        <item>
            <title>Версія $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$NEXT_BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
            <description>$RELEASE_NOTES_HTML</description>
            <enclosure url="$DOWNLOAD_URL" sparkle:edSignature="$ED_SIGNATURE" length="$DMG_LENGTH" type="application/octet-stream" />
        </item>
EOF
)
    # Text-splice, not an XML-DOM re-serialize — preserves the rest of the
    # file (comments, formatting) byte-for-byte instead of risking a
    # library reformatting/reordering everything around the one line that
    # actually changed.
    MARKER="<!-- release.sh:insert-here"
    python3 - "$APPCAST" "$MARKER" "$ITEM" <<'PY'
import sys
path, marker, item = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
idx = text.index(marker)
end = text.index("\n", text.index("-->", idx)) + 1
open(path, "w", encoding="utf-8").write(text[:end] + item + "\n" + text[end:])
PY
    echo "    appcast.xml updated — review with 'git diff appcast.xml'"
else
    echo "==> SPARKLE_BIN_DIR not set (or sign_update not found there) — sign this DMG yourself:"
    echo ""
    echo "    <path-to-extracted-Sparkle-release>/bin/sign_update \"$DMG_PATH\""
    echo ""
    echo "    Then add this <item> to appcast.xml, right after the"
    echo "    'release.sh:insert-here' comment inside <channel>:"
    echo ""
    echo "        <item>"
    echo "            <title>Версія $VERSION</title>"
    echo "            <pubDate>$PUB_DATE</pubDate>"
    echo "            <sparkle:version>$NEXT_BUILD</sparkle:version>"
    echo "            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
    echo "            <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>"
    echo "            <description>$RELEASE_NOTES_HTML</description>"
    echo "            <enclosure url=\"$DOWNLOAD_URL\" sparkle:edSignature=\"PASTE_FROM_sign_update\" length=\"$DMG_LENGTH\" type=\"application/octet-stream\" />"
    echo "        </item>"
fi

echo ""
echo "==> Next steps:"
echo "    1. Review: git diff Sources/ReplixerMacApp/Info.plist appcast.xml"
echo "    2. Commit: git add -A && git commit -m \"Release v$VERSION\""
echo "    3. Tag + push: git tag v$VERSION && git push origin main v$VERSION"
echo "    4. Publish the GitHub Release with the DMG + appcast.xml attached:"
echo "       gh release create v$VERSION \"$DMG_PATH\" \"$APPCAST\" --title \"v$VERSION\" --notes \"...\""
echo "       (or do it by hand: GitHub web UI -> Releases -> Draft a new release,"
echo "       attach both files, publish)."

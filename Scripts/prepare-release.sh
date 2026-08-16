#!/bin/bash
set -euo pipefail

# Phase 9.1 — CI-automated release, step 1 of 2. Split out of release.sh's
# original all-in-one flow: THIS script does only the part that has to be a
# deliberate, reviewed, human action (bump version, commit, tag, push) —
# the rest (build, package, sign, publish) is now .github/workflows/
# release.yml's job, triggered automatically by the tag push this script
# ends with. Deliberately kept separate rather than folded into release.yml
# itself: bumping the version and deciding "yes, this commit is a release"
# should stay a reviewable local action, not something CI decides on its
# own — same "спершу лише локально/собі" caution documented in release.sh's
# own header, just relocated to a narrower, cheaper step.
#
# Needs only python3 + git — no Xcode/Swift toolchain — so unlike
# release.sh, this one can run on the Windows machine too (git-bash), not
# just the Mac. Windows parity: this + release.yml together are the mac
# equivalent of Replixer's "bump version -> tag -> push -> release.yml
# takes over" shape.
#
# Usage: Scripts/prepare-release.sh <version>   e.g. Scripts/prepare-release.sh 0.2.1

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>   e.g. $0 0.2.1" >&2
    exit 1
fi

VERSION="$1"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$REPO_DIR/Sources/ReplixerMacApp/Info.plist"

# Refuse to run with a dirty tree — this script's whole job is to produce
# ONE clean commit that is exactly "bump version to $VERSION", nothing
# else; any other pending changes would get swept into that commit and
# muddy release.yml's later `git rev-parse HEAD == origin/main` sanity
# check (see release.yml's "Commit updated appcast.xml to main" step).
if [ -n "$(cd "$REPO_DIR" && git status --porcelain)" ]; then
    echo "prepare-release.sh: working tree is not clean — commit or stash pending changes first." >&2
    exit 1
fi

echo "==> Bumping version to $VERSION"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")"
NEXT_BUILD=$((CURRENT_BUILD + 1))
# Same text-splice approach as release.sh used to do inline, and for the
# same reason: PlistBuddy's `Set` re-serializes the whole plist through
# CFPropertyList, which has no concept of XML comments, silently deleting
# every doc comment in the file (confirmed the hard way on the very first
# real release.sh run — see that script's own comment on this same block).
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
    sys.exit("prepare-release.sh: could not find CFBundleShortVersionString/CFBundleVersion in Info.plist")
open(path, "w", encoding="utf-8").write(text)
PY
echo "    CFBundleShortVersionString = $VERSION, CFBundleVersion = $NEXT_BUILD"

echo "==> Committing, tagging, pushing"
cd "$REPO_DIR"
git add "$INFO_PLIST"
git commit -m "Bump version to $VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"

echo ""
echo "==> Pushed v$VERSION — .github/workflows/release.yml should now be running:"
echo "    https://github.com/antoniukmewgen-byte/ReplixerMac/actions"

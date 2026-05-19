#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  Replixer — macOS build + DMG packager
#  Працює без Apple Developer акаунту (ad-hoc)
# ─────────────────────────────────────────────

APP_NAME="Replixer"
BUNDLE_ID="com.replixer.mac"
VERSION="1.0.0"
MIN_MACOS="13.0"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/$APP_NAME-$VERSION.dmg"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }

# ── 1. Перевірка залежностей ─────────────────
log "Перевірка середовища..."

command -v swift   &>/dev/null || fail "Swift не знайдено. Встанови Xcode."
command -v xcodebuild &>/dev/null || fail "xcodebuild не знайдено. Встанови Xcode."

SWIFT_VER=$(swift --version 2>&1 | head -1)
log "Swift: $SWIFT_VER"

# ── 2. Збірка через Swift PM ─────────────────
log "Збірка (Release)..."

cd "$ROOT_DIR"

swift build \
    -c release \
    --arch arm64 \
    --arch x86_64 2>&1 | grep -v "^$" || fail "Збірка провалилась"

BINARY_PATH=$(swift build -c release --show-bin-path 2>/dev/null)/ReplixerMac
[ -f "$BINARY_PATH" ] || fail "Бінарний файл не знайдено: $BINARY_PATH"

log "Бінарник зібрано: $BINARY_PATH"

# ── 3. Формування .app bundle ────────────────
log "Формування $APP_NAME.app..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Копіюємо бінарник
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Копіюємо Info.plist
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Копіюємо service_account.json якщо є
if [ -f "$ROOT_DIR/service_account.json" ]; then
    cp "$ROOT_DIR/service_account.json" "$APP_BUNDLE/Contents/Resources/"
    log "service_account.json включено"
else
    warn "service_account.json не знайдено — Google Drive буде недоступний"
fi

# ── 4. Іконка (опційно) ──────────────────────
if [ -f "$ROOT_DIR/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" ]; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$ROOT_DIR/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" --out "$ICONSET/icon_16x16.png"    &>/dev/null
    sips -z 32 32     "$ROOT_DIR/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" --out "$ICONSET/icon_32x32.png"    &>/dev/null
    sips -z 128 128   "$ROOT_DIR/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" --out "$ICONSET/icon_128x128.png"  &>/dev/null
    sips -z 256 256   "$ROOT_DIR/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" --out "$ICONSET/icon_256x256.png"  &>/dev/null
    sips -z 512 512   "$ROOT_DIR/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" --out "$ICONSET/icon_512x512.png"  &>/dev/null
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_BUNDLE/Contents/Info.plist"
    log "Іконка додана"
fi

# ── 5. Підпис (ad-hoc — без Developer акаунту) ──
log "Підпис додатку (ad-hoc)..."

codesign \
    --sign "-" \
    --force \
    --deep \
    --timestamp=none \
    --entitlements "$ROOT_DIR/ReplixerMac.entitlements" \
    "$APP_BUNDLE" && log "Підпис: OK" || warn "Підпис не вдався — додаток все одно запуститься локально"

# ── 6. Зняти карантин (щоб macOS не блокував) ──
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# ── 7. Створення DMG через hdiutil ───────────
log "Створення DMG..."

rm -f "$DMG_PATH"

# Тимчасова папка для вмісту DMG
STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"

cp -r "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Створюємо DMG
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

rm -rf "$STAGING"

# ── 8. Результат ─────────────────────────────
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅  Готово!${NC}"
echo -e "   Файл : $DMG_PATH"
echo -e "   Розмір: $DMG_SIZE"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Встановлення:"
echo "  1. Відкрий $APP_NAME-$VERSION.dmg"
echo "  2. Перетягни $APP_NAME.app у папку Applications"
echo "  3. При першому запуску: System Settings → Privacy → дозволь Screen Recording та Microphone"
echo ""

# Відкрити папку з DMG
open -R "$DMG_PATH" 2>/dev/null || true

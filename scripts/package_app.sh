#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$ROOT/.build-scratch"
MODULE_CACHE="$ROOT/.build/ModuleCache"
DIST_DIR="$ROOT/dist"
APP_NAME="MultiPaste"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$BUILD_ROOT/release/$APP_NAME"
VERSION="${1:-0.1.0}"
SIGNING_IDENTITY="${MULTIPASTE_SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN="${MULTIPASTE_SIGNING_KEYCHAIN:-}"

mkdir -p "$MODULE_CACHE" "$BUILD_ROOT" "$DIST_DIR"

SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"

env \
  SDKROOT="$SDKROOT" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift build -c release --scratch-path "$BUILD_ROOT"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.ishaan.multipaste</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

if [[ -n "$SIGNING_IDENTITY" ]]; then
  CODESIGN_ARGS=(
    --force
    --deep
    --options runtime
    --sign "$SIGNING_IDENTITY"
  )

  if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    CODESIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
  fi

  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
xattr -cr "$APP_DIR"

rm -f "$DIST_DIR/$APP_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/$APP_NAME.zip"

echo "Created:"
echo "  $APP_DIR"
echo "  $DIST_DIR/$APP_NAME.zip"

#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$ROOT/.build-scratch"
MODULE_CACHE="$ROOT/.build/ModuleCache"
DIST_DIR="$ROOT/dist"
APP_NAME="MultiPaste"
APP_DIR="$DIST_DIR/$APP_NAME.app"
LAUNCHER_NAME="Open MultiPaste.command"
LAUNCHER_PATH="$DIST_DIR/$LAUNCHER_NAME"
PACKAGE_ROOT="$DIST_DIR/package-root"
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

cat > "$LAUNCHER_PATH" <<'EOF'
#!/bin/zsh
set -euo pipefail

APP_NAME="MultiPaste.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/$APP_NAME"
APPLICATIONS_PATH="/Applications/$APP_NAME"

if [[ -d "$APPLICATIONS_PATH" ]]; then
  APP_PATH="$APPLICATIONS_PATH"
elif [[ ! -d "$APP_PATH" ]]; then
  echo "Could not find $APP_NAME next to this launcher or in /Applications."
  echo "Move this launcher next to $APP_NAME, or drag $APP_NAME into Applications and run this again."
  read -r "?Press Return to close."
  exit 1
fi

xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
open "$APP_PATH"
EOF
chmod +x "$LAUNCHER_PATH"
xattr -c "$LAUNCHER_PATH"

rm -f "$DIST_DIR/$APP_NAME.zip"
rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT"
ditto "$APP_DIR" "$PACKAGE_ROOT/$APP_NAME.app"
ditto "$LAUNCHER_PATH" "$PACKAGE_ROOT/$LAUNCHER_NAME"
ditto -c -k --sequesterRsrc "$PACKAGE_ROOT" "$DIST_DIR/$APP_NAME.zip"
rm -rf "$PACKAGE_ROOT"

echo "Created:"
echo "  $APP_DIR"
echo "  $LAUNCHER_PATH"
echo "  $DIST_DIR/$APP_NAME.zip"

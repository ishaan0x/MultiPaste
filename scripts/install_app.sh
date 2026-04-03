#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MultiPaste"
SOURCE_APP="$ROOT/dist/$APP_NAME.app"
TARGET_APP="/Applications/$APP_NAME.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.ishaan.multipaste.plist"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing built app at $SOURCE_APP"
  echo "Run ./scripts/package_app.sh first."
  exit 1
fi

mkdir -p /Applications
ditto "$SOURCE_APP" "$TARGET_APP"

if [[ -f "$LAUNCH_AGENT" ]]; then
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -f "$TARGET_APP/Contents/MacOS/MultiPaste" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
fi

echo "Updated $TARGET_APP"

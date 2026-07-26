#!/bin/bash
# MySMC Uninstaller
# Usage: sudo ./scripts/uninstall.sh

set -euo pipefail

APP_DST="/Applications/MySMC.app"
PLIST_DST="/Library/LaunchAgents/com.mysmc.app.plist"
LABEL="com.mysmc.app"

if [ "$EUID" -ne 0 ]; then
    echo "Error: run as root — sudo ./scripts/uninstall.sh"
    exit 1
fi

# Stop and unload the LaunchAgent
if [ -f "$PLIST_DST" ]; then
    CONSOLE_USER=$(stat -f '%u' /dev/console 2>/dev/null || id -u)
    echo "Unloading LaunchAgent..."
    launchctl bootout "gui/$CONSOLE_USER" "$PLIST_DST" 2>/dev/null \
        || launchctl unload "$PLIST_DST" 2>/dev/null \
        || true
    rm -f "$PLIST_DST"
    echo "Removed: $PLIST_DST"
fi

# Kill any running instance
pkill -f "MySMC.app/Contents/MacOS/MySMC" 2>/dev/null || true

# Remove the app
if [ -d "$APP_DST" ]; then
    rm -rf "$APP_DST"
    echo "Removed: $APP_DST"
fi

# Remove preferences and profiles
PREFS_DIR="$HOME/Library/Application Support/MySMC"
if [ -d "$PREFS_DIR" ]; then
    read -rp "Remove saved profiles and preferences at $PREFS_DIR? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$PREFS_DIR"
        echo "Removed: $PREFS_DIR"
    fi
fi

echo ""
echo "✓ MySMC uninstalled."

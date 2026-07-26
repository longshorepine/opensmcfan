#!/bin/bash
# MySMC Installer
# Copies the app to /Applications and installs a LaunchAgent so it
# auto-starts as root on every login (no sudo needed after install).
#
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

APP_SRC="$REPO_ROOT/.build/MySMC.app"
APP_DST="/Applications/MySMC.app"
PLIST_SRC="$REPO_ROOT/Resources/com.mysmc.app.plist"
AGENT_DIR="/Library/LaunchAgents"
PLIST_DST="$AGENT_DIR/com.mysmc.app.plist"
LABEL="com.mysmc.app"

# ── Checks ──────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    echo "Error: run as root — sudo ./scripts/install.sh"
    exit 1
fi

if [ ! -d "$APP_SRC" ]; then
    echo "Error: $APP_SRC not found. Run 'make app' first."
    exit 1
fi

# ── Stop any running instance ────────────────────────────────────────────────

if launchctl list "$LABEL" &>/dev/null; then
    echo "Stopping running MySMC instance..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# ── Install app ──────────────────────────────────────────────────────────────

echo "Installing MySMC.app → $APP_DST"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
chown -R root:wheel "$APP_DST"
chmod -R 755 "$APP_DST"

# ── Install LaunchAgent ──────────────────────────────────────────────────────

echo "Installing LaunchAgent → $PLIST_DST"
mkdir -p "$AGENT_DIR"
cp "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

# ── Load it for the current login session ───────────────────────────────────

# Get the UID of the console user (the currently logged-in user)
CONSOLE_USER=$(stat -f '%u' /dev/console 2>/dev/null || id -u)
echo "Starting MySMC for user UID $CONSOLE_USER..."
launchctl bootstrap "gui/$CONSOLE_USER" "$PLIST_DST" 2>/dev/null \
    || launchctl load "$PLIST_DST" 2>/dev/null \
    || true

echo ""
echo "✓ MySMC installed successfully."
echo "  • App:          $APP_DST"
echo "  • Auto-start:   $PLIST_DST (runs as root on every login)"
echo ""
echo "  To uninstall: sudo ./scripts/uninstall.sh"

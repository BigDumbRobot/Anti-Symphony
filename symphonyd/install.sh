#!/bin/sh
# Installs symphonyd as a LaunchAgent for the current user: starts at login, restarts if it exits.
set -eu
cd "$(dirname "$0")/.."
LABEL=ca.arraymusic.symphonyd
DEST="$HOME/Library/Application Support/Anti-Symphony"
BIN="$DEST/symphonyd"
LOG="$HOME/Library/Logs/symphonyd.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

make -s build/symphonyd build/symctl
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
cp build/symphonyd build/symctl "$DEST/"
sed -e "s|__BIN__|$BIN|" -e "s|__LOG__|$LOG|g" symphonyd/$LABEL.plist > "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
if [ -d "build/Symphony Control.app" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Symphony Control.app"
    cp -R "build/Symphony Control.app" "$HOME/Applications/"
    echo "app:       $HOME/Applications/Symphony Control.app"
fi
echo "installed: $BIN"
echo "log:       $LOG"

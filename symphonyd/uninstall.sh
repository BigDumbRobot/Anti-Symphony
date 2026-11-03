#!/bin/sh
# Stops and removes the symphonyd LaunchAgent. The box keeps working until it is power cycled,
# unplugged or the Mac sleeps; after that it shows "!" again.
set -eu
LABEL=ca.arraymusic.symphonyd
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/Library/Application Support/Anti-Symphony/symphonyd" "$HOME/Library/Application Support/Anti-Symphony/symctl"
rm -rf "$HOME/Applications/Symphony Control.app"
echo "removed (kept: profiles and settings in ~/Library/Application Support/Anti-Symphony, log in ~/Library/Logs/symphonyd.log)"

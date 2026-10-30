#!/bin/zsh
# Swap Apogee's USB daemon for a logging copy. Run with: sudo ./capture-start.sh
# Undo with: sudo ./capture-stop.sh
set -e
HERE=${0:A:h}
LOG="$HERE/usbspy.log"

launchctl bootout system /Library/LaunchDaemons/com.SymphonyIOUSBDaemon.plist 2>/dev/null || true
sleep 1
pkill -x symphonyIOUSBDaemon 2>/dev/null || true
sleep 1

: > "$LOG"
chmod 666 "$LOG"
cd "$HERE/daemon-copy"
USBSPY_LOG="$LOG" DYLD_INSERT_LIBRARIES="$HERE/usbspy.dylib" ./symphonyIOUSBDaemon > "$HERE/daemon-stdout.log" 2>&1 &
echo $! > "$HERE/daemon.pid"
sleep 2
echo "Logging daemon running (pid $(cat "$HERE/daemon.pid")). First lines of the log:"
head -5 "$LOG"

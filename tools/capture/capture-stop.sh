#!/bin/zsh
# Stop the logging daemon and restart Apogee's original. Run with: sudo ./capture-stop.sh
HERE=${0:A:h}
pkill -f "$HERE/daemon-copy/symphonyIOUSBDaemon"
pkill -x -f "./symphonyIOUSBDaemon"
sleep 1
pkill -9 -x -f "./symphonyIOUSBDaemon"
rm -f "$HERE/daemon.pid"
sleep 1
launchctl print system/com.SymphonyIOUSBDaemon.plist >/dev/null 2>&1 \
  || launchctl bootstrap system /Library/LaunchDaemons/com.SymphonyIOUSBDaemon.plist
sleep 1
pgrep -lf symphonyIOUSBDaemon

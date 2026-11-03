#!/bin/bash
# Anti-Symphony installer: builds everything on this Mac and installs it for the current user.
#
#   curl -fsSL https://raw.githubusercontent.com/BigDumbRobot/Anti-Symphony/main/install.sh | bash
#
# Or run it from a downloaded copy of the source: ./install.sh
# Remove everything:  ./install.sh --uninstall   (or the same curl line with "| bash -s -- --uninstall")
#
# No admin password, no kernel extension. Needs macOS 14 or later and Apple's free Command Line
# Tools, which this script offers to install. Building here (rather than downloading an app) means
# macOS doesn't block it as an unsigned download.
set -euo pipefail

REPO="BigDumbRobot/Anti-Symphony"
BRANCH="${ANTI_SYMPHONY_BRANCH:-main}"
CACHE="$HOME/Library/Caches/Anti-Symphony"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- uninstall ----
if [ "${1:-}" = "--uninstall" ]; then
    LABEL=ca.arraymusic.symphonyd
    say "Removing Anti-Symphony"
    osascript -e 'quit app "Symphony Control"' >/dev/null 2>&1 || true
    pkill -f "Symphony Control.app/Contents/MacOS/SymphonyControl" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
    rm -f "$HOME/Library/Application Support/Anti-Symphony/symphonyd" "$HOME/Library/Application Support/Anti-Symphony/symctl"
    rm -rf "$HOME/Applications/Symphony Control.app" "$CACHE"
    echo "Removed. Your profiles and settings are kept in ~/Library/Application Support/Anti-Symphony"
    echo "(delete that folder too if you want them gone)."
    exit 0
fi

# ---- checks ----
[ "$(uname -s)" = Darwin ] || fail "Anti-Symphony runs on macOS only."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 14 ] || fail "macOS 14 (Sonoma) or later is needed; this Mac has $(sw_vers -productVersion)."

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
    say "Installing Apple's Command Line Tools (free, about 1 GB)"
    echo "A window will ask you to install them: click Install and accept the licence."
    xcode-select --install >/dev/null 2>&1 || true
    printf "Waiting for the install to finish"
    for _ in $(seq 1 720); do                     # up to an hour
        if xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; then break; fi
        printf "."; sleep 5
    done
    echo
    xcrun --find swift >/dev/null 2>&1 || fail "The Command Line Tools aren't installed yet. Install them, then run this again."
fi

# ---- source: this folder if run from a copy, else download ----
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/Makefile" ] && [ -d "$HERE/symphonyd" ] && [ -d "$HERE/app" ]; then
    SRC="$HERE"
    say "Building from $SRC"
else
    say "Downloading Anti-Symphony ($BRANCH)"
    rm -rf "$CACHE/source" && mkdir -p "$CACHE/source"
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
        | tar -xz -C "$CACHE/source" --strip-components 1 \
        || fail "Couldn't download the source. Check the internet connection and try again."
    SRC="$CACHE/source"
fi
cd "$SRC"

# ---- build ----
say "Building symphonyd (background service) — a few seconds"
make -s WERROR= build/symphonyd build/symctl || fail "symphonyd didn't build (see the messages above)."

say "Building Symphony Control (the app) — a minute or two the first time"
app/build.sh || fail "Symphony Control didn't build (see the messages above)."

# ---- install ----
say "Installing"
osascript -e 'quit app "Symphony Control"' >/dev/null 2>&1 || true
pkill -f "Symphony Control.app/Contents/MacOS/SymphonyControl" 2>/dev/null || true
sleep 1
symphonyd/install.sh
open "$HOME/Applications/Symphony Control.app"

cat <<EOF

$(printf '\033[1;32m')Anti-Symphony $(cat VERSION) is installed.$(printf '\033[0m')
  • Symphony Control is open, and in ~/Applications. It also lives in the menu bar (speaker icon).
  • symphonyd runs in the background and starts at login. Log: ~/Library/Logs/symphonyd.log
  • Plug in and power on the Symphony: the "!" on its front panel clears within a second or two.
  • Update later by running the same command again.
EOF

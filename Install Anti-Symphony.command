#!/bin/bash
# Double-click to build and install Anti-Symphony from this folder.
# First time: if macOS says it can't verify this file, right-click it and choose Open.
cd "$(dirname "$0")" && ./install.sh
echo; read -n 1 -s -r -p "Done. Press any key to close this window."

#!/bin/bash
# Builds Puffer, installs it to /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

# Ask a running copy to quit so it saves first; wait for it to go.
osascript -e 'tell application id "co.yuca.puffer" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x Puffer >/dev/null || break
  sleep 0.3
done
pkill -x Puffer 2>/dev/null || true

rm -rf /Applications/Puffer.app
cp -R dist/Puffer.app /Applications/Puffer.app
open /Applications/Puffer.app
echo "Installed /Applications/Puffer.app"

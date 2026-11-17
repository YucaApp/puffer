#!/bin/bash
# Runs the unit tests.
#
# With full Xcode installed plain `swift test` works. With only the Command
# Line Tools, the Swift Testing macro plugin is installed but not on the
# compiler's default plugin path, so point at it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ "$(xcode-select -p)" == *CommandLineTools* && -d "$plugins" ]]; then
  flags=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi

swift test ${flags[@]+"${flags[@]}"} "$@"

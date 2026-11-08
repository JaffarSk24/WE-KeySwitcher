#!/bin/zsh
# Runs the unit tests. With only the Command Line Tools installed, Swift
# Testing lives in a framework folder SwiftPM does not search by default, and
# its Foundation overlay is missing, so cross-import overlays are turned off.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d "$F/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  swift test -Xswiftc -F"$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" "$@"
else
  swift test "$@"
fi

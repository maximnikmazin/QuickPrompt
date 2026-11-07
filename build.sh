#!/bin/zsh
# Builds QuickPrompt.app and installs it into ~/Applications.
# Signs with the "Apple Development" certificate when one exists, so that macOS keeps the Accessibility
# permission across rebuilds; otherwise signs ad hoc, and every rebuild needs the permission again.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/QuickPrompt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/QuickPrompt "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc (no Apple Development certificate found)"
fi

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/QuickPrompt.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/QuickPrompt.app"

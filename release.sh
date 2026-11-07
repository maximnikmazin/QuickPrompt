#!/bin/zsh
# Builds the download for a GitHub release: build/QuickPrompt.zip with QuickPrompt.app inside.
# The app is universal (Apple silicon and Intel) and signed ad hoc. It is not notarised, so it is meant to be
# installed with install.sh: files downloaded with curl are not quarantined, and macOS opens them without a warning.
# Usage: ./release.sh, then: gh release create v<version> build/QuickPrompt.zip
set -euo pipefail
cd "$(dirname "$0")"

PUBLIC_ID="io.github.maximnikmazin.quickprompt"
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
[[ "$ID" == "$PUBLIC_ID" ]] || { echo "Info.plist has bundle identifier $ID, not $PUBLIC_ID. Run this in the public repository."; exit 1; }

# The prefix map keeps the build folder's path, which contains the user name, out of the binary.
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
BINARY=.build/apple/Products/Release/QuickPrompt
if strings "$BINARY" | grep -q "$HOME"; then
    echo "The binary contains the path of your home folder; stopping."
    exit 1
fi

APP=build/QuickPrompt.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/QuickPrompt.zip

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
echo "Built build/QuickPrompt.zip (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/QuickPrompt"))"
shasum -a 256 build/QuickPrompt.zip

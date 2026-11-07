#!/bin/zsh
# Installs QuickPrompt from the latest GitHub release into ~/Applications and starts it.
#   curl -fsSL https://raw.githubusercontent.com/maximnikmazin/QuickPrompt/main/install.sh | zsh
# Running it again updates the app. Settings in ~/Library/Application Support/QuickPrompt are kept.
# For testing: QUICKPROMPT_ZIP=<path to a zip> uses a local file; QUICKPROMPT_NO_OPEN=1 does not start the app.
set -euo pipefail

REPO="maximnikmazin/QuickPrompt"
ID="io.github.maximnikmazin.quickprompt"
TARGET="$HOME/Applications/QuickPrompt.app"

say() { print -- "$@"; }
fail() { print -u2 -- "QuickPrompt: $@"; exit 1; }

# macOS 26 or later: the app uses the Translation framework of macOS 26.
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MAJOR >= 26 )) || fail "needs macOS 26 (Tahoe) or later; this Mac has $(sw_vers -productVersion)."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${QUICKPROMPT_ZIP:-}" ]]; then
    cp "$QUICKPROMPT_ZIP" "$WORK/QuickPrompt.zip"
else
    say "Downloading the latest QuickPrompt…"
    curl -fsSL "https://github.com/$REPO/releases/latest/download/QuickPrompt.zip" -o "$WORK/QuickPrompt.zip" \
        || fail "the download failed. Check the internet connection, or see https://github.com/$REPO/releases."
fi
ditto -x -k "$WORK/QuickPrompt.zip" "$WORK" || fail "the downloaded file is not a valid zip."
[[ -d "$WORK/QuickPrompt.app" ]] || fail "the download has no QuickPrompt.app inside."
codesign --verify "$WORK/QuickPrompt.app" 2>/dev/null || fail "the app's signature is broken."

UPDATE=false
if [[ -d "$TARGET" ]]; then
    UPDATE=true
    osascript -e 'tell application id "'"$ID"'" to quit' >/dev/null 2>&1 || true
    pkill -f "$TARGET/Contents/MacOS/QuickPrompt" 2>/dev/null || true
    sleep 1
    rm -rf "$TARGET"
fi
mkdir -p "$HOME/Applications"
ditto "$WORK/QuickPrompt.app" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# The app is signed ad hoc, so macOS treats every new build as a new app. The old Accessibility entry would stay
# switched on but no longer work; removing it makes the app ask again cleanly.
if $UPDATE; then
    tccutil reset Accessibility "$ID" >/dev/null 2>&1 || true
fi

say "Installed $TARGET"
say ""
say "What is needed for the actions:"
if command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" || -x /opt/homebrew/bin/claude || -x /usr/local/bin/claude ]]; then
    say "  ✓ Claude Code is installed. If it is not signed in yet, run: claude   and sign in with your Claude subscription."
else
    say "  • Claude Code is not installed. Most actions use it: https://claude.com/claude-code (sign in with a Claude subscription)."
fi
if command -v codex >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/codex" || -x /opt/homebrew/bin/codex || -x /usr/local/bin/codex || -x "$HOME/.npm-global/bin/codex" || -x "$HOME/.bun/bin/codex" ]]; then
    say "  ✓ Codex is installed (optional). If it is not signed in yet, run: codex login"
else
    say "  • Codex is optional; without it, the settings offer no Codex models."
fi
say "  • Translate (⇧⌘C) runs on the Mac with Apple Translation. Download your language and English in"
say "    System Settings → General → Language & Region → Translation Languages."
say ""
say "Next: when QuickPrompt asks for Accessibility access, click Open System Settings and switch QuickPrompt on."
say "It needs it to copy the selection (⌘C) and paste results (⌘V). Then select text anywhere and press ⇧⌘C."
say "The app lives in the menu bar (speech-bubble icon); it has no Dock icon."

if [[ -z "${QUICKPROMPT_NO_OPEN:-}" ]]; then
    open "$TARGET"
fi

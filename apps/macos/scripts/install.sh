#!/bin/sh
# Builds and installs voz to /Applications — the stable home the permission grants
# are tied to. Rebuilding re-signs the app; with a stable identity (see bundle.sh)
# the Accessibility / Microphone grants carry over.
set -e
cd "$(dirname "$0")/.."
sh scripts/bundle.sh
killall voz 2>/dev/null || true
rm -rf /Applications/voz.app
ditto build/voz.app /Applications/voz.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/voz.app
open /Applications/voz.app
echo "Installed and launched /Applications/voz.app"
echo "Each capability prompts only for what it needs the first time you use it:"
echo "  • Read aloud (⌃V): Accessibility (to read your selection)"
echo "  • Dictate (hold ⌃+⌥): Microphone + Accessibility (to type the result)"

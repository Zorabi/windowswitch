#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/setup-signing.py
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/WindowSwitch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Config/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
ditto Config/Localizations "$app/Contents/Resources"
cp "$bin_dir/WindowSwitch" "$app/Contents/MacOS/WindowSwitch"
swift scripts/make-icon.swift build/WindowSwitch.iconset Assets/AppIcon.png
iconutil -c icns build/WindowSwitch.iconset -o "$app/Contents/Resources/AppIcon.icns"
identity="$(cat Config/signing-fingerprint.txt)"
codesign --force --sign "$identity" --identifier dongx.windowswitch --options runtime --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"
codesign --display --requirements - "$app" > build/designated-requirement.txt 2>&1
python3 - <<'PY'
from pathlib import Path
import re
p=Path('build/designated-requirement.txt')
text=p.read_text()
requirement=next((line for line in text.splitlines() if line.startswith('designated =>')),None)
if not requirement or 'dongx.windowswitch' not in requirement or 'cdhash' in requirement:
    raise SystemExit('Unstable or unexpected signing requirement; installation is blocked.')
pin=Path('Config/designated-requirement.txt')
if pin.exists() and pin.read_text().strip()!=requirement:
    raise SystemExit('Designated requirement changed; installation is blocked.')
pin.write_text(requirement+'\n')
print('Stable application identity verified.')
PY
if [[ "${1:-}" == "--install" ]]; then
    pkill -TERM -f '^/Applications/WindowSwitch[.]app/Contents/MacOS/WindowSwitch$' || true
    for attempt in {1..30}; do
        if ! pgrep -f '^/Applications/WindowSwitch[.]app/Contents/MacOS/WindowSwitch$' > /dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -f '^/Applications/WindowSwitch[.]app/Contents/MacOS/WindowSwitch$' > /dev/null; then
        echo 'WindowSwitch has not exited; installation stopped.' >&2
        exit 1
    fi
    ditto "$app" /Applications/WindowSwitch.app
    codesign --verify --strict /Applications/WindowSwitch.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/WindowSwitch.app
    open -n /Applications/WindowSwitch.app
fi

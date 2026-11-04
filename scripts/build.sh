#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/setup-signing.py
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/.Products.noindex/窗序.app"
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
    installed="/Applications/窗序.app"
    legacy="/Applications/WindowSwitch.app"
    lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    process_pattern='^/Applications/(WindowSwitch|窗序)[.]app/Contents/MacOS/WindowSwitch$'
    requirement="$(sed -n 's/^designated => //p' build/designated-requirement.txt)"
    for existing in "$installed" "$legacy"; do
        if [[ -e "$existing" || -L "$existing" ]]; then
            codesign --verify --strict -R "=$requirement" "$existing"
        fi
    done
    if [[ -e "$installed" && -e "$legacy" ]]; then
        echo 'Both application paths exist; installation stopped to avoid replacing either copy.' >&2
        exit 1
    fi
    pkill -TERM -f "$process_pattern" || true
    for attempt in {1..30}; do
        if ! pgrep -f "$process_pattern" > /dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -f "$process_pattern" > /dev/null; then
        echo 'WindowSwitch has not exited; installation stopped.' >&2
        exit 1
    fi
    if [[ -d "$legacy" ]]; then
        "$lsregister" -u "$legacy"
        mv "$legacy" "$installed"
    fi
    ditto "$app" "$installed"
    codesign --verify --strict "$installed"
    "$lsregister" -f "$installed"
    open -n "$installed"
fi

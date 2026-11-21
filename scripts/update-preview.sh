#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }
[[ $# == 0 ]] || fail "Usage: $0"
cd "$(cd "$(dirname "$0")/.." && pwd -P)"

review="$PWD/build/unrated-stars-review"
preview="$review/Phosdeck Preview.app"
preview_id="dev.cmkk.oh-my-lrc.unratedstars20261021"
source_app="build/Build/Products/Debug/Phosdeck.app"
[[ -d "$preview" && ! -L "$preview" ]] || fail "The fixed Preview app is missing."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$preview/Contents/Info.plist")" == "$preview_id" ]] ||
    fail "The installed Preview app has a different identity."
/usr/bin/codesign --verify --strict --deep "$preview"

stage="$(/usr/bin/mktemp -d "$review/.preview-update.XXXXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
/usr/bin/codesign --display --extract-certificates="$stage/cert-" "$preview"
[[ -s "$stage/cert-0" ]] || fail "The installed Preview app has no developer certificate."
identity="$(/usr/bin/shasum "$stage/cert-0" | /usr/bin/awk '{print toupper($1)}')"

running() {
    /bin/ps -axo comm= | /usr/bin/grep -Fx "$preview/Contents/MacOS/Phosdeck" >/dev/null
}
if running; then
    /usr/bin/osascript -e 'tell application id "dev.cmkk.oh-my-lrc.unratedstars20261021" to quit'
    for ((attempt = 0; attempt < 40; attempt++)); do
        if ! running; then break; fi
        sleep 0.25
    done
fi
if running; then fail "Finish closing the Preview app before updating it."; fi

xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Debug \
    -derivedDataPath build -destination 'platform=macOS' build
app="$stage/Phosdeck Preview.app"
/usr/bin/ditto "$source_app" "$app"
python3 scripts/bind-preview-photo-tools.py "$app"

sign() {
    /usr/bin/codesign --force --sign "$identity" --timestamp=none --preserve-metadata=entitlements,flags "$1"
}
while IFS= read -r -d '' library; do
    sign "$library"
done < <(/usr/bin/find "$app/Contents" -type f -name '*.dylib' -print0)
for extension in "$app"/Contents/Extensions/*.appex; do
    sign "$extension"
done
sign "$app"
/usr/bin/codesign --verify --strict --deep "$app"
if running; then fail "The Preview app reopened while its update was being prepared."; fi

swap_bundles() {
    # Keep the old signed bundle in staging until the new path is verified.
    python3 - "$app" "$preview" <<'PY'
import ctypes
import os
import sys

rename_swap = 0x00000002  # RENAME_SWAP in the macOS SDK
rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
rename.restype = ctypes.c_int
if rename(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), rename_swap):
    raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()), sys.argv[2])
PY
}
swap_bundles
if ! /usr/bin/codesign --verify --strict --deep "$preview"; then
    if ! swap_bundles; then
        trap - EXIT
        fail "The previous Preview app is preserved at $app"
    fi
    fail "The installed signature failed verification. Restored the previous Preview app."
fi
printf 'Updated %s\n' "$preview"

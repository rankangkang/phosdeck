#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }
[[ $# == 1 ]] || fail "Usage: $0 /path/to/exported/Phosdeck.app"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
[[ -d "$app" && "${app##*/}" == Phosdeck.app ]] || fail "Expected an exported Phosdeck.app"
info="$app/Contents/Info.plist"
read_info() { /usr/libexec/PlistBuddy -c "Print :$1" "$info"; }
[[ "$(read_info CFBundleIdentifier)" == dev.cmkk.oh-my-lrc ]] || fail "Unexpected bundle identifier"
version="$(read_info PhosdeckReleaseVersion)"
marketing="$(read_info CFBundleShortVersionString)"
build="$(read_info CFBundleVersion)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9]+(\.[a-z0-9]+)*$ &&
   "$version" == "$marketing-"* && "$build" =~ ^[1-9][0-9]*$ ]] || fail "Invalid release version or build number"

signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)" || fail "Cannot inspect the app signature"
[[ "$signature" == *"Authority=Developer ID Application:"* && "$signature" == *"Timestamp="* &&
   "$signature" == *"runtime"* ]] || fail "A timestamped Developer ID Application signature with hardened runtime is required"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/codesign --display --entitlements :- "$app" 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
actual = plistlib.loads(sys.stdin.buffer.read())
with open(sys.argv[1], "rb") as source:
    expected = plistlib.load(source)
if any(actual.get(key) != value for key, value in expected.items()) or actual.get("com.apple.security.get-task-allow"):
    sys.exit("Exported app does not preserve the required entitlements")
' "$root/Sources/App/Phosdeck.entitlements"
/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app"

resources="$app/Contents/Resources"
[[ -d "$resources/SmartMaskModels" && -z "$(/bin/ls -A "$resources/SmartMaskModels")" ]] || fail "Release must not contain research models"
for notice in LICENSE grdb-LICENSE.txt litert-NOTICES.txt SmartMaskRuntime-LICENSE.txt oklab-LICENSE.txt lightcraft-LICENSE.txt; do
    [[ -s "$resources/$notice" ]] || fail "Missing bundled notice: $notice"
done

/bin/mkdir -p "$root/build/releases"
directory="$(/usr/bin/mktemp -d "$root/build/releases/$version.XXXXXXXX")"
partial="$directory/.Phosdeck.partial.zip"
output="$directory/Phosdeck-$version.zip"
printf 'Working directory: %s\n' "$directory"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$partial"
/bin/mkdir "$directory/check"
/usr/bin/ditto -x -k "$partial" "$directory/check"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$directory/check/Phosdeck.app"
/usr/bin/xcrun stapler validate "$directory/check/Phosdeck.app"

# The exclusive link publishes only a flushed, read-back archive on the same volume.
/usr/bin/python3 -c 'import os,sys; f=os.open(sys.argv[1],os.O_RDONLY); os.fsync(f); os.close(f)' "$partial"
/bin/ln "$partial" "$output"
/usr/bin/cmp "$partial" "$output"
/usr/bin/shasum -a 256 "$output"
/bin/rm "$partial"
printf 'Local package: %s\n' "$output"

#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }
[[ $# == 1 ]] || fail "Usage: $0 /path/to/exported/Phosdeck.app"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
"$root/scripts/verify-release.sh" "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :PhosdeckReleaseVersion' "$app/Contents/Info.plist")"

/bin/mkdir -p "$root/build/releases"
directory="$(/usr/bin/mktemp -d "$root/build/releases/$version.XXXXXXXX")"
partial="$directory/.Phosdeck.partial.zip"
output="$directory/Phosdeck-$version.zip"
printf 'Working directory: %s\n' "$directory"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$partial"
/bin/mkdir "$directory/check"
/usr/bin/ditto -x -k "$partial" "$directory/check"
"$root/scripts/verify-release.sh" "$directory/check/Phosdeck.app" "$version"

# The exclusive link publishes only a flushed, read-back archive on the same volume.
/usr/bin/python3 -c 'import os,sys; f=os.open(sys.argv[1],os.O_RDONLY); os.fsync(f); os.close(f)' "$partial"
/bin/ln "$partial" "$output"
/usr/bin/cmp "$partial" "$output"
/usr/bin/shasum -a 256 "$output"
/bin/rm "$partial"
printf 'Local package: %s\n' "$output"

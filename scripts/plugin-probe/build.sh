#!/bin/bash
set -euo pipefail

if [[ $# != 3 ]]; then
    echo "Usage: $0 <host signing identity> <host Team ID> <vendor signing identity>" >&2
    exit 2
fi
host_identity="$1"
host_team="$2"
vendor_identity="$3"
[[ "$host_team" =~ ^[A-Z0-9]{10}$ ]]
sources="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$sources/../.." && pwd)"
mkdir -p "$root/build/plugin-probe"
output="$(mktemp -d "$root/build/plugin-probe/run.XXXXXXXX")"
cp "$sources/"*.swift "$sources/project.yml" "$output/"
xcodegen generate --spec "$output/project.yml" --quiet
printf 'Probe run directory: %s\n' "$output"
xcodebuild -project "$output/PluginProbe.xcodeproj" -scheme PluginProbe -configuration Release \
    -derivedDataPath "$output/Derived" -destination 'platform=macOS' ARCHS=arm64 build >"$output/build.log" 2>&1 || {
    tail -100 "$output/build.log" >&2
    exit 1
}

products="$output/Derived/Build/Products/Release"
host="$products/ProbeHost.app"
vendor="$products/ProbeVendor.app"
extension_entitlements="$output/extension.entitlements"
cat >"$extension_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST

sign() {
    local app="$1" extension="$2" identity="$3" app_entitlements="$4"
    /usr/libexec/PlistBuddy -c "Add :ProbeHostTeam string $host_team" "$extension/Contents/Info.plist"
    codesign --force --options runtime --sign "$identity" --entitlements "$extension_entitlements" "$extension"
    codesign --force --options runtime --sign "$identity" --entitlements "$app_entitlements" "$app"
    codesign --verify --strict --deep --verbose=2 "$app"
    for bundle in "$app" "$extension"; do
        codesign --display --verbose=4 --entitlements - "$bundle" >>"$output/signing.log" 2>&1
    done
}

sign "$host" "$host/Contents/Extensions/BundledTone.appex" "$host_identity" "$root/Sources/App/Phosdeck.entitlements"
sign "$vendor" "$vendor/Contents/Extensions/VendorTone.appex" "$vendor_identity" "$extension_entitlements"
codesign --display --verbose=4 "$host" 2>&1 | /usr/bin/grep -Fx "TeamIdentifier=$host_team"
printf 'Host: %s\nVendor: %s\n' "$host" "$vendor"

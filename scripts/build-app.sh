#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Sync Claude.app"
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$PWD/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Sync Claude.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/SyncClaude" "$bundle/Contents/MacOS/SyncClaude"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SyncClaude</string>
<key>CFBundleIdentifier</key><string>com.syncclaude.desktop</string>
<key>CFBundleName</key><string>Sync Claude</string>
<key>CFBundleDisplayName</key><string>Sync Claude</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.3</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --deep --strict "$bundle"
rm -rf "$app"
mv "$bundle" "$app"
print "Built: $app"

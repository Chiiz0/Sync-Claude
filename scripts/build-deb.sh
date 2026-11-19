#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build against Noble's glibc so this package runs on both Ubuntu LTS releases.
. /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]] || ! command -v swift >/dev/null; then
    exec docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$PWD:/src" -w /src swift:6.1 bash scripts/build-deb.sh
fi

version=0.1.10-1
arch=$(dpkg --print-architecture)
swift build -c release --static-swift-stdlib --force-resolved-versions -j "${SWIFT_JOBS:-4}"
bin=$(swift build -c release --show-bin-path)
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.deb-XXXXXX")
trap 'rm -rf "$stage"' EXIT
pkg="$stage/pkg"
install -Dm755 "$bin/SyncClaude" "$pkg/usr/lib/sync-claude/SyncClaude"
strip --strip-unneeded "$pkg/usr/lib/sync-claude/SyncClaude"
install -Dm644 linux/window.py "$pkg/usr/lib/sync-claude/window.py"
install -Dm755 linux/sync-claude "$pkg/usr/bin/sync-claude"
install -Dm644 linux/com.syncclaude.desktop.desktop "$pkg/usr/share/applications/com.syncclaude.desktop.desktop"
install -Dm644 linux/com.syncclaude.desktop.gschema.xml "$pkg/usr/share/glib-2.0/schemas/com.syncclaude.desktop.gschema.xml"
docs="$pkg/usr/share/doc/sync-claude"
install -Dm644 LICENSE "$docs/copyright"
install -m644 /usr/share/swift/LICENSE.txt "$docs/Swift-LICENSE.txt"
install -m644 .build/checkouts/swift-crypto/LICENSE.txt "$docs/SwiftCrypto-LICENSE.txt"
install -m644 .build/checkouts/swift-crypto/NOTICE.txt "$docs/SwiftCrypto-NOTICE.txt"
mkdir -p "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: sync-claude
Version: $version
Architecture: $arch
Maintainer: Sync Claude contributors <noreply@github.com>
Section: utils
Priority: optional
Depends: libc6 (>= 2.39), libgcc-s1, libstdc++6, libcurl4t64, libgtk-3-bin, gir1.2-gtk-3.0, python3-gi, python3, libsecret-tools
Recommends: gnome-keyring
Homepage: https://github.com/Chiiz0/Sync-Claude
Description: Switch Claude Desktop profiles and sync local Claude Code history
 GTK application and command-line tools for native Claude Desktop installations.
CONTROL
name="sync-claude_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz -z5 --build "$pkg" "$stage/$name"
mv "$stage/$name" "dist/$name"
echo "dist/$name"

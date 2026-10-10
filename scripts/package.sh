#!/bin/zsh
# Builds Стежа.app and wraps it into dist/Stezha-<version>.dmg / .zip for a GitHub release.
set -e
cd "$(dirname "$0")/.."
./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p dist
STAGE=$(mktemp -d)
cp -R "build/Стежа.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/Stezha-$VER.dmg" "dist/Stezha-$VER.zip"
hdiutil create -volname "Стежа $VER" -srcfolder "$STAGE" -ov -format UDZO "dist/Stezha-$VER.dmg" >/dev/null
(cd build && ditto -c -k --keepParent "Стежа.app" "../dist/Stezha-$VER.zip")
echo "dist/Stezha-$VER.dmg"

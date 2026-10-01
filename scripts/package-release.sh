#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' KinoStream/Info.plist)"
RELEASE_DIR="$PROJECT_ROOT/dist/v$VERSION"
DERIVED_DIR="$PROJECT_ROOT/.build/ReleaseDerivedData"
APP="$RELEASE_DIR/KinoStream.app"
mkdir -p "$RELEASE_DIR"
if [[ -e "$APP" ]]; then
    echo "Release app already exists. Choose a new version or move the old output first." >&2
    exit 1
fi
python3 scripts/validate-release-config.py .env
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project KinoStream.xcodeproj -scheme KinoStream -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DIR" \
    -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/XcodeDerivedData/SourcePackages" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    build CODE_SIGNING_ALLOWED=NO -quiet
ditto "$DERIVED_DIR/Build/Products/Release/KinoStream.app" "$APP"
python3 scripts/validate-release-config.py "$APP/Contents/Resources/.env"
[[ "$(lipo -archs "$APP/Contents/MacOS/KinoStream")" == arm64 ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/TorrServer")" == arm64 ]]
NOTICES="$APP/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$NOTICES"
cp KinoStream/Vendor/TorrServer/LICENSE "$NOTICES/TorrServer-GPL-3.0.txt"
cp KinoStream/Vendor/TorrServer/README.md "$NOTICES/TorrServer.md"
for dependency in "$PROJECT_ROOT/.build/XcodeDerivedData/SourcePackages/checkouts/"*; do
    for license in LICENSE LICENSE.txt LICENSE.md; do
        if [[ -f "$dependency/$license" ]]; then
            cp "$dependency/$license" "$NOTICES/$(basename "$dependency")-$license"
            break
        fi
    done
done
# Local ad hoc signatures support execution on arm64. This is not Developer ID
# signing or Apple notarization; the release notes must explain that limitation.
codesign --force --sign - "$APP/Contents/MacOS/TorrServer"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_DIR/KinoStream-$VERSION-macos-arm64.zip"
STAGING="$RELEASE_DIR/dmg-content"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/KinoStream.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "KinoStream $VERSION" -srcfolder "$STAGING" -ov -format UDZO \
    "$RELEASE_DIR/KinoStream-$VERSION-macos-arm64.dmg"
cp "docs/releases/v$VERSION.md" "$RELEASE_DIR/RELEASE-NOTES.md"
cp docs/TORRSERVER-SOURCE.md "$RELEASE_DIR/TORRSERVER-SOURCE.md"
echo "Release files prepared in $RELEASE_DIR. No files have been uploaded."

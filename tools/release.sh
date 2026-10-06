#!/bin/zsh
# Build carroto.app and zip it for a release.
#   tools/release.sh   → dist/carroto.zip
set -e
cd "${0:A:h}/.."
rm -rf build-release dist && mkdir -p dist
xcodebuild -project lil-agents.xcodeproj -scheme LilAgents -configuration Release -derivedDataPath build-release \
  PRODUCT_NAME=carroto PRODUCT_BUNDLE_IDENTIFIER=com.carrotpothead.carroto INFOPLIST_KEY_CFBundleDisplayName=carroto \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build | grep -E "error:|BUILD"
APP=build-release/Build/Products/Release/carroto.app
# (two looks: Outfits/classic is the default; the glasses look is the main set of clips in LilAgents/)
# no debug symbols: they carry the build folder's path
strip -S -x "$APP/Contents/MacOS/carroto"
# the licences travel with the app
cp LICENSE FONTS-LICENSE.txt "$APP/Contents/Resources/"
# ad-hoc sign (no Apple developer account): runs after right-click → Open the first time
codesign --force --deep --sign - "$APP"
# one neutral time on every file, zipped in UTC (zip entries store local time)
find "$APP" -exec env TZ=UTC touch -h -t 202610060000 {} +
TZ=UTC ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" dist/carroto.zip   # (no hidden ._ files: plain unzip stays valid)
echo "dist/carroto.zip ($(du -h dist/carroto.zip | cut -f1))"

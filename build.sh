#!/bin/zsh
# Builds "All Menus.app" next to this script.
set -e
cd "${0:A:h}"
APP="All Menus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ! -f Resources/AppIcon.icns ]]; then
  TMP=$(mktemp -d)
  swiftc -O Tools/MakeIcon.swift -o $TMP/makeicon && $TMP/makeicon $TMP/AppIcon.iconset && iconutil -c icns $TMP/AppIcon.iconset -o Resources/AppIcon.icns
  rm -rf $TMP
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
python3 Tools/strings.py >/dev/null
rm -rf "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ko.lproj"
cp -R Resources/en.lproj Resources/ko.lproj "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/AllMenus"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.allmenus</string>
  <key>CFBundleName</key><string>All Menus</string>
  <key>CFBundleDisplayName</key><string>All Menus</string>
  <key>CFBundleExecutable</key><string>AllMenus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Sign with the local certificate when present ("All Menus Local Signing" in the login keychain), so the
# signature's designated requirement stays the same across rebuilds and macOS keeps the granted permissions.
# Without it, fall back to ad-hoc signing (permissions must then be re-enabled after every build).
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"All Menus Local Signing"/ {print $2; exit}')
if [[ -n "$ID" ]]; then
  codesign --force --sign "$ID" "$APP"
else
  echo "note: no 'All Menus Local Signing' certificate, signing ad-hoc"
  codesign --force --sign - "$APP"
fi
echo "built $PWD/$APP"

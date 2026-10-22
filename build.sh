#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
# shortcut: the current default build engine stalls locally; retry it after a toolchain update.
swift build --build-system native -c release --disable-sandbox -debug-info-format none
bundle="$PWD/Glint.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/Glint "$bundle/Contents/MacOS/Glint"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.glint.switcher</string>
<key>CFBundleName</key><string>Glint</string>
<key>CFBundleDisplayName</key><string>Glint</string>
<key>CFBundleExecutable</key><string>Glint</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Justus August. MIT License.</string>
</dict></plist>
PLIST
xcrun actool Assets/Glint.icon --compile "$bundle/Contents/Resources" --platform macosx \
    --target-device mac --minimum-deployment-target 26.0 --app-icon Glint \
    --output-partial-info-plist .build/icon-info.plist --output-format human-readable-text --warnings --errors
/usr/libexec/PlistBuddy -c "Merge .build/icon-info.plist" "$bundle/Contents/Info.plist"
identity=${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development:/ { print $2; exit }')}
# A development identity keeps macOS permission identity stable between local builds.
codesign --force --sign "${identity:--}" --options runtime --timestamp=none --identifier local.glint.switcher "$bundle"
codesign --verify --strict "$bundle"
print "Built $bundle"

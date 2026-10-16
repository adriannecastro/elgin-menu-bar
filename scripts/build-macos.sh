#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
FINAL_APP_PATH="$PROJECT_ROOT/local/Elgin Menu Bar.app"
TASK_BUILD_DIRECTORY="$(mktemp -d /private/tmp/elgin-build.XXXXXX)"
trap 'rm -rf "$TASK_BUILD_DIRECTORY"' EXIT
APP_PATH="$TASK_BUILD_DIRECTORY/Elgin Menu Bar.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$PROJECT_ROOT/local/swift-cache"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos13.0" -O -module-cache-path "$PROJECT_ROOT/local/swift-cache" \
  "$PROJECT_ROOT"/macos/Sources/*.swift -o "$APP_PATH/Contents/MacOS/ElginMenuBar"
mkdir -p "$APP_PATH/Contents/Resources"
ditto --noextattr "$PROJECT_ROOT/macos/Sources/Resources" "$APP_PATH/Contents/Resources"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ElginMenuBar</string>
<key>CFBundleIdentifier</key><string>com.adrianne.elginmenubar.preview</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>pt</string></array>
<key>CFBundleName</key><string>Elgin Menu Bar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Consultar e controlar os aparelhos do quarto pela rede local.</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
xattr -dr com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
codesign --force --sign - "$APP_PATH"
ditto --noextattr "$APP_PATH" "$FINAL_APP_PATH"
xattr -dr com.apple.FinderInfo "$FINAL_APP_PATH" 2>/dev/null || true
print "App criado: $FINAL_APP_PATH"

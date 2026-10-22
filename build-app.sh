#!/bin/zsh
# Builds a release binary and wraps it in a menu-bar-only .app bundle (no Dock icon).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/LLMMemCleaner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LLMMemCleaner "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LLM Mem Cleaner</string>
  <key>CFBundleIdentifier</key><string>local.llm-mem-cleaner</string>
  <key>CFBundleExecutable</key><string>LLMMemCleaner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

# --install: copy to ~/Applications so the login item points at a stable path.
if [[ "$1" == "--install" ]]; then
  pkill -x LLMMemCleaner || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/LLMMemCleaner.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/LLMMemCleaner.app
  echo "Installed to ~/Applications/LLMMemCleaner.app"
fi

#!/bin/bash
# Builds NotifCorner.app and installs it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=NotifCorner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.alonso.NotifCorner</string>
  <key>CFBundleName</key><string>NotifCorner</string>
  <key>CFBundleExecutable</key><string>NotifCorner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

swiftc NotifCorner.swift -O -parse-as-library -o "$APP/Contents/MacOS/NotifCorner"
codesign --force --sign - "$APP"

# Quit the running copy (it moves Notification Center back on quit).
osascript -e 'quit app "NotifCorner"' 2>/dev/null || true
sleep 1
pkill -x NotifCorner 2>/dev/null || true
# Restart Notification Center so its window is back in the default spot.
killall NotificationCenter 2>/dev/null || true

rm -rf ~/Applications/"$APP"
cp -R "$APP" ~/Applications/
# A new build has a new signature, so the old Accessibility entry no longer
# matches. Remove it so macOS asks again cleanly.
tccutil reset Accessibility com.alonso.NotifCorner >/dev/null 2>&1 || true
echo "Installed to ~/Applications/$APP"
open ~/Applications/"$APP"

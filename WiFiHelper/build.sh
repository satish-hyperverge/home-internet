#!/bin/bash
# Build Speed Monitor Menu Bar app
# This creates a native macOS menu bar app with Location Services permission

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="SpeedMonitor"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Read version from VERSION file
if [[ -f "$PROJECT_ROOT/VERSION" ]]; then
    VERSION=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')
else
    VERSION="3.1.0"
fi

echo "Building Speed Monitor Menu Bar App v$VERSION..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Create Info.plist for menu bar app (with version from VERSION file)
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.speedmonitor.menubar</string>
    <key>CFBundleName</key>
    <string>Speed Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>Speed Monitor</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>SpeedMonitor</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocationUsageDescription</key>
    <string>Speed Monitor needs Location Services to detect your WiFi network name (SSID). This is required by macOS. Your location is never tracked or stored.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Speed Monitor needs Location Services to detect your WiFi network name (SSID). This is required by macOS. Your location is never tracked or stored.</string>
    <key>NSLocationAlwaysUsageDescription</key>
    <string>Speed Monitor needs Location Services to detect your WiFi network name (SSID). This is required by macOS. Your location is never tracked or stored.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>Speed Monitor needs Location Services to detect your WiFi network name (SSID). This is required by macOS. Your location is never tracked or stored.</string>
</dict>
</plist>
EOF

# Compile Swift code
echo "Compiling Swift..."
swiftc -O -parse-as-library \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SCRIPT_DIR/SpeedMonitorMenuBar.swift" \
    -framework SwiftUI \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework AppKit

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "✅ Build complete: $APP_BUNDLE"
echo ""
echo "To install and run:"
echo "  1. Copy to Applications:"
echo "     cp -r '$APP_BUNDLE' /Applications/"
echo ""
echo "  2. Open the app:"
echo "     open /Applications/SpeedMonitor.app"
echo ""
echo "  3. Click the menu bar icon and go to Settings"
echo "     to grant Location Services permission"
echo ""
echo "  4. (Optional) Add to Login Items to start automatically"
echo ""
echo "For script WiFi output:"
echo "  '$APP_BUNDLE/Contents/MacOS/SpeedMonitor' --output"

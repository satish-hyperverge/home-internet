#!/bin/bash
# Speed Monitor v3.1.0 - One-line installer for employees
# Usage: curl -fsSL https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/install.sh | bash

set -e

SERVER_URL="https://home-internet-production.up.railway.app"
SCRIPT_DIR="$HOME/.local/share/nkspeedtest"
CONFIG_DIR="$HOME/.config/nkspeedtest"
BIN_DIR="$HOME/.local/bin"
PLIST_NAME="com.speedmonitor.plist"
MENUBAR_PLIST_NAME="com.speedmonitor.menubar.plist"

echo "=== Speed Monitor v3.1.0 Installer ==="
echo ""

# Create directories
mkdir -p "$SCRIPT_DIR" "$BIN_DIR" "$CONFIG_DIR"

# Collect user email
echo "Please enter your Hyperverge email address:"
read -p "Email: " USER_EMAIL

# Validate email format (basic check)
if [[ ! "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Warning: Email format looks invalid, but continuing anyway..."
fi

# Store email
echo "$USER_EMAIL" > "$CONFIG_DIR/user_email"
echo "Email saved: $USER_EMAIL"
echo ""

# Check for Xcode Command Line Tools (required for Swift compilation)
if ! xcode-select -p &> /dev/null; then
    echo "Installing Xcode Command Line Tools (required for Swift)..."
    xcode-select --install
    echo ""
    echo "Please complete the Xcode CLT installation popup, then run this script again."
    exit 1
fi

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install speedtest-cli
if ! command -v speedtest-cli &> /dev/null; then
    echo "Installing speedtest-cli..."
    brew install speedtest-cli
fi

# Download the speed monitor script
echo "Downloading speed monitor script..."
curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/speed_monitor.sh" -o "$BIN_DIR/speed_monitor.sh"
chmod +x "$BIN_DIR/speed_monitor.sh"

# Download wifi_info Swift helper (pre-compiled or compile if needed)
echo "Setting up WiFi helper..."
if [[ -f "/opt/homebrew/bin/wifi_info" ]]; then
    ln -sf "/opt/homebrew/bin/wifi_info" "$BIN_DIR/wifi_info"
else
    # Download and compile
    curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/src/wifi_info.swift" -o "$SCRIPT_DIR/wifi_info.swift"
    swiftc -O -o "$BIN_DIR/wifi_info" "$SCRIPT_DIR/wifi_info.swift" -framework CoreWLAN -framework Foundation 2>/dev/null || echo "WiFi helper compilation skipped (will use fallback)"
fi

# Build and install SpeedMonitor.app (native menu bar app with Location Services)
echo "Building SpeedMonitor menu bar app..."
SPEEDMONITOR_BUILD_TEMP=$(mktemp -d)

# Download Swift source and build script
curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/WiFiHelper/SpeedMonitorMenuBar.swift" -o "$SPEEDMONITOR_BUILD_TEMP/SpeedMonitorMenuBar.swift"

# Create build script inline (simpler than downloading)
APP_BUNDLE="$SPEEDMONITOR_BUILD_TEMP/SpeedMonitor.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST_EOF'
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
    <string>3.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>3.1.0</string>
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
</dict>
</plist>
PLIST_EOF

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Compile Swift code
if swiftc -O -parse-as-library \
    -o "$APP_BUNDLE/Contents/MacOS/SpeedMonitor" \
    "$SPEEDMONITOR_BUILD_TEMP/SpeedMonitorMenuBar.swift" \
    -framework SwiftUI \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework AppKit 2>/dev/null; then

    # Install to Applications folder
    rm -rf /Applications/SpeedMonitor.app 2>/dev/null || true
    cp -r "$APP_BUNDLE" /Applications/SpeedMonitor.app
    echo "SpeedMonitor.app installed to /Applications"
else
    echo "Warning: SpeedMonitor.app build failed (Swift toolchain issue). WiFi detection will use fallback."
fi

# Cleanup temp directory
rm -rf "$SPEEDMONITOR_BUILD_TEMP"

# Create launchd plist
echo "Creating launchd service..."
cat > "$HOME/Library/LaunchAgents/$PLIST_NAME" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.speedmonitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/speed_monitor.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$SCRIPT_DIR/launchd_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPT_DIR/launchd_stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>SPEED_MONITOR_SERVER</key>
        <string>$SERVER_URL</string>
    </dict>
</dict>
</plist>
EOF

# Unload existing service if present
launchctl unload "$HOME/Library/LaunchAgents/$PLIST_NAME" 2>/dev/null || true

# Load the service
launchctl load "$HOME/Library/LaunchAgents/$PLIST_NAME"

# Create launchd plist for menu bar app (auto-launch on login)
if [[ -d "/Applications/SpeedMonitor.app" ]]; then
    echo "Setting up menu bar app to launch on login..."
    cat > "$HOME/Library/LaunchAgents/$MENUBAR_PLIST_NAME" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.speedmonitor.menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/SpeedMonitor.app/Contents/MacOS/SpeedMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$SCRIPT_DIR/menubar_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPT_DIR/menubar_stderr.log</string>
</dict>
</plist>
EOF

    # Unload existing menu bar service if present
    launchctl unload "$HOME/Library/LaunchAgents/$MENUBAR_PLIST_NAME" 2>/dev/null || true

    # Load the menu bar service
    launchctl load "$HOME/Library/LaunchAgents/$MENUBAR_PLIST_NAME"

    # Also launch the app now
    open /Applications/SpeedMonitor.app
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Speed Monitor is now running and will:"
echo "  - Run a speed test every 10 minutes"
echo "  - Upload results to: $SERVER_URL"
echo "  - Store local logs in: $SCRIPT_DIR"
echo "  - Show live stats in your menu bar"
echo ""
echo "View the dashboard: $SERVER_URL"
echo ""
if [[ -d "/Applications/SpeedMonitor.app" ]]; then
echo "Menu Bar App:"
echo "  - Click the menu bar icon to see speed stats"
echo "  - Go to Settings to grant Location Services"
echo "  - This enables WiFi network name detection"
echo ""
fi
echo "Commands:"
echo "  Run test now:  SPEED_MONITOR_SERVER=$SERVER_URL $BIN_DIR/speed_monitor.sh"
echo "  View logs:     tail -f $SCRIPT_DIR/launchd_stdout.log"
echo "  Stop service:  launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
echo ""

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
# When running via 'curl | bash', stdin is not a tty, so we need to read from /dev/tty
echo "Please enter your Hyperverge email address:"
echo "(This is required to identify your device in the dashboard)"
echo ""

USER_EMAIL=""
MAX_ATTEMPTS=3
ATTEMPT=0

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    ATTEMPT=$((ATTEMPT + 1))

    if [[ -t 0 ]]; then
        # Interactive mode - stdin is a terminal
        read -p "Email: " USER_EMAIL
    else
        # Non-interactive (curl | bash) - read from /dev/tty
        read -p "Email: " USER_EMAIL < /dev/tty 2>/dev/null || {
            echo "Error: Cannot read input. Please run the installer differently:"
            echo "  bash <(curl -fsSL https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/install.sh)"
            exit 1
        }
    fi

    # Trim whitespace
    USER_EMAIL=$(echo "$USER_EMAIL" | xargs)

    # Check if empty
    if [[ -z "$USER_EMAIL" ]]; then
        echo "❌ Email cannot be empty. Please try again. (Attempt $ATTEMPT/$MAX_ATTEMPTS)"
        continue
    fi

    # Validate email format
    if [[ ! "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "❌ Invalid email format. Please enter a valid email. (Attempt $ATTEMPT/$MAX_ATTEMPTS)"
        continue
    fi

    # Valid email - break out of loop
    break
done

# Final check after all attempts
if [[ -z "$USER_EMAIL" ]] || [[ ! "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo ""
    echo "❌ Error: A valid email address is required to proceed."
    echo "Please run the installer again and provide your email."
    exit 1
fi

echo "✓ Email validated: $USER_EMAIL"

# Store email
echo "$USER_EMAIL" > "$CONFIG_DIR/user_email"
echo "Email saved: $USER_EMAIL"
echo ""

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    # Use /dev/null for stdin to prevent consuming piped script
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/null
fi

# Install speedtest-cli
if ! command -v speedtest-cli &> /dev/null; then
    echo "Installing speedtest-cli..."
    # Use /dev/null for stdin to prevent consuming piped script
    brew install speedtest-cli < /dev/null
fi

# Download the speed monitor script
echo "Downloading speed monitor script..."
curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/speed_monitor.sh" -o "$BIN_DIR/speed_monitor.sh"
chmod +x "$BIN_DIR/speed_monitor.sh"

# Fix CSV header if it's out of sync (upgrade scenario)
CSV_FILE="$SCRIPT_DIR/speed_log.csv"
if [[ -f "$CSV_FILE" ]]; then
    # Get expected header from the new script
    EXPECTED_HEADER=$(grep "^CSV_HEADER=" "$BIN_DIR/speed_monitor.sh" | sed 's/CSV_HEADER="//' | sed 's/"$//')
    CURRENT_HEADER=$(head -1 "$CSV_FILE")

    if [[ "$EXPECTED_HEADER" != "$CURRENT_HEADER" ]]; then
        echo "Updating CSV header to match new schema..."
        cp "$CSV_FILE" "$CSV_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        echo "$EXPECTED_HEADER" > "$CSV_FILE.new"
        tail -n +2 "$CSV_FILE" >> "$CSV_FILE.new"
        mv "$CSV_FILE.new" "$CSV_FILE"
        echo "✓ CSV header updated (backup saved)"
    fi
fi

# Optional: wifi_info Swift helper (backup for SpeedMonitor.app)
# Only compile if Xcode CLT is available - not required since SpeedMonitor.app is primary
if command -v swiftc &> /dev/null; then
    echo "Setting up WiFi helper (backup)..."
    if [[ -f "/opt/homebrew/bin/wifi_info" ]]; then
        ln -sf "/opt/homebrew/bin/wifi_info" "$BIN_DIR/wifi_info"
    else
        curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/src/wifi_info.swift" -o "$SCRIPT_DIR/wifi_info.swift" 2>/dev/null
        swiftc -O -o "$BIN_DIR/wifi_info" "$SCRIPT_DIR/wifi_info.swift" -framework CoreWLAN -framework Foundation 2>/dev/null || true
    fi
fi

# Download and install pre-built SpeedMonitor.app (native menu bar app)
echo "Installing SpeedMonitor menu bar app..."
rm -rf /Applications/SpeedMonitor.app 2>/dev/null || true

curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/SpeedMonitor.app.zip" -o /tmp/SpeedMonitor.app.zip
if [[ -f /tmp/SpeedMonitor.app.zip ]]; then
    unzip -o /tmp/SpeedMonitor.app.zip -d /tmp/
    if [[ -d /tmp/SpeedMonitor.app ]]; then
        cp -r /tmp/SpeedMonitor.app /Applications/

        # Remove quarantine flag (Gatekeeper) and ad-hoc sign
        xattr -cr /Applications/SpeedMonitor.app 2>/dev/null || true
        codesign --force --deep --sign - /Applications/SpeedMonitor.app 2>/dev/null || true

        echo "✓ SpeedMonitor.app installed to /Applications"
    else
        echo "✗ Failed to unzip SpeedMonitor.app"
    fi
    rm -f /tmp/SpeedMonitor.app.zip
    rm -rf /tmp/SpeedMonitor.app
else
    echo "✗ Failed to download SpeedMonitor.app"
fi

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

# Run the first speed test immediately so menu bar shows real data
echo ""
echo "Running initial speed test (this takes ~30 seconds)..."
SPEED_MONITOR_SERVER="$SERVER_URL" "$BIN_DIR/speed_monitor.sh" 2>/dev/null &
SPEEDTEST_PID=$!

# Wait for speed test with a simple progress indicator
for i in {1..40}; do
    if ! kill -0 $SPEEDTEST_PID 2>/dev/null; then
        break
    fi
    printf "."
    sleep 1
done
echo " Done!"

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
echo "  - Go to Settings → Grant Permission for WiFi name"
echo ""
fi
echo "Commands:"
echo "  Run test now:  SPEED_MONITOR_SERVER=$SERVER_URL $BIN_DIR/speed_monitor.sh"
echo "  View logs:     tail -f $SCRIPT_DIR/launchd_stdout.log"
echo "  Stop service:  launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
echo ""

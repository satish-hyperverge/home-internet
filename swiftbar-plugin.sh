#!/bin/bash

# Speed Monitor v3.1 - SwiftBar Plugin with Auto-Update
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

PLUGIN_VERSION="3.2"

# Configuration
SERVER_URL="${SPEED_MONITOR_SERVER:-https://home-internet-production.up.railway.app}"
CSV_FILE="$HOME/.local/share/nkspeedtest/speed_log.csv"
SPEED_MONITOR="$HOME/.local/bin/speed_monitor.sh"
DEVICE_ID_FILE="$HOME/.config/nkspeedtest/device_id"
CONFIG_DIR="$HOME/.config/nkspeedtest"
UPDATE_CHECK_FILE="$CONFIG_DIR/last_update_check"
PLUGIN_PATH="$HOME/Library/Application Support/SwiftBar/Plugins/nkspeedtest.5m.sh"
GITHUB_RAW_URL="https://raw.githubusercontent.com/hyperkishore/home-internet/main/swiftbar-plugin.sh"

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Get device ID
DEVICE_ID=""
if [[ -f "$DEVICE_ID_FILE" ]]; then
    DEVICE_ID=$(cat "$DEVICE_ID_FILE")
fi

# Function to format numbers
format_num() {
    printf "%.1f" "$1" 2>/dev/null || echo "--"
}

# Function to check for updates (runs once per hour)
check_for_updates() {
    local now=$(date +%s)
    local last_check=0

    if [[ -f "$UPDATE_CHECK_FILE" ]]; then
        last_check=$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0)
    fi

    # Check every hour (3600 seconds)
    local elapsed=$((now - last_check))
    if [[ $elapsed -lt 3600 ]]; then
        return 1  # No update needed
    fi

    # Record this check
    echo "$now" > "$UPDATE_CHECK_FILE"

    # Fetch remote version
    local remote_script=$(curl -s --max-time 5 "$GITHUB_RAW_URL" 2>/dev/null)
    if [[ -z "$remote_script" ]]; then
        return 1  # Can't reach GitHub
    fi

    # Extract remote version
    local remote_version=$(echo "$remote_script" | grep '^PLUGIN_VERSION=' | cut -d'"' -f2)
    if [[ -z "$remote_version" ]]; then
        return 1  # Can't parse version
    fi

    # Compare versions (simple string comparison works for x.y format)
    if [[ "$remote_version" != "$PLUGIN_VERSION" ]]; then
        # Newer version available - store for display
        echo "$remote_version" > "$CONFIG_DIR/available_update"
        return 0
    fi

    # No update needed, clear any pending update notice
    rm -f "$CONFIG_DIR/available_update" 2>/dev/null
    return 1
}

# Function to perform self-update
self_update() {
    local remote_script=$(curl -s --max-time 10 "$GITHUB_RAW_URL" 2>/dev/null)
    if [[ -z "$remote_script" ]]; then
        echo "Failed to download update"
        exit 1
    fi

    # Verify it looks like a valid script
    if ! echo "$remote_script" | head -1 | grep -q "#!/bin/bash"; then
        echo "Invalid update file"
        exit 1
    fi

    # Backup current plugin
    cp "$PLUGIN_PATH" "$PLUGIN_PATH.backup" 2>/dev/null

    # Write new plugin
    echo "$remote_script" > "$PLUGIN_PATH"
    chmod +x "$PLUGIN_PATH"

    # Clear update notice
    rm -f "$CONFIG_DIR/available_update" 2>/dev/null

    echo "Updated to latest version. Please refresh SwiftBar."
}

# Handle update command
if [[ "$1" == "update" ]]; then
    self_update
    exit 0
fi

# Check for updates in background (non-blocking)
check_for_updates &

# Check if an update is available
UPDATE_AVAILABLE=""
if [[ -f "$CONFIG_DIR/available_update" ]]; then
    UPDATE_AVAILABLE=$(cat "$CONFIG_DIR/available_update")
fi

# Track status for diagnostics
STATUS="ok"
STATUS_MSG=""

# Try to get data from server first
SERVER_DATA=""
if [[ -n "$DEVICE_ID" && -n "$SERVER_URL" ]]; then
    SERVER_DATA=$(curl -s --max-time 3 "$SERVER_URL/api/devices/$DEVICE_ID/health" 2>/dev/null)
    if [[ -z "$SERVER_DATA" ]]; then
        STATUS="server_unreachable"
        STATUS_MSG="Cannot reach server"
    fi
fi

# Parse server data if available
if [[ -n "$SERVER_DATA" ]] && echo "$SERVER_DATA" | grep -q "avg_download"; then
    # Parse JSON using basic tools
    AVG_DOWN=$(echo "$SERVER_DATA" | grep -o '"avg_download":[0-9.]*' | cut -d: -f2)
    AVG_UP=$(echo "$SERVER_DATA" | grep -o '"avg_upload":[0-9.]*' | cut -d: -f2)
    # Use median jitter (more accurate, ignores outliers)
    MEDIAN_JITTER=$(echo "$SERVER_DATA" | grep -o '"median_jitter":[0-9.]*' | cut -d: -f2)
    # Fallback to avg_jitter if median not available
    if [[ -z "$MEDIAN_JITTER" ]]; then
        MEDIAN_JITTER=$(echo "$SERVER_DATA" | grep -o '"avg_jitter":[0-9.]*' | cut -d: -f2)
    fi
    TOTAL_TESTS=$(echo "$SERVER_DATA" | grep -o '"total_tests":[0-9]*' | cut -d: -f2)
    VPN_STATUS=$(echo "$SERVER_DATA" | grep -o '"current_vpn_status":"[^"]*"' | cut -d'"' -f4)
    VPN_NAME=$(echo "$SERVER_DATA" | grep -o '"current_vpn_name":"[^"]*"' | cut -d'"' -f4)
    LAST_SEEN=$(echo "$SERVER_DATA" | grep -o '"last_seen":"[^"]*"' | cut -d'"' -f4)

    # Validate we got actual data
    if [[ -z "$AVG_DOWN" || "$AVG_DOWN" == "null" ]]; then
        STATUS="no_data"
        STATUS_MSG="No speed data from server"
    else
        STATUS="ok"

        # Format display values
        DOWN_DISPLAY=$(format_num "$AVG_DOWN")
        UP_DISPLAY=$(format_num "$AVG_UP")
        JITTER_DISPLAY=$(format_num "$MEDIAN_JITTER")

        # Menu bar display with VPN indicator and update badge
        MENU_BAR="↓${DOWN_DISPLAY} ↑${UP_DISPLAY}"
        [[ "$VPN_STATUS" == "connected" ]] && MENU_BAR="🔒 $MENU_BAR"
        [[ -n "$UPDATE_AVAILABLE" ]] && MENU_BAR="🔄 $MENU_BAR"
        echo "$MENU_BAR | sfimage=wifi"

        echo "---"

        # Show update notice at top if available
        if [[ -n "$UPDATE_AVAILABLE" ]]; then
            echo "🔄 Update Available: v$UPDATE_AVAILABLE | color=#ff9500"
            echo "Install Update | bash='$PLUGIN_PATH' param1=update terminal=false refresh=true sfimage=arrow.down.circle.fill color=#ff9500"
            echo "---"
        fi

        echo "Speed Monitor v$PLUGIN_VERSION | size=14"
        echo "---"
        echo "📊 Performance (Avg) | size=12 color=#888888"
        echo "Download: ${DOWN_DISPLAY} Mbps | sfimage=arrow.down.circle"
        echo "Upload: ${UP_DISPLAY} Mbps | sfimage=arrow.up.circle"
        echo "Jitter: ${JITTER_DISPLAY} ms (median) | sfimage=waveform.path"
        echo "---"

        # VPN Status
        if [[ "$VPN_STATUS" == "connected" ]]; then
            echo "🔒 VPN: $VPN_NAME | color=#00ff88"
        else
            echo "🔓 VPN: Disconnected | color=#888888"
        fi

        echo "Tests: $TOTAL_TESTS total | sfimage=number.circle"

        # Last test time
        if [[ -n "$LAST_SEEN" ]]; then
            LAST_TIME=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_SEEN:0:19}" "+%H:%M" 2>/dev/null || echo "$LAST_SEEN")
            echo "Last: $LAST_TIME | sfimage=clock"
        fi

        echo "---"
        echo "🌐 Quick Actions | size=12 color=#888888"
        echo "Run Speed Test | bash='$SPEED_MONITOR' terminal=false refresh=true sfimage=play.circle"
        echo "Open Dashboard | href=$SERVER_URL sfimage=chart.line.uptrend.xyaxis"
        echo "My Device Stats | href=$SERVER_URL/device/$DEVICE_ID sfimage=person.circle"
        echo "---"
        echo "View Local Logs | bash=/usr/bin/tail param1=-20 param2=$CSV_FILE terminal=true sfimage=doc.text"
    fi

elif [[ -n "$SERVER_DATA" ]] && echo "$SERVER_DATA" | grep -q "error"; then
    # Server returned an error
    STATUS="server_error"
    STATUS_MSG=$(echo "$SERVER_DATA" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)

else
    # Fallback to local CSV if server unavailable
    if [[ -f "$CSV_FILE" ]]; then
        LATEST=$(tail -1 "$CSV_FILE")

        # Detect CSV format by counting fields
        FIELD_COUNT=$(echo "$LATEST" | awk -F',' '{print NF}')

        if [[ $FIELD_COUNT -lt 20 ]]; then
            # Old format detected - needs upgrade
            STATUS="format_outdated"
            STATUS_MSG="CSV format outdated. Run speed test to update."
        else
            # Parse v2.0+ CSV format
            IFS=',' read -ra FIELDS <<< "$LATEST"

            TIMESTAMP="${FIELDS[0]}"
            SSID="${FIELDS[6]}"
            DOWNLOAD="${FIELDS[22]}"
            UPLOAD="${FIELDS[23]}"
            VPN_STATUS="${FIELDS[24]}"
            VPN_NAME="${FIELDS[25]}"
            JITTER="${FIELDS[18]}"

            # Clean up values
            DOWNLOAD=$(echo "$DOWNLOAD" | xargs)
            UPLOAD=$(echo "$UPLOAD" | xargs)
            VPN_STATUS=$(echo "$VPN_STATUS" | xargs)

            if [[ -n "$DOWNLOAD" && "$DOWNLOAD" != "0" ]]; then
                STATUS="ok_local"

                MENU_BAR="↓${DOWNLOAD} ↑${UPLOAD}"
                [[ "$VPN_STATUS" == "connected" ]] && MENU_BAR="🔒 $MENU_BAR"
                [[ -n "$UPDATE_AVAILABLE" ]] && MENU_BAR="🔄 $MENU_BAR"
                echo "$MENU_BAR | sfimage=wifi"

                echo "---"

                # Show update notice at top if available
                if [[ -n "$UPDATE_AVAILABLE" ]]; then
                    echo "🔄 Update Available: v$UPDATE_AVAILABLE | color=#ff9500"
                    echo "Install Update | bash='$PLUGIN_PATH' param1=update terminal=false refresh=true sfimage=arrow.down.circle.fill color=#ff9500"
                    echo "---"
                fi

                echo "Speed Monitor v$PLUGIN_VERSION (Local) | size=14"
                echo "⚠️ Server unreachable - using local data | color=#ff9500 size=11"
                echo "---"
                echo "Download: $DOWNLOAD Mbps | sfimage=arrow.down.circle"
                echo "Upload: $UPLOAD Mbps | sfimage=arrow.up.circle"
                [[ -n "$JITTER" ]] && echo "Jitter: $JITTER ms | sfimage=waveform.path"
                echo "---"
                [[ -n "$SSID" ]] && echo "Network: $SSID | sfimage=wifi"
                echo "Last: $TIMESTAMP | sfimage=clock"
                echo "---"
                echo "Run Speed Test | bash='$SPEED_MONITOR' terminal=false refresh=true sfimage=play.circle"
                [[ -n "$SERVER_URL" ]] && echo "Open Dashboard | href=$SERVER_URL sfimage=chart.line.uptrend.xyaxis"
            else
                STATUS="no_speed_data"
                STATUS_MSG="Last test had no speed data"
            fi
        fi
    else
        STATUS="no_csv"
        STATUS_MSG="No speed test data found"
    fi
fi

# Handle error states
if [[ "$STATUS" != "ok" && "$STATUS" != "ok_local" ]]; then
    # Show error state in menu bar
    echo "⚠️ Offline | sfimage=wifi.slash"
    echo "---"

    # Show update notice even in error state
    if [[ -n "$UPDATE_AVAILABLE" ]]; then
        echo "🔄 Update Available: v$UPDATE_AVAILABLE | color=#ff9500"
        echo "Install Update | bash='$PLUGIN_PATH' param1=update terminal=false refresh=true sfimage=arrow.down.circle.fill color=#ff9500"
        echo "---"
    fi

    echo "Speed Monitor v$PLUGIN_VERSION | size=14"
    echo "---"

    # Diagnostic info
    echo "⚠️ Status: $STATUS | color=#ff6b6b"
    [[ -n "$STATUS_MSG" ]] && echo "$STATUS_MSG | color=#888888"
    echo "---"

    # Troubleshooting
    echo "🔧 Troubleshooting | size=12 color=#888888"

    case "$STATUS" in
        "server_unreachable")
            echo "• Check internet connection | color=#888888"
            echo "• Server may be down temporarily | color=#888888"
            ;;
        "no_data"|"no_speed_data")
            echo "• Run a speed test to generate data | color=#888888"
            ;;
        "format_outdated")
            echo "• Speed monitor script needs update | color=#888888"
            echo "• Run installer to update | color=#888888"
            ;;
        "no_csv")
            echo "• Run the installer first | color=#888888"
            echo "• Or run a speed test manually | color=#888888"
            ;;
    esac

    echo "---"

    # Device ID info
    if [[ -n "$DEVICE_ID" ]]; then
        echo "Device: ${DEVICE_ID:0:8}... | sfimage=person.circle color=#888888"
    else
        echo "⚠️ No Device ID | color=#ff6b6b"
    fi

    echo "---"
    echo "Run Speed Test | bash='$SPEED_MONITOR' terminal=false refresh=true sfimage=play.circle"
    [[ -n "$SERVER_URL" ]] && echo "Open Dashboard | href=$SERVER_URL sfimage=chart.line.uptrend.xyaxis"
    echo "---"
    echo "View Local Logs | bash=/usr/bin/tail param1=-20 param2=$CSV_FILE terminal=true sfimage=doc.text"
    echo "Check for Updates | bash='$PLUGIN_PATH' param1=update terminal=false refresh=true sfimage=arrow.triangle.2.circlepath"
fi

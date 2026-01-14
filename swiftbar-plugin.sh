#!/bin/bash

# Speed Monitor v3.0 - SwiftBar Plugin
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# Configuration
SERVER_URL="${SPEED_MONITOR_SERVER:-https://home-internet-production.up.railway.app}"
CSV_FILE="$HOME/.local/share/nkspeedtest/speed_log.csv"
SPEED_MONITOR="$HOME/.local/bin/speed_monitor.sh"
DEVICE_ID_FILE="$HOME/.config/nkspeedtest/device_id"

# Get device ID
DEVICE_ID=""
if [[ -f "$DEVICE_ID_FILE" ]]; then
    DEVICE_ID=$(cat "$DEVICE_ID_FILE")
fi

# Function to format numbers
format_num() {
    printf "%.1f" "$1" 2>/dev/null || echo "--"
}

# Try to get data from server first
SERVER_DATA=""
if [[ -n "$DEVICE_ID" && -n "$SERVER_URL" ]]; then
    SERVER_DATA=$(curl -s --max-time 3 "$SERVER_URL/api/devices/$DEVICE_ID/health" 2>/dev/null)
fi

# Parse server data if available
if [[ -n "$SERVER_DATA" ]] && echo "$SERVER_DATA" | grep -q "avg_download"; then
    # Parse JSON using basic tools
    AVG_DOWN=$(echo "$SERVER_DATA" | grep -o '"avg_download":[0-9.]*' | cut -d: -f2)
    AVG_UP=$(echo "$SERVER_DATA" | grep -o '"avg_upload":[0-9.]*' | cut -d: -f2)
    AVG_JITTER=$(echo "$SERVER_DATA" | grep -o '"avg_jitter":[0-9.]*' | cut -d: -f2)
    TOTAL_TESTS=$(echo "$SERVER_DATA" | grep -o '"total_tests":[0-9]*' | cut -d: -f2)
    VPN_STATUS=$(echo "$SERVER_DATA" | grep -o '"current_vpn_status":"[^"]*"' | cut -d'"' -f4)
    VPN_NAME=$(echo "$SERVER_DATA" | grep -o '"current_vpn_name":"[^"]*"' | cut -d'"' -f4)
    LAST_SEEN=$(echo "$SERVER_DATA" | grep -o '"last_seen":"[^"]*"' | cut -d'"' -f4)

    # Format display values
    DOWN_DISPLAY=$(format_num "$AVG_DOWN")
    UP_DISPLAY=$(format_num "$AVG_UP")
    JITTER_DISPLAY=$(format_num "$AVG_JITTER")

    # Menu bar display with VPN indicator
    if [[ "$VPN_STATUS" == "connected" ]]; then
        echo "🔒 ↓${DOWN_DISPLAY} ↑${UP_DISPLAY} | sfimage=wifi"
    else
        echo "↓${DOWN_DISPLAY} ↑${UP_DISPLAY} | sfimage=wifi"
    fi

    echo "---"
    echo "Speed Monitor v3.0 | size=14"
    echo "---"
    echo "📊 Performance (Avg) | size=12 color=#888888"
    echo "Download: ${DOWN_DISPLAY} Mbps | sfimage=arrow.down.circle"
    echo "Upload: ${UP_DISPLAY} Mbps | sfimage=arrow.up.circle"
    echo "Jitter: ${JITTER_DISPLAY} ms | sfimage=waveform.path"
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

else
    # Fallback to local CSV if server unavailable
    if [[ -f "$CSV_FILE" ]]; then
        LATEST=$(tail -1 "$CSV_FILE")

        # Parse v2.0 CSV format
        # timestamp_utc,device_id,os_version,app_version,timezone,interface,ssid,bssid,band,channel,width_mhz,
        # rssi_dbm,noise_dbm,snr_db,tx_rate_mbps,local_ip,public_ip,latency_ms,jitter_ms,jitter_p50,jitter_p95,
        # packet_loss_pct,download_mbps,upload_mbps,vpn_status,vpn_name,errors,raw_payload

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
            if [[ "$VPN_STATUS" == "connected" ]]; then
                echo "🔒 ↓${DOWNLOAD} ↑${UPLOAD} | sfimage=wifi"
            else
                echo "↓${DOWNLOAD} ↑${UPLOAD} | sfimage=wifi"
            fi

            echo "---"
            echo "Speed Monitor (Local) | size=14"
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
            echo "⚠ No Data | sfimage=wifi.slash"
            echo "---"
            echo "Last test had no speed data"
            echo "---"
            echo "Run Speed Test | bash='$SPEED_MONITOR' terminal=false refresh=true sfimage=play.circle"
        fi
    else
        echo "⚠ Setup Required | sfimage=wifi.slash"
        echo "---"
        echo "No speed test data found"
        echo "Run the installer first"
        echo "---"
        echo "Run Speed Test | bash='$SPEED_MONITOR' terminal=false refresh=true sfimage=play.circle"
    fi
fi

#!/bin/bash
#
# Speed Monitor v3.0.0 - Organization-Wide Internet Speed Monitoring
# Enhanced data collection for fleet deployment (300+ devices)
# v3.0.0: Unified versioning, self-update mechanism
# v2.4.0: Added curl timeout to prevent process hangs
# v2.3.0: Bug fixes - jitter percentiles, TCP retransmits delta, JSON escaping, status field
# v2.2.0: Fixed VPN detection - now checks for active tunnel, not just process running
# v2.1.0: Added WiFi debugging metrics (MCS, error rates, BSSID tracking)
#

APP_VERSION="3.1.06"

# Configuration
DATA_DIR="$HOME/.local/share/nkspeedtest"
CONFIG_DIR="$HOME/.config/nkspeedtest"
CSV_FILE="$DATA_DIR/speed_log.csv"
LOG_FILE="$DATA_DIR/speed_monitor.log"
WIFI_HELPER="$HOME/.local/bin/wifi_info"

# Server configuration
SERVER_URL="${SPEED_MONITOR_SERVER:-https://home-internet-production.up.railway.app}"

# Ensure directories exist
mkdir -p "$DATA_DIR" "$CONFIG_DIR"

# CSV Header (v2.1 schema - added MCS, error rates, BSSID tracking)
CSV_HEADER="timestamp_utc,device_id,os_version,app_version,timezone,interface,ssid,bssid,band,channel,width_mhz,rssi_dbm,noise_dbm,snr_db,tx_rate_mbps,mcs_index,spatial_streams,local_ip,public_ip,latency_ms,jitter_ms,jitter_p50,jitter_p95,packet_loss_pct,download_mbps,upload_mbps,vpn_status,vpn_name,input_errors,output_errors,input_error_rate,output_error_rate,tcp_retransmits,bssid_changed,roam_count,errors,raw_payload"

# Create CSV header if file doesn't exist
if [[ ! -f "$CSV_FILE" ]]; then
    echo "$CSV_HEADER" > "$CSV_FILE"
fi

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# GitHub base URL for updates
GITHUB_BASE="https://raw.githubusercontent.com/hyperkishore/home-internet/main"

# Semantic version comparison (returns 0 if v1 >= v2)
version_gte() {
    local v1=$1 v2=$2
    [[ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]
}

# Check for available updates (returns 0 if update available)
check_update() {
    local remote_version=$(curl -s --max-time 5 "$GITHUB_BASE/VERSION" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$remote_version" ]]; then
        return 1  # Can't reach server
    fi

    if version_gte "$APP_VERSION" "$remote_version"; then
        return 1  # Already on latest
    fi

    echo "$remote_version"
    return 0
}

# Self-update function
update_app() {
    echo "Speed Monitor Update"
    echo "===================="
    echo "Current version: $APP_VERSION"
    echo ""

    # Check remote version
    echo "Checking for updates..."
    local remote_version=$(curl -s --max-time 5 "$GITHUB_BASE/VERSION" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$remote_version" ]]; then
        echo "Failed to check for updates (network error)"
        return 1
    fi

    echo "Latest version: $remote_version"

    # Compare versions
    if version_gte "$APP_VERSION" "$remote_version"; then
        echo ""
        echo "✓ Already on latest version ($APP_VERSION)"
        return 0
    fi

    echo ""
    echo "Updating from $APP_VERSION to $remote_version..."

    # Download to temp files
    local tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" EXIT

    echo "Downloading speed_monitor.sh..."
    if ! curl -s --max-time 30 "$GITHUB_BASE/speed_monitor.sh" -o "$tmp_dir/speed_monitor.sh"; then
        echo "Failed to download speed_monitor.sh"
        return 1
    fi

    echo "Downloading swiftbar-plugin.sh..."
    if ! curl -s --max-time 30 "$GITHUB_BASE/swiftbar-plugin.sh" -o "$tmp_dir/swiftbar-plugin.sh"; then
        echo "Failed to download swiftbar-plugin.sh"
        return 1
    fi

    # Validate downloads
    if ! head -1 "$tmp_dir/speed_monitor.sh" | grep -q "#!/bin/bash"; then
        echo "Download validation failed for speed_monitor.sh"
        return 1
    fi

    if ! head -1 "$tmp_dir/swiftbar-plugin.sh" | grep -q "#!/bin/bash"; then
        echo "Download validation failed for swiftbar-plugin.sh"
        return 1
    fi

    # Create timestamped backup
    local backup_dir="$DATA_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up to $backup_dir..."
    cp "$HOME/.local/bin/speed_monitor.sh" "$backup_dir/" 2>/dev/null
    cp "$HOME/Library/Application Support/SwiftBar/Plugins/nkspeedtest.5m.sh" "$backup_dir/" 2>/dev/null

    # Atomic install - speed_monitor.sh
    echo "Installing speed_monitor.sh..."
    mv "$tmp_dir/speed_monitor.sh" "$HOME/.local/bin/speed_monitor.sh"
    chmod +x "$HOME/.local/bin/speed_monitor.sh"

    # Atomic install - SwiftBar plugin (if SwiftBar is installed)
    local swiftbar_plugin="$HOME/Library/Application Support/SwiftBar/Plugins/nkspeedtest.5m.sh"
    if [[ -d "$HOME/Library/Application Support/SwiftBar/Plugins" ]]; then
        echo "Installing SwiftBar plugin..."
        mv "$tmp_dir/swiftbar-plugin.sh" "$swiftbar_plugin"
        chmod +x "$swiftbar_plugin"
    fi

    echo ""
    echo "✓ Updated to version $remote_version"
    echo "  Backup saved to: $backup_dir"
    return 0
}

# Handle command-line arguments
case "${1:-}" in
    --version|-v)
        echo "Speed Monitor v$APP_VERSION"
        exit 0
        ;;
    --update|-u)
        update_app
        exit $?
        ;;
    --check-update)
        if new_version=$(check_update); then
            echo "Update available: $new_version"
            exit 0
        else
            echo "Up to date ($APP_VERSION)"
            exit 1
        fi
        ;;
    --help|-h)
        echo "Speed Monitor v$APP_VERSION"
        echo ""
        echo "Usage: speed_monitor.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --version, -v     Show version"
        echo "  --update, -u      Update to latest version"
        echo "  --check-update    Check if update is available"
        echo "  --help, -h        Show this help"
        echo ""
        echo "Without options, runs a speed test."
        exit 0
        ;;
esac

# Get stable device ID (persisted across reinstalls)
get_device_id() {
    local device_id_file="$CONFIG_DIR/device_id"
    if [[ -f "$device_id_file" ]]; then
        cat "$device_id_file"
    else
        # Generate from hardware UUID for stability
        local hw_uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk '/IOPlatformUUID/ { print $3 }' | tr -d '"')
        echo "$hw_uuid" | shasum -a 256 | cut -c1-16 > "$device_id_file"
        cat "$device_id_file"
    fi
}

# Get user email (set during installation)
get_user_email() {
    local email_file="$CONFIG_DIR/user_email"
    if [[ -f "$email_file" ]]; then
        cat "$email_file"
    else
        echo ""
    fi
}

# Get WiFi details via SpeedMonitor.app, Swift helper, or system_profiler fallback
get_wifi_details() {
    # Priority 1: SpeedMonitor.app (best: has Location Services UI for SSID)
    local speedmonitor_app="/Applications/SpeedMonitor.app/Contents/MacOS/SpeedMonitor"
    if [[ -x "$speedmonitor_app" ]]; then
        local wifi_output=$("$speedmonitor_app" --output 2>/dev/null)
        # Check if helper returned valid data (CONNECTED=true)
        if echo "$wifi_output" | grep -q "CONNECTED=true"; then
            echo "$wifi_output"
            return
        fi
    fi

    # Priority 2: wifi_info Swift helper (if it has Location Services permission)
    if [[ -x "$WIFI_HELPER" ]]; then
        local wifi_output=$("$WIFI_HELPER" 2>/dev/null)
        # Check if helper returned valid data (CONNECTED=true)
        if echo "$wifi_output" | grep -q "CONNECTED=true"; then
            echo "$wifi_output"
            return
        fi
    fi

    # Fallback: try legacy airport command (pre-Sequoia)
    local airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    if [[ -x "$airport" ]]; then
        local ssid=$("$airport" -I 2>/dev/null | awk -F': ' '/^ *SSID/ {print $2}')
        if [[ -n "$ssid" ]]; then
            local bssid=$("$airport" -I 2>/dev/null | awk -F': ' '/^ *BSSID/ {print $2}')
            local channel=$("$airport" -I 2>/dev/null | awk -F': ' '/^ *channel/ {print $2}' | cut -d',' -f1)
            local rssi=$("$airport" -I 2>/dev/null | awk -F': ' '/^ *agrCtlRSSI/ {print $2}')
            local noise=$("$airport" -I 2>/dev/null | awk -F': ' '/^ *agrCtlNoise/ {print $2}')

            echo "CONNECTED=true"
            echo "INTERFACE=en0"
            echo "SSID=${ssid}"
            echo "BSSID=${bssid:-unknown}"
            echo "CHANNEL=${channel:-0}"
            echo "BAND=unknown"
            echo "WIDTH_MHZ=0"
            echo "RSSI_DBM=${rssi:-0}"
            echo "NOISE_DBM=${noise:-0}"
            echo "SNR_DB=0"
            echo "TX_RATE_MBPS=0"
            return
        fi
    fi

    # Fallback: use system_profiler (works on macOS Sequoia, no permissions needed)
    local profiler_output=$(system_profiler SPAirPortDataType 2>/dev/null)
    if echo "$profiler_output" | grep -q "Status: Connected"; then
        # Parse WiFi info from system_profiler
        # Note: SSID may be <redacted> due to privacy, but other metrics are available
        local signal_line=$(echo "$profiler_output" | grep "Signal / Noise:" | head -1)
        local rssi=$(echo "$signal_line" | sed 's/.*Signal \/ Noise: \(-*[0-9]*\) dBm.*/\1/')
        local noise=$(echo "$signal_line" | sed 's/.*\/ \(-*[0-9]*\) dBm.*/\1/')
        local channel_line=$(echo "$profiler_output" | grep "Channel:" | grep -v "Supported" | head -1)
        local channel=$(echo "$channel_line" | sed 's/.*Channel: \([0-9]*\).*/\1/')
        local band="unknown"
        if echo "$channel_line" | grep -q "5GHz"; then
            band="5GHz"
        elif echo "$channel_line" | grep -q "2GHz"; then
            band="2.4GHz"
        fi
        local width=0
        if echo "$channel_line" | grep -q "80MHz"; then
            width=80
        elif echo "$channel_line" | grep -q "40MHz"; then
            width=40
        elif echo "$channel_line" | grep -q "20MHz"; then
            width=20
        fi
        local tx_rate=$(echo "$profiler_output" | grep "Transmit Rate:" | head -1 | sed 's/.*Transmit Rate: \([0-9]*\).*/\1/')
        local mcs=$(echo "$profiler_output" | grep "MCS Index:" | head -1 | sed 's/.*MCS Index: \([0-9]*\).*/\1/')

        # Calculate SNR
        local snr=0
        if [[ -n "$rssi" && -n "$noise" && "$rssi" =~ ^-?[0-9]+$ && "$noise" =~ ^-?[0-9]+$ ]]; then
            snr=$((rssi - noise))
        fi

        echo "CONNECTED=true"
        echo "INTERFACE=en0"
        echo "SSID=WiFi"  # SSID is redacted by macOS privacy
        echo "BSSID=unknown"
        echo "CHANNEL=${channel:-0}"
        echo "BAND=${band}"
        echo "WIDTH_MHZ=${width}"
        echo "RSSI_DBM=${rssi:-0}"
        echo "NOISE_DBM=${noise:-0}"
        echo "SNR_DB=${snr}"
        echo "TX_RATE_MBPS=${tx_rate:-0}"
        echo "MCS_INDEX=${mcs:--1}"
        return
    fi

    # Not connected to WiFi or using Ethernet
    echo "CONNECTED=false"
    echo "INTERFACE=none"
    echo "SSID=Unknown/Ethernet"
    echo "BSSID=unknown"
    echo "CHANNEL=0"
    echo "BAND=unknown"
    echo "WIDTH_MHZ=0"
    echo "RSSI_DBM=0"
    echo "NOISE_DBM=0"
    echo "SNR_DB=0"
    echo "TX_RATE_MBPS=0"
}

# Detect VPN status
# Note: Process running does NOT mean VPN is connected - must check for active tunnel
detect_vpn() {
    local vpn_status="disconnected"
    local vpn_name="none"

    # Helper: Check if any utun interface has an IPv4 address (active tunnel)
    local has_active_tunnel=false
    if ifconfig 2>/dev/null | grep -A2 "^utun" | grep -q "inet "; then
        has_active_tunnel=true
    fi

    # Zscaler Client Connector - must have process AND active tunnel
    if pgrep -x "Zscaler" > /dev/null 2>&1 || pgrep -x "ZscalerTunnel" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="Zscaler"
        fi
        # If tunnel not active, status stays "disconnected" and name stays "none"
    # Cisco AnyConnect - check for vpnagentd AND tunnel
    elif pgrep -x "vpnagentd" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="Cisco_AnyConnect"
        fi
    # Palo Alto GlobalProtect
    elif pgrep -x "PanGPS" > /dev/null 2>&1 || pgrep -x "GlobalProtect" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="GlobalProtect"
        fi
    # Fortinet FortiClient
    elif pgrep -x "FortiClient" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="FortiClient"
        fi
    # OpenVPN - process typically only runs when connected
    elif pgrep -x "openvpn" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="OpenVPN"
        fi
    # Tunnelblick (OpenVPN GUI) - app can run without tunnel
    elif pgrep -x "Tunnelblick" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="Tunnelblick"
        fi
    # WireGuard
    elif pgrep -x "wireguard-go" > /dev/null 2>&1; then
        if [[ "$has_active_tunnel" == "true" ]]; then
            vpn_status="connected"
            vpn_name="WireGuard"
        fi
    # Generic: unknown VPN with active tunnel
    elif [[ "$has_active_tunnel" == "true" ]]; then
        vpn_status="connected"
        vpn_name="Unknown_VPN"
    fi

    echo "VPN_STATUS=$vpn_status"
    echo "VPN_NAME=$vpn_name"
}

# Get MCS index and spatial streams from system_profiler
# This is slower (~2-3 sec) but provides valuable link quality info
get_mcs_info() {
    local mcs_index=-1
    local spatial_streams=0

    # Only run if we have WiFi (skip for Ethernet)
    if [[ "$CONNECTED" == "true" ]]; then
        # Parse system_profiler for MCS Index (in Current Network Information section)
        local sp_output=$(system_profiler SPAirPortDataType 2>/dev/null | grep -A 20 "Current Network Information:" | head -25)

        # Extract MCS Index
        mcs_index=$(echo "$sp_output" | grep "MCS Index:" | awk '{print $NF}')
        mcs_index=${mcs_index:--1}

        # Estimate spatial streams from MCS and rate
        # MCS 0-7 = 1 stream, MCS 8-15 = 2 streams, MCS 16-23 = 3 streams, etc.
        if [[ "$mcs_index" -ge 0 ]]; then
            spatial_streams=$(( (mcs_index / 8) + 1 ))
            # Cap at reasonable max
            if [[ $spatial_streams -gt 4 ]]; then
                spatial_streams=4
            fi
        fi
    fi

    echo "MCS_INDEX=$mcs_index"
    echo "SPATIAL_STREAMS=$spatial_streams"
}

# Get interface statistics (packet errors, collisions)
get_interface_stats() {
    local input_errors=0
    local output_errors=0
    local input_packets=0
    local output_packets=0

    # Parse netstat -I en0 for interface stats
    local netstat_output=$(netstat -I en0 2>/dev/null | tail -1)

    if [[ -n "$netstat_output" ]]; then
        # Columns: Name Mtu Network Address Ipkts Ierrs Opkts Oerrs Coll
        input_packets=$(echo "$netstat_output" | awk '{print $5}')
        input_errors=$(echo "$netstat_output" | awk '{print $6}')
        output_packets=$(echo "$netstat_output" | awk '{print $7}')
        output_errors=$(echo "$netstat_output" | awk '{print $8}')
    fi

    # Ensure numeric values (default to 0 if empty, dash, or non-numeric)
    [[ "$input_packets" == "-" || -z "$input_packets" ]] && input_packets=0
    [[ "$input_errors" == "-" || -z "$input_errors" ]] && input_errors=0
    [[ "$output_packets" == "-" || -z "$output_packets" ]] && output_packets=0
    [[ "$output_errors" == "-" || -z "$output_errors" ]] && output_errors=0

    # Calculate error rates based on previous values
    local prev_stats_file="$DATA_DIR/prev_interface_stats"
    local input_error_rate=0
    local output_error_rate=0

    if [[ -f "$prev_stats_file" ]]; then
        local prev_ipkts=$(awk 'NR==1' "$prev_stats_file")
        local prev_ierrs=$(awk 'NR==2' "$prev_stats_file")
        local prev_opkts=$(awk 'NR==3' "$prev_stats_file")
        local prev_oerrs=$(awk 'NR==4' "$prev_stats_file")

        # Default to 0 if empty or dash
        [[ "$prev_ipkts" == "-" || -z "$prev_ipkts" ]] && prev_ipkts=0
        [[ "$prev_ierrs" == "-" || -z "$prev_ierrs" ]] && prev_ierrs=0
        [[ "$prev_opkts" == "-" || -z "$prev_opkts" ]] && prev_opkts=0
        [[ "$prev_oerrs" == "-" || -z "$prev_oerrs" ]] && prev_oerrs=0

        local delta_ipkts=$((input_packets - prev_ipkts))
        local delta_ierrs=$((input_errors - prev_ierrs))
        local delta_opkts=$((output_packets - prev_opkts))
        local delta_oerrs=$((output_errors - prev_oerrs))

        # Calculate error rate as percentage (avoid division by zero)
        if [[ $delta_ipkts -gt 0 ]]; then
            input_error_rate=$(awk "BEGIN {printf \"%.4f\", ($delta_ierrs / $delta_ipkts) * 100}")
        fi
        if [[ $delta_opkts -gt 0 ]]; then
            output_error_rate=$(awk "BEGIN {printf \"%.4f\", ($delta_oerrs / $delta_opkts) * 100}")
        fi
    fi

    # Save current values for next run
    echo "$input_packets" > "$prev_stats_file"
    echo "$input_errors" >> "$prev_stats_file"
    echo "$output_packets" >> "$prev_stats_file"
    echo "$output_errors" >> "$prev_stats_file"

    echo "INPUT_ERRORS=$input_errors"
    echo "OUTPUT_ERRORS=$output_errors"
    echo "INPUT_ERROR_RATE=$input_error_rate"
    echo "OUTPUT_ERROR_RATE=$output_error_rate"
}

# Get TCP retransmission count (delta since last test, not cumulative)
get_tcp_retransmits() {
    local tcp_retransmits=0
    local tcp_retransmits_delta=0

    # Parse netstat -s for TCP retransmit stats (cumulative since boot)
    local retransmit_line=$(netstat -s 2>/dev/null | grep "data packets.*retransmitted" | head -1)

    if [[ -n "$retransmit_line" ]]; then
        tcp_retransmits=$(echo "$retransmit_line" | awk '{print $1}')
    fi

    # Calculate delta since last test
    local prev_retransmits_file="$DATA_DIR/prev_tcp_retransmits"
    if [[ -f "$prev_retransmits_file" ]]; then
        local prev_retransmits=$(cat "$prev_retransmits_file")
        [[ -z "$prev_retransmits" ]] && prev_retransmits=0
        tcp_retransmits_delta=$((tcp_retransmits - prev_retransmits))
        # Handle counter reset (reboot)
        [[ $tcp_retransmits_delta -lt 0 ]] && tcp_retransmits_delta=$tcp_retransmits
    fi

    # Save current value for next run
    echo "$tcp_retransmits" > "$prev_retransmits_file"

    echo "TCP_RETRANSMITS=${tcp_retransmits_delta:-0}"
}

# Track BSSID changes (roaming detection)
track_bssid_changes() {
    local current_bssid="$1"
    local bssid_changed=0
    local roam_count=0

    local prev_bssid_file="$DATA_DIR/prev_bssid"
    local roam_count_file="$DATA_DIR/roam_count"

    # Load previous BSSID
    if [[ -f "$prev_bssid_file" ]]; then
        local prev_bssid=$(cat "$prev_bssid_file")

        # Check if BSSID changed (roaming event)
        if [[ "$current_bssid" != "$prev_bssid" && -n "$current_bssid" && "$current_bssid" != "unknown" ]]; then
            bssid_changed=1
            log "BSSID changed from $prev_bssid to $current_bssid (roaming detected)"

            # Increment roam count
            if [[ -f "$roam_count_file" ]]; then
                roam_count=$(cat "$roam_count_file")
            fi
            roam_count=$((roam_count + 1))
            echo "$roam_count" > "$roam_count_file"
        fi
    fi

    # Load current roam count
    if [[ -f "$roam_count_file" ]]; then
        roam_count=$(cat "$roam_count_file")
    fi

    # Save current BSSID
    echo "$current_bssid" > "$prev_bssid_file"

    echo "BSSID_CHANGED=$bssid_changed"
    echo "ROAM_COUNT=${roam_count:-0}"
}

# Run ping test for jitter and packet loss calculation
run_ping_test() {
    local target="${1:-8.8.8.8}"
    local count="${2:-15}"

    # Run ping and capture output
    local ping_output=$(ping -c "$count" -q "$target" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "JITTER_MS=0"
        echo "JITTER_P50=0"
        echo "JITTER_P95=0"
        echo "PACKET_LOSS_PCT=100"
        return
    fi

    # Extract packet loss
    local packet_loss=$(echo "$ping_output" | grep "packet loss" | sed 's/.*\([0-9.]*\)% packet loss.*/\1/')
    packet_loss=${packet_loss:-0}

    # Run detailed ping for jitter calculation
    local detailed_ping=$(ping -c "$count" "$target" 2>&1)

    # Extract RTT values
    local rtt_values=$(echo "$detailed_ping" | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/')

    # Calculate jitter using awk
    # Bug fix: P50/P95 now calculated on jitter deltas, not RTT values
    local jitter_stats=$(echo "$rtt_values" | awk '
    BEGIN { n=0; prev=0; jitter_n=0 }
    NF > 0 {
        rtt = $1
        if (n > 0) {
            diff = (rtt > prev) ? (rtt - prev) : (prev - rtt)
            jitter_values[jitter_n] = diff
            jitter_n++
        }
        prev = rtt
        n++
    }
    END {
        if (jitter_n <= 0) {
            print "0 0 0"
            exit
        }

        # Mean jitter
        sum = 0
        for (i = 0; i < jitter_n; i++) {
            sum += jitter_values[i]
        }
        mean_jitter = sum / jitter_n

        # Sort jitter values for percentiles
        for (i = 0; i < jitter_n; i++) {
            for (j = i + 1; j < jitter_n; j++) {
                if (jitter_values[i] > jitter_values[j]) {
                    tmp = jitter_values[i]
                    jitter_values[i] = jitter_values[j]
                    jitter_values[j] = tmp
                }
            }
        }

        # P50 (median) of jitter
        p50_idx = int(jitter_n * 0.5)
        p50 = jitter_values[p50_idx]

        # P95 of jitter
        p95_idx = int(jitter_n * 0.95)
        if (p95_idx >= jitter_n) p95_idx = jitter_n - 1
        p95 = jitter_values[p95_idx]

        printf "%.2f %.2f %.2f\n", mean_jitter, p50, p95
    }')

    local jitter=$(echo "$jitter_stats" | awk '{print $1}')
    local p50=$(echo "$jitter_stats" | awk '{print $2}')
    local p95=$(echo "$jitter_stats" | awk '{print $3}')

    echo "JITTER_MS=${jitter:-0}"
    echo "JITTER_P50=${p50:-0}"
    echo "JITTER_P95=${p95:-0}"
    echo "PACKET_LOSS_PCT=${packet_loss:-0}"
}

# Get local IP address
get_local_ip() {
    # Get IP of the primary interface
    local ip=$(ipconfig getifaddr en0 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(ipconfig getifaddr en1 2>/dev/null)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}')
    fi
    echo "${ip:-unknown}"
}

# Escape string for JSON (handle quotes, backslashes, newlines)
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"      # Escape backslashes first
    str="${str//\"/\\\"}"      # Escape quotes
    str="${str//$'\n'/\\n}"    # Escape newlines
    str="${str//$'\r'/\\r}"    # Escape carriage returns
    str="${str//$'\t'/\\t}"    # Escape tabs
    echo "$str"
}

# Build JSON payload
build_json_payload() {
    local user_email=$(get_user_email)
    # Escape strings that might contain special characters
    local safe_ssid=$(json_escape "$SSID")
    local safe_vpn_name=$(json_escape "$VPN_NAME")
    local safe_errors=$(json_escape "$ERRORS")

    local json="{"
    json+="\"timestamp_utc\":\"$TIMESTAMP_UTC\","
    json+="\"device_id\":\"$DEVICE_ID\","
    json+="\"user_email\":\"$user_email\","
    json+="\"os_version\":\"$OS_VERSION\","
    json+="\"app_version\":\"$APP_VERSION\","
    json+="\"timezone\":\"$TIMEZONE\","
    json+="\"interface\":\"$INTERFACE\","
    json+="\"ssid\":\"$safe_ssid\","
    json+="\"bssid\":\"$BSSID\","
    json+="\"band\":\"$BAND\","
    json+="\"channel\":$CHANNEL,"
    json+="\"width_mhz\":$WIDTH_MHZ,"
    json+="\"rssi_dbm\":$RSSI_DBM,"
    json+="\"noise_dbm\":$NOISE_DBM,"
    json+="\"snr_db\":$SNR_DB,"
    json+="\"tx_rate_mbps\":$TX_RATE_MBPS,"
    json+="\"mcs_index\":$MCS_INDEX,"
    json+="\"spatial_streams\":$SPATIAL_STREAMS,"
    json+="\"local_ip\":\"$LOCAL_IP\","
    json+="\"public_ip\":\"$PUBLIC_IP\","
    json+="\"latency_ms\":$LATENCY_MS,"
    json+="\"jitter_ms\":$JITTER_MS,"
    json+="\"jitter_p50\":$JITTER_P50,"
    json+="\"jitter_p95\":$JITTER_P95,"
    json+="\"packet_loss_pct\":$PACKET_LOSS_PCT,"
    json+="\"download_mbps\":$DOWNLOAD_MBPS,"
    json+="\"upload_mbps\":$UPLOAD_MBPS,"
    json+="\"vpn_status\":\"$VPN_STATUS\","
    json+="\"vpn_name\":\"$safe_vpn_name\","
    json+="\"input_errors\":$INPUT_ERRORS,"
    json+="\"output_errors\":$OUTPUT_ERRORS,"
    json+="\"input_error_rate\":$INPUT_ERROR_RATE,"
    json+="\"output_error_rate\":$OUTPUT_ERROR_RATE,"
    json+="\"tcp_retransmits\":$TCP_RETRANSMITS,"
    json+="\"bssid_changed\":$BSSID_CHANGED,"
    json+="\"roam_count\":$ROAM_COUNT,"
    json+="\"errors\":\"$safe_errors\","
    json+="\"status\":\"$STATUS\""
    json+="}"
    echo "$json"
}

# Main collection function
collect_metrics() {
    local errors=""
    STATUS="pending"  # Initialize status

    log "Starting speed test (v$APP_VERSION)..."

    # Timestamp and device info
    TIMESTAMP_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    DEVICE_ID=$(get_device_id)
    OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    TIMEZONE=$(date +"%z")

    # WiFi details
    log "Collecting WiFi details..."
    eval $(get_wifi_details)

    # Handle missing WiFi (Ethernet connection)
    if [[ "$CONNECTED" != "true" ]]; then
        SSID="${SSID:-Unknown/Ethernet}"
        BSSID="${BSSID:-none}"
        CHANNEL="${CHANNEL:-0}"
        BAND="${BAND:-none}"
        WIDTH_MHZ="${WIDTH_MHZ:-0}"
        RSSI_DBM="${RSSI_DBM:-0}"
        NOISE_DBM="${NOISE_DBM:-0}"
        SNR_DB="${SNR_DB:-0}"
        TX_RATE_MBPS="${TX_RATE_MBPS:-0}"
    fi

    # Network info
    LOCAL_IP=$(get_local_ip)
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")

    # VPN detection
    log "Detecting VPN status..."
    eval $(detect_vpn)

    # MCS index and spatial streams (WiFi link quality)
    log "Collecting MCS info..."
    eval $(get_mcs_info)

    # Interface error stats
    log "Collecting interface stats..."
    eval $(get_interface_stats)

    # TCP retransmits
    eval $(get_tcp_retransmits)

    # BSSID change tracking (roaming detection)
    eval $(track_bssid_changes "$BSSID")

    # Ping/jitter test
    log "Running ping test for jitter..."
    eval $(run_ping_test)

    # Speed test
    log "Running speed test..."
    local speedtest_output=$(speedtest-cli --simple 2>&1)
    local speedtest_exit=$?

    if [[ $speedtest_exit -eq 0 ]]; then
        LATENCY_MS=$(echo "$speedtest_output" | grep "Ping:" | awk '{print $2}')
        DOWNLOAD_MBPS=$(echo "$speedtest_output" | grep "Download:" | awk '{print $2}')
        UPLOAD_MBPS=$(echo "$speedtest_output" | grep "Upload:" | awk '{print $2}')
        STATUS="success"
        log "Speed test completed - Down: ${DOWNLOAD_MBPS} Mbps, Up: ${UPLOAD_MBPS} Mbps"
    else
        LATENCY_MS="0"
        DOWNLOAD_MBPS="0"
        UPLOAD_MBPS="0"
        STATUS="failed"
        errors="speedtest_failed"
        log "Speed test failed: $speedtest_output"
    fi

    # Set defaults for any missing values
    LATENCY_MS=${LATENCY_MS:-0}
    DOWNLOAD_MBPS=${DOWNLOAD_MBPS:-0}
    UPLOAD_MBPS=${UPLOAD_MBPS:-0}
    JITTER_MS=${JITTER_MS:-0}
    JITTER_P50=${JITTER_P50:-0}
    JITTER_P95=${JITTER_P95:-0}
    PACKET_LOSS_PCT=${PACKET_LOSS_PCT:-0}
    MCS_INDEX=${MCS_INDEX:--1}
    SPATIAL_STREAMS=${SPATIAL_STREAMS:-0}
    INPUT_ERRORS=${INPUT_ERRORS:-0}
    OUTPUT_ERRORS=${OUTPUT_ERRORS:-0}
    INPUT_ERROR_RATE=${INPUT_ERROR_RATE:-0}
    OUTPUT_ERROR_RATE=${OUTPUT_ERROR_RATE:-0}
    TCP_RETRANSMITS=${TCP_RETRANSMITS:-0}
    BSSID_CHANGED=${BSSID_CHANGED:-0}
    ROAM_COUNT=${ROAM_COUNT:-0}

    ERRORS="$errors"

    # Build JSON payload
    local raw_payload=$(build_json_payload)
    # Escape quotes for CSV
    local csv_payload=$(echo "$raw_payload" | sed 's/"/\\"/g')

    # Append to CSV (v2.1 schema)
    echo "$TIMESTAMP_UTC,$DEVICE_ID,$OS_VERSION,$APP_VERSION,$TIMEZONE,$INTERFACE,$SSID,$BSSID,$BAND,$CHANNEL,$WIDTH_MHZ,$RSSI_DBM,$NOISE_DBM,$SNR_DB,$TX_RATE_MBPS,$MCS_INDEX,$SPATIAL_STREAMS,$LOCAL_IP,$PUBLIC_IP,$LATENCY_MS,$JITTER_MS,$JITTER_P50,$JITTER_P95,$PACKET_LOSS_PCT,$DOWNLOAD_MBPS,$UPLOAD_MBPS,$VPN_STATUS,$VPN_NAME,$INPUT_ERRORS,$OUTPUT_ERRORS,$INPUT_ERROR_RATE,$OUTPUT_ERROR_RATE,$TCP_RETRANSMITS,$BSSID_CHANGED,$ROAM_COUNT,$ERRORS,\"$csv_payload\"" >> "$CSV_FILE"

    # Send to server if configured
    if [[ -n "$SERVER_URL" ]]; then
        log "Sending results to server..."
        curl -s --max-time 10 --connect-timeout 5 -X POST "$SERVER_URL/api/results" \
            -H "Content-Type: application/json" \
            -d "$raw_payload" > /dev/null 2>&1 || log "Failed to send to server"
    fi

    # Print summary
    echo "=== Speed Test Results (v$APP_VERSION) ==="
    echo "Time: $TIMESTAMP_UTC"
    echo "Device: $DEVICE_ID"
    echo "OS: macOS $OS_VERSION"
    echo "Network: $SSID ($INTERFACE)"
    echo "BSSID: $BSSID"
    echo "Band: $BAND | Channel: $CHANNEL | Width: ${WIDTH_MHZ}MHz"
    echo "Signal: ${RSSI_DBM}dBm | Noise: ${NOISE_DBM}dBm | SNR: ${SNR_DB}dB"
    echo "Link: MCS $MCS_INDEX | Streams: $SPATIAL_STREAMS | TX Rate: ${TX_RATE_MBPS}Mbps"
    echo "VPN: $VPN_NAME ($VPN_STATUS)"
    echo "Download: $DOWNLOAD_MBPS Mbps"
    echo "Upload: $UPLOAD_MBPS Mbps"
    echo "Latency: $LATENCY_MS ms"
    echo "Jitter: $JITTER_MS ms (P50: $JITTER_P50 | P95: $JITTER_P95)"
    echo "Packet Loss: $PACKET_LOSS_PCT%"
    echo "Errors: In=${INPUT_ERROR_RATE}% Out=${OUTPUT_ERROR_RATE}% | Retransmits: $TCP_RETRANSMITS"
    echo "Roaming: Changed=$BSSID_CHANGED | Total Roams: $ROAM_COUNT"
    echo "Status: $STATUS"
    echo "Results saved to: $CSV_FILE"

    log "Test completed"
}

# Run main collection
collect_metrics

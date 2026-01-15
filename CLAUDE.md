# Speed Monitor v3.1 - Organization Internet Monitoring

## Overview

Speed Monitor is an automated internet performance tracking system for organizations. It consists of:
- **Client**: macOS shell script that runs speed tests every 10 minutes via launchd
- **Server**: Node.js/Express API with SQLite database, deployed on Railway
- **Dashboard**: Real-time web dashboard with shadcn-inspired UI
- **Menu Bar**: SwiftBar plugin showing live connection stats
- **Self-Service Portal**: Employee-facing dashboard at `/my/:email`

**Live URLs:**
- Dashboard: https://home-internet-production.up.railway.app/
- Self-Service Portal: https://home-internet-production.up.railway.app/my
- Setup Guide: https://home-internet-production.up.railway.app/setup
- GitHub: https://github.com/hyperkishore/home-internet

---

## Architecture

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  macOS Client   │         │  Railway Server │         │   Dashboard     │
│                 │  POST   │                 │   GET   │                 │
│ speed_monitor.sh├────────►│  /api/results   ├────────►│  dashboard.html │
│ (launchd 10min) │         │  (SQLite DB)    │         │  (Chart.js)     │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

---

## Project Structure

```
home-internet/
├── CLAUDE.md                    # This file - project documentation
├── speed_monitor.sh             # Main client script (v2.1)
├── com.speedmonitor.plist       # launchd configuration
├── swiftbar-plugin.sh           # SwiftBar menu bar integration
│
├── dist/
│   ├── install.sh               # One-line installer for employees
│   ├── src/
│   │   └── wifi_info.swift      # Swift helper for WiFi details
│   └── server/
│       ├── index.js             # Express server (v3.1)
│       ├── package.json         # Node dependencies
│       ├── Dockerfile           # Railway deployment
│       └── public/
│           ├── dashboard.html   # IT Admin dashboard (shadcn UI)
│           ├── my.html          # Employee portal landing page
│           ├── my-employee.html # Employee self-service dashboard
│           └── setup.html       # Installation guide
│
└── credentials.md               # Router credentials (gitignored)
```

---

## Key Files & Purposes

| File | Purpose |
|------|---------|
| `speed_monitor.sh` | Runs speedtest-cli, collects WiFi metrics, POSTs to server |
| `dist/install.sh` | One-line installer: installs Homebrew, speedtest-cli, sets up launchd |
| `dist/server/index.js` | Express API with SQLite, anomaly detection, Slack alerts |
| `dashboard.html` | Organization-wide stats, charts, device fleet view |
| `my-device.html` | Per-device stats, recommendations, CSV export |
| `setup.html` | Installation guide with copy-paste commands |
| `swiftbar-plugin.sh` | Menu bar widget showing current speeds |

---

## API Endpoints

### Core Endpoints
| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/api/results` | Submit speed test result |
| GET | `/api/stats` | Overall + per-device stats |
| GET | `/api/stats/vpn` | VPN distribution and speed comparison |
| GET | `/api/stats/wifi` | WiFi band/channel/SSID stats |
| GET | `/api/stats/jitter` | Jitter distribution + problem devices |

### v3.0 Analytics Endpoints
| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/stats/trends?days=30` | Historical trends (7/30/60/90 days) |
| GET | `/api/stats/isp` | ISP comparison by avg download |
| GET | `/api/stats/timeofday?days=30` | Performance heatmap by hour |
| GET | `/api/recommendations/wifi` | WiFi optimization suggestions |

### Device Endpoints
| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/devices/:id/health` | Device health + recent tests |
| GET | `/api/devices/:id/troubleshoot` | Auto-generated recommendations |
| GET | `/api/devices/:id/export?days=30` | CSV export of device data |

### Employee Self-Service (v3.1)
| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/my/:email` | Employee dashboard data (health, timeline, recommendations) |
| GET | `/api/stats/timeline?hours=24` | Speed timeline for charts |

### Alerts Endpoints
| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/api/alerts/config` | Create alert configuration |
| GET | `/api/alerts/config` | List alert configs |
| GET | `/api/alerts/history` | Recent alert history |
| POST | `/api/alerts/test` | Send test alert |

---

## Database Schema (SQLite)

### Main Table: `speed_results`
```sql
-- Identity
device_id TEXT NOT NULL,
hostname TEXT,
timestamp_utc DATETIME NOT NULL,

-- WiFi
ssid TEXT, bssid TEXT, band TEXT,
channel INTEGER, rssi_dbm INTEGER,

-- Performance
download_mbps REAL, upload_mbps REAL,
latency_ms REAL, jitter_ms REAL,
packet_loss_pct REAL,

-- VPN
vpn_status TEXT, vpn_name TEXT,

-- Status
status TEXT DEFAULT 'success',
errors TEXT
```

### v3.0 Tables
- `alert_configs` - Slack/Teams webhook configurations
- `alert_history` - Triggered alert log
- `isp_cache` - IP geolocation cache (ip-api.com)
- `daily_aggregates` - Pre-computed daily stats
- `device_baselines` - Z-score anomaly detection baselines

---

## Common Failure Points & Solutions

### 1. Client: "Operation not permitted" on macOS
**Cause**: macOS security blocking script execution
**Solution**:
```bash
# Grant Full Disk Access to bash
System Settings → Privacy & Security → Full Disk Access → Add /bin/bash
# Then restart launchd
launchctl unload ~/Library/LaunchAgents/com.speedmonitor.plist
launchctl load ~/Library/LaunchAgents/com.speedmonitor.plist
```

### 2. Client: speedtest-cli not found
**Cause**: Homebrew not in PATH for launchd
**Solution**: The plist includes PATH explicitly:
```xml
<key>PATH</key>
<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
```

### 3. Client: WiFi info empty
**Cause**: wifi_info Swift helper not compiled
**Solution**:
```bash
swiftc -O -o ~/.local/bin/wifi_info \
  ~/.local/share/nkspeedtest/wifi_info.swift \
  -framework CoreWLAN -framework Foundation
```

### 4. Server: Database reset on deploy
**Cause**: Railway ephemeral filesystem - SQLite file deleted on redeploy
**Solution**: Use Railway's persistent volume or migrate to PostgreSQL
```bash
# Current workaround: data is transient, acceptable for monitoring
# For persistence: Railway → Settings → Add Volume → Mount at /data
```

### 5. Server: ISP lookup failing
**Cause**: ip-api.com rate limit (45 req/min for free tier)
**Solution**: Results are cached in `isp_cache` table for 7 days

### 6. Dashboard: Charts not loading
**Cause**: API returning empty arrays
**Solution**: Check browser console, verify `/api/stats` returns data

### 7. Alerts: Slack webhook not firing
**Cause**: Webhook URL not configured or invalid
**Solution**:
```bash
# Test webhook manually
curl -X POST https://hooks.slack.com/services/XXX \
  -H "Content-Type: application/json" \
  -d '{"text":"Test alert"}'
```

### 8. launchd: Job not running
**Cause**: plist syntax error or not loaded
**Solution**:
```bash
# Check if loaded
launchctl list | grep speedmonitor

# Check for errors
plutil -lint ~/Library/LaunchAgents/com.speedmonitor.plist

# View logs
tail -50 ~/.local/share/nkspeedtest/launchd_stderr.log
```

---

## Deployment (Railway)

### Environment Variables
```
PORT=3000              # Set automatically by Railway
DB_PATH=./speed_monitor.db
```

### Dockerfile
```dockerfile
FROM node:20-alpine
RUN apk add --no-cache python3 make g++ sqlite
WORKDIR /app
COPY dist/server/package*.json ./
RUN npm ci --only=production
COPY dist/server .
EXPOSE 3000
CMD ["node", "index.js"]
```

### Deploy Commands
```bash
git push origin main   # Auto-deploys via GitHub integration
```

---

## Installation (Employee Onboarding)

### One-Line Install
```bash
curl -fsSL https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/install.sh | bash
```

### What It Installs
1. Homebrew (if not present)
2. speedtest-cli via Homebrew
3. speed_monitor.sh → ~/.local/bin/
4. wifi_info Swift helper (compiled)
5. launchd plist → ~/Library/LaunchAgents/
6. Starts service (runs every 10 minutes)

### Verify Installation
```bash
launchctl list | grep speedmonitor          # Should show PID
cat ~/.config/nkspeedtest/device_id         # Unique device ID
tail -5 ~/.local/share/nkspeedtest/speed_log.csv  # Recent results
```

---

## Local Development

```bash
# Server
cd dist/server
npm install
node index.js
# → http://localhost:3000

# Client (manual test)
SPEED_MONITOR_SERVER=http://localhost:3000 ./speed_monitor.sh
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| SQLite over PostgreSQL | Simpler deployment, sufficient for ~300 devices |
| Shell script over native app | No Apple Developer account needed, easy to audit |
| launchd over cron | Native macOS, survives reboots, better logging |
| Z-score anomaly detection | No ML dependencies, works with small datasets |
| shadcn-inspired UI | Modern, clean, matches Vercel aesthetic |
| curl installer over .dmg | Bypasses Gatekeeper, no notarization required |

---

## Metrics Collected

| Metric | Source | Unit |
|--------|--------|------|
| Download speed | speedtest-cli | Mbps |
| Upload speed | speedtest-cli | Mbps |
| Latency (ping) | speedtest-cli | ms |
| Jitter | speedtest-cli --json | ms |
| Packet loss | speedtest-cli --json | % |
| WiFi SSID | wifi_info / airport | string |
| WiFi BSSID | wifi_info | MAC |
| WiFi Band | wifi_info | 2.4/5/6 GHz |
| WiFi Channel | wifi_info | 1-165 |
| WiFi RSSI | wifi_info | dBm |
| VPN Status | scutil --nc list | connected/disconnected |
| VPN Name | scutil --nc list | string |
| Public IP | speedtest-cli | IP address |

---

## Router Configuration (Home Setup)

### Hardware
- **Model:** TP-Link Archer C5 v4
- **Firmware:** 3.16.0 0.9.1 v6015.0
- **ISP:** ACT Fibernet

### Optimized Settings
| Setting | Value | Reason |
|---------|-------|--------|
| 2.4GHz Encryption | AES | Faster than TKIP |
| 2.4GHz Mode | 802.11g/n | Removed slow 802.11b |
| 5GHz Encryption | AES | Faster than TKIP |
| Band Steering | Enabled | Auto-switches to best band |

### Known Router Bug
**Error 7503**: "The input SSID already exists" - Firmware bug. Workaround: Slightly modify SSID before saving.

---

## Useful Commands

```bash
# View recent speed tests
tail -20 ~/.local/share/nkspeedtest/speed_log.csv

# Run test manually
~/.local/bin/speed_monitor.sh

# Check service status
launchctl list | grep speedmonitor

# View launchd logs
tail -f ~/.local/share/nkspeedtest/launchd_stdout.log

# Restart service
launchctl unload ~/Library/LaunchAgents/com.speedmonitor.plist
launchctl load ~/Library/LaunchAgents/com.speedmonitor.plist

# Check device ID
cat ~/.config/nkspeedtest/device_id
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | - | Basic speed logging to CSV |
| 2.0 | - | Server upload, WiFi metrics, VPN detection |
| 2.1 | 2026-01 | Added user_email support, fixed netstat dash handling |
| 3.0 | 2026-01 | Anomaly detection, Slack alerts, ISP comparison, shadcn UI |
| 3.1 | 2026-01 | Employee self-service portal, median jitter, local time display, speed timeline charts |

---

## Key Features (v3.1)

### Employee Self-Service Portal
- **URL**: `/my` → enter email → `/my/:email`
- **Traffic light status**: Green/Yellow/Red health indicator
- **Problem detection**: High jitter, weak signal, slow speed, VPN off
- **Recommendations**: Actionable suggestions based on diagnostics
- **24-hour speed chart**: Interactive Chart.js visualization
- **Recent tests table**: Last 10 speed test results
- **Share/Export**: Copy link, email IT support

### Median vs Average Jitter
- **Problem**: One outlier (19712ms) skewed average to 1411ms
- **Solution**: Use median jitter (typically ~4ms) for accurate representation
- **API**: Returns both `avg_jitter` and `median_jitter`

### Data Collection (v2.1 client)
| Metric | Source | Notes |
|--------|--------|-------|
| MCS Index | system_profiler | WiFi link quality |
| Spatial Streams | Calculated | From MCS index |
| Interface Errors | netstat -I en0 | Input/output error rates |
| TCP Retransmits | netstat -s | Connection quality |
| BSSID Changes | Tracked | Roaming detection |
| User Email | ~/.config/nkspeedtest/user_email | Set during install |

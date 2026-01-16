# Speed Monitor v3.1.0 - Installation Fixes Applied

## What Was Fixed

### 1. ✅ Homebrew Installation (Major Fix)

**Previous Issue:**
- Homebrew installation failed with "Need sudo access" error
- Ran in interactive mode during .pkg installation
- Permission issues with /opt/homebrew

**Fixed:**
- Added `NONINTERACTIVE=1` and `CI=1` flags for silent installation
- Pre-creates /opt/homebrew with correct ownership
- Fixes permissions automatically after installation
- Detects architecture (ARM64 vs Intel) and uses correct prefix
- Verifies installation succeeded before proceeding
- Comprehensive logging to `/var/log/homebrew-install-*.log`

### 2. ✅ Swift Menu Bar App Compilation

**Previous Issue:**
```
error: 'main' attribute cannot be used in a module that contains top-level code
```

**Fixed:**
- Added `-parse-as-library` flag to Swift compilation
- Now compiles SpeedMonitor.app successfully
- Creates proper .app bundle structure

### 3. ✅ speedtest-cli Installation

**Previous Issue:**
- Failed to install due to Homebrew issues
- Incorrect PATH detection
- Permission errors

**Fixed:**
- Waits for Homebrew to finish installing
- Uses correct Homebrew prefix path
- Verifies binary exists before marking as successful
- Creates symlink in user's ~/.local/bin for easy access

### 4. ✅ Error Handling

**Previous Issue:**
- Script exited on first error (set -e)
- No graceful fallbacks

**Fixed:**
- Changed to `set +e` to continue on errors
- Each component can fail independently
- Logs warnings instead of failing entirely
- User can fix issues manually if needed

---

## What Gets Installed

### Phase 1: Preinstall (Checks)
- ✓ Verifies macOS 11+ (Big Sur or later)
- ✓ Checks for Xcode Command Line Tools
- ✓ Validates disk space (500MB+ needed)

### Phase 2: File Installation
```
/usr/local/speedmonitor/
├── bin/
│   ├── speed_monitor.sh       Main monitoring script
│   ├── wifi_info              Compiled Swift WiFi helper
│   └── watchdog.sh            Health monitor
└── lib/
    ├── config.sh              Your configuration
    ├── SpeedMonitor.app/      Menu bar app (compiled)
    └── *.swift                Source files
```

### Phase 3: Postinstall (Setup)

**Step 1: Homebrew (5-10 minutes)**
- Detects Apple Silicon (ARM64) → /opt/homebrew
- Or Intel (x86_64) → /usr/local
- Downloads and installs Homebrew non-interactively
- Sets correct ownership and permissions

**Step 2: speedtest-cli (~1 minute)**
- Installs via Homebrew: `brew install speedtest-cli`
- Verifies binary at `/opt/homebrew/bin/speedtest-cli`
- Creates symlink for user access

**Step 3: Swift Compilation (~30 seconds)**
- Compiles wifi_info helper (CoreWLAN framework)
- Compiles SpeedMonitor.app (menu bar application)
- Creates proper .app bundle with Info.plist

**Step 4: User Setup (for each user)**
- Generates unique device ID
- Creates directories (~/.local, ~/.config)
- Creates LaunchAgent (runs every 10 minutes)
- Installs SpeedMonitor.app to ~/Applications/
- Loads LaunchAgent if user is logged in

**Step 5: Initial Test**
- Runs first speed test in background
- Results saved to ~/.local/share/nkspeedtest/

---

## Installation Time

- **Quick (if Homebrew exists):** ~2 minutes
- **Full (fresh install):** ~10-15 minutes
  - Homebrew download: 5-10 minutes
  - speedtest-cli: 30-60 seconds
  - Swift compilation: 30 seconds
  - User setup: 30 seconds

---

## How to Install

### Clean Install (Removes Previous Attempt)

```bash
# 1. Remove previous installation (if exists)
sudo rm -rf /usr/local/speedmonitor
sudo rm -rf /opt/homebrew  # Only if you want fresh Homebrew
rm -rf ~/.local/share/nkspeedtest
rm -rf ~/.local/bin/speed_monitor.sh
rm ~/Library/LaunchAgents/com.speedmonitor.plist

# 2. Install the fixed package
sudo installer -pkg SpeedMonitor-3.1.0.pkg -target /

# 3. Watch installation progress (in another Terminal tab)
tail -f /var/log/speedmonitor-install.log

# 4. Wait for "Installation Complete" message (10-15 minutes)
```

### Upgrade Install (Keep Existing Setup)

```bash
# Just run the installer - it will upgrade existing installation
sudo installer -pkg SpeedMonitor-3.1.0.pkg -target /
```

---

## Verify Installation

### Check 1: Homebrew Installed
```bash
/opt/homebrew/bin/brew --version
# Expected: Homebrew 4.x.x
```

### Check 2: speedtest-cli Works
```bash
/opt/homebrew/bin/speedtest-cli --version
# Expected: speedtest-cli 2.1.x
```

### Check 3: Menu Bar App Exists
```bash
ls -la ~/Applications/SpeedMonitor.app/Contents/MacOS/SpeedMonitor
# Expected: -rwxr-xr-x ... SpeedMonitor (executable file, not empty)
```

### Check 4: LaunchAgent Running
```bash
launchctl list | grep speedmonitor
# Expected: 12345  0  com.speedmonitor (with PID)
```

### Check 5: Data Being Collected
```bash
tail ~/.local/share/nkspeedtest/speed_log.csv
# Expected: Recent test results with non-zero speeds
```

### Check 6: Menu Bar Icon Visible
```bash
# Launch the menu bar app
open ~/Applications/SpeedMonitor.app

# Check if it's running
ps aux | grep SpeedMonitor | grep -v grep
# Expected: Shows SpeedMonitor process
```

---

## Troubleshooting

### Issue: "Installation Failed"

**Check logs:**
```bash
tail -100 /var/log/speedmonitor-install.log
tail -100 /var/log/install.log | grep -i error
```

**Common causes:**
- Network issues during Homebrew download
- Insufficient disk space
- Missing Xcode Command Line Tools

### Issue: Homebrew Still Not Working

**Manual fix:**
```bash
# Fix ownership
sudo chown -R $(whoami) /opt/homebrew

# Update Homebrew
/opt/homebrew/bin/brew update
```

### Issue: speedtest-cli Not Found

**Manual install:**
```bash
/opt/homebrew/bin/brew install speedtest-cli

# Or download directly
curl -Lo /usr/local/bin/speedtest-cli https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py
chmod +x /usr/local/bin/speedtest-cli
```

### Issue: Menu Bar App Not Compiling

**Check Swift version:**
```bash
swiftc --version
# Need Swift 5.5+
```

**Manual compile:**
```bash
cd /usr/local/speedmonitor/lib

swiftc -parse-as-library \
       -o SpeedMonitor.app/Contents/MacOS/SpeedMonitor \
       SpeedMonitorMenuBar.swift \
       -framework SwiftUI \
       -framework CoreWLAN \
       -framework CoreLocation \
       -framework AppKit

cp -r SpeedMonitor.app ~/Applications/
open ~/Applications/SpeedMonitor.app
```

### Issue: No Menu Bar Icon After Launch

**Grant Location Services:**
1. Open SpeedMonitor.app
2. macOS will prompt for Location Services
3. Click "Allow" to see WiFi SSID in menu bar

**Or check System Settings:**
```
System Settings → Privacy & Security → Location Services
→ Find SpeedMonitor → Enable
```

---

## Success Criteria

After installation completes, you should have:

- [x] Homebrew installed at /opt/homebrew (ARM) or /usr/local (Intel)
- [x] speedtest-cli binary at /opt/homebrew/bin/speedtest-cli
- [x] SpeedMonitor.app in ~/Applications/ (with executable)
- [x] LaunchAgent running (check with `launchctl list`)
- [x] CSV file with speed test data
- [x] Menu bar icon showing current speed

---

## Next Steps After Installation

### 1. Grant Location Services Permission

```bash
open ~/Applications/SpeedMonitor.app
# Click "Allow" when prompted for Location Services
```

### 2. Run Test Script

```bash
cd /Users/User/Documents/wifi-resolution/wifi-desktop-analyser
./test-installation.sh
```

### 3. Wait for First Speed Test

The LaunchAgent runs every 10 minutes. Check logs:
```bash
tail -f ~/.local/share/nkspeedtest/speed_monitor.log
```

### 4. View Dashboard

Open your browser to:
```
https://home-internet-production.up.railway.app/
```

---

## Installation Logs

**Main installation log:**
```
/var/log/speedmonitor-install.log
```

**Homebrew installation log:**
```
/var/log/homebrew-install-*.log
```

**Runtime logs:**
```
~/.local/share/nkspeedtest/speed_monitor.log
~/.local/share/nkspeedtest/launchd_stdout.log
~/.local/share/nkspeedtest/launchd_stderr.log
```

---

## Package Details

- **Version:** 3.1.0
- **Size:** 24KB
- **Architecture:** Universal (Intel + Apple Silicon)
- **macOS:** 11.0+ (Big Sur or later)
- **Dependencies:**
  - Homebrew (auto-installed)
  - speedtest-cli (auto-installed)
  - Xcode Command Line Tools (required)

---

## What Changed from Previous Version

| Component | Previous | Fixed |
|-----------|----------|-------|
| Homebrew install | Failed (interactive) | ✅ Works (NONINTERACTIVE=1) |
| speedtest-cli | Not installed | ✅ Auto-installed |
| SpeedMonitor.app | Compile error | ✅ Compiles with -parse-as-library |
| Permissions | Manual fixes needed | ✅ Auto-fixed |
| Error handling | Fails on first error | ✅ Continues gracefully |

---

## Distribution Ready

The package is now ready for:

✅ **Email/Slack distribution** (send .pkg file)
✅ **Jamf Pro deployment** (upload as package)
✅ **Microsoft Intune** (upload as LOB app)
✅ **Self-Service installation** (double-click .pkg)

**No user interaction required except:**
- Entering admin password once
- Granting Location Services (optional, for WiFi SSID)

---

## Support

**If installation still fails:**

1. Check logs: `/var/log/speedmonitor-install.log`
2. Verify Homebrew works: `/opt/homebrew/bin/brew doctor`
3. Run test script: `./test-installation.sh`
4. Contact IT support with log files

**Package location:**
```
/Users/User/Documents/wifi-resolution/wifi-desktop-analyser/SpeedMonitor-3.1.0.pkg
```

Ready to deploy! 🚀

# Speed Monitor .pkg Installer Builder

This directory contains everything needed to build a self-contained macOS .pkg installer for Speed Monitor.

## What Does the .pkg Do?

The installer package will **automatically**:

1. ✅ Install Homebrew (if not present)
2. ✅ Install speedtest-cli via Homebrew
3. ✅ Compile Swift WiFi helper
4. ✅ Build SpeedMonitor.app menu bar application
5. ✅ Set up LaunchAgents for all users (runs every 10 minutes)
6. ✅ Create data directories and configuration
7. ✅ Generate unique device IDs
8. ✅ Run initial speed test

**User only needs to:** Click "Install" and enter admin password once.

---

## Quick Start

### Step 1: Configure Your Deployment

```bash
cd /Users/User/Documents/wifi-resolution/wifi-desktop-analyser

# Run configuration wizard
./configure-pkg.sh

# You'll be prompted for:
# - Railway server URL (e.g., https://your-app.up.railway.app)
# - Company name (for branding)
# - Email domain (optional)
```

### Step 2: Build the Package

```bash
# Build the .pkg installer
./build-pkg.sh

# Output: SpeedMonitor-3.1.0.pkg (ready to distribute)
```

### Step 3: Test Locally

```bash
# Install on your test Mac
sudo installer -pkg SpeedMonitor-3.1.0.pkg -target /

# Verify installation
launchctl list | grep speedmonitor
tail -f /var/log/speedmonitor-install.log

# Check menu bar for SpeedMonitor icon
```

### Step 4: Distribute

**Option A: Email/Slack (for small teams)**
- Send the .pkg file to employees
- They double-click and install (requires admin password)

**Option B: Jamf Pro**
1. Upload to Jamf → Computer Management → Packages
2. Create policy → Deploy at enrollment or check-in
3. Zero-touch deployment

**Option C: Microsoft Intune**
1. Wrap with Intune tool (optional)
2. Upload to Apps → macOS → Line-of-business app
3. Assign to device groups

---

## Configuration Options

Edit `pkg-config.env` after running `./configure-pkg.sh`:

```bash
# Speed Monitor Package Configuration

# REQUIRED: Your Railway server URL
SERVER_URL="https://your-app.up.railway.app"

# Company name shown in UI
COMPANY_NAME="Acme Corp"

# Email domain for validation (optional)
EMAIL_DOMAIN="acme.com"
```

---

## What Gets Installed

### Global Installation (All Users):

```
/usr/local/speedmonitor/
├── bin/
│   ├── speed_monitor.sh          # Main monitoring script
│   ├── wifi_info                 # Compiled Swift helper
│   └── watchdog.sh               # Health monitor
├── lib/
│   ├── config.sh                 # Configuration file
│   ├── wifi_info.swift           # Swift helper source
│   ├── SpeedMonitor.app/         # Menu bar app
│   └── *.plist                   # LaunchAgent templates
```

### Per-User Installation:

```
~/Library/LaunchAgents/
└── com.speedmonitor.plist        # Auto-start configuration

~/.local/
├── bin/
│   └── speed_monitor.sh → /usr/local/speedmonitor/bin/speed_monitor.sh
└── share/nkspeedtest/
    ├── speed_log.csv             # Local data backup
    ├── speed_monitor.log         # Application logs
    └── launchd_stdout.log        # LaunchAgent logs

~/.config/nkspeedtest/
├── device_id                     # Unique device identifier
└── user_email                    # User email (optional)

~/Applications/
└── SpeedMonitor.app              # Menu bar app (or /Applications/)
```

---

## Installation Logs

All installation activity is logged to:

```
/var/log/speedmonitor-install.log
```

View logs:
```bash
sudo tail -f /var/log/speedmonitor-install.log
```

---

## Requirements

### macOS Version:
- macOS 11 (Big Sur) or later
- Works on both Intel (x86_64) and Apple Silicon (arm64)

### Disk Space:
- ~500MB for Homebrew + dependencies
- ~50MB for Speed Monitor

### Permissions:
- Admin password required for installation
- Location Services (granted by user after install)

---

## Troubleshooting

### Build Issues

**Problem:** `xcrun: error: invalid active developer path`

**Solution:**
```bash
# Install Xcode Command Line Tools
xcode-select --install
```

**Problem:** `build-pkg.sh: Permission denied`

**Solution:**
```bash
chmod +x build-pkg.sh configure-pkg.sh
```

### Installation Issues

**Problem:** Homebrew installation hangs

**Solution:**
- Installation may take 5-10 minutes (downloads ~300MB)
- Check `/var/log/speedmonitor-install.log` for progress
- If stuck, cancel and install Homebrew manually first:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

**Problem:** speedtest-cli not found after installation

**Solution:**
```bash
# Add Homebrew to PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Verify
which speedtest-cli
```

**Problem:** LaunchAgent not running

**Solution:**
```bash
# Check if loaded
launchctl list | grep speedmonitor

# Manual load
launchctl load ~/Library/LaunchAgents/com.speedmonitor.plist

# Check logs
tail ~/.local/share/nkspeedtest/launchd_stderr.log
```

### Runtime Issues

**Problem:** Menu bar icon not appearing

**Solution:**
```bash
# Launch app manually
open ~/Applications/SpeedMonitor.app
# or
open /Applications/SpeedMonitor.app
```

**Problem:** SSID shows as "WiFi" (redacted)

**Solution:**
- Open SpeedMonitor.app
- Click "Settings" → "Grant Permission"
- Allow Location Services when prompted

**Problem:** Speed test fails

**Solution:**
```bash
# Test speedtest-cli manually
speedtest-cli --simple

# Check network connectivity
curl -I https://www.google.com

# View error logs
tail ~/.local/share/nkspeedtest/speed_monitor.log
```

---

## Advanced Customization

### Change Collection Interval

Edit LaunchAgent template before building:

```bash
nano com.speedmonitor.plist

# Change this line:
<key>StartInterval</key>
<integer>600</integer>  <!-- 600 seconds = 10 minutes -->

# Options:
# 300  = 5 minutes
# 600  = 10 minutes (default)
# 900  = 15 minutes
# 1800 = 30 minutes
```

Then rebuild: `./build-pkg.sh`

### Customize Email Prompt

Edit postinstall script in `build-pkg.sh` around line 350:

```bash
# Prompt for email (interactive mode only)
if [ -t 0 ] && [ ! -f "$user_home/${USER_CONFIG_DIR}/user_email" ]; then
    echo ""
    echo "Enter email for $username (or press Enter to skip):"
    read -r user_email
    if [ -n "$user_email" ]; then
        echo "$user_email" | sudo -u "$username" tee "$user_home/${USER_CONFIG_DIR}/user_email" > /dev/null
        log "Email saved for $username: $user_email"
    fi
fi
```

Change to auto-generate from username:
```bash
# Auto-generate email from username
if [ ! -f "$user_home/${USER_CONFIG_DIR}/user_email" ]; then
    user_email="${username}@${EMAIL_DOMAIN}"
    echo "$user_email" | sudo -u "$username" tee "$user_home/${USER_CONFIG_DIR}/user_email" > /dev/null
    log "Generated email for $username: $user_email"
fi
```

### Add Custom Branding

Replace SpeedMonitor.app icon:

```bash
# Create icon from PNG (requires macOS iconutil)
mkdir SpeedMonitor.iconset
# Add icon files: icon_16x16.png, icon_32x32.png, etc.
iconutil -c icns SpeedMonitor.iconset

# Copy to app bundle
cp SpeedMonitor.icns WiFiHelper/build/SpeedMonitor.app/Contents/Resources/

# Update Info.plist
# Add: <key>CFBundleIconFile</key><string>SpeedMonitor.icns</string>
```

---

## Signing the Package (Optional)

For enterprise distribution, sign the package with your Developer ID:

```bash
# Sign the package
productsign --sign "Developer ID Installer: Your Company (TEAMID)" \
             SpeedMonitor-3.1.0.pkg \
             SpeedMonitor-3.1.0-signed.pkg

# Verify signature
pkgutil --check-signature SpeedMonitor-3.1.0-signed.pkg

# Notarize with Apple (for Gatekeeper)
xcrun notarytool submit SpeedMonitor-3.1.0-signed.pkg \
                       --apple-id "your@email.com" \
                       --team-id "TEAMID" \
                       --password "app-specific-password" \
                       --wait

# Staple notarization ticket
xcrun stapler staple SpeedMonitor-3.1.0-signed.pkg
```

---

## Uninstallation

To remove Speed Monitor from a Mac:

```bash
# Stop LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.speedmonitor.plist

# Remove files
rm -rf /usr/local/speedmonitor
rm ~/Library/LaunchAgents/com.speedmonitor.plist
rm -rf ~/.local/share/nkspeedtest
rm -rf ~/.local/bin/speed_monitor.sh
rm -rf ~/.config/nkspeedtest
rm -rf ~/Applications/SpeedMonitor.app
rm -rf /Applications/SpeedMonitor.app

# Optional: Remove speedtest-cli
brew uninstall speedtest-cli
```

Or create an uninstaller script:

```bash
# Build uninstaller
pkgbuild --nopayload \
         --scripts uninstall-scripts/ \
         --identifier com.speedmonitor.uninstall \
         SpeedMonitor-Uninstall-3.1.0.pkg
```

---

## Support

**Installation Logs:**
- `/var/log/speedmonitor-install.log`

**Runtime Logs:**
- `~/.local/share/nkspeedtest/speed_monitor.log`
- `~/.local/share/nkspeedtest/launchd_stdout.log`
- `~/.local/share/nkspeedtest/launchd_stderr.log`

**Local Data:**
- `~/.local/share/nkspeedtest/speed_log.csv`

**Configuration:**
- `~/.config/nkspeedtest/device_id`
- `~/.config/nkspeedtest/user_email`

**Server Dashboard:**
- https://YOUR-RAILWAY-URL.up.railway.app/

---

## FAQ

**Q: Can users install without admin password?**
A: No. The package installs to `/usr/local/` which requires admin access. This is intentional for security.

**Q: Will it overwrite existing Homebrew installation?**
A: No. If Homebrew is already installed, it will be used as-is.

**Q: What if speedtest-cli is already installed?**
A: The installer checks and skips installation if already present.

**Q: Can I deploy to multiple Macs at once?**
A: Yes! Use Jamf, Intune, or Apple Remote Desktop for mass deployment.

**Q: Does it work offline?**
A: Partially. WiFi metrics will be collected locally, but speed tests and server uploads require internet.

**Q: How do I update to a new version?**
A: Build a new .pkg with updated version number and deploy. The postinstall script will update existing installations.

**Q: Can I customize the server URL per-user?**
A: Yes. Edit `/usr/local/speedmonitor/lib/config.sh` after installation, or modify the LaunchAgent plist.

**Q: Does it support VPN detection?**
A: Yes! Detects Zscaler, Cisco AnyConnect, GlobalProtect, FortiClient, OpenVPN, Tunnelblick, and WireGuard.

---

## Building for Production

### Checklist:

- [ ] Run `./configure-pkg.sh` with your Railway URL
- [ ] Verify `pkg-config.env` has correct settings
- [ ] Build: `./build-pkg.sh`
- [ ] Test on clean Mac: `sudo installer -pkg SpeedMonitor-3.1.0.pkg -target /`
- [ ] Verify LaunchAgent loaded: `launchctl list | grep speedmonitor`
- [ ] Check dashboard shows test data
- [ ] Sign package (optional, for enterprise)
- [ ] Notarize with Apple (optional, bypasses Gatekeeper)
- [ ] Upload to Jamf/Intune OR distribute via email

### Test Matrix:

Test on:
- [ ] macOS 11 (Big Sur) - Intel
- [ ] macOS 12 (Monterey) - Apple Silicon
- [ ] macOS 13 (Ventura)
- [ ] macOS 14 (Sonoma)
- [ ] macOS 15 (Sequoia)

Verify:
- [ ] Homebrew installs correctly
- [ ] speedtest-cli works
- [ ] Swift helper compiles
- [ ] LaunchAgent runs every 10 minutes
- [ ] Data appears in dashboard
- [ ] Menu bar app shows stats
- [ ] Location Services can be granted

---

## Version History

### v3.1.0 (Current)
- Native SpeedMonitor.app menu bar application
- Location Services UI for WiFi SSID
- Self-contained .pkg installer

### v3.0.0
- Unified versioning
- Self-update mechanism
- macOS Sequoia WiFi support

### v2.1.0
- User email support
- Advanced WiFi metrics (MCS, error rates)
- BSSID roaming detection

---

## License

Speed Monitor is open-source software. Check the main repository for license details.

## Credits

- Built for enterprise macOS deployment
- Uses Homebrew, speedtest-cli (Ookla), CoreWLAN framework
- Server powered by Node.js + Railway

---

**Need Help?**

Check installation logs: `/var/log/speedmonitor-install.log`

View this guide online: [GitHub Repository URL]

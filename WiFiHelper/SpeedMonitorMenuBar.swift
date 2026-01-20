import SwiftUI
import CoreWLAN
import CoreLocation
import AppKit
import ServiceManagement

// MARK: - Auto Launch Manager
class AutoLaunchManager {
    static let shared = AutoLaunchManager()

    var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                // For older macOS, check UserDefaults
                return UserDefaults.standard.bool(forKey: "AutoLaunchEnabled")
            }
        }
    }

    func enable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to enable auto-launch: \(error)")
                // Fallback to AppleScript method
                enableViaAppleScript()
            }
        } else {
            enableViaAppleScript()
        }
    }

    func disable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                print("Failed to disable auto-launch: \(error)")
                disableViaAppleScript()
            }
        } else {
            disableViaAppleScript()
        }
    }

    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    private func enableViaAppleScript() {
        let script = """
        tell application "System Events"
            make login item at end with properties {path:"/Applications/SpeedMonitor.app", hidden:false}
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        UserDefaults.standard.set(true, forKey: "AutoLaunchEnabled")
    }

    private func disableViaAppleScript() {
        let script = """
        tell application "System Events"
            delete login item "SpeedMonitor"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        UserDefaults.standard.set(false, forKey: "AutoLaunchEnabled")
    }

    // Auto-enable on first launch
    func setupAutoLaunchIfNeeded() {
        let hasSetupAutoLaunch = UserDefaults.standard.bool(forKey: "HasSetupAutoLaunch")
        if !hasSetupAutoLaunch {
            enable()
            UserDefaults.standard.set(true, forKey: "HasSetupAutoLaunch")
        }
    }
}

// MARK: - Location Manager
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var permissionRequested = false
    @Published var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced  // We only need WiFi, not precise location
        authorizationStatus = manager.authorizationStatus

        // If already authorized, start monitoring to keep permission active
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func requestPermission() {
        permissionRequested = true
        lastError = nil

        // On macOS, we need to start location updates to trigger the permission dialog
        // This is because menu bar apps (LSUIElement) may not show the dialog otherwise
        manager.startUpdatingLocation()

        // Request authorization - on macOS, requestAlwaysAuthorization is more reliable
        // for background/menu bar apps
        if #available(macOS 10.15, *) {
            manager.requestAlwaysAuthorization()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus

            // Start updates if authorized (keeps permission active)
            if self.isAuthorized {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
            }
        }
    }

    // We don't actually need location data, but implementing this keeps the permission active
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We only need CoreLocation for WiFi SSID access, not actual location
        // Stop updates after first success to save battery
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorized
    }
}

// MARK: - WiFi Manager
class WiFiManager: ObservableObject {
    @Published var ssid: String = "Unknown"
    @Published var rssi: Int = 0
    @Published var channel: Int = 0
    @Published var band: String = ""
    @Published var bssid: String = ""
    @Published var apName: String = ""
    @Published var txRate: Double = 0
    @Published var noise: Int = 0
    @Published var isConnected: Bool = false

    // AP name mapping based on BSSID prefix (first 5 bytes) to handle multiple virtual APs
    private let apPrefixMap: [String: String] = [
        "a8:ba:25:ce:a4:d": "2F-AP_1", "a8:ba:25:6a:4d": "2F-AP_1",   // 2F-AP_1
        "a8:ba:25:ce:a1:a": "2F-AP_2", "a8:ba:25:6a:1a": "2F-AP_2",   // 2F-AP_2
        "a8:ba:25:ce:a1:2": "2F-AP_3", "a8:ba:25:6a:12": "2F-AP_3",   // 2F-AP_3
        "a8:ba:25:ce:a2:3": "2F-AP_4", "a8:ba:25:6a:23": "2F-AP_4",   // 2F-AP_4
        "a8:ba:25:ce:a3:e": "2F-AP_5", "a8:ba:25:6a:3e": "2F-AP_5",   // 2F-AP_5
        "a8:ba:25:ce:a1:c": "3F-AP_5", "a8:ba:25:6a:1c": "3F-AP_5",   // 3F-AP_5
        "a8:ba:25:ce:9f:5": "3F-AP-1", "a8:ba:25:69:f5": "3F-AP-1",   // 3F-AP-1
        "a8:ba:25:ce:9f:0": "3F-AP-2", "a8:ba:25:69:f0": "3F-AP-2",   // 3F-AP-2
        "a8:ba:25:ce:a4:6": "3F-AP-3", "a8:ba:25:6a:46": "3F-AP-3",   // 3F-AP-3
        "a8:ba:25:ce:a4:e": "3F-AP-4", "a8:ba:25:6a:4e": "3F-AP-4"    // 3F-AP-4
    ]

    // Lookup AP name by BSSID prefix (first 5 bytes)
    func lookupAPName(_ bssid: String) -> String {
        let lowerBssid = bssid.lowercased()
        // Try prefix match (first 14 chars = "aa:bb:cc:dd:ee")
        let prefix = String(lowerBssid.prefix(14))
        if let name = apPrefixMap[prefix] {
            return name
        }
        // Try shorter prefix (first 13 chars for single hex digit in 5th byte)
        let shortPrefix = String(lowerBssid.prefix(13))
        for (key, name) in apPrefixMap {
            if key.hasPrefix(shortPrefix) || shortPrefix.hasPrefix(key) {
                return name
            }
        }
        return ""
    }

    func refresh() {
        let client = CWWiFiClient.shared()
        guard let interface = client.interface() else {
            isConnected = false
            return
        }

        isConnected = interface.ssid() != nil
        ssid = interface.ssid() ?? "Not Connected"
        bssid = interface.bssid() ?? "N/A"
        apName = lookupAPName(bssid)
        rssi = interface.rssiValue()
        noise = interface.noiseMeasurement()
        txRate = interface.transmitRate()

        if let wlanChannel = interface.wlanChannel() {
            channel = wlanChannel.channelNumber
            switch wlanChannel.channelBand {
            case .band2GHz: band = "2.4GHz"
            case .band5GHz: band = "5GHz"
            case .band6GHz: band = "6GHz"
            case .bandUnknown: band = "Unknown"
            @unknown default: band = ""
            }
        }
    }

    var signalBars: String {
        if rssi >= -50 { return "▂▄▆█" }
        if rssi >= -60 { return "▂▄▆░" }
        if rssi >= -70 { return "▂▄░░" }
        if rssi >= -80 { return "▂░░░" }
        return "░░░░"
    }

    var signalQuality: String {
        if rssi >= -50 { return "Excellent" }
        if rssi >= -60 { return "Good" }
        if rssi >= -70 { return "Fair" }
        return "Poor"
    }

    func outputForScript() -> String {
        refresh()
        let snr = rssi - noise
        return """
        INTERFACE=en0
        POWER=on
        CONNECTED=\(isConnected)
        SSID=\(ssid)
        BSSID=\(bssid)
        RSSI_DBM=\(rssi)
        NOISE_DBM=\(noise)
        SNR_DB=\(snr)
        CHANNEL=\(channel)
        BAND=\(band)
        WIDTH_MHZ=0
        TX_RATE_MBPS=\(txRate)
        MCS_INDEX=-1
        """
    }
}

// MARK: - Settings Manager
class SettingsManager {
    static let shared = SettingsManager()
    private let configPath = NSHomeDirectory() + "/.config/nkspeedtest/settings.json"

    var testIntervalSeconds: Int {
        get { loadSettings()["testIntervalSeconds"] as? Int ?? 600 }
        set { saveSettings(["testIntervalSeconds": newValue]) }
    }

    private func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func saveSettings(_ settings: [String: Any]) {
        var current = loadSettings()
        for (key, value) in settings {
            current[key] = value
        }
        if let data = try? JSONSerialization.data(withJSONObject: current, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }
}

// MARK: - Speed Data Manager
class SpeedDataManager: ObservableObject {
    @Published var lastDownload: Double = 0
    @Published var lastUpload: Double = 0
    @Published var lastLatency: Double = 0
    @Published var lastJitter: Double = 0
    @Published var lastTest: Date?
    @Published var vpnStatus: String = ""
    @Published var lastError: String = ""
    @Published var lastStatus: String = ""
    @Published var updateAvailable: Bool = false
    @Published var updateStatus: String = ""
    @Published var isRunningTest: Bool = false
    @Published var isUpdating: Bool = false
    @Published var isSubmittingDiagnostics: Bool = false
    @Published var diagnosticsResult: String = ""
    @Published var testCountdown: Int = 0

    // Installation status
    @Published var hasHomebrew: Bool = true
    @Published var hasSpeedtest: Bool = true
    @Published var hasScript: Bool = true
    @Published var hasLaunchd: Bool = true
    @Published var isRepairing: Bool = false
    @Published var repairStatus: String = ""

    var needsRepair: Bool {
        !hasHomebrew || !hasSpeedtest || !hasScript || !hasLaunchd
    }
    @Published var testIntervalSeconds: Int = 600 {
        didSet {
            SettingsManager.shared.testIntervalSeconds = testIntervalSeconds
            restartAutoTestTimer()
        }
    }

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var autoTestTimer: Timer?

    init() {
        // Load saved settings
        testIntervalSeconds = SettingsManager.shared.testIntervalSeconds

        refresh()

        // Check installation status on startup
        checkInstallation()

        // Refresh display every 30 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Start auto-test timer based on settings
        restartAutoTestTimer()

        // Auto-run speed test if no data exists (first launch)
        if lastDownload == 0 && lastTest == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                // Auto-repair if needed, then run speed test
                if self?.needsRepair == true {
                    self?.repairInstallation()
                } else {
                    self?.runSpeedTest()
                }
            }
        }
    }

    func restartAutoTestTimer() {
        autoTestTimer?.invalidate()

        // Only start auto-test timer if interval is less than 10 minutes (600 sec)
        // For 10+ min intervals, rely on launchd background service which always runs
        guard testIntervalSeconds < 600 else { return }

        autoTestTimer = Timer.scheduledTimer(withTimeInterval: Double(testIntervalSeconds), repeats: true) { [weak self] _ in
            self?.runSpeedTest()
        }
    }

    func runSpeedTest() {
        guard !isRunningTest else { return }
        isRunningTest = true
        testCountdown = 30  // Start countdown at 30 seconds

        // Start countdown timer on main thread
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.testCountdown > 0 {
                self.testCountdown -= 1
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scriptPath = NSHomeDirectory() + "/.local/bin/speed_monitor.sh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "SPEED_MONITOR_SERVER": "https://home-internet-production.up.railway.app"
            ]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("Failed to run speed test: \(error)")
            }

            DispatchQueue.main.async {
                self?.countdownTimer?.invalidate()
                self?.countdownTimer = nil
                self?.testCountdown = 0
                self?.isRunningTest = false
                self?.refresh()
            }
        }
    }

    func updateApp() {
        guard !isUpdating else { return }

        isUpdating = true
        updateStatus = "Checking..."

        // Always do a fresh version check first
        checkForUpdateAndProceed { [weak self] hasUpdate in
            guard let self = self else { return }

            if !hasUpdate {
                DispatchQueue.main.async {
                    self.updateStatus = "✓ Already up to date"
                    self.isUpdating = false
                    // Clear status after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.updateStatus = ""
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.updateStatus = "Downloading..."
            }
            self.performUpdate()
        }
    }

    // Version check with completion handler for immediate feedback
    private func checkForUpdateAndProceed(completion: @escaping (Bool) -> Void) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let versionURL = URL(string: "https://raw.githubusercontent.com/hyperkishore/home-internet/main/VERSION?t=\(timestamp)")!

        var request = URLRequest(url: versionURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data,
                  let versionString = String(data: data, encoding: .utf8) else {
                completion(self?.updateAvailable ?? false) // Fall back to cached value
                return
            }

            let remoteVersion = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
            let localVersion = SpeedDataManager.appVersion
            let hasUpdate = Self.isNewerVersion(remoteVersion, than: localVersion)

            DispatchQueue.main.async {
                self?.updateAvailable = hasUpdate
            }
            completion(hasUpdate)
        }.resume()
    }

    private func performUpdate() {
        updateStatus = "Downloading..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let logFile = NSHomeDirectory() + "/.local/share/nkspeedtest/update.log"
            func log(_ msg: String) {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let logMsg = "[\(timestamp)] \(msg)\n"
                if let data = logMsg.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: logFile) {
                        if let handle = FileHandle(forWritingAtPath: logFile) {
                            handle.seekToEndOfFile()
                            handle.write(data)
                            handle.closeFile()
                        }
                    } else {
                        try? data.write(to: URL(fileURLWithPath: logFile))
                    }
                }
                print(msg)
            }

            log("=== Update started (from GitHub, bypassing Railway) ===")

            // Step 1: Download the update directly from GitHub
            log("Step 1: Downloading from GitHub...")
            let downloadScript = """
            curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/SpeedMonitor.app.zip" -o /tmp/SpeedMonitor.app.zip 2>&1 && \
            rm -rf /tmp/SpeedMonitor.app && \
            unzip -o /tmp/SpeedMonitor.app.zip -d /tmp/ 2>&1 && \
            test -d "/tmp/SpeedMonitor.app" && test -f "/tmp/SpeedMonitor.app/Contents/MacOS/SpeedMonitor"
            """

            let downloadProcess = Process()
            let downloadPipe = Pipe()
            downloadProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            downloadProcess.arguments = ["-c", downloadScript]
            downloadProcess.standardOutput = downloadPipe
            downloadProcess.standardError = downloadPipe

            do {
                try downloadProcess.run()
                downloadProcess.waitUntilExit()

                let downloadOutput = String(data: downloadPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log("Download output: \(downloadOutput)")
                log("Download exit code: \(downloadProcess.terminationStatus)")

                if downloadProcess.terminationStatus != 0 {
                    log("Download failed!")
                    DispatchQueue.main.async {
                        self?.isUpdating = false
                        self?.updateStatus = "✗ Download failed"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            self?.updateStatus = ""
                        }
                    }
                    return
                }

                log("Download successful, proceeding to install...")
                DispatchQueue.main.async {
                    self?.updateStatus = "Installing..."
                }

                // Step 2: Install with admin privileges (triggers Touch ID / password prompt)
                let installScript = "rm -rf /Applications/SpeedMonitor.app && cp -r /tmp/SpeedMonitor.app /Applications/ && chown -R root:wheel /Applications/SpeedMonitor.app && rm -f /tmp/SpeedMonitor.app.zip && rm -rf /tmp/SpeedMonitor.app"

                log("Step 2: Running install with admin privileges...")
                log("Install script: \(installScript)")

                // Use osascript with administrator privileges - this shows Touch ID / password dialog
                let scriptProcess = Process()
                let scriptPipe = Pipe()
                scriptProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                scriptProcess.arguments = ["-e", "do shell script \"\(installScript)\" with administrator privileges"]
                scriptProcess.standardOutput = scriptPipe
                scriptProcess.standardError = scriptPipe

                try scriptProcess.run()
                scriptProcess.waitUntilExit()

                let scriptOutput = String(data: scriptPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log("Install output: \(scriptOutput)")
                log("Install exit code: \(scriptProcess.terminationStatus)")

                if scriptProcess.terminationStatus == 0 {
                    log("Install successful! Launching new app...")
                    // Success - launch new app and quit this instance
                    DispatchQueue.main.async {
                        self?.updateStatus = "✓ Updated! Restarting..."
                        // Launch the new app after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let task = Process()
                            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                            task.arguments = ["/Applications/SpeedMonitor.app"]
                            try? task.run()

                            // Quit this instance after launching new one
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                NSApplication.shared.terminate(nil)
                            }
                        }
                    }
                } else {
                    log("Install failed or cancelled by user")
                    // User cancelled or error
                    DispatchQueue.main.async {
                        self?.isUpdating = false
                        self?.updateStatus = "✗ Cancelled"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            self?.updateStatus = ""
                        }
                    }
                }
            } catch let error {
                log("Exception: \(error)")
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.updateStatus = "✗ Update failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self?.updateStatus = ""
                    }
                }
            }
        }
    }

    func refresh() {
        // Read from speed log CSV
        let logPath = NSHomeDirectory() + "/.local/share/nkspeedtest/speed_log.csv"

        guard FileManager.default.fileExists(atPath: logPath),
              let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return }  // Need header + at least one data row

        // Parse header to build column index map (prevents hardcoded index bugs)
        let headerLine = lines[0]
        let headers = headerLine.components(separatedBy: ",")
        var columnIndex: [String: Int] = [:]
        for (index, header) in headers.enumerated() {
            columnIndex[header] = index
        }

        // Get last data line (skip if it's the header)
        guard let lastLine = lines.last, !lastLine.starts(with: "timestamp") else { return }
        let cols = lastLine.components(separatedBy: ",")

        // Helper to safely get column value by name
        func getValue(_ columnName: String) -> String? {
            guard let index = columnIndex[columnName], index < cols.count else { return nil }
            return cols[index]
        }

        // Parse values using column names (schema-independent)
        if let val = getValue("latency_ms"), let latency = Double(val) { lastLatency = latency }
        if let val = getValue("jitter_ms"), let jitter = Double(val) { lastJitter = jitter }
        if let val = getValue("download_mbps"), let download = Double(val) { lastDownload = download }
        if let val = getValue("upload_mbps"), let upload = Double(val) { lastUpload = upload }
        if let val = getValue("vpn_status") { vpnStatus = val }
        if let val = getValue("errors") { lastError = val }

        // Determine status based on download speed and errors
        if lastDownload > 0 {
            lastStatus = "success"
        } else if lastError.contains("vpn_blocking") {
            lastStatus = "vpn_blocked"
        } else if lastError.contains("timeout") {
            lastStatus = "timeout"
        } else if !lastError.isEmpty {
            lastStatus = "failed"
        }

        // Parse timestamp (try with and without fractional seconds)
        if let timestampStr = getValue("timestamp_utc") ?? getValue("timestamp") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: timestampStr) {
                lastTest = date
            } else {
                // Fallback: try with fractional seconds
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: timestampStr) {
                    lastTest = date
                }
            }
        }

        // Check for updates
        checkForUpdate()
    }

    static let appVersion = "3.1.26"

    func checkForUpdate() {
        // Check version directly from GitHub (not Railway) to avoid deployment delays
        // Add timestamp to bypass GitHub CDN cache
        let timestamp = Int(Date().timeIntervalSince1970)
        let versionURL = URL(string: "https://raw.githubusercontent.com/hyperkishore/home-internet/main/VERSION?t=\(timestamp)")!

        var request = URLRequest(url: versionURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let versionString = String(data: data, encoding: .utf8) else { return }

            // VERSION file contains just the version number (e.g., "3.1.21\n")
            let remoteVersion = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
            let localVersion = SpeedDataManager.appVersion
            DispatchQueue.main.async {
                self?.updateAvailable = Self.isNewerVersion(remoteVersion, than: localVersion)
            }
        }.resume()
    }

    /// Compare semantic versions numerically (e.g., "3.1.04" > "3.1.2")
    static func isNewerVersion(_ v1: String, than v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false  // Equal versions
    }

    // Submit diagnostic logs to server for remote troubleshooting
    func submitDiagnostics() {
        guard !isSubmittingDiagnostics else { return }
        isSubmittingDiagnostics = true
        diagnosticsResult = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Collect diagnostic information via shell commands
            // Use Python for JSON encoding (available on all Macs, unlike jq)
            let appVersion = SpeedDataManager.appVersion
            let script = """
            export DEVICE_ID=$(cat ~/.config/nkspeedtest/device_id 2>/dev/null || echo "unknown")
            export USER_EMAIL=$(cat ~/.config/nkspeedtest/user_email 2>/dev/null || echo "")
            export HOSTNAME_VAL=$(hostname)
            export OS_VERSION=$(sw_vers -productVersion)
            export APP_VERSION="\(appVersion)"
            export SCRIPT_VERSION=$(grep "APP_VERSION=" ~/.local/bin/speed_monitor.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "unknown")
            export LAUNCHD_STATUS=$(launchctl list 2>/dev/null | grep speedmonitor | head -1 || echo "not loaded")
            export SPEEDTEST_PATH=$(which speedtest-cli 2>/dev/null || echo "not found")
            if [[ -x "$SPEEDTEST_PATH" ]]; then export SPEEDTEST_INSTALLED="True"; else export SPEEDTEST_INSTALLED="False"; fi
            export ERROR_LOG=$(tail -10 ~/.local/share/nkspeedtest/launchd_stderr.log 2>/dev/null | tr "\\n" "|" || echo "no logs")
            export LAST_TEST=$(tail -1 ~/.local/share/nkspeedtest/speed_log.csv 2>/dev/null | cut -d"," -f1-20 || echo "no data")
            export NETWORK_INFO=$(ifconfig en0 2>/dev/null | grep "inet " | head -1 || echo "")

            /usr/bin/python3 -c "import json, os; data = {'device_id': os.environ.get('DEVICE_ID', 'unknown'), 'user_email': os.environ.get('USER_EMAIL', ''), 'hostname': os.environ.get('HOSTNAME_VAL', ''), 'os_version': os.environ.get('OS_VERSION', ''), 'app_version': os.environ.get('APP_VERSION', ''), 'script_version': os.environ.get('SCRIPT_VERSION', ''), 'launchd_status': os.environ.get('LAUNCHD_STATUS', ''), 'speedtest_installed': os.environ.get('SPEEDTEST_INSTALLED', 'False') == 'True', 'speedtest_path': os.environ.get('SPEEDTEST_PATH', ''), 'error_log': os.environ.get('ERROR_LOG', ''), 'last_test_result': os.environ.get('LAST_TEST', ''), 'network_interfaces': os.environ.get('NETWORK_INFO', '')}; print(json.dumps(data))"
            """

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            process.standardOutput = pipe
            process.standardError = pipe

            var jsonOutput = ""
            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                jsonOutput = String(data: data, encoding: .utf8) ?? "{}"
            } catch {
                print("Failed to collect diagnostics: \\(error)")
                DispatchQueue.main.async {
                    self?.isSubmittingDiagnostics = false
                    self?.diagnosticsResult = "❌ Failed to collect"
                }
                return
            }

            // POST to server
            guard let url = URL(string: "https://home-internet-production.up.railway.app/api/diagnostics"),
                  let jsonData = jsonOutput.data(using: .utf8) else {
                DispatchQueue.main.async {
                    self?.isSubmittingDiagnostics = false
                    self?.diagnosticsResult = "❌ Invalid data"
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    self?.isSubmittingDiagnostics = false

                    if let error = error {
                        self?.diagnosticsResult = "❌ \\(error.localizedDescription)"
                        return
                    }

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        self?.diagnosticsResult = "✅ Sent to IT"
                    } else {
                        self?.diagnosticsResult = "❌ Server error"
                    }

                    // Clear result after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self?.diagnosticsResult = ""
                    }
                }
            }.resume()
        }
    }

    // Check if all required components are installed
    func checkInstallation() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let brewPath = Self.runCommand("/usr/bin/which brew")
            // Check for speedtest-cli in common locations including package install path
            let speedtestPath = Self.runCommand("/bin/bash -c 'export PATH=$HOME/.local/bin:/usr/local/speedmonitor/bin:/opt/homebrew/bin:/usr/local/bin:$PATH && which speedtest-cli'")
            // Check both symlink location and package install location
            let scriptExistsSymlink = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.local/bin/speed_monitor.sh")
            let scriptExistsPackage = FileManager.default.fileExists(atPath: "/usr/local/speedmonitor/bin/speed_monitor.sh")
            let launchdStatus = Self.runCommand("/bin/launchctl list | /usr/bin/grep speedmonitor")

            DispatchQueue.main.async {
                self?.hasHomebrew = !brewPath.isEmpty && !brewPath.contains("not found")
                self?.hasSpeedtest = !speedtestPath.isEmpty && !speedtestPath.contains("not found")
                self?.hasScript = scriptExistsSymlink || scriptExistsPackage
                self?.hasLaunchd = !launchdStatus.isEmpty
            }
        }
    }

    // Repair installation by opening Terminal with repair script
    func repairInstallation() {
        guard !isRepairing else { return }
        isRepairing = true
        repairStatus = "Opening Terminal..."

        // Create a repair script that shows progress in Terminal
        let repairScript = """
#!/bin/bash
# Speed Monitor Repair Script
# This script will fix any missing components

set -e
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

echo "========================================"
echo "  Speed Monitor - Installation Repair"
echo "========================================"
echo ""

# Step 1: Check Homebrew
echo "Step 1/4: Checking Homebrew..."
if ! command -v brew &> /dev/null; then
    echo "  ❌ Homebrew not found"
    echo "  Installing Homebrew (this may take a few minutes)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "  ✅ Homebrew installed"
else
    echo "  ✅ Homebrew found: $(which brew)"
fi
echo ""

# Step 2: Check speedtest-cli
echo "Step 2/4: Checking speedtest-cli..."
if ! command -v speedtest-cli &> /dev/null; then
    echo "  ❌ speedtest-cli not found"
    echo "  Installing via Homebrew..."
    brew install speedtest-cli
    echo "  ✅ speedtest-cli installed"
else
    echo "  ✅ speedtest-cli found: $(which speedtest-cli)"
fi
echo ""

# Step 3: Install/update speed_monitor.sh
echo "Step 3/4: Updating speed_monitor.sh..."
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/speed_monitor.sh 'https://raw.githubusercontent.com/hyperkishore/home-internet/main/speed_monitor.sh'
chmod +x ~/.local/bin/speed_monitor.sh
echo "  ✅ Script updated: ~/.local/bin/speed_monitor.sh"
echo "  Version: $(~/.local/bin/speed_monitor.sh --version 2>/dev/null || echo 'unknown')"
echo ""

# Step 4: Setup launchd service
echo "Step 4/4: Setting up background service..."
mkdir -p ~/Library/LaunchAgents
mkdir -p ~/.config/nkspeedtest
mkdir -p ~/.local/share/nkspeedtest

# Generate device ID if needed
if [ ! -f ~/.config/nkspeedtest/device_id ]; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 16 > ~/.config/nkspeedtest/device_id
    echo "  Generated device ID: $(cat ~/.config/nkspeedtest/device_id)"
fi

# Download and install plist
curl -fsSL -o ~/Library/LaunchAgents/com.speedmonitor.plist 'https://raw.githubusercontent.com/hyperkishore/home-internet/main/com.speedmonitor.plist'

# Load launchd job
launchctl unload ~/Library/LaunchAgents/com.speedmonitor.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.speedmonitor.plist
echo "  ✅ Background service started"
echo ""

# Verify
echo "========================================"
echo "  Verification"
echo "========================================"
echo "Homebrew:     $(command -v brew &> /dev/null && echo '✅ OK' || echo '❌ Missing')"
echo "speedtest-cli: $(command -v speedtest-cli &> /dev/null && echo '✅ OK' || echo '❌ Missing')"
echo "Script:       $([ -f ~/.local/bin/speed_monitor.sh ] && echo '✅ OK' || echo '❌ Missing')"
echo "Service:      $(launchctl list | grep -q 'com.speedmonitor$' && echo '✅ Running' || echo '❌ Not running')"
echo ""
echo "========================================"
echo "  ✅ Repair Complete!"
echo "========================================"
echo ""
echo "You can close this window."
echo "Click the menu bar icon and press Refresh to update the status."
"""

        // Write script to temp file
        let scriptPath = "/tmp/speedmonitor_repair.sh"
        do {
            try repairScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            // Make executable
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["+x", scriptPath]
            try chmodProcess.run()
            chmodProcess.waitUntilExit()

            // Open Terminal and run the script
            let appleScript = """
            tell application "Terminal"
                activate
                do script "/tmp/speedmonitor_repair.sh"
            end tell
            """

            if let script = NSAppleScript(source: appleScript) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                if let error = error {
                    print("AppleScript error: \\(error)")
                }
            }

            DispatchQueue.main.async {
                self.isRepairing = false
                self.repairStatus = "Check Terminal window"

                // Re-check installation after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    self.checkInstallation()
                    self.repairStatus = ""
                }
            }
        } catch {
            print("Failed to create repair script: \\(error)")
            DispatchQueue.main.async {
                self.isRepairing = false
                self.repairStatus = "❌ Failed to start repair"
            }
        }
    }

    // Helper to run shell commands and return output
    private static func runCommand(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    var timeSinceTest: String {
        guard let date = lastTest else { return "Never" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    var statusEmoji: String {
        if lastDownload >= 100 { return "🟢" }
        if lastDownload >= 50 { return "🟡" }
        if lastDownload >= 25 { return "🟠" }
        return "🔴"
    }
}

// MARK: - Settings Window
struct SettingsView: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var wifiManager: WiFiManager
    @ObservedObject var speedData: SpeedDataManager
    @Environment(\.dismiss) var dismiss

    let intervalOptions: [(String, Int)] = [
        ("30 seconds (Testing)", 30),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("10 minutes (Default)", 600),
        ("30 minutes", 1800)
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("Speed Monitor Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Test Interval Section
            GroupBox("Speed Test Interval") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Run tests every:", selection: $speedData.testIntervalSeconds) {
                        ForEach(intervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if speedData.testIntervalSeconds < 600 {
                        Text("⚡ Fast mode: Tests run automatically at this interval")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("💤 Normal mode: Tests run via background service")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            // Auto-Launch Section
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { AutoLaunchManager.shared.isEnabled },
                        set: { _ in AutoLaunchManager.shared.toggle() }
                    )) {
                        Text("Launch at Login")
                    }
                    Text("Automatically start Speed Monitor when you log in")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }

            // Location Permission Section
            GroupBox("WiFi Detection") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: locationManager.isAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(locationManager.isAuthorized ? .green : .red)
                        Text("Location Services: \(locationManager.isAuthorized ? "Enabled" : "Disabled")")
                    }

                    if !locationManager.isAuthorized {
                        Text("Location Services is required to detect your WiFi network name (SSID). macOS requires this permission for any app reading WiFi details.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let error = locationManager.lastError {
                            Text("Error: \(error)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        if locationManager.authorizationStatus == .notDetermined {
                            Button("Grant Permission") {
                                locationManager.requestPermission()
                            }
                            .buttonStyle(.borderedProminent)

                            Text("A system dialog should appear. If not, click 'Open System Settings' below.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted || locationManager.permissionRequested {
                            Button("Open System Settings") {
                                // Open Privacy & Security → Location Services directly
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                    NSWorkspace.shared.open(url)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Steps to enable:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("1. Enable 'Location Services' at the top")
                                    .font(.caption)
                                Text("2. Scroll down and find 'Speed Monitor'")
                                    .font(.caption)
                                Text("3. Toggle it ON")
                                    .font(.caption)
                                Text("4. Restart this app")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            Text("Current Network:")
                            Spacer()
                            Text(wifiManager.ssid)
                                .fontWeight(.medium)
                        }

                        Text("✓ WiFi SSID detection is working")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 8)
            }

            // About Section
            GroupBox("About") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Version:")
                        Spacer()
                        Text(SpeedDataManager.appVersion)
                    }
                    HStack {
                        Text("Dashboard:")
                        Spacer()
                        Link("Open Dashboard", destination: URL(string: "https://home-internet-production.up.railway.app/")!)
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer()

            Button("Close") {
                dismiss()
            }
        }
        .padding()
        .frame(width: 400, height: 550)
    }
}

// MARK: - Menu Bar Content
struct MenuBarView: View {
    @ObservedObject var speedData: SpeedDataManager
    @ObservedObject var wifiManager: WiFiManager
    @ObservedObject var locationManager: LocationManager
    @State private var showingSettings = false
    @State private var isPulsing = false
    @State private var isHoveringHeader = false
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with version + hover controls
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed Monitor")
                        .font(.headline)
                    Text("v\(SpeedDataManager.appVersion)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Hover-only close button
                if isHoveringHeader {
                    Button(action: { onClose?() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .padding(.vertical, 4)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringHeader = hovering
                }
            }

            // Update banner (prominent when available)
            if speedData.updateAvailable {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.white)
                    Text("Update Available!")
                        .fontWeight(.medium)
                    Spacer()
                    Text("Click below to install")
                        .font(.caption)
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(8)
                .background(Color.blue)
                .cornerRadius(6)
            }

            // Repair banner (when installation issues detected)
            if speedData.needsRepair || !speedData.repairStatus.isEmpty {
                Button(action: { speedData.repairInstallation() }) {
                    HStack {
                        Image(systemName: speedData.isRepairing ? "hourglass" : "wrench.and.screwdriver.fill")
                            .foregroundColor(.white)
                        if !speedData.repairStatus.isEmpty {
                            Text(speedData.repairStatus)
                                .fontWeight(.medium)
                        } else {
                            Text("Setup Required")
                                .fontWeight(.medium)
                            Spacer()
                            Text("Click to fix")
                                .font(.caption)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(speedData.repairStatus.contains("✅") ? Color.green : Color.orange)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(speedData.isRepairing)
            }

            // VPN blocking banner
            if speedData.lastStatus == "vpn_blocked" || (speedData.vpnStatus == "connected" && speedData.lastDownload == 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "building.2.fill")
                            .foregroundColor(.white)
                        Text("Corporate IT Policy Blocking")
                            .fontWeight(.medium)
                        Spacer()
                    }
                    Text("VPN is preventing speed tests from running.")
                        .font(.caption2)
                    Button(action: {
                        if let url = URL(string: "https://www.speedtest.net") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Text("→ Try speedtest.net in browser")
                            .font(.caption2)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(8)
                .background(Color.red.opacity(0.85))
                .cornerRadius(6)
            }

            Divider()

            // Speed Stats
            Group {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.green)
                    Text("Download:")
                    Spacer()
                    Text(String(format: "%.1f Mbps", speedData.lastDownload))
                        .fontWeight(.medium)
                }

                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.blue)
                    Text("Upload:")
                    Spacer()
                    Text(String(format: "%.1f Mbps", speedData.lastUpload))
                        .fontWeight(.medium)
                }

                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.orange)
                    Text("Latency:")
                    Spacer()
                    Text(String(format: "%.0f ms", speedData.lastLatency))
                }

                HStack {
                    Image(systemName: "waveform.path")
                        .foregroundColor(.purple)
                    Text("Jitter:")
                    Spacer()
                    Text(String(format: "%.1f ms", speedData.lastJitter))
                }
            }

            Divider()

            // WiFi Info
            Group {
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.cyan)
                    Text("Network:")
                    Spacer()
                    if locationManager.isAuthorized {
                        Text(wifiManager.ssid)
                    } else {
                        Button(action: {
                            // First try to request permission (shows dialog if not determined)
                            if locationManager.authorizationStatus == .notDetermined {
                                locationManager.requestPermission()
                            } else {
                                // Already denied - open System Settings
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }) {
                            Text("(Location required)")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .underline()
                        }
                        .buttonStyle(.plain)
                    }
                }

                if locationManager.isAuthorized && wifiManager.isConnected {
                    HStack {
                        Text("Access Point:")
                        Spacer()
                        if !wifiManager.apName.isEmpty {
                            Text(wifiManager.apName)
                                .fontWeight(.medium)
                        } else {
                            Text(wifiManager.bssid)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 24)

                    HStack {
                        Text("Signal:")
                        Spacer()
                        Text("\(wifiManager.signalBars) \(wifiManager.rssi) dBm")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.leading, 24)

                    HStack {
                        Text("Channel:")
                        Spacer()
                        Text("\(wifiManager.channel) (\(wifiManager.band))")
                    }
                    .padding(.leading, 24)
                }

                HStack {
                    Image(systemName: speedData.vpnStatus == "connected" ? "lock.shield.fill" : "lock.open.fill")
                        .foregroundColor(speedData.vpnStatus == "connected" ? .green : .gray)
                    Text("VPN:")
                    Spacer()
                    Text(speedData.vpnStatus.capitalized)
                }
            }

            Divider()

            // Footer
            HStack {
                Text("Last test: \(speedData.timeSinceTest)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Divider()

            // Actions
            Button(action: {
                // Always check for updates immediately
                speedData.checkForUpdate()

                if speedData.isRunningTest {
                    // If already running, just refresh display
                    speedData.refresh()
                    wifiManager.refresh()
                } else {
                    // Run speed test then refresh
                    speedData.runSpeedTest()
                    wifiManager.refresh()
                }
            }) {
                HStack {
                    Image(systemName: speedData.isRunningTest ? "hourglass" : "arrow.clockwise")
                    if speedData.isRunningTest {
                        Text("Running... (\(speedData.testCountdown)s)")
                    } else {
                        Text("Refresh")
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: {
                if let url = URL(string: "https://home-internet-production.up.railway.app/") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                    Text("Open Dashboard")
                }
            }
            .buttonStyle(.plain)

            Button(action: { showingSettings = true }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                }
            }
            .buttonStyle(.plain)

            Button(action: { speedData.submitDiagnostics() }) {
                HStack {
                    Image(systemName: speedData.isSubmittingDiagnostics ? "hourglass" : "stethoscope")
                        .foregroundColor(.orange)
                    if !speedData.diagnosticsResult.isEmpty {
                        Text(speedData.diagnosticsResult)
                    } else if speedData.isSubmittingDiagnostics {
                        Text("Sending...")
                    } else {
                        Text("Send Diagnostics to IT")
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(speedData.isSubmittingDiagnostics)

            Button(action: { speedData.updateApp() }) {
                HStack {
                    Image(systemName: speedData.isUpdating ? "hourglass" : "arrow.down.circle.fill")
                        .foregroundColor(speedData.updateAvailable ? .blue : (speedData.updateStatus.contains("✓") ? .green : .primary))
                    if !speedData.updateStatus.isEmpty {
                        Text(speedData.updateStatus)
                            .foregroundColor(speedData.updateStatus.contains("✓") ? .green : (speedData.updateStatus.contains("✗") ? .red : .primary))
                    } else {
                        Text(speedData.updateAvailable ? "Update Available!" : "Check for Updates")
                            .fontWeight(speedData.updateAvailable ? .semibold : .regular)
                    }
                }
                .opacity(speedData.updateAvailable && speedData.updateStatus.isEmpty ? (isPulsing ? 1.0 : 0.5) : 1.0)
                .animation(speedData.updateAvailable && speedData.updateStatus.isEmpty ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)
            }
            .buttonStyle(.plain)
            .disabled(speedData.isUpdating)
            .onAppear {
                if speedData.updateAvailable {
                    isPulsing = true
                }
            }
            .onChange(of: speedData.updateAvailable) { newValue in
                isPulsing = newValue
            }

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
        .sheet(isPresented: $showingSettings) {
            SettingsView(locationManager: locationManager, wifiManager: wifiManager, speedData: speedData)
        }
    }
}

// MARK: - App Delegate for Menu Bar
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var speedData = SpeedDataManager()
    var wifiManager = WiFiManager()
    var locationManager = LocationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup auto-launch on first run
        AutoLaunchManager.shared.setupAutoLaunchIfNeeded()

        // Initial WiFi refresh
        wifiManager.refresh()

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusButton(button)

            // Update button periodically
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.speedData.refresh()
                self?.wifiManager.refresh()
                if let button = self?.statusItem.button {
                    self?.updateStatusButton(button)
                }
            }
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.behavior = .transient

        let contentView = MenuBarView(
            speedData: speedData,
            wifiManager: wifiManager,
            locationManager: locationManager,
            onClose: { [weak self] in
                self?.popover.performClose(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    func updateStatusButton(_ button: NSStatusBarButton) {
        let emoji = speedData.statusEmoji
        let update = speedData.updateAvailable ? "↑" : ""
        let download = String(format: "%.0f", speedData.lastDownload)
        button.title = "\(emoji)\(update) \(download) Mbps"
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                speedData.refresh()
                wifiManager.refresh()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                // Make popover window key to receive clicks
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}

// MARK: - Main App
@main
struct SpeedMonitorMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Handle command-line arguments
        let args = CommandLine.arguments
        if args.contains("--output") || args.contains("-o") {
            let manager = WiFiManager()
            print(manager.outputForScript())
            exit(0)
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            Speed Monitor Menu Bar App

            Usage:
              SpeedMonitor.app          Run as menu bar app
              SpeedMonitor.app --output Output WiFi info for scripts
              SpeedMonitor.app --help   Show this help
            """)
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(
                locationManager: appDelegate.locationManager,
                wifiManager: appDelegate.wifiManager,
                speedData: appDelegate.speedData
            )
        }
    }
}

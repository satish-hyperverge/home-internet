import SwiftUI
import CoreWLAN
import CoreLocation
import AppKit

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
    @Published var txRate: Double = 0
    @Published var noise: Int = 0
    @Published var isConnected: Bool = false

    func refresh() {
        let client = CWWiFiClient.shared()
        guard let interface = client.interface() else {
            isConnected = false
            return
        }

        isConnected = interface.ssid() != nil
        ssid = interface.ssid() ?? "Not Connected"
        bssid = interface.bssid() ?? "N/A"
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
    @Published var updateAvailable: Bool = false
    @Published var isRunningTest: Bool = false
    @Published var isUpdating: Bool = false
    @Published var testCountdown: Int = 0
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

        // Refresh display every 30 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Start auto-test timer based on settings
        restartAutoTestTimer()

        // Auto-run speed test if no data exists (first launch)
        if lastDownload == 0 && lastTest == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runSpeedTest()
            }
        }
    }

    func restartAutoTestTimer() {
        autoTestTimer?.invalidate()

        // Only start auto-test timer if interval is less than 10 minutes (600 sec)
        // For 10+ min intervals, rely on launchd background service
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Download and prepare update - launch happens in background AFTER this app exits
            let script = """
            set -e

            # Download
            curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/SpeedMonitor.app.zip" -o /tmp/SpeedMonitor.app.zip

            # Extract
            rm -rf /tmp/SpeedMonitor.app
            unzip -o /tmp/SpeedMonitor.app.zip -d /tmp/

            # Verify download succeeded
            if [ ! -d "/tmp/SpeedMonitor.app" ] || [ ! -f "/tmp/SpeedMonitor.app/Contents/MacOS/SpeedMonitor" ]; then
                echo "ERROR: Download or extract failed"
                exit 1
            fi

            # Install: remove old, copy new
            rm -rf /Applications/SpeedMonitor.app
            cp -r /tmp/SpeedMonitor.app /Applications/

            # Remove quarantine and sign
            xattr -cr /Applications/SpeedMonitor.app 2>/dev/null || true
            codesign --force --deep --sign - /Applications/SpeedMonitor.app 2>/dev/null || true

            # Cleanup
            rm -f /tmp/SpeedMonitor.app.zip
            rm -rf /tmp/SpeedMonitor.app

            # Launch new app in background (nohup ensures it survives parent exit)
            nohup /Applications/SpeedMonitor.app/Contents/MacOS/SpeedMonitor &>/dev/null &

            # Small delay to let new app start
            sleep 2
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    // Exit this instance - new app is already running
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSApplication.shared.terminate(nil)
                    }
                } else {
                    // Update failed - reset state
                    DispatchQueue.main.async {
                        self?.isUpdating = false
                    }
                }
            } catch {
                print("Failed to update app: \(error)")
                DispatchQueue.main.async {
                    self?.isUpdating = false
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

    func checkForUpdate() {
        let versionURL = URL(string: "https://home-internet-production.up.railway.app/api/version")!
        URLSession.shared.dataTask(with: versionURL) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let serverVersion = json["version"] as? String else { return }

            // Read local version
            let localVersionPath = NSHomeDirectory() + "/.local/bin/speed_monitor.sh"
            guard let script = try? String(contentsOfFile: localVersionPath, encoding: .utf8) else { return }

            // Extract version from script
            let pattern = "APP_VERSION=\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
               let range = Range(match.range(at: 1), in: script) {
                let localVersion = String(script[range])
                DispatchQueue.main.async {
                    self?.updateAvailable = localVersion != serverVersion
                }
            }
        }.resume()
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
                        Text("3.0.0")
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

    let appVersion = "3.1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with version
            VStack(alignment: .leading, spacing: 2) {
                Text("Speed Monitor")
                    .font(.headline)
                Text("v\(appVersion)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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

            Button(action: { speedData.updateApp() }) {
                HStack {
                    Image(systemName: speedData.isUpdating ? "hourglass" : "arrow.down.circle.fill")
                        .foregroundColor(speedData.updateAvailable ? .blue : .primary)
                    Text(speedData.isUpdating ? "Updating..." : (speedData.updateAvailable ? "Update Available!" : "Update App"))
                        .fontWeight(speedData.updateAvailable ? .semibold : .regular)
                }
                .opacity(speedData.updateAvailable ? (isPulsing ? 1.0 : 0.5) : 1.0)
                .animation(speedData.updateAvailable ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isPulsing)
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

        let contentView = MenuBarView(speedData: speedData, wifiManager: wifiManager, locationManager: locationManager)
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    func updateStatusButton(_ button: NSStatusBarButton) {
        let emoji = speedData.statusEmoji
        let update = speedData.updateAvailable ? "🔄" : ""
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

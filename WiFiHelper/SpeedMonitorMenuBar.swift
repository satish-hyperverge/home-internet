import SwiftUI
import CoreWLAN
import CoreLocation
import AppKit

// MARK: - Location Manager
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var permissionRequested = false

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        permissionRequested = true
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
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

    private var refreshTimer: Timer?

    init() {
        refresh()
        // Refresh every 30 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Auto-run speed test if no data exists (first launch)
        if lastDownload == 0 && lastTest == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runSpeedTest()
            }
        }
    }

    func runSpeedTest() {
        guard !isRunningTest else { return }
        isRunningTest = true

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
                self?.isRunningTest = false
                self?.refresh()
            }
        }
    }

    func updateApp() {
        guard !isUpdating else { return }
        isUpdating = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Download and install latest SpeedMonitor.app
            let script = """
            curl -fsSL "https://raw.githubusercontent.com/hyperkishore/home-internet/main/dist/SpeedMonitor.app.zip" -o /tmp/SpeedMonitor.app.zip && \
            unzip -o /tmp/SpeedMonitor.app.zip -d /tmp/ && \
            rm -rf /Applications/SpeedMonitor.app && \
            cp -r /tmp/SpeedMonitor.app /Applications/ && \
            rm -f /tmp/SpeedMonitor.app.zip && \
            rm -rf /tmp/SpeedMonitor.app
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    // Relaunch the app
                    DispatchQueue.main.async {
                        let url = URL(fileURLWithPath: "/Applications/SpeedMonitor.app")
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        NSApplication.shared.terminate(nil)
                    }
                }
            } catch {
                print("Failed to update app: \(error)")
            }

            DispatchQueue.main.async {
                self?.isUpdating = false
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
        guard let lastLine = lines.last, !lastLine.starts(with: "timestamp") else { return }

        let cols = lastLine.components(separatedBy: ",")
        guard cols.count >= 27 else { return }

        // Parse CSV columns based on v2.1 schema
        // timestamp,device_id,os_version,app_version,timezone,interface,ssid,bssid,band,channel,width,rssi,noise,snr,tx_rate,mcs,streams,local_ip,public_ip,latency,jitter,jitter_p50,jitter_p95,packet_loss,download,upload,vpn_status,vpn_name,...
        if let latency = Double(cols[19]) { lastLatency = latency }
        if let jitter = Double(cols[20]) { lastJitter = jitter }
        if let download = Double(cols[24]) { lastDownload = download }
        if let upload = Double(cols[25]) { lastUpload = upload }
        vpnStatus = cols[26]

        // Parse timestamp (try with and without fractional seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: cols[0]) {
            lastTest = date
        } else {
            // Fallback: try with fractional seconds
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: cols[0]) {
                lastTest = date
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
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Speed Monitor Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Location Permission Section
            GroupBox("WiFi Detection") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: locationManager.isAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(locationManager.isAuthorized ? .green : .red)
                        Text("Location Services: \(locationManager.isAuthorized ? "Enabled" : "Disabled")")
                    }

                    if !locationManager.isAuthorized {
                        Text("Location Services is required to detect your WiFi network name (SSID).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if locationManager.authorizationStatus == .notDetermined {
                            Button("Grant Permission") {
                                locationManager.requestPermission()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Text("Enable for 'Speed Monitor' then restart app")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            Text("Current Network:")
                            Spacer()
                            Text(wifiManager.ssid)
                                .fontWeight(.medium)
                        }
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
        .frame(width: 400, height: 400)
    }
}

// MARK: - Menu Bar Content
struct MenuBarView: View {
    @ObservedObject var speedData: SpeedDataManager
    @ObservedObject var wifiManager: WiFiManager
    @ObservedObject var locationManager: LocationManager
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Speed Monitor")
                    .font(.headline)
                Spacer()
                if speedData.updateAvailable {
                    Text("🔄 Update")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
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
                    Text(locationManager.isAuthorized ? wifiManager.ssid : "⚠️ Enable Location")
                        .foregroundColor(locationManager.isAuthorized ? .primary : .orange)
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
            Button(action: { speedData.runSpeedTest() }) {
                HStack {
                    Image(systemName: speedData.isRunningTest ? "hourglass" : "bolt.fill")
                    Text(speedData.isRunningTest ? "Running Test..." : "Run Speed Test")
                }
            }
            .buttonStyle(.plain)
            .disabled(speedData.isRunningTest)

            Button(action: { speedData.refresh(); wifiManager.refresh() }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
            }
            .buttonStyle(.plain)

            if !locationManager.isAuthorized {
                Button(action: { showingSettings = true }) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Enable WiFi Detection...")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)
            }

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
                    Image(systemName: speedData.isUpdating ? "hourglass" : "arrow.down.circle")
                    Text(speedData.isUpdating ? "Updating..." : "Update App")
                }
            }
            .buttonStyle(.plain)
            .disabled(speedData.isUpdating)

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
            SettingsView(locationManager: locationManager, wifiManager: wifiManager)
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
                wifiManager: appDelegate.wifiManager
            )
        }
    }
}

const express = require('express');
const Database = require('better-sqlite3');
const cors = require('cors');
const path = require('path');
const rateLimit = require('express-rate-limit');

const app = express();
const PORT = process.env.PORT || 3000;

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // limit each IP to 100 requests per windowMs
  message: { error: 'Too many requests, please try again later.' }
});

// Middleware
app.use(cors());
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(__dirname, 'public')));
app.use('/api/', limiter);

// Initialize SQLite database with persistent storage
// Railway provides RAILWAY_VOLUME_MOUNT_PATH for persistent volumes
const dbPath = process.env.RAILWAY_VOLUME_MOUNT_PATH
  ? path.join(process.env.RAILWAY_VOLUME_MOUNT_PATH, 'speed_monitor.db')
  : (process.env.DB_PATH || './speed_monitor.db');
console.log(`Database path: ${dbPath}`);
const db = new Database(dbPath);

// Create tables with v2.1 schema (added WiFi debugging fields)
db.exec(`
  CREATE TABLE IF NOT EXISTS speed_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    -- Identity
    device_id TEXT NOT NULL,
    user_id TEXT,
    user_email TEXT,
    hostname TEXT,

    -- Metadata
    timestamp_utc DATETIME NOT NULL,
    os_version TEXT,
    app_version TEXT,
    timezone TEXT,

    -- Network interface
    interface TEXT,
    local_ip TEXT,
    public_ip TEXT,

    -- WiFi details
    ssid TEXT,
    bssid TEXT,
    band TEXT,
    channel INTEGER DEFAULT 0,
    width_mhz INTEGER DEFAULT 0,
    rssi_dbm INTEGER DEFAULT 0,
    noise_dbm INTEGER DEFAULT 0,
    snr_db INTEGER DEFAULT 0,
    tx_rate_mbps REAL DEFAULT 0,

    -- v2.1: Link quality metrics
    mcs_index INTEGER DEFAULT -1,
    spatial_streams INTEGER DEFAULT 0,

    -- Performance metrics
    latency_ms REAL DEFAULT 0,
    jitter_ms REAL DEFAULT 0,
    jitter_p50 REAL DEFAULT 0,
    jitter_p95 REAL DEFAULT 0,
    packet_loss_pct REAL DEFAULT 0,
    download_mbps REAL DEFAULT 0,
    upload_mbps REAL DEFAULT 0,

    -- VPN status
    vpn_status TEXT DEFAULT 'disconnected',
    vpn_name TEXT DEFAULT 'none',

    -- v2.1: Interface error metrics
    input_errors BIGINT DEFAULT 0,
    output_errors BIGINT DEFAULT 0,
    input_error_rate REAL DEFAULT 0,
    output_error_rate REAL DEFAULT 0,
    tcp_retransmits BIGINT DEFAULT 0,

    -- v2.1: BSSID tracking (roaming detection)
    bssid_changed INTEGER DEFAULT 0,
    roam_count INTEGER DEFAULT 0,

    -- Status and errors
    status TEXT DEFAULT 'success',
    errors TEXT,

    -- Raw data
    raw_payload TEXT,

    -- Timestamps
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  -- Indexes for common queries
  CREATE INDEX IF NOT EXISTS idx_device_id ON speed_results(device_id);
  CREATE INDEX IF NOT EXISTS idx_timestamp ON speed_results(timestamp_utc);
  CREATE INDEX IF NOT EXISTS idx_ssid ON speed_results(ssid);
  CREATE INDEX IF NOT EXISTS idx_bssid ON speed_results(bssid);
  CREATE INDEX IF NOT EXISTS idx_vpn_status ON speed_results(vpn_status);
  CREATE INDEX IF NOT EXISTS idx_status ON speed_results(status);

  -- Composite index for time-series queries
  CREATE INDEX IF NOT EXISTS idx_device_time ON speed_results(device_id, timestamp_utc);

  -- v3.0 Tables

  -- Alert configurations
  CREATE TABLE IF NOT EXISTS alert_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,                    -- 'slack', 'teams'
    webhook_url TEXT NOT NULL,
    channel_name TEXT,
    threshold_download_mbps REAL,
    threshold_jitter_ms REAL,
    threshold_packet_loss_pct REAL,
    enabled INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  -- Alert history
  CREATE TABLE IF NOT EXISTS alert_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    alert_config_id INTEGER,
    device_id TEXT,
    alert_type TEXT,
    message TEXT,
    severity TEXT DEFAULT 'warning',
    triggered_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    resolved_at DATETIME,
    FOREIGN KEY (alert_config_id) REFERENCES alert_configs(id)
  );

  -- ISP lookup cache
  CREATE TABLE IF NOT EXISTS isp_cache (
    public_ip TEXT PRIMARY KEY,
    isp_name TEXT,
    isp_org TEXT,
    city TEXT,
    region TEXT,
    country TEXT,
    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  -- Daily aggregates for historical trends
  CREATE TABLE IF NOT EXISTS daily_aggregates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,
    device_id TEXT,
    avg_download REAL,
    avg_upload REAL,
    avg_latency REAL,
    avg_jitter REAL,
    avg_packet_loss REAL,
    test_count INTEGER,
    vpn_on_count INTEGER DEFAULT 0,
    vpn_off_count INTEGER DEFAULT 0,
    UNIQUE(date, device_id)
  );

  -- Anomaly baselines per device
  CREATE TABLE IF NOT EXISTS device_baselines (
    device_id TEXT PRIMARY KEY,
    baseline_download REAL,
    baseline_upload REAL,
    baseline_jitter REAL,
    stddev_download REAL,
    stddev_upload REAL,
    stddev_jitter REAL,
    sample_count INTEGER DEFAULT 0,
    last_updated DATETIME
  );

  -- Indexes for new tables
  CREATE INDEX IF NOT EXISTS idx_alert_history_device ON alert_history(device_id);
  CREATE INDEX IF NOT EXISTS idx_alert_history_time ON alert_history(triggered_at);
  CREATE INDEX IF NOT EXISTS idx_daily_aggregates_date ON daily_aggregates(date);
  CREATE INDEX IF NOT EXISTS idx_isp_cache_time ON isp_cache(cached_at);

  -- v2.1: Connection events table (for tracking disconnects/roaming)
  CREATE TABLE IF NOT EXISTS connection_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    event_type TEXT NOT NULL,  -- 'connect', 'disconnect', 'roam', 'bssid_change'
    timestamp_utc DATETIME NOT NULL,
    ssid TEXT,
    bssid TEXT,
    prev_bssid TEXT,
    channel INTEGER,
    band TEXT,
    rssi_dbm INTEGER,
    association_duration_sec INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE INDEX IF NOT EXISTS idx_conn_events_device ON connection_events(device_id, timestamp_utc);
  CREATE INDEX IF NOT EXISTS idx_conn_events_type ON connection_events(event_type);
`);

// v2.1: Add new columns to existing speed_results table (for existing databases)
const columnsToAdd = [
  { name: 'mcs_index', type: 'INTEGER DEFAULT -1' },
  { name: 'spatial_streams', type: 'INTEGER DEFAULT 0' },
  { name: 'input_errors', type: 'BIGINT DEFAULT 0' },
  { name: 'output_errors', type: 'BIGINT DEFAULT 0' },
  { name: 'input_error_rate', type: 'REAL DEFAULT 0' },
  { name: 'output_error_rate', type: 'REAL DEFAULT 0' },
  { name: 'tcp_retransmits', type: 'BIGINT DEFAULT 0' },
  { name: 'bssid_changed', type: 'INTEGER DEFAULT 0' },
  { name: 'roam_count', type: 'INTEGER DEFAULT 0' },
  { name: 'user_email', type: 'TEXT' }
];

for (const col of columnsToAdd) {
  try {
    db.exec(`ALTER TABLE speed_results ADD COLUMN ${col.name} ${col.type}`);
  } catch (err) {
    // Column already exists, ignore
  }
}

// API: Submit speed test result (v2.1 - added WiFi debugging fields)
app.post('/api/results', (req, res) => {
  const data = req.body;

  if (!data.device_id) {
    return res.status(400).json({ error: 'device_id is required' });
  }

  try {
    const stmt = db.prepare(`
      INSERT INTO speed_results (
        device_id, user_id, user_email, hostname, timestamp_utc, os_version, app_version, timezone,
        interface, local_ip, public_ip,
        ssid, bssid, band, channel, width_mhz, rssi_dbm, noise_dbm, snr_db, tx_rate_mbps,
        mcs_index, spatial_streams,
        latency_ms, jitter_ms, jitter_p50, jitter_p95, packet_loss_pct, download_mbps, upload_mbps,
        vpn_status, vpn_name,
        input_errors, output_errors, input_error_rate, output_error_rate, tcp_retransmits,
        bssid_changed, roam_count,
        status, errors, raw_payload
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?,
        ?, ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?,
        ?, ?, ?, ?, ?, ?, ?,
        ?, ?,
        ?, ?, ?, ?, ?,
        ?, ?,
        ?, ?, ?
      )
    `);

    const result = stmt.run(
      data.device_id,
      data.user_id || data.device_id,
      data.user_email || null,
      data.hostname || null,
      data.timestamp_utc || new Date().toISOString(),
      data.os_version || null,
      data.app_version || null,
      data.timezone || null,
      data.interface || null,
      data.local_ip || null,
      data.public_ip || null,
      data.ssid || null,
      data.bssid || null,
      data.band || null,
      data.channel || 0,
      data.width_mhz || 0,
      data.rssi_dbm || 0,
      data.noise_dbm || 0,
      data.snr_db || 0,
      data.tx_rate_mbps || 0,
      data.mcs_index ?? -1,
      data.spatial_streams || 0,
      data.latency_ms || 0,
      data.jitter_ms || 0,
      data.jitter_p50 || 0,
      data.jitter_p95 || 0,
      data.packet_loss_pct || 0,
      data.download_mbps || 0,
      data.upload_mbps || 0,
      data.vpn_status || 'disconnected',
      data.vpn_name || 'none',
      data.input_errors || 0,
      data.output_errors || 0,
      data.input_error_rate || 0,
      data.output_error_rate || 0,
      data.tcp_retransmits || 0,
      data.bssid_changed || 0,
      data.roam_count || 0,
      data.status || 'success',
      data.errors || null,
      typeof data === 'object' ? JSON.stringify(data) : null
    );

    // v2.1: Record BSSID change as connection event
    if (data.bssid_changed === 1 || data.bssid_changed === true) {
      db.prepare(`
        INSERT INTO connection_events (device_id, event_type, timestamp_utc, ssid, bssid, channel, band, rssi_dbm)
        VALUES (?, 'roam', ?, ?, ?, ?, ?, ?)
      `).run(data.device_id, data.timestamp_utc || new Date().toISOString(),
             data.ssid, data.bssid, data.channel || 0, data.band, data.rssi_dbm || 0);
    }

    // v3.0: Check alerts and anomalies asynchronously
    checkAlerts(data).catch(err => console.error('Alert check error:', err));

    // Update device baseline periodically (every 10th test)
    const testCount = db.prepare('SELECT COUNT(*) as count FROM speed_results WHERE device_id = ?').get(data.device_id);
    if (testCount.count % 10 === 0) {
      updateBaseline(data.device_id);
    }

    res.json({ success: true, id: result.lastInsertRowid });
  } catch (err) {
    console.error('Error inserting result:', err);
    res.status(500).json({ error: 'Failed to save result' });
  }
});

// API: Get all results (with pagination)
app.get('/api/results', (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 100, 1000);
  const offset = parseInt(req.query.offset) || 0;
  const device_id = req.query.device_id;
  const ssid = req.query.ssid;
  const vpn_status = req.query.vpn_status;

  try {
    let query = 'SELECT * FROM speed_results WHERE 1=1';
    let params = [];

    if (device_id) {
      query += ' AND device_id = ?';
      params.push(device_id);
    }
    if (ssid) {
      query += ' AND ssid = ?';
      params.push(ssid);
    }
    if (vpn_status) {
      query += ' AND vpn_status = ?';
      params.push(vpn_status);
    }

    query += ' ORDER BY timestamp_utc DESC LIMIT ? OFFSET ?';
    params.push(limit, offset);

    const results = db.prepare(query).all(...params);
    res.json(results);
  } catch (err) {
    console.error('Error fetching results:', err);
    res.status(500).json({ error: 'Failed to fetch results' });
  }
});

// API: Get aggregated stats
app.get('/api/stats', (req, res) => {
  try {
    // Overall stats
    const overall = db.prepare(`
      SELECT
        COUNT(*) as total_tests,
        COUNT(DISTINCT device_id) as total_devices,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(latency_ms), 2) as avg_latency,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        ROUND(AVG(packet_loss_pct), 2) as avg_packet_loss,
        ROUND(MIN(download_mbps), 2) as min_download,
        ROUND(MAX(download_mbps), 2) as max_download
      FROM speed_results
      WHERE status = 'success'
    `).get();

    // Per-device stats
    const perDevice = db.prepare(`
      SELECT
        device_id,
        MAX(user_email) as user_email,
        MAX(hostname) as hostname,
        MAX(os_version) as os_version,
        MAX(app_version) as app_version,
        COUNT(*) as test_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(latency_ms), 2) as avg_latency,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        MAX(timestamp_utc) as last_test,
        MAX(vpn_status) as vpn_status,
        MAX(vpn_name) as vpn_name
      FROM speed_results
      WHERE status = 'success'
      GROUP BY device_id
      ORDER BY last_test DESC
    `).all();

    // Hourly trends (last 24 hours)
    const hourly = db.prepare(`
      SELECT
        strftime('%Y-%m-%d %H:00', timestamp_utc) as hour,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        COUNT(*) as test_count
      FROM speed_results
      WHERE status = 'success'
        AND timestamp_utc > datetime('now', '-24 hours')
      GROUP BY hour
      ORDER BY hour
    `).all();

    res.json({ overall, perDevice, hourly });
  } catch (err) {
    console.error('Error fetching stats:', err);
    res.status(500).json({ error: 'Failed to fetch stats' });
  }
});

// API: WiFi/Access Point statistics
app.get('/api/stats/wifi', (req, res) => {
  try {
    // Stats by access point (BSSID)
    const byAccessPoint = db.prepare(`
      SELECT
        bssid,
        MAX(ssid) as ssid,
        MAX(band) as band,
        MAX(channel) as channel,
        COUNT(*) as test_count,
        COUNT(DISTINCT device_id) as device_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(rssi_dbm), 0) as avg_rssi,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        ROUND(AVG(packet_loss_pct), 2) as avg_packet_loss
      FROM speed_results
      WHERE status = 'success' AND bssid IS NOT NULL AND bssid != 'none'
      GROUP BY bssid
      ORDER BY test_count DESC
    `).all();

    // Stats by SSID
    const bySSID = db.prepare(`
      SELECT
        ssid,
        COUNT(*) as test_count,
        COUNT(DISTINCT device_id) as device_count,
        COUNT(DISTINCT bssid) as ap_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(rssi_dbm), 0) as avg_rssi
      FROM speed_results
      WHERE status = 'success' AND ssid IS NOT NULL
      GROUP BY ssid
      ORDER BY test_count DESC
    `).all();

    // Band distribution
    const bandDistribution = db.prepare(`
      SELECT
        band,
        COUNT(*) as count,
        ROUND(AVG(download_mbps), 2) as avg_download
      FROM speed_results
      WHERE status = 'success' AND band IS NOT NULL AND band != 'none'
      GROUP BY band
    `).all();

    res.json({ byAccessPoint, bySSID, bandDistribution });
  } catch (err) {
    console.error('Error fetching WiFi stats:', err);
    res.status(500).json({ error: 'Failed to fetch WiFi stats' });
  }
});

// API: VPN statistics
app.get('/api/stats/vpn', (req, res) => {
  try {
    // VPN usage distribution
    const distribution = db.prepare(`
      SELECT
        vpn_status,
        vpn_name,
        COUNT(*) as count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(latency_ms), 2) as avg_latency,
        ROUND(AVG(jitter_ms), 2) as avg_jitter
      FROM speed_results
      WHERE status = 'success'
      GROUP BY vpn_status, vpn_name
      ORDER BY count DESC
    `).all();

    // VPN vs non-VPN comparison
    const comparison = db.prepare(`
      SELECT
        CASE WHEN vpn_status = 'connected' THEN 'VPN On' ELSE 'VPN Off' END as mode,
        COUNT(*) as test_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(latency_ms), 2) as avg_latency,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        ROUND(AVG(packet_loss_pct), 2) as avg_packet_loss
      FROM speed_results
      WHERE status = 'success'
      GROUP BY mode
    `).all();

    res.json({ distribution, comparison });
  } catch (err) {
    console.error('Error fetching VPN stats:', err);
    res.status(500).json({ error: 'Failed to fetch VPN stats' });
  }
});

// API: Jitter distribution
app.get('/api/stats/jitter', (req, res) => {
  try {
    const distribution = db.prepare(`
      SELECT
        CASE
          WHEN jitter_ms < 5 THEN '< 5ms'
          WHEN jitter_ms < 10 THEN '5-10ms'
          WHEN jitter_ms < 20 THEN '10-20ms'
          WHEN jitter_ms < 50 THEN '20-50ms'
          ELSE '> 50ms'
        END as bucket,
        COUNT(*) as count,
        ROUND(AVG(download_mbps), 2) as avg_download
      FROM speed_results
      WHERE status = 'success' AND jitter_ms IS NOT NULL
      GROUP BY bucket
      ORDER BY
        CASE bucket
          WHEN '< 5ms' THEN 1
          WHEN '5-10ms' THEN 2
          WHEN '10-20ms' THEN 3
          WHEN '20-50ms' THEN 4
          ELSE 5
        END
    `).all();

    // Problem devices (high jitter)
    const problemDevices = db.prepare(`
      SELECT
        device_id,
        MAX(hostname) as hostname,
        COUNT(*) as test_count,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        ROUND(AVG(packet_loss_pct), 2) as avg_packet_loss,
        MAX(timestamp_utc) as last_test
      FROM speed_results
      WHERE status = 'success'
      GROUP BY device_id
      HAVING AVG(jitter_ms) > 20 OR AVG(packet_loss_pct) > 1
      ORDER BY avg_jitter DESC
      LIMIT 20
    `).all();

    res.json({ distribution, problemDevices });
  } catch (err) {
    console.error('Error fetching jitter stats:', err);
    res.status(500).json({ error: 'Failed to fetch jitter stats' });
  }
});

// API: Device health
app.get('/api/devices/:device_id/health', (req, res) => {
  const { device_id } = req.params;

  try {
    const health = db.prepare(`
      SELECT
        device_id,
        MAX(user_email) as user_email,
        MAX(hostname) as hostname,
        MAX(os_version) as os_version,
        MAX(app_version) as app_version,
        COUNT(*) as total_tests,
        SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as successful_tests,
        ROUND(AVG(CASE WHEN status = 'success' THEN download_mbps END), 2) as avg_download,
        ROUND(AVG(CASE WHEN status = 'success' THEN upload_mbps END), 2) as avg_upload,
        ROUND(AVG(CASE WHEN status = 'success' THEN jitter_ms END), 2) as avg_jitter,
        ROUND(AVG(CASE WHEN status = 'success' THEN packet_loss_pct END), 2) as avg_packet_loss,
        MAX(timestamp_utc) as last_seen,
        MAX(vpn_status) as current_vpn_status,
        MAX(vpn_name) as current_vpn_name,
        MAX(ssid) as current_ssid
      FROM speed_results
      WHERE device_id = ?
    `).get(device_id);

    // Calculate median jitter (more robust than average for outliers)
    const jitterValues = db.prepare(`
      SELECT jitter_ms
      FROM speed_results
      WHERE device_id = ? AND status = 'success' AND jitter_ms IS NOT NULL
      ORDER BY jitter_ms
    `).all(device_id).map(r => r.jitter_ms);

    const medianJitter = jitterValues.length > 0
      ? jitterValues[Math.floor(jitterValues.length / 2)]
      : 0;

    health.median_jitter = Math.round(medianJitter * 100) / 100;

    // Recent tests
    const recentTests = db.prepare(`
      SELECT *
      FROM speed_results
      WHERE device_id = ?
      ORDER BY timestamp_utc DESC
      LIMIT 20
    `).all(device_id);

    res.json({ health, recentTests });
  } catch (err) {
    console.error('Error fetching device health:', err);
    res.status(500).json({ error: 'Failed to fetch device health' });
  }
});

// API: Device test history (for detail panel)
app.get('/api/devices/:device_id/history', (req, res) => {
  const { device_id } = req.params;
  const limit = Math.min(parseInt(req.query.limit) || 10, 50);

  try {
    const history = db.prepare(`
      SELECT
        timestamp_utc,
        download_mbps,
        upload_mbps,
        latency_ms,
        jitter_ms,
        vpn_status,
        vpn_name,
        ssid,
        rssi_dbm,
        status
      FROM speed_results
      WHERE device_id = ?
      ORDER BY timestamp_utc DESC
      LIMIT ?
    `).all(device_id, limit);

    res.json(history);
  } catch (err) {
    console.error('Error fetching device history:', err);
    res.status(500).json({ error: 'Failed to fetch device history' });
  }
});

// API: Employee Self-Service Portal - Get my connection data by email
app.get('/api/my/:email', (req, res) => {
  const { email } = req.params;
  const hours = Math.min(parseInt(req.query.hours) || 24, 168);

  try {
    // Find device by email
    const device = db.prepare(`
      SELECT DISTINCT device_id
      FROM speed_results
      WHERE LOWER(user_email) = LOWER(?)
      ORDER BY timestamp_utc DESC
      LIMIT 1
    `).get(email);

    if (!device) {
      return res.status(404).json({
        error: 'not_found',
        message: 'No device found for this email. Make sure Speed Monitor is installed and configured with your email.'
      });
    }

    const deviceId = device.device_id;

    // Get health summary
    const health = db.prepare(`
      SELECT
        device_id,
        MAX(user_email) as user_email,
        MAX(hostname) as hostname,
        MAX(os_version) as os_version,
        MAX(app_version) as app_version,
        COUNT(*) as total_tests,
        ROUND(AVG(CASE WHEN status = 'success' THEN download_mbps END), 2) as avg_download,
        ROUND(AVG(CASE WHEN status = 'success' THEN upload_mbps END), 2) as avg_upload,
        ROUND(AVG(CASE WHEN status = 'success' THEN latency_ms END), 2) as avg_latency,
        ROUND(AVG(CASE WHEN status = 'success' THEN jitter_ms END), 2) as avg_jitter,
        ROUND(AVG(CASE WHEN status = 'success' THEN packet_loss_pct END), 3) as avg_packet_loss,
        MAX(timestamp_utc) as last_seen,
        MAX(vpn_status) as vpn_status,
        MAX(vpn_name) as vpn_name
      FROM speed_results
      WHERE device_id = ?
    `).get(deviceId);

    // Calculate median jitter (more robust than average for outliers)
    const jitterValues = db.prepare(`
      SELECT jitter_ms
      FROM speed_results
      WHERE device_id = ? AND status = 'success' AND jitter_ms IS NOT NULL
      ORDER BY jitter_ms
    `).all(deviceId).map(r => r.jitter_ms);

    const medianJitter = jitterValues.length > 0
      ? jitterValues[Math.floor(jitterValues.length / 2)]
      : 0;

    health.median_jitter = Math.round(medianJitter * 100) / 100;

    // Get latest test for current status
    const latest = db.prepare(`
      SELECT *
      FROM speed_results
      WHERE device_id = ?
      ORDER BY timestamp_utc DESC
      LIMIT 1
    `).get(deviceId);

    // Get recent tests
    const recentTests = db.prepare(`
      SELECT
        timestamp_utc,
        download_mbps,
        upload_mbps,
        latency_ms,
        jitter_ms,
        packet_loss_pct,
        vpn_status,
        vpn_name,
        ssid,
        rssi_dbm,
        band,
        channel,
        status
      FROM speed_results
      WHERE device_id = ?
      ORDER BY timestamp_utc DESC
      LIMIT 10
    `).all(deviceId);

    // Get timeline for chart (last 24h by default)
    const timeline = db.prepare(`
      SELECT
        timestamp_utc,
        download_mbps,
        upload_mbps,
        latency_ms,
        jitter_ms
      FROM speed_results
      WHERE device_id = ?
        AND status = 'success'
        AND timestamp_utc > datetime('now', '-' || ? || ' hours')
      ORDER BY timestamp_utc ASC
    `).all(deviceId, hours);

    // Determine health status and generate recommendations
    const problems = [];
    const recommendations = [];

    if (latest) {
      // Check jitter
      if (latest.jitter_ms > 30) {
        problems.push({
          type: 'high_jitter',
          severity: latest.jitter_ms > 50 ? 'critical' : 'warning',
          message: `High jitter (${latest.jitter_ms.toFixed(1)}ms) - may cause choppy video calls`,
          value: latest.jitter_ms
        });
        recommendations.push('Close bandwidth-heavy applications during calls');
        recommendations.push('Try using a wired ethernet connection');
      }

      // Check signal strength
      if (latest.rssi_dbm && latest.rssi_dbm < -70) {
        problems.push({
          type: 'weak_signal',
          severity: latest.rssi_dbm < -80 ? 'critical' : 'warning',
          message: `Weak WiFi signal (${latest.rssi_dbm} dBm)`,
          value: latest.rssi_dbm
        });
        recommendations.push('Move closer to your WiFi router');
        recommendations.push('Remove obstacles between you and the router');
      }

      // Check download speed
      if (latest.download_mbps < 25) {
        problems.push({
          type: 'slow_download',
          severity: latest.download_mbps < 10 ? 'critical' : 'warning',
          message: `Slow download speed (${latest.download_mbps.toFixed(1)} Mbps)`,
          value: latest.download_mbps
        });
        recommendations.push('Check if others are using bandwidth on your network');
        recommendations.push('Consider upgrading your internet plan');
      }

      // Check VPN
      if (latest.vpn_status !== 'connected') {
        problems.push({
          type: 'vpn_disconnected',
          severity: 'info',
          message: 'VPN is not connected',
          value: null
        });
        recommendations.push('Connect to VPN for secure access to company resources');
      }

      // Check packet loss
      if (latest.packet_loss_pct > 1) {
        problems.push({
          type: 'packet_loss',
          severity: latest.packet_loss_pct > 3 ? 'critical' : 'warning',
          message: `Packet loss detected (${latest.packet_loss_pct.toFixed(1)}%)`,
          value: latest.packet_loss_pct
        });
        recommendations.push('Check for WiFi interference from other devices');
        recommendations.push('Try switching to 5GHz band if available');
      }

      // Band recommendation
      if (latest.band === '2.4GHz' && latest.rssi_dbm > -60) {
        recommendations.push('Switch to 5GHz band for faster speeds (you have good signal)');
      }
    }

    // Determine overall status
    const criticalCount = problems.filter(p => p.severity === 'critical').length;
    const warningCount = problems.filter(p => p.severity === 'warning').length;

    let status = 'healthy';
    let statusMessage = 'Your connection looks good!';

    if (criticalCount > 0) {
      status = 'critical';
      statusMessage = `${criticalCount} critical issue${criticalCount > 1 ? 's' : ''} detected`;
    } else if (warningCount > 0) {
      status = 'warning';
      statusMessage = `${warningCount} issue${warningCount > 1 ? 's' : ''} to review`;
    }

    // WiFi details
    const wifi = latest ? {
      ssid: latest.ssid || 'Unknown',
      band: latest.band || 'Unknown',
      channel: latest.channel || 'Unknown',
      rssi: latest.rssi_dbm,
      signalQuality: latest.rssi_dbm > -50 ? 'Excellent' :
                     latest.rssi_dbm > -60 ? 'Good' :
                     latest.rssi_dbm > -70 ? 'Fair' : 'Poor',
      txRate: latest.tx_rate_mbps
    } : null;

    res.json({
      email,
      deviceId,
      status,
      statusMessage,
      health,
      latest,
      wifi,
      problems,
      recommendations: [...new Set(recommendations)], // dedupe
      recentTests,
      timeline
    });
  } catch (err) {
    console.error('Error fetching self-service data:', err);
    res.status(500).json({ error: 'Failed to fetch connection data' });
  }
});

// API: Speed timeline (all devices, for chart)
app.get('/api/stats/timeline', (req, res) => {
  const hours = Math.min(parseInt(req.query.hours) || 24, 168); // Max 7 days

  try {
    const timeline = db.prepare(`
      SELECT
        timestamp_utc,
        device_id,
        user_email,
        download_mbps,
        upload_mbps,
        latency_ms,
        jitter_ms,
        vpn_status,
        vpn_name,
        ssid,
        rssi_dbm
      FROM speed_results
      WHERE status = 'success'
        AND timestamp_utc > datetime('now', '-' || ? || ' hours')
      ORDER BY timestamp_utc ASC
    `).all(hours);

    res.json(timeline);
  } catch (err) {
    console.error('Timeline error:', err);
    res.status(500).json({ error: 'Failed to fetch timeline' });
  }
});

// API: Get device's results
app.get('/api/results/:device_id', (req, res) => {
  const { device_id } = req.params;
  const limit = Math.min(parseInt(req.query.limit) || 50, 500);

  try {
    const results = db.prepare(`
      SELECT * FROM speed_results
      WHERE device_id = ?
      ORDER BY timestamp_utc DESC
      LIMIT ?
    `).all(device_id, limit);

    res.json(results);
  } catch (err) {
    console.error('Error fetching device results:', err);
    res.status(500).json({ error: 'Failed to fetch results' });
  }
});

// ============================================
// v3.0 Features - Alerts, Analytics, ISP, etc.
// ============================================

// ISP Lookup function (using ip-api.com)
async function lookupISP(publicIP) {
  if (!publicIP || publicIP === 'unknown') return null;

  try {
    // Check cache first (7-day TTL)
    const cached = db.prepare('SELECT * FROM isp_cache WHERE public_ip = ?').get(publicIP);
    if (cached) {
      const cacheAge = Date.now() - new Date(cached.cached_at).getTime();
      if (cacheAge < 7 * 24 * 60 * 60 * 1000) {
        return cached;
      }
    }

    // Fetch from API
    const response = await fetch(`http://ip-api.com/json/${publicIP}?fields=status,isp,org,city,regionName,country`);
    const data = await response.json();

    if (data.status === 'success') {
      db.prepare(`INSERT OR REPLACE INTO isp_cache (public_ip, isp_name, isp_org, city, region, country, cached_at)
                  VALUES (?, ?, ?, ?, ?, ?, datetime('now'))`).run(
        publicIP, data.isp, data.org, data.city, data.regionName, data.country
      );
      return { isp_name: data.isp, isp_org: data.org, city: data.city, region: data.regionName, country: data.country };
    }
  } catch (err) {
    console.error('ISP lookup error:', err.message);
  }
  return null;
}

// Anomaly detection (Z-score based)
function detectAnomaly(result) {
  const baseline = db.prepare('SELECT * FROM device_baselines WHERE device_id = ?').get(result.device_id);

  if (!baseline || baseline.sample_count < 10) {
    // Not enough data for baseline, update it
    updateBaseline(result.device_id);
    return null;
  }

  const anomalies = [];

  // Check download speed (z-score < -2 means significantly lower)
  if (baseline.stddev_download > 0) {
    const downloadZScore = (result.download_mbps - baseline.baseline_download) / baseline.stddev_download;
    if (downloadZScore < -2) {
      anomalies.push({
        type: 'low_download',
        zscore: downloadZScore.toFixed(2),
        expected: baseline.baseline_download.toFixed(1),
        actual: result.download_mbps
      });
    }
  }

  // Check jitter (z-score > 2 means significantly higher)
  if (baseline.stddev_jitter > 0) {
    const jitterZScore = (result.jitter_ms - baseline.baseline_jitter) / baseline.stddev_jitter;
    if (jitterZScore > 2) {
      anomalies.push({
        type: 'high_jitter',
        zscore: jitterZScore.toFixed(2),
        expected: baseline.baseline_jitter.toFixed(1),
        actual: result.jitter_ms
      });
    }
  }

  return anomalies.length > 0 ? anomalies : null;
}

// Update device baseline
function updateBaseline(deviceId) {
  try {
    const stats = db.prepare(`
      SELECT
        COUNT(*) as sample_count,
        AVG(download_mbps) as avg_download,
        AVG(upload_mbps) as avg_upload,
        AVG(jitter_ms) as avg_jitter
      FROM (
        SELECT download_mbps, upload_mbps, jitter_ms
        FROM speed_results
        WHERE device_id = ? AND status = 'success'
        ORDER BY timestamp_utc DESC
        LIMIT 100
      )
    `).get(deviceId);

    if (stats.sample_count < 5) return;

    // Calculate standard deviations
    const stddevStats = db.prepare(`
      SELECT
        SQRT(AVG((download_mbps - ?) * (download_mbps - ?))) as stddev_download,
        SQRT(AVG((upload_mbps - ?) * (upload_mbps - ?))) as stddev_upload,
        SQRT(AVG((jitter_ms - ?) * (jitter_ms - ?))) as stddev_jitter
      FROM (
        SELECT download_mbps, upload_mbps, jitter_ms
        FROM speed_results
        WHERE device_id = ? AND status = 'success'
        ORDER BY timestamp_utc DESC
        LIMIT 100
      )
    `).get(stats.avg_download, stats.avg_download, stats.avg_upload, stats.avg_upload,
           stats.avg_jitter, stats.avg_jitter, deviceId);

    db.prepare(`
      INSERT OR REPLACE INTO device_baselines
      (device_id, baseline_download, baseline_upload, baseline_jitter,
       stddev_download, stddev_upload, stddev_jitter, sample_count, last_updated)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
    `).run(deviceId, stats.avg_download, stats.avg_upload, stats.avg_jitter,
           stddevStats.stddev_download || 0, stddevStats.stddev_upload || 0, stddevStats.stddev_jitter || 0,
           stats.sample_count);
  } catch (err) {
    console.error('Error updating baseline:', err.message);
  }
}

// Send Slack alert
async function sendSlackAlert(webhookUrl, deviceId, alertType, message, severity = 'warning') {
  const emoji = severity === 'critical' ? '🚨' : '⚠️';
  const color = severity === 'critical' ? '#dc3545' : '#ffc107';

  try {
    await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        attachments: [{
          color: color,
          blocks: [
            {
              type: 'header',
              text: { type: 'plain_text', text: `${emoji} Speed Monitor Alert`, emoji: true }
            },
            {
              type: 'section',
              fields: [
                { type: 'mrkdwn', text: `*Alert Type:*\n${alertType}` },
                { type: 'mrkdwn', text: `*Device:*\n${deviceId.substring(0, 12)}...` }
              ]
            },
            {
              type: 'section',
              text: { type: 'mrkdwn', text: `*Details:*\n${message}` }
            },
            {
              type: 'context',
              elements: [
                { type: 'mrkdwn', text: `🕐 ${new Date().toISOString()} | <https://home-internet-production.up.railway.app|View Dashboard>` }
              ]
            }
          ]
        }]
      })
    });
    return true;
  } catch (err) {
    console.error('Slack alert error:', err.message);
    return false;
  }
}

// Check alerts after each result
async function checkAlerts(result) {
  const configs = db.prepare('SELECT * FROM alert_configs WHERE enabled = 1').all();

  for (const config of configs) {
    let triggered = false;
    let alertType = '';
    let message = '';
    let severity = 'warning';

    // Check download threshold
    if (config.threshold_download_mbps && result.download_mbps < config.threshold_download_mbps) {
      triggered = true;
      alertType = 'Low Download Speed';
      message = `Download speed ${result.download_mbps} Mbps is below threshold of ${config.threshold_download_mbps} Mbps`;
      severity = result.download_mbps < config.threshold_download_mbps / 2 ? 'critical' : 'warning';
    }

    // Check jitter threshold
    if (config.threshold_jitter_ms && result.jitter_ms > config.threshold_jitter_ms) {
      triggered = true;
      alertType = 'High Jitter';
      message = `Jitter ${result.jitter_ms}ms exceeds threshold of ${config.threshold_jitter_ms}ms`;
      severity = result.jitter_ms > config.threshold_jitter_ms * 2 ? 'critical' : 'warning';
    }

    // Check packet loss threshold
    if (config.threshold_packet_loss_pct && result.packet_loss_pct > config.threshold_packet_loss_pct) {
      triggered = true;
      alertType = 'High Packet Loss';
      message = `Packet loss ${result.packet_loss_pct}% exceeds threshold of ${config.threshold_packet_loss_pct}%`;
      severity = 'critical';
    }

    // WiFi Debugging Alerts

    // Check high error rate (>1% packet errors)
    const errorRate = Math.max(result.input_error_rate || 0, result.output_error_rate || 0);
    if (!triggered && errorRate > 1.0) {
      triggered = true;
      alertType = 'High Error Rate';
      message = `Packet error rate ${errorRate.toFixed(2)}% exceeds 1% threshold (input: ${(result.input_error_rate || 0).toFixed(2)}%, output: ${(result.output_error_rate || 0).toFixed(2)}%)`;
      severity = errorRate > 5.0 ? 'critical' : 'warning';
    }

    // Check excessive roaming (>5 BSSID changes/hour)
    if (!triggered && result.bssid_changed) {
      const recentRoams = db.prepare(`
        SELECT COUNT(*) as count FROM connection_events
        WHERE device_id = ? AND event_type = 'roam'
        AND timestamp_utc > datetime('now', '-1 hour')
      `).get(result.device_id);

      if (recentRoams && recentRoams.count > 5) {
        triggered = true;
        alertType = 'Excessive Roaming';
        message = `Device roamed ${recentRoams.count} times in the last hour (threshold: 5). Possible AP instability or weak signal areas.`;
        severity = recentRoams.count > 10 ? 'critical' : 'warning';
      }
    }

    // Check hidden congestion (good RSSI but poor MCS and high retransmits)
    // This detects "slow despite good signal" issue
    if (!triggered && result.rssi_dbm && result.rssi_dbm > -60) {
      const hasPoorMCS = result.mcs_index !== undefined && result.mcs_index >= 0 && result.mcs_index < 5;
      const hasHighRetransmits = result.tcp_retransmits && result.tcp_retransmits > 100;
      const hasSlowSpeed = result.download_mbps < 50;

      if (hasPoorMCS && (hasHighRetransmits || hasSlowSpeed)) {
        triggered = true;
        alertType = 'Hidden Congestion';
        message = `Good signal (${result.rssi_dbm} dBm) but poor link quality: MCS ${result.mcs_index}, ${result.download_mbps} Mbps. Possible interference or congestion.`;
        severity = 'critical';
      }
    }

    // Check frequent disconnects (>3 disconnects/hour)
    if (!triggered) {
      const recentDisconnects = db.prepare(`
        SELECT COUNT(*) as count FROM connection_events
        WHERE device_id = ? AND event_type = 'disconnect'
        AND timestamp_utc > datetime('now', '-1 hour')
      `).get(result.device_id);

      if (recentDisconnects && recentDisconnects.count > 3) {
        triggered = true;
        alertType = 'Frequent Disconnects';
        message = `Device disconnected ${recentDisconnects.count} times in the last hour (threshold: 3). Check for interference or router issues.`;
        severity = 'critical';
      }
    }

    if (triggered) {
      // Record alert in history
      db.prepare(`
        INSERT INTO alert_history (alert_config_id, device_id, alert_type, message, severity)
        VALUES (?, ?, ?, ?, ?)
      `).run(config.id, result.device_id, alertType, message, severity);

      // Send alert
      if (config.type === 'slack') {
        await sendSlackAlert(config.webhook_url, result.device_id, alertType, message, severity);
      }
    }
  }

  // Check for anomalies
  const anomalies = detectAnomaly(result);
  if (anomalies && anomalies.length > 0) {
    for (const config of configs.filter(c => c.enabled)) {
      const anomalyMsg = anomalies.map(a => `${a.type}: expected ${a.expected}, got ${a.actual} (z=${a.zscore})`).join('; ');

      db.prepare(`
        INSERT INTO alert_history (alert_config_id, device_id, alert_type, message, severity)
        VALUES (?, ?, ?, ?, ?)
      `).run(config.id, result.device_id, 'Anomaly Detected', anomalyMsg, 'warning');

      if (config.type === 'slack') {
        await sendSlackAlert(config.webhook_url, result.device_id, 'Anomaly Detected', anomalyMsg, 'warning');
      }
    }
  }
}

// Generate troubleshooting recommendations
function generateTroubleshooting(deviceId) {
  const health = db.prepare(`
    SELECT
      AVG(download_mbps) as avg_download,
      AVG(upload_mbps) as avg_upload,
      AVG(jitter_ms) as avg_jitter,
      AVG(packet_loss_pct) as avg_packet_loss,
      AVG(rssi_dbm) as avg_rssi,
      MAX(band) as band,
      MAX(channel) as channel,
      AVG(CASE WHEN vpn_status = 'connected' THEN download_mbps END) as vpn_on_speed,
      AVG(CASE WHEN vpn_status = 'disconnected' THEN download_mbps END) as vpn_off_speed
    FROM speed_results
    WHERE device_id = ? AND status = 'success'
      AND timestamp_utc > datetime('now', '-7 days')
  `).get(deviceId);

  if (!health) return [];

  const recommendations = [];

  // Weak WiFi signal
  if (health.avg_rssi && health.avg_rssi < -70) {
    recommendations.push({
      issue: 'Weak WiFi Signal',
      severity: health.avg_rssi < -80 ? 'high' : 'medium',
      icon: '📶',
      suggestion: 'Move closer to the router, reduce obstacles, or consider a WiFi extender/mesh system.',
      metrics: { rssi: Math.round(health.avg_rssi), threshold: -70 }
    });
  }

  // High jitter
  if (health.avg_jitter > 30) {
    recommendations.push({
      issue: 'Network Congestion',
      severity: health.avg_jitter > 50 ? 'high' : 'medium',
      icon: '🌐',
      suggestion: 'Try switching to 5GHz band, use a wired connection, or check for bandwidth-heavy applications.',
      metrics: { jitter: Math.round(health.avg_jitter), threshold: 30 }
    });
  }

  // Packet loss
  if (health.avg_packet_loss > 1) {
    recommendations.push({
      issue: 'Packet Loss Detected',
      severity: health.avg_packet_loss > 5 ? 'high' : 'medium',
      icon: '📦',
      suggestion: 'Check for WiFi interference, restart your router, or contact your ISP if issue persists.',
      metrics: { packet_loss: health.avg_packet_loss.toFixed(1), threshold: 1 }
    });
  }

  // VPN slowdown
  if (health.vpn_on_speed && health.vpn_off_speed && health.vpn_on_speed < health.vpn_off_speed * 0.5) {
    recommendations.push({
      issue: 'VPN Significantly Reducing Speed',
      severity: 'low',
      icon: '🔒',
      suggestion: 'VPN is reducing speeds by >50%. Consider split tunneling if available, or check VPN server location.',
      metrics: { vpn_on: Math.round(health.vpn_on_speed), vpn_off: Math.round(health.vpn_off_speed) }
    });
  }

  // Suboptimal WiFi channel (2.4GHz overlapping channels)
  if (health.band === '2.4GHz' && health.channel && ![1, 6, 11].includes(health.channel)) {
    recommendations.push({
      issue: 'Suboptimal WiFi Channel',
      severity: 'low',
      icon: '📻',
      suggestion: `Channel ${health.channel} overlaps with others. Switch to channel 1, 6, or 11 for better performance.`,
      metrics: { current_channel: health.channel, recommended: [1, 6, 11] }
    });
  }

  // Low download speed
  if (health.avg_download < 25) {
    recommendations.push({
      issue: 'Low Download Speed',
      severity: health.avg_download < 10 ? 'high' : 'medium',
      icon: '⬇️',
      suggestion: 'Check your ISP plan limits, try restarting your router, or test with a wired connection to isolate WiFi issues.',
      metrics: { speed: Math.round(health.avg_download) }
    });
  }

  return recommendations;
}

// ============================================
// v3.0 API Endpoints
// ============================================

// Alert Configuration APIs
app.post('/api/alerts/config', (req, res) => {
  const { name, type, webhook_url, channel_name, threshold_download_mbps, threshold_jitter_ms, threshold_packet_loss_pct } = req.body;

  if (!name || !type || !webhook_url) {
    return res.status(400).json({ error: 'name, type, and webhook_url are required' });
  }

  try {
    const result = db.prepare(`
      INSERT INTO alert_configs (name, type, webhook_url, channel_name, threshold_download_mbps, threshold_jitter_ms, threshold_packet_loss_pct)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(name, type, webhook_url, channel_name || null, threshold_download_mbps || null, threshold_jitter_ms || null, threshold_packet_loss_pct || null);

    res.json({ success: true, id: result.lastInsertRowid });
  } catch (err) {
    res.status(500).json({ error: 'Failed to create alert config' });
  }
});

app.get('/api/alerts/config', (req, res) => {
  try {
    const configs = db.prepare('SELECT * FROM alert_configs ORDER BY created_at DESC').all();
    res.json(configs);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch alert configs' });
  }
});

app.put('/api/alerts/config/:id', (req, res) => {
  const { id } = req.params;
  const { name, webhook_url, channel_name, threshold_download_mbps, threshold_jitter_ms, threshold_packet_loss_pct, enabled } = req.body;

  try {
    db.prepare(`
      UPDATE alert_configs SET
        name = COALESCE(?, name),
        webhook_url = COALESCE(?, webhook_url),
        channel_name = COALESCE(?, channel_name),
        threshold_download_mbps = ?,
        threshold_jitter_ms = ?,
        threshold_packet_loss_pct = ?,
        enabled = COALESCE(?, enabled)
      WHERE id = ?
    `).run(name, webhook_url, channel_name, threshold_download_mbps, threshold_jitter_ms, threshold_packet_loss_pct, enabled, id);

    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update alert config' });
  }
});

app.delete('/api/alerts/config/:id', (req, res) => {
  const { id } = req.params;
  try {
    db.prepare('DELETE FROM alert_configs WHERE id = ?').run(id);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete alert config' });
  }
});

app.get('/api/alerts/history', (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 50, 200);
  const device_id = req.query.device_id;

  try {
    let query = `
      SELECT ah.*, ac.name as config_name
      FROM alert_history ah
      LEFT JOIN alert_configs ac ON ah.alert_config_id = ac.id
    `;
    let params = [];

    if (device_id) {
      query += ' WHERE ah.device_id = ?';
      params.push(device_id);
    }

    query += ' ORDER BY ah.triggered_at DESC LIMIT ?';
    params.push(limit);

    const history = db.prepare(query).all(...params);
    res.json(history);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch alert history' });
  }
});

app.post('/api/alerts/test', async (req, res) => {
  const { config_id } = req.body;

  try {
    const config = db.prepare('SELECT * FROM alert_configs WHERE id = ?').get(config_id);
    if (!config) {
      return res.status(404).json({ error: 'Alert config not found' });
    }

    const success = await sendSlackAlert(
      config.webhook_url,
      'test-device',
      'Test Alert',
      'This is a test alert from Speed Monitor v3.0',
      'warning'
    );

    res.json({ success, message: success ? 'Test alert sent!' : 'Failed to send alert' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to send test alert' });
  }
});

// ISP Comparison API
app.get('/api/stats/isp', async (req, res) => {
  try {
    // Get unique public IPs with their stats
    const ipStats = db.prepare(`
      SELECT
        public_ip,
        COUNT(*) as test_count,
        COUNT(DISTINCT device_id) as device_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(latency_ms), 2) as avg_latency,
        ROUND(AVG(jitter_ms), 2) as avg_jitter
      FROM speed_results
      WHERE status = 'success' AND public_ip IS NOT NULL AND public_ip != ''
      GROUP BY public_ip
      HAVING test_count >= 3
      ORDER BY test_count DESC
      LIMIT 50
    `).all();

    // Enrich with ISP data
    const enriched = [];
    for (const stat of ipStats) {
      const isp = await lookupISP(stat.public_ip);
      enriched.push({
        ...stat,
        isp_name: isp?.isp_name || 'Unknown',
        isp_org: isp?.isp_org || null,
        city: isp?.city || null,
        region: isp?.region || null
      });
    }

    // Aggregate by ISP
    const byISP = {};
    for (const e of enriched) {
      const key = e.isp_name;
      if (!byISP[key]) {
        byISP[key] = {
          isp_name: key,
          total_tests: 0,
          device_count: 0,
          sum_download: 0,
          sum_upload: 0,
          sum_latency: 0,
          sum_jitter: 0
        };
      }
      byISP[key].total_tests += e.test_count;
      byISP[key].device_count += e.device_count;
      byISP[key].sum_download += e.avg_download * e.test_count;
      byISP[key].sum_upload += e.avg_upload * e.test_count;
      byISP[key].sum_latency += e.avg_latency * e.test_count;
      byISP[key].sum_jitter += e.avg_jitter * e.test_count;
    }

    const ispComparison = Object.values(byISP).map(isp => ({
      isp_name: isp.isp_name,
      total_tests: isp.total_tests,
      device_count: isp.device_count,
      avg_download: (isp.sum_download / isp.total_tests).toFixed(2),
      avg_upload: (isp.sum_upload / isp.total_tests).toFixed(2),
      avg_latency: (isp.sum_latency / isp.total_tests).toFixed(2),
      avg_jitter: (isp.sum_jitter / isp.total_tests).toFixed(2)
    })).sort((a, b) => b.total_tests - a.total_tests);

    res.json({ byIP: enriched, byISP: ispComparison });
  } catch (err) {
    console.error('ISP stats error:', err);
    res.status(500).json({ error: 'Failed to fetch ISP stats' });
  }
});

// Time-of-Day Analysis API
app.get('/api/stats/timeofday', (req, res) => {
  const days = parseInt(req.query.days) || 30;

  try {
    const data = db.prepare(`
      SELECT
        CAST(strftime('%H', timestamp_utc) AS INTEGER) as hour,
        CAST(strftime('%w', timestamp_utc) AS INTEGER) as day_of_week,
        COUNT(*) as test_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(jitter_ms), 2) as avg_jitter
      FROM speed_results
      WHERE status = 'success'
        AND timestamp_utc > datetime('now', '-' || ? || ' days')
      GROUP BY hour, day_of_week
      ORDER BY day_of_week, hour
    `).all(days);

    // Create 7x24 heatmap matrix
    const heatmap = Array(7).fill(null).map(() => Array(24).fill(null));
    for (const row of data) {
      heatmap[row.day_of_week][row.hour] = {
        download: row.avg_download,
        upload: row.avg_upload,
        jitter: row.avg_jitter,
        tests: row.test_count
      };
    }

    // Find peak and off-peak hours
    let peakHour = { download: 0, hour: 0, day: 0 };
    let offPeakHour = { download: Infinity, hour: 0, day: 0 };

    for (const row of data) {
      if (row.avg_download > peakHour.download) {
        peakHour = { download: row.avg_download, hour: row.hour, day: row.day_of_week };
      }
      if (row.avg_download < offPeakHour.download && row.test_count >= 3) {
        offPeakHour = { download: row.avg_download, hour: row.hour, day: row.day_of_week };
      }
    }

    res.json({
      heatmap,
      raw: data,
      insights: {
        peakPerformance: peakHour,
        worstPerformance: offPeakHour.download < Infinity ? offPeakHour : null
      }
    });
  } catch (err) {
    console.error('Time-of-day error:', err);
    res.status(500).json({ error: 'Failed to fetch time-of-day stats' });
  }
});

// Historical Trends API (30/60/90 days)
app.get('/api/stats/trends', (req, res) => {
  const days = Math.min(parseInt(req.query.days) || 30, 90);

  try {
    const trends = db.prepare(`
      SELECT
        date(timestamp_utc) as date,
        COUNT(*) as total_tests,
        COUNT(DISTINCT device_id) as active_devices,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(upload_mbps), 2) as avg_upload,
        ROUND(AVG(latency_ms), 2) as avg_latency,
        ROUND(AVG(jitter_ms), 2) as avg_jitter,
        ROUND(AVG(packet_loss_pct), 3) as avg_packet_loss,
        SUM(CASE WHEN vpn_status = 'connected' THEN 1 ELSE 0 END) as vpn_on_tests,
        SUM(CASE WHEN vpn_status = 'disconnected' THEN 1 ELSE 0 END) as vpn_off_tests
      FROM speed_results
      WHERE status = 'success'
        AND timestamp_utc > datetime('now', '-' || ? || ' days')
      GROUP BY date(timestamp_utc)
      ORDER BY date
    `).all(days);

    // Calculate week-over-week changes
    const currentWeek = trends.slice(-7);
    const previousWeek = trends.slice(-14, -7);

    const avgCurrent = currentWeek.length > 0 ?
      currentWeek.reduce((sum, d) => sum + parseFloat(d.avg_download), 0) / currentWeek.length : 0;
    const avgPrevious = previousWeek.length > 0 ?
      previousWeek.reduce((sum, d) => sum + parseFloat(d.avg_download), 0) / previousWeek.length : 0;

    const weekOverWeekChange = avgPrevious > 0 ?
      ((avgCurrent - avgPrevious) / avgPrevious * 100).toFixed(1) : 0;

    res.json({
      trends,
      summary: {
        days_analyzed: days,
        total_data_points: trends.length,
        week_over_week_change: parseFloat(weekOverWeekChange),
        trend_direction: parseFloat(weekOverWeekChange) > 2 ? 'improving' :
                         parseFloat(weekOverWeekChange) < -2 ? 'declining' : 'stable'
      }
    });
  } catch (err) {
    console.error('Trends error:', err);
    res.status(500).json({ error: 'Failed to fetch trends' });
  }
});

// WiFi Channel Analysis & Recommendations
app.get('/api/stats/channels', (req, res) => {
  try {
    const channels = db.prepare(`
      SELECT
        channel,
        band,
        COUNT(*) as test_count,
        COUNT(DISTINCT device_id) as device_count,
        ROUND(AVG(download_mbps), 2) as avg_download,
        ROUND(AVG(rssi_dbm), 0) as avg_rssi,
        ROUND(AVG(jitter_ms), 2) as avg_jitter
      FROM speed_results
      WHERE status = 'success'
        AND channel > 0
        AND timestamp_utc > datetime('now', '-7 days')
      GROUP BY channel, band
      ORDER BY band, channel
    `).all();

    res.json(channels);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch channel stats' });
  }
});

app.get('/api/recommendations/wifi', (req, res) => {
  try {
    const recommendations = [];

    // Channel congestion analysis
    const channelStats = db.prepare(`
      SELECT channel, band, COUNT(DISTINCT device_id) as devices,
             ROUND(AVG(download_mbps), 2) as avg_speed,
             ROUND(AVG(rssi_dbm), 0) as avg_rssi
      FROM speed_results
      WHERE status = 'success' AND channel > 0
        AND timestamp_utc > datetime('now', '-7 days')
      GROUP BY channel, band
      ORDER BY devices DESC
    `).all();

    // Find congested 2.4GHz channels
    const congested24 = channelStats.filter(c => c.band === '2.4GHz' && c.devices > 5);
    if (congested24.length > 0) {
      const bestChannel = [1, 6, 11].find(ch => !congested24.find(c => c.channel === ch)) || 11;
      recommendations.push({
        type: 'channel_congestion',
        severity: 'medium',
        icon: '📻',
        message: `${congested24.length} congested 2.4GHz channel(s) detected`,
        suggestion: `Consider switching affected devices to channel ${bestChannel} or 5GHz`,
        data: congested24
      });
    }

    // Weak signal devices
    const weakSignal = db.prepare(`
      SELECT device_id, ROUND(AVG(rssi_dbm), 0) as avg_rssi, MAX(ssid) as ssid
      FROM speed_results
      WHERE rssi_dbm < -70 AND rssi_dbm != 0
        AND timestamp_utc > datetime('now', '-7 days')
      GROUP BY device_id
      HAVING COUNT(*) >= 3
    `).all();

    if (weakSignal.length > 0) {
      recommendations.push({
        type: 'weak_signal',
        severity: weakSignal.some(d => d.avg_rssi < -80) ? 'high' : 'medium',
        icon: '📶',
        message: `${weakSignal.length} device(s) with weak WiFi signal`,
        suggestion: 'Consider repositioning router, adding mesh nodes, or using WiFi extenders',
        affected_devices: weakSignal.slice(0, 10)
      });
    }

    // 2.4GHz vs 5GHz comparison
    const bandComparison = db.prepare(`
      SELECT band,
             ROUND(AVG(download_mbps), 2) as avg_download,
             COUNT(DISTINCT device_id) as devices
      FROM speed_results
      WHERE status = 'success' AND band IN ('2.4GHz', '5GHz')
        AND timestamp_utc > datetime('now', '-7 days')
      GROUP BY band
    `).all();

    const band24 = bandComparison.find(b => b.band === '2.4GHz');
    const band5 = bandComparison.find(b => b.band === '5GHz');

    if (band24 && band5 && band24.avg_download < band5.avg_download * 0.5) {
      recommendations.push({
        type: 'band_upgrade',
        severity: 'low',
        icon: '⬆️',
        message: '2.4GHz significantly slower than 5GHz',
        suggestion: `Switch capable devices to 5GHz for ~${Math.round(band5.avg_download - band24.avg_download)} Mbps improvement`,
        data: { '2.4GHz': band24, '5GHz': band5 }
      });
    }

    res.json(recommendations);
  } catch (err) {
    console.error('WiFi recommendations error:', err);
    res.status(500).json({ error: 'Failed to generate recommendations' });
  }
});

// Troubleshooting API
app.get('/api/devices/:device_id/troubleshoot', (req, res) => {
  const { device_id } = req.params;

  try {
    const recommendations = generateTroubleshooting(device_id);
    res.json({
      device_id,
      generated_at: new Date().toISOString(),
      recommendation_count: recommendations.length,
      recommendations
    });
  } catch (err) {
    console.error('Troubleshooting error:', err);
    res.status(500).json({ error: 'Failed to generate troubleshooting' });
  }
});

// ============================================
// v2.1 WiFi Debugging APIs
// ============================================

// Link Quality Analysis API - MCS trends, error rates over time
app.get('/api/devices/:device_id/link-quality', (req, res) => {
  const { device_id } = req.params;
  const hours = Math.min(parseInt(req.query.hours) || 24, 168);

  try {
    // Get link quality metrics over time
    const linkQuality = db.prepare(`
      SELECT
        timestamp_utc,
        rssi_dbm,
        mcs_index,
        spatial_streams,
        tx_rate_mbps,
        download_mbps,
        input_error_rate,
        output_error_rate,
        tcp_retransmits,
        bssid_changed
      FROM speed_results
      WHERE device_id = ? AND status = 'success'
        AND timestamp_utc > datetime('now', '-' || ? || ' hours')
      ORDER BY timestamp_utc DESC
    `).all(device_id, hours);

    // Calculate correlations
    const validMCS = linkQuality.filter(r => r.mcs_index >= 0);
    const avgMCS = validMCS.length > 0 ?
      validMCS.reduce((sum, r) => sum + r.mcs_index, 0) / validMCS.length : -1;

    const avgRSSI = linkQuality.length > 0 ?
      linkQuality.reduce((sum, r) => sum + (r.rssi_dbm || 0), 0) / linkQuality.length : 0;

    const avgErrorRate = linkQuality.length > 0 ?
      linkQuality.reduce((sum, r) => sum + (r.input_error_rate || 0) + (r.output_error_rate || 0), 0) / linkQuality.length : 0;

    const avgSpeed = linkQuality.length > 0 ?
      linkQuality.reduce((sum, r) => sum + (r.download_mbps || 0), 0) / linkQuality.length : 0;

    // Detect "slow despite good signal" pattern
    const goodSignalSlowSpeed = linkQuality.filter(r =>
      r.rssi_dbm > -60 && r.download_mbps < 50
    );

    // Expected MCS based on RSSI (rough mapping)
    // RSSI > -50: MCS 9-11, RSSI -50 to -60: MCS 7-9, RSSI -60 to -70: MCS 5-7
    const expectedMCS = avgRSSI > -50 ? 9 : avgRSSI > -60 ? 7 : avgRSSI > -70 ? 5 : 3;
    const mcsDeficit = avgMCS >= 0 ? expectedMCS - avgMCS : 0;

    res.json({
      device_id,
      period_hours: hours,
      data_points: linkQuality.length,
      metrics: linkQuality,
      summary: {
        avg_rssi: Math.round(avgRSSI),
        avg_mcs: avgMCS >= 0 ? avgMCS.toFixed(1) : 'N/A',
        expected_mcs: expectedMCS,
        mcs_deficit: mcsDeficit.toFixed(1),
        avg_error_rate: avgErrorRate.toFixed(4),
        avg_download: avgSpeed.toFixed(1),
        good_signal_slow_speed_count: goodSignalSlowSpeed.length,
        total_roam_events: linkQuality.filter(r => r.bssid_changed).length
      },
      diagnosis: {
        has_link_quality_issue: mcsDeficit > 2 || avgErrorRate > 0.01,
        has_slow_despite_good_signal: goodSignalSlowSpeed.length > linkQuality.length * 0.2,
        issue_description: mcsDeficit > 2 ?
          'MCS index lower than expected for signal strength - possible interference or AP congestion' :
          avgErrorRate > 0.01 ?
          'Elevated packet error rate - check for interference or driver issues' :
          goodSignalSlowSpeed.length > linkQuality.length * 0.2 ?
          'Good signal but slow speeds - likely AP overload or backhaul issue' :
          'No significant link quality issues detected'
      }
    });
  } catch (err) {
    console.error('Link quality error:', err);
    res.status(500).json({ error: 'Failed to fetch link quality data' });
  }
});

// Connection Events API - track disconnects and roaming
app.get('/api/devices/:device_id/connection-events', (req, res) => {
  const { device_id } = req.params;
  const hours = Math.min(parseInt(req.query.hours) || 24, 168);
  const event_type = req.query.event_type;

  try {
    let query = `
      SELECT * FROM connection_events
      WHERE device_id = ?
        AND timestamp_utc > datetime('now', '-' || ? || ' hours')
    `;
    let params = [device_id, hours];

    if (event_type) {
      query += ' AND event_type = ?';
      params.push(event_type);
    }

    query += ' ORDER BY timestamp_utc DESC LIMIT 100';

    const events = db.prepare(query).all(...params);

    // Get BSSID change count from speed_results as backup
    const roamCount = db.prepare(`
      SELECT COUNT(*) as count FROM speed_results
      WHERE device_id = ? AND bssid_changed = 1
        AND timestamp_utc > datetime('now', '-' || ? || ' hours')
    `).get(device_id, hours);

    res.json({
      device_id,
      period_hours: hours,
      events,
      summary: {
        total_events: events.length,
        roam_events: events.filter(e => e.event_type === 'roam').length,
        disconnect_events: events.filter(e => e.event_type === 'disconnect').length,
        roam_count_from_tests: roamCount.count
      }
    });
  } catch (err) {
    console.error('Connection events error:', err);
    res.status(500).json({ error: 'Failed to fetch connection events' });
  }
});

// Submit Connection Event
app.post('/api/connection-events', (req, res) => {
  const data = req.body;

  if (!data.device_id || !data.event_type) {
    return res.status(400).json({ error: 'device_id and event_type are required' });
  }

  try {
    const result = db.prepare(`
      INSERT INTO connection_events (device_id, event_type, timestamp_utc, ssid, bssid, prev_bssid, channel, band, rssi_dbm, association_duration_sec)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      data.device_id,
      data.event_type,
      data.timestamp_utc || new Date().toISOString(),
      data.ssid || null,
      data.bssid || null,
      data.prev_bssid || null,
      data.channel || 0,
      data.band || null,
      data.rssi_dbm || 0,
      data.association_duration_sec || null
    );

    res.json({ success: true, id: result.lastInsertRowid });
  } catch (err) {
    console.error('Connection event insert error:', err);
    res.status(500).json({ error: 'Failed to record connection event' });
  }
});

// Link Quality Correlation API - organization-wide RSSI vs speed analysis
app.get('/api/stats/link-quality-correlation', (req, res) => {
  const days = Math.min(parseInt(req.query.days) || 7, 30);

  try {
    // Get all data points with link quality metrics
    const data = db.prepare(`
      SELECT
        device_id,
        rssi_dbm,
        mcs_index,
        spatial_streams,
        download_mbps,
        input_error_rate,
        output_error_rate
      FROM speed_results
      WHERE status = 'success'
        AND rssi_dbm < 0
        AND download_mbps > 0
        AND timestamp_utc > datetime('now', '-' || ? || ' days')
    `).all(days);

    // Group by RSSI buckets for analysis
    const rssiBuckets = {};
    for (const row of data) {
      const bucket = Math.floor(row.rssi_dbm / 10) * 10; // -50, -60, -70, etc.
      if (!rssiBuckets[bucket]) {
        rssiBuckets[bucket] = { rssi: bucket, speeds: [], mcs: [], errors: [] };
      }
      rssiBuckets[bucket].speeds.push(row.download_mbps);
      if (row.mcs_index >= 0) rssiBuckets[bucket].mcs.push(row.mcs_index);
      rssiBuckets[bucket].errors.push((row.input_error_rate || 0) + (row.output_error_rate || 0));
    }

    // Calculate averages per bucket
    const bucketStats = Object.values(rssiBuckets).map(b => ({
      rssi_range: `${b.rssi} to ${b.rssi + 9}`,
      rssi_midpoint: b.rssi + 5,
      sample_count: b.speeds.length,
      avg_download: (b.speeds.reduce((a, c) => a + c, 0) / b.speeds.length).toFixed(1),
      avg_mcs: b.mcs.length > 0 ? (b.mcs.reduce((a, c) => a + c, 0) / b.mcs.length).toFixed(1) : 'N/A',
      avg_error_rate: (b.errors.reduce((a, c) => a + c, 0) / b.errors.length).toFixed(4)
    })).sort((a, b) => b.rssi_midpoint - a.rssi_midpoint);

    // Find outliers - good signal but slow speed
    const outliers = data.filter(r =>
      r.rssi_dbm > -60 && r.download_mbps < 30
    ).slice(0, 20).map(r => ({
      device_id: r.device_id.substring(0, 8) + '...',
      rssi: r.rssi_dbm,
      speed: r.download_mbps,
      mcs: r.mcs_index,
      error_rate: ((r.input_error_rate || 0) + (r.output_error_rate || 0)).toFixed(4)
    }));

    res.json({
      period_days: days,
      total_samples: data.length,
      rssi_buckets: bucketStats,
      outliers: {
        count: outliers.length,
        description: 'Devices with good signal (>-60dBm) but slow speeds (<30Mbps)',
        samples: outliers
      },
      scatter_data: data.slice(0, 500).map(r => ({
        rssi: r.rssi_dbm,
        download: r.download_mbps,
        mcs: r.mcs_index,
        error_rate: (r.input_error_rate || 0) + (r.output_error_rate || 0)
      }))
    });
  } catch (err) {
    console.error('Link quality correlation error:', err);
    res.status(500).json({ error: 'Failed to fetch link quality correlation' });
  }
});

// Advanced Diagnosis API - comprehensive multi-factor analysis
app.get('/api/devices/:device_id/diagnose', (req, res) => {
  const { device_id } = req.params;

  try {
    // Get recent metrics
    const recentData = db.prepare(`
      SELECT * FROM speed_results
      WHERE device_id = ? AND status = 'success'
        AND timestamp_utc > datetime('now', '-7 days')
      ORDER BY timestamp_utc DESC
      LIMIT 50
    `).all(device_id);

    if (recentData.length < 3) {
      return res.json({
        device_id,
        diagnosis: null,
        message: 'Insufficient data for diagnosis (need at least 3 tests)'
      });
    }

    // Calculate averages
    const avg = (arr, key) => arr.reduce((sum, r) => sum + (r[key] || 0), 0) / arr.length;

    const avgRSSI = avg(recentData, 'rssi_dbm');
    const avgDownload = avg(recentData, 'download_mbps');
    const avgJitter = avg(recentData, 'jitter_ms');
    const avgPacketLoss = avg(recentData, 'packet_loss_pct');
    const avgInputErrorRate = avg(recentData, 'input_error_rate');
    const avgOutputErrorRate = avg(recentData, 'output_error_rate');
    const validMCS = recentData.filter(r => r.mcs_index >= 0);
    const avgMCS = validMCS.length > 0 ? avg(validMCS, 'mcs_index') : -1;
    const roamCount = recentData.filter(r => r.bssid_changed === 1).length;

    // Calculate issue scores (0-1 scale)
    const issues = [];

    // 1. Weak signal
    if (avgRSSI < -70) {
      issues.push({
        factor: 'weak_signal',
        score: Math.min(1, (-avgRSSI - 70) / 20),
        value: Math.round(avgRSSI),
        threshold: -70,
        unit: 'dBm'
      });
    }

    // 2. High error rate
    const totalErrorRate = avgInputErrorRate + avgOutputErrorRate;
    if (totalErrorRate > 0.005) {
      issues.push({
        factor: 'high_error_rate',
        score: Math.min(1, totalErrorRate / 0.05),
        value: (totalErrorRate * 100).toFixed(3),
        threshold: 0.5,
        unit: '%'
      });
    }

    // 3. MCS below expected
    if (avgMCS >= 0) {
      const expectedMCS = avgRSSI > -50 ? 9 : avgRSSI > -60 ? 7 : avgRSSI > -70 ? 5 : 3;
      const mcsDeficit = expectedMCS - avgMCS;
      if (mcsDeficit > 2) {
        issues.push({
          factor: 'mcs_below_expected',
          score: Math.min(1, mcsDeficit / 5),
          value: avgMCS.toFixed(1),
          expected: expectedMCS,
          deficit: mcsDeficit.toFixed(1)
        });
      }
    }

    // 4. High jitter
    if (avgJitter > 20) {
      issues.push({
        factor: 'high_jitter',
        score: Math.min(1, (avgJitter - 20) / 50),
        value: avgJitter.toFixed(1),
        threshold: 20,
        unit: 'ms'
      });
    }

    // 5. Packet loss
    if (avgPacketLoss > 0.5) {
      issues.push({
        factor: 'packet_loss',
        score: Math.min(1, avgPacketLoss / 5),
        value: avgPacketLoss.toFixed(2),
        threshold: 0.5,
        unit: '%'
      });
    }

    // 6. Excessive roaming
    if (roamCount > 3) {
      issues.push({
        factor: 'excessive_roaming',
        score: Math.min(1, roamCount / 10),
        value: roamCount,
        threshold: 3,
        unit: 'events/week'
      });
    }

    // 7. Low speed despite good signal
    if (avgRSSI > -60 && avgDownload < 50) {
      issues.push({
        factor: 'slow_despite_good_signal',
        score: Math.min(1, (50 - avgDownload) / 50),
        value: avgDownload.toFixed(1),
        rssi: Math.round(avgRSSI),
        unit: 'Mbps'
      });
    }

    // Determine primary issue
    issues.sort((a, b) => b.score - a.score);
    const primaryIssue = issues.length > 0 ? issues[0] : null;

    // Calculate overall confidence
    const totalScore = issues.reduce((sum, i) => sum + i.score, 0);
    const confidence = issues.length > 0 ?
      Math.min(0.95, 0.5 + (primaryIssue.score * 0.3) + (Math.min(issues.length, 3) * 0.05)) : 0.1;

    // Generate recommendations
    const recommendations = [];

    if (issues.find(i => i.factor === 'weak_signal')) {
      recommendations.push('Move closer to the router or add a WiFi extender/mesh node');
    }
    if (issues.find(i => i.factor === 'high_error_rate')) {
      recommendations.push('Check for interference sources (microwave, Bluetooth, neighboring WiFi)');
    }
    if (issues.find(i => i.factor === 'mcs_below_expected')) {
      recommendations.push('Access point may be congested - try switching to a different channel or band');
    }
    if (issues.find(i => i.factor === 'high_jitter')) {
      recommendations.push('Network congestion detected - check for bandwidth-heavy applications');
    }
    if (issues.find(i => i.factor === 'excessive_roaming')) {
      recommendations.push('Device frequently switches between access points - check AP placement or signal overlap');
    }
    if (issues.find(i => i.factor === 'slow_despite_good_signal')) {
      recommendations.push('Good signal but slow speeds suggests AP backhaul or ISP issue - test with wired connection');
    }

    if (recommendations.length === 0) {
      recommendations.push('No significant issues detected - network performance appears normal');
    }

    res.json({
      device_id,
      generated_at: new Date().toISOString(),
      data_points: recentData.length,
      primary_issue: primaryIssue ? primaryIssue.factor : 'none',
      confidence: confidence.toFixed(2),
      factors: issues,
      summary: {
        avg_rssi: Math.round(avgRSSI),
        avg_download: avgDownload.toFixed(1),
        avg_mcs: avgMCS >= 0 ? avgMCS.toFixed(1) : 'N/A',
        avg_error_rate: (totalErrorRate * 100).toFixed(3) + '%',
        roam_count: roamCount
      },
      recommendations
    });
  } catch (err) {
    console.error('Diagnose error:', err);
    res.status(500).json({ error: 'Failed to generate diagnosis' });
  }
});

// Device Data Export (CSV)
app.get('/api/devices/:device_id/export', (req, res) => {
  const { device_id } = req.params;
  const days = Math.min(parseInt(req.query.days) || 30, 90);

  try {
    const results = db.prepare(`
      SELECT * FROM speed_results
      WHERE device_id = ?
        AND timestamp_utc > datetime('now', '-' || ? || ' days')
      ORDER BY timestamp_utc DESC
    `).all(device_id, days);

    if (results.length === 0) {
      return res.status(404).json({ error: 'No data found for device' });
    }

    // Generate CSV
    const headers = Object.keys(results[0]).join(',');
    const rows = results.map(r => Object.values(r).map(v =>
      typeof v === 'string' && v.includes(',') ? `"${v}"` : v
    ).join(','));

    const csv = [headers, ...rows].join('\n');

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename=speed_monitor_${device_id.substring(0, 8)}_${days}d.csv`);
    res.send(csv);
  } catch (err) {
    console.error('Export error:', err);
    res.status(500).json({ error: 'Failed to export data' });
  }
});

// Anomaly Detection Status
app.get('/api/anomalies', (req, res) => {
  const hours = parseInt(req.query.hours) || 24;

  try {
    const recentAlerts = db.prepare(`
      SELECT * FROM alert_history
      WHERE alert_type = 'Anomaly Detected'
        AND triggered_at > datetime('now', '-' || ? || ' hours')
      ORDER BY triggered_at DESC
    `).all(hours);

    const baselines = db.prepare(`
      SELECT * FROM device_baselines
      ORDER BY last_updated DESC
      LIMIT 50
    `).all();

    res.json({ recentAnomalies: recentAlerts, baselines });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch anomaly data' });
  }
});

// Employee self-service portal landing page
app.get('/my', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'my.html'));
});

// Employee self-service portal by email
app.get('/my/:email', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'my-employee.html'));
});

// Self-service portal route (by device ID - for IT admins)
app.get('/device/:device_id', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'my-device.html'));
});

// Serve setup/installation guide
app.get('/setup', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'setup.html'));
});

// Serve dashboard
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
});

// Health check
app.get('/health', (req, res) => {
  try {
    const count = db.prepare('SELECT COUNT(*) as count FROM speed_results').get();
    res.json({
      status: 'ok',
      timestamp: new Date().toISOString(),
      version: '3.1.0',
      features: ['wifi_debugging', 'mcs_tracking', 'error_rates', 'roaming_detection'],
      total_results: count.count
    });
  } catch (err) {
    res.status(500).json({ status: 'error', error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Speed Monitor Server v3.1.0 running on port ${PORT}`);
  console.log(`Dashboard: http://localhost:${PORT}`);
  console.log(`API: http://localhost:${PORT}/api`);
});

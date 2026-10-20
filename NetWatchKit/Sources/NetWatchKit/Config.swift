import Foundation

/// A host:port the monitor will try to open a TCP connection to on every check.
/// Put your kiosk's own backend server here so you can tell "internet is fine but
/// our server is unreachable" apart from "Wi-Fi is down".
public struct ProbeTarget: Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Parses "host:port". The port defaults to 443 when omitted.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let idx = trimmed.lastIndex(of: ":"), let port = UInt16(trimmed[trimmed.index(after: idx)...]) {
            host = String(trimmed[..<idx])
            self.port = port
        } else {
            host = trimmed
            port = 443
        }
    }

    public var label: String { "\(host):\(port)" }
}

public struct NetWatchConfig {
    /// Name used in logs and uploads. Set it per device from MDM (e.g. $SERIALNUMBER / $DEVICENAME).
    public var deviceLabel = ""
    /// Optional HTTP endpoint (see collector/collector.py) that receives log uploads.
    public var collectorURL: URL?
    /// Optional shared secret sent as X-NetWatch-Token to the collector.
    public var collectorToken: String?
    /// URL fetched on every check. Default is Apple's captive-portal check page.
    public var probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    /// Text that must appear in the probe response body; nil means "any 2xx/3xx is fine".
    public var probeExpectBody: String? = "Success"
    /// TCP connect targets checked on every probe.
    public var probeTargets = [ProbeTarget(host: "www.apple.com", port: 443)]
    public var probeInterval: TimeInterval = 60
    /// Faster probing while an outage is in progress, so recovery time is accurate.
    public var outageProbeInterval: TimeInterval = 10
    public var heartbeatInterval: TimeInterval = 30
    public var uploadInterval: TimeInterval = 120
    /// Disable iOS auto-lock while the app runs (screen sleep turns Wi-Fi down).
    public var keepAwake = false
    /// Standalone app only: show this page full screen (web-based kiosks).
    public var kioskURL: URL?
    public var maxFileBytes = 2_000_000
    public var maxFiles = 30

    public init() {}

    public static let managedConfigKey = "com.apple.configuration.managed"

    /// Overlays values pushed by MDM as Managed App Configuration.
    public static func fromManagedConfig(base: NetWatchConfig = NetWatchConfig()) -> NetWatchConfig {
        var c = base
        guard let mc = UserDefaults.standard.dictionary(forKey: managedConfigKey) else { return c }

        func string(_ key: String) -> String? {
            guard let v = mc[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func number(_ key: String) -> Double? {
            if let n = mc[key] as? NSNumber { return n.doubleValue }
            return string(key).flatMap(Double.init)
        }
        func bool(_ key: String) -> Bool? {
            if let b = mc[key] as? Bool { return b }
            return string(key).map { ["true", "yes", "1"].contains($0.lowercased()) }
        }

        if let v = string("deviceLabel") { c.deviceLabel = v }
        if let v = string("collectorURL") { c.collectorURL = URL(string: v) }
        if let v = string("collectorToken") { c.collectorToken = v }
        if let v = string("probeURL"), let url = URL(string: v) {
            c.probeURL = url
            c.probeExpectBody = string("probeExpectBody")
        }
        if let list = mc["probeTargets"] as? [String] {
            c.probeTargets = list.compactMap(ProbeTarget.init(string:))
        } else if let v = string("probeTargets") {
            c.probeTargets = v.split(separator: ",").compactMap { ProbeTarget(string: String($0)) }
        }
        if let v = number("probeIntervalSeconds"), v >= 10 { c.probeInterval = v }
        if let v = number("outageProbeIntervalSeconds"), v >= 5 { c.outageProbeInterval = v }
        if let v = number("heartbeatSeconds"), v >= 10 { c.heartbeatInterval = v }
        if let v = number("uploadIntervalSeconds"), v >= 30 { c.uploadInterval = v }
        if let v = bool("keepAwake") { c.keepAwake = v }
        if let v = string("kioskURL") { c.kioskURL = URL(string: v) }
        return c
    }

    var summary: [String: Any] {
        [
            "device_label": deviceLabel,
            "collector": collectorURL?.absoluteString ?? "none",
            "probe_url": probeURL.absoluteString,
            "probe_targets": probeTargets.map(\.label),
            "probe_interval_s": probeInterval,
            "outage_probe_interval_s": outageProbeInterval,
            "heartbeat_s": heartbeatInterval,
            "keep_awake": keepAwake,
            "kiosk_url": kioskURL?.absoluteString ?? "none",
        ]
    }
}

func orNull(_ value: Any?) -> Any { value ?? NSNull() }

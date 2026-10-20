import Foundation
import MetricKit
import Network
import UIKit

/// Live state for an on-screen diagnostics view. Updated on the main queue.
public final class NetWatchStatus: ObservableObject {
    @Published public internal(set) var pathStatus = "starting"
    @Published public internal(set) var interfaces = ""
    @Published public internal(set) var ssid: String?
    @Published public internal(set) var bssid: String?
    @Published public internal(set) var ipv4: String?
    @Published public internal(set) var lastVerdict = "pending"
    @Published public internal(set) var lastDetail = ""
    @Published public internal(set) var lastProbeTime: Date?
    @Published public internal(set) var outageSince: Date?
    @Published public internal(set) var recentEvents: [LogEvent] = []

    func append(_ event: LogEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 300 { recentEvents.removeLast(recentEvents.count - 300) }
    }
}

/// Network / restart monitor. Call `NetWatch.shared.start()` once from
/// `application(_:didFinishLaunchingWithOptions:)`.
public final class NetWatch {
    public static let shared = NetWatch()

    public let status = NetWatchStatus()
    public private(set) var config = NetWatchConfig()
    public var logDirectory: URL { EventLog.shared.directory }
    public var logFiles: [URL] { EventLog.shared.logFiles() }

    private var started = false
    private let queue = DispatchQueue(label: "netwatch.core")
    private let pathMonitor = NWPathMonitor()

    // Owned by `queue`
    private var lastPathSignature: String?
    private var pathUsesWiFi = false
    private var gateways: [String] = []
    private var prober: Prober?
    private var probeRunning = false
    private var probeRequested = false
    private var nextProbe: DispatchWorkItem?
    private var outageStart: Date?
    private var outageVerdict: String?
    private var lastSSID: String?
    private var lastBSSID: String?
    private var locationAuthorized = false
    private var wifiUnavailableLogged = false

    // Owned by main
    private var wifi: WiFiInfo?
    private var metrics: MetricsSubscriber?
    private var uploader: Uploader?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastHeartbeat: Date?
    private var heartbeatCount = 0
    private var lastBatteryBucket: Int?
    private var persisted = PersistedState()
    private var observers: [NSObjectProtocol] = []

    private init() {}

    public func log(_ type: String, _ message: String, level: LogLevel = .info, data: [String: Any] = [:]) {
        EventLog.shared.log(type, message, level: level, data: data)
    }

    public func start(config: NetWatchConfig = .fromManagedConfig()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true

        var config = config
        if config.deviceLabel.isEmpty {
            let idfv = UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown"
            config.deviceLabel = "ipad-\(idfv)"
        }
        self.config = config
        EventLog.shared.configure(deviceLabel: config.deviceLabel, maxFileBytes: config.maxFileBytes, maxFiles: config.maxFiles)
        EventLog.shared.onEvent = { [weak self] event in self?.status.append(event) }

        UIDevice.current.isBatteryMonitoringEnabled = true
        if config.keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        lastBatteryBucket = DeviceState.batteryLevelPercent().map { $0 / 10 }

        log("monitor_start", "NetWatch started", data: ["config": config.summary, "device": DeviceState.snapshot()])
        analyzePreviousRun()
        observeLifecycle()
        startHeartbeat()

        let metrics = MetricsSubscriber()
        MXMetricManager.shared.add(metrics)
        self.metrics = metrics

        if let url = config.collectorURL {
            let uploader = Uploader(endpoint: url, deviceLabel: config.deviceLabel,
                                    token: config.collectorToken, interval: config.uploadInterval)
            uploader.start()
            self.uploader = uploader
        }
        prober = Prober(config: config)

        let wifi = WiFiInfo()
        wifi.onAuthorizationChange = { [weak self] name, authorized in
            guard let self else { return }
            self.log("location_permission", "Location permission (needed to read Wi-Fi name/AP): \(name)",
                     level: authorized ? .info : .warn, data: ["status": name])
            self.queue.async {
                self.locationAuthorized = authorized
                self.refreshWiFi(trigger: "permission_change")
            }
        }
        wifi.requestAuthorizationIfNeeded()
        self.wifi = wifi

        pathMonitor.pathUpdateHandler = { [weak self] path in self?.handlePath(path) }
        pathMonitor.start(queue: queue)
        queue.async { self.scheduleProbe(after: 2) }
    }

    /// Run a connectivity check right away.
    public func probeNow() {
        queue.async { self.scheduleProbe(after: 0) }
    }

    // MARK: - Network path (queue)

    private func handlePath(_ path: NWPath) {
        let info = PathInfo(path)
        pathUsesWiFi = path.usesInterfaceType(.wifi)
        gateways = info.gateways
        DispatchQueue.main.async {
            self.status.pathStatus = info.status
            self.status.interfaces = info.interfaceSummary
        }

        guard info.signature != lastPathSignature else { return }
        let first = lastPathSignature == nil
        lastPathSignature = info.signature

        var data = info.dict
        data["addresses"] = Interfaces.summary()
        let reason = info.unsatisfiedReason.map { " (reason: \($0))" } ?? ""
        log(first ? "network_initial" : "network_change",
            "Network \(info.status) via \(info.interfaceSummary.isEmpty ? "no interface" : info.interfaceSummary)\(reason)",
            level: path.status == .satisfied ? .info : .warn,
            data: data)

        refreshWiFi(trigger: "path_change")
        scheduleProbe(after: 2)
    }

    // MARK: - Wi-Fi association / roaming (queue)

    private func refreshWiFi(trigger: String) {
        WiFiInfo.fetchCurrent { [weak self] ssid, bssid in
            self?.queue.async { self?.handleWiFi(ssid: ssid, bssid: bssid, trigger: trigger) }
        }
    }

    private func handleWiFi(ssid: String?, bssid: String?, trigger: String) {
        DispatchQueue.main.async {
            self.status.ssid = ssid
            self.status.bssid = bssid
        }

        if ssid == nil && pathUsesWiFi && !locationAuthorized {
            if !wifiUnavailableLogged {
                wifiUnavailableLogged = true
                log("wifi_info_unavailable",
                    "Wi-Fi name/AP not readable: allow location access for this app and check the Access WiFi Information entitlement",
                    level: .warn)
            }
            return
        }
        guard ssid != lastSSID || bssid != lastBSSID else { return }

        let data: [String: Any] = [
            "ssid": orNull(ssid), "bssid": orNull(bssid),
            "previous_ssid": orNull(lastSSID), "previous_bssid": orNull(lastBSSID),
            "trigger": trigger, "wifi_ipv4": orNull(Interfaces.wifiIPv4()),
        ]
        switch (lastSSID, ssid) {
        case (nil, let new?):
            log("wifi_joined", "Joined Wi-Fi \"\(new)\" via AP \(bssid ?? "?")", data: data)
        case (let old?, nil):
            log("wifi_lost", "Lost Wi-Fi association (was \"\(old)\" on AP \(lastBSSID ?? "?"))", level: .warn, data: data)
        case (let old?, let new?) where old != new:
            log("wifi_network_changed", "Wi-Fi changed from \"\(old)\" to \"\(new)\"", level: .warn, data: data)
        default:
            log("wifi_roam", "Roamed to AP \(bssid ?? "?") (from \(lastBSSID ?? "?")) on \"\(ssid ?? "?")\"", data: data)
        }
        lastSSID = ssid
        lastBSSID = bssid
    }

    // MARK: - Connectivity probes (queue)

    private func scheduleProbe(after delay: TimeInterval) {
        nextProbe?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runProbe() }
        nextProbe = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runProbe() {
        guard let prober else { return }
        if probeRunning {
            probeRequested = true
            return
        }
        probeRunning = true
        prober.run { [weak self] result in
            self?.queue.async { self?.handleProbe(result) }
        }
    }

    private func handleProbe(_ result: ProbeResult) {
        probeRunning = false
        let now = Date()
        var data = result.data
        data["verdict"] = result.verdict
        data["gateways"] = gateways
        data["ssid"] = orNull(lastSSID)
        data["bssid"] = orNull(lastBSSID)

        if result.ok {
            if let start = outageStart {
                let seconds = Int(now.timeIntervalSince(start))
                data["duration_s"] = seconds
                data["outage_start"] = start
                data["cause"] = orNull(outageVerdict)
                log("outage_end", "Connectivity restored after \(seconds)s (was: \(outageVerdict ?? "?"))", level: .warn, data: data)
                outageStart = nil
                outageVerdict = nil
                uploader?.kick()
            } else {
                log("probe_ok", result.detail, level: .debug, data: data)
            }
        } else if outageStart == nil {
            outageStart = now
            outageVerdict = result.verdict
            log("outage_start", "Connectivity problem: \(result.verdict): \(result.detail)", level: .error, data: data)
        } else if result.verdict != outageVerdict {
            log("outage_update", "Still down, now: \(result.verdict): \(result.detail)", level: .error, data: data)
            outageVerdict = result.verdict
        } else {
            log("probe_fail", result.detail, level: .debug, data: data)
        }

        refreshWiFi(trigger: "probe")

        let outage = outageStart
        DispatchQueue.main.async {
            self.status.lastVerdict = result.verdict
            self.status.lastDetail = result.detail
            self.status.lastProbeTime = now
            self.status.outageSince = outage
            self.status.ipv4 = result.data["wifi_ipv4"] as? String
            self.persisted.lastNetVerdict = result.verdict
        }

        if probeRequested {
            probeRequested = false
            scheduleProbe(after: 1)
        } else {
            scheduleProbe(after: outageStart == nil ? config.probeInterval : config.outageProbeInterval)
        }
    }

    // MARK: - Restart analysis (main)

    private func analyzePreviousRun() {
        let prev = PersistedState.load()
        persisted = prev
        persisted.launchCount = prev.launchCount + 1
        defer { savePersisted() }

        let now = Date()
        let boot = DeviceState.bootTime()
        guard let prevHeartbeat = prev.lastHeartbeat else {
            log("first_launch", "First run of NetWatch on this device", data: ["boot_time": orNull(boot)])
            return
        }

        let lastSeen = Date(timeIntervalSince1970: prevHeartbeat)
        var data: [String: Any] = [
            "last_seen": lastSeen,
            "boot_time": orNull(boot),
            "app_launched_after_boot_s": orNull(boot.map { Int(now.timeIntervalSince($0)) }),
            "previous_os": orNull(prev.osVersion),
            "previous_app_version": orNull(prev.appVersion),
            "previous_app_state": orNull(prev.lastAppState),
            "previous_battery_pct": orNull(prev.lastBattery),
            "previous_battery_state": orNull(prev.lastBatteryState),
            "previous_thermal": orNull(prev.lastThermal),
            "previous_network": orNull(prev.lastNetVerdict),
        ]

        var rebooted = false
        if let boot, let prevBoot = prev.bootTime {
            rebooted = abs(boot.timeIntervalSince1970 - prevBoot) > 60
        }

        if rebooted, let boot {
            var clues: [String] = []
            let currentOS = UIDevice.current.systemVersion
            if let oldOS = prev.osVersion, oldOS != currentOS {
                clues.append("iOS was updated \(oldOS) -> \(currentOS); the restart was part of the update")
            }
            if let battery = prev.lastBattery, battery <= 5,
               prev.lastBatteryState != "charging", prev.lastBatteryState != "full" {
                clues.append("Battery was at \(battery)% and not charging: the device most likely ran flat (check charger, cable and outlet)")
            }
            if let thermal = prev.lastThermal, thermal == "serious" || thermal == "critical" {
                clues.append("Device was overheating (\(thermal)) before the restart")
            }
            let passcode = prev.passcodeSet ?? DeviceState.passcodeSet()
            data["passcode_set"] = passcode
            data["last_unlock"] = orNull(prev.lastUnlockTime.map { Date(timeIntervalSince1970: $0) })
            if let offSince = prev.lastLockTime ?? prev.lastBackgroundTime {
                let offFor = boot.timeIntervalSince1970 - offSince
                data["locked_before_boot_s"] = Int(offFor)
                if passcode && prev.lastLockTime != nil && offFor > 60 * 3600 && offFor < 84 * 3600 {
                    clues.insert("Device had been locked for \(Self.duration(offFor)) before it restarted: matches the iOS inactivity reboot (72 hours locked without an unlock)", at: 0)
                } else {
                    clues.append("Screen was locked/off for \(Self.duration(offFor)) before the restart")
                }
            }
            let launchDelay = now.timeIntervalSince(boot)
            if passcode && launchDelay > 300 {
                clues.insert("After the restart the app could not start for \(Self.duration(launchDelay)): the iPad was waiting at the passcode screen (Before First Unlock). Saved Wi-Fi is unavailable in that state, so the device stays offline until someone enters the passcode", at: 0)
            }
            let silent = boot.timeIntervalSince(lastSeen)
            data["silent_before_boot_s"] = Int(silent)
            if silent < 300 {
                clues.append("Restart came \(Int(max(0, silent)))s after the last heartbeat while the app was \(prev.lastAppState ?? "?"): sudden reboot (kernel panic/watchdog), forced restart, or an MDM Restart command. Check MDM command history and sysdiagnose for panic-full-*.ips")
            } else {
                clues.append("Monitor was silent for \(Self.duration(silent)) before boot: the device was asleep, the app was not running, or the device was powered off")
            }
            data["clues"] = clues
            log("device_rebooted", "Device restarted at \(EventLog.isoFormatter.string(from: boot)). \(clues.first ?? "")",
                level: .warn, data: data)
        } else if prev.appVersion != nil && prev.appVersion != DeviceState.appVersion {
            log("app_updated", "App updated \(prev.appVersion ?? "?") -> \(DeviceState.appVersion)", data: data)
        } else if prev.lastAppState == "active" || prev.lastAppState == "inactive" {
            log("app_relaunched_unexpectedly",
                "App stopped while on screen without a device restart (crash, memory kill, watchdog, or terminated by iOS/MDM). Watch for metrickit_crash events with the exact cause.",
                level: .error, data: data)
        } else {
            log("app_relaunched", "App relaunched; last run ended normally (\(prev.lastAppState ?? "?"))", data: data)
        }
        persisted.lastLockTime = nil
        persisted.lastBackgroundTime = nil
    }

    // MARK: - Heartbeat (main)

    private func startHeartbeat() {
        lastHeartbeat = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + config.heartbeatInterval, repeating: config.heartbeatInterval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.heartbeat() }
        t.resume()
        heartbeatTimer = t
    }

    private func heartbeat() {
        let now = Date()
        if let last = lastHeartbeat, now.timeIntervalSince(last) > config.heartbeatInterval * 3 {
            let gap = now.timeIntervalSince(last)
            log("monitor_gap",
                "No activity for \(Self.duration(gap)): app was suspended or the device was asleep/locked",
                level: .warn, data: ["from": last, "to": now, "seconds": Int(gap)])
        }
        lastHeartbeat = now
        heartbeatCount += 1
        if heartbeatCount % max(1, Int(600 / config.heartbeatInterval)) == 0 {
            log("status", "Periodic status", data: DeviceState.snapshot())
        }
        savePersisted(now)
    }

    private func savePersisted(_ now: Date = Date()) {
        persisted.lastHeartbeat = now.timeIntervalSince1970
        persisted.bootTime = DeviceState.bootTime()?.timeIntervalSince1970
        persisted.osVersion = UIDevice.current.systemVersion
        persisted.appVersion = DeviceState.appVersion
        persisted.lastBattery = DeviceState.batteryLevelPercent()
        persisted.lastBatteryState = DeviceState.batteryStateName(UIDevice.current.batteryState)
        persisted.lastThermal = DeviceState.thermalName(ProcessInfo.processInfo.thermalState)
        persisted.lastAppState = DeviceState.appStateName(UIApplication.shared.applicationState)
        persisted.passcodeSet = DeviceState.passcodeSet()
        persisted.save()
    }

    // MARK: - Lifecycle & power (main)

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
        }

        on(UIApplication.didBecomeActiveNotification) { [weak self] in
            self?.log("app_active", "App became active")
            self?.persisted.lastBackgroundTime = nil
            self?.savePersisted()
            self?.probeNow()
        }
        on(UIApplication.willResignActiveNotification) { [weak self] in
            self?.log("app_inactive", "App resigning active (screen lock, alert, or switching away)")
        }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.log("app_background", "App moved to background: in Single App Mode this usually means the screen locked or the kiosk was exited",
                      level: .warn, data: DeviceState.snapshot())
            self?.persisted.lastBackgroundTime = Date().timeIntervalSince1970
            self?.savePersisted()
            EventLog.shared.flush()
        }
        on(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.log("app_foreground", "App returning to foreground")
        }
        on(UIApplication.willTerminateNotification) { [weak self] in
            guard let self else { return }
            self.log("app_terminate", "App is being terminated by iOS", level: .warn)
            self.savePersisted()
            self.persisted.lastAppState = "terminated"
            self.persisted.save()
            EventLog.shared.flush()
        }
        on(UIApplication.didReceiveMemoryWarningNotification) { [weak self] in
            self?.log("memory_warning", "iOS memory warning (app may be killed if it continues)", level: .warn,
                      data: ["app_memory_mb": orNull(DeviceState.memoryFootprintMB())])
        }
        on(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
            guard let self else { return }
            self.log("device_locked", "Device locked with a passcode. iOS will restart it if it stays locked for 72 hours", level: .warn)
            self.persisted.lastLockTime = Date().timeIntervalSince1970
            self.persisted.save()
            EventLog.shared.flush()
        }
        on(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
            guard let self else { return }
            self.log("device_unlocked", "Device unlocked")
            self.persisted.lastLockTime = nil
            self.persisted.lastUnlockTime = Date().timeIntervalSince1970
            self.persisted.save()
        }
        on(UIApplication.significantTimeChangeNotification) { [weak self] in
            self?.log("clock_change", "Significant time change (midnight, time zone, or clock adjusted)")
        }
        on(UIDevice.batteryStateDidChangeNotification) { [weak self] in
            let state = DeviceState.batteryStateName(UIDevice.current.batteryState)
            self?.log("battery_state", "Battery is now \(state) at \(DeviceState.batteryLevelPercent().map { "\($0)%" } ?? "?")",
                      level: state == "unplugged" ? .warn : .info)
        }
        on(UIDevice.batteryLevelDidChangeNotification) { [weak self] in
            guard let self, let pct = DeviceState.batteryLevelPercent() else { return }
            let bucket = pct / 10
            if bucket != self.lastBatteryBucket || pct <= 10 {
                self.lastBatteryBucket = bucket
                self.log("battery_level", "Battery \(pct)%", level: pct <= 15 ? .warn : .info)
            }
        }
        on(.NSProcessInfoPowerStateDidChange) { [weak self] in
            let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.log("low_power_mode", "Low Power Mode \(enabled ? "ON (background network activity reduced)" : "off")",
                      level: enabled ? .warn : .info)
        }
        on(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            let t = DeviceState.thermalName(ProcessInfo.processInfo.thermalState)
            self?.log("thermal_state", "Thermal state: \(t)", level: (t == "serious" || t == "critical") ? .warn : .info)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 120 { return "\(s)s" }
        if s < 7200 { return "\(s / 60)m" }
        return String(format: "%.1fh", Double(s) / 3600)
    }
}

/// Flattened NWPath for logging and change detection.
private struct PathInfo {
    let status: String
    let unsatisfiedReason: String?
    let interfaceSummary: String
    let gateways: [String]
    let dict: [String: Any]
    let signature: String

    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires_connection"
        @unknown default: status = "unknown"
        }

        if path.status == .satisfied {
            unsatisfiedReason = nil
        } else {
            switch path.unsatisfiedReason {
            case .notAvailable: unsatisfiedReason = "not_available"
            case .cellularDenied: unsatisfiedReason = "cellular_denied"
            case .wifiDenied: unsatisfiedReason = "wifi_denied_by_settings"
            case .localNetworkDenied: unsatisfiedReason = "local_network_permission_denied"
            @unknown default: unsatisfiedReason = "other"
            }
        }

        let ifaces = path.availableInterfaces.map { iface -> String in
            let type: String
            switch iface.type {
            case .wifi: type = "wifi"
            case .cellular: type = "cellular"
            case .wiredEthernet: type = "ethernet"
            case .loopback: type = "loopback"
            case .other: type = "other"
            @unknown default: type = "unknown"
            }
            return "\(iface.name)/\(type)"
        }
        interfaceSummary = ifaces.joined(separator: ", ")
        gateways = path.gateways.map { "\($0)" }

        dict = [
            "status": status,
            "unsatisfied_reason": orNull(unsatisfiedReason),
            "interfaces": ifaces,
            "gateways": gateways,
            "ipv4": path.supportsIPv4,
            "ipv6": path.supportsIPv6,
            "dns": path.supportsDNS,
            "expensive": path.isExpensive,
            "constrained": path.isConstrained,
        ]
        signature = [status, unsatisfiedReason ?? "", interfaceSummary, gateways.joined(separator: ","),
                     "\(path.supportsIPv4)", "\(path.supportsIPv6)", "\(path.supportsDNS)"].joined(separator: "|")
    }
}

import Foundation
import LocalAuthentication
import UIKit

enum DeviceState {
    /// Kernel boot time. Changes only when the device restarts.
    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var hardwareModel: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func batteryLevelPercent() -> Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    static func batteryStateName(_ s: UIDevice.BatteryState) -> String {
        switch s {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func appStateName(_ s: UIApplication.State) -> String {
        switch s {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// True when the device has a passcode. With a passcode, any restart leaves the
    /// iPad in "Before First Unlock" until someone types it in.
    static func passcodeSet() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func freeDiskMB() -> Int? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0 / 1_048_576) }
    }

    static func memoryFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// Main thread only.
    static func snapshot() -> [String: Any] {
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        return [
            "model": hardwareModel,
            "os": "\(device.systemName) \(device.systemVersion)",
            "app_version": appVersion,
            "battery_pct": orNull(batteryLevelPercent()),
            "battery_state": batteryStateName(device.batteryState),
            "low_power_mode": process.isLowPowerModeEnabled,
            "thermal": thermalName(process.thermalState),
            "uptime_s": Int(process.systemUptime),
            "boot_time": orNull(bootTime()),
            "app_state": appStateName(UIApplication.shared.applicationState),
            "idle_timer_disabled": UIApplication.shared.isIdleTimerDisabled,
            "passcode_set": passcodeSet(),
            "free_disk_mb": orNull(freeDiskMB()),
            "app_memory_mb": orNull(memoryFootprintMB()),
            "addresses": Interfaces.summary(),
        ]
    }
}

/// What we knew at the last heartbeat. Read on the next launch to explain restarts.
struct PersistedState: Codable {
    var launchCount = 0
    var bootTime: Double?
    var lastHeartbeat: Double?
    var osVersion: String?
    var appVersion: String?
    var lastBattery: Int?
    var lastBatteryState: String?
    var lastThermal: String?
    var lastAppState: String?
    var lastNetVerdict: String?
    var passcodeSet: Bool?
    /// Set when the device locks / the app leaves the screen; cleared when it comes back.
    var lastLockTime: Double?
    var lastBackgroundTime: Double?
    var lastUnlockTime: Double?

    private static let key = "NetWatch.persistedState"

    static func load() -> PersistedState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

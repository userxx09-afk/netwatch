import CoreLocation
import NetworkExtension

/// Wi-Fi network name (SSID) and access point (BSSID).
/// iOS only returns these when the app has the "Access WiFi Information" entitlement
/// AND location permission. Signal strength (RSSI) is not available to normal apps.
final class WiFiInfo: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: ((String, Bool) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        onAuthorizationChange?(Self.name(status), authorized)
    }

    static func name(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when_in_use"
        @unknown default: return "unknown"
        }
    }

    static func fetchCurrent(_ completion: @escaping (_ ssid: String?, _ bssid: String?) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            completion(network?.ssid, network?.bssid)
        }
    }
}

import Foundation
import Network

struct ProbeResult {
    /// ok, no_ip_address, dhcp_failure, dns_failure, internet_unreachable,
    /// http_failure, captive_portal_or_proxy, target_unreachable
    var verdict: String
    var detail: String
    var data: [String: Any]
    var ok: Bool { verdict == "ok" }
}

/// Walks the connectivity ladder so a failure says *where* it broke:
/// IP address -> DHCP -> DNS -> TCP -> HTTP (captive portal) -> your own servers.
final class Prober {
    private let config: NetWatchConfig
    private let queue = DispatchQueue(label: "netwatch.probe")
    private let session: URLSession

    init(config: NetWatchConfig) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func run(completion: @escaping (ProbeResult) -> Void) {
        queue.async { completion(self.runBlocking()) }
    }

    private func runBlocking() -> ProbeResult {
        var data: [String: Any] = [:]

        // 1. Do we have an address at all?
        let addrs = Interfaces.addresses()
        let wifiV4 = addrs.first { $0.name == "en0" && $0.family == "ipv4" }?.address
        let otherV4 = addrs
            .filter { $0.family == "ipv4" && $0.name != "en0" && Interfaces.isInteresting($0.name) }
            .map { "\($0.name)=\($0.address)" }
        data["wifi_ipv4"] = orNull(wifiV4)
        data["other_ipv4"] = otherV4

        if wifiV4 == nil && otherV4.isEmpty {
            return ProbeResult(
                verdict: "no_ip_address",
                detail: "No IPv4 address on Wi-Fi or any other interface: not joined to Wi-Fi, Wi-Fi off, or DHCP never answered",
                data: data)
        }
        if let ip = wifiV4, ip.hasPrefix("169.254.") {
            return ProbeResult(
                verdict: "dhcp_failure",
                detail: "Wi-Fi has self-assigned address \(ip): joined the access point but DHCP did not answer (scope exhausted, VLAN, NAC/MAC filtering, or private Wi-Fi address changed)",
                data: data)
        }

        // 2. DNS
        let host = config.probeURL.host ?? "captive.apple.com"
        let dns = resolve(host, timeout: 8)
        data["dns_host"] = host
        data["dns_ms"] = dns.ms
        data["dns_addresses"] = dns.addresses
        if let e = dns.error { data["dns_error"] = e }

        // 3. TCP to each target
        var tcp: [[String: Any]] = []
        var failedTargets: [String] = []
        for target in config.probeTargets {
            let r = tcpConnect(target, timeout: 8)
            tcp.append(["target": target.label, "ms": r.ms, "error": orNull(r.error)])
            if r.error != nil { failedTargets.append(target.label) }
        }
        data["tcp"] = tcp
        let tcpOK = config.probeTargets.count - failedTargets.count

        if let e = dns.error {
            if tcpOK > 0 {
                return ProbeResult(verdict: "dns_failure",
                                   detail: "DNS lookup of \(host) failed (\(e)) but TCP to \(tcpOK) target(s) works: DNS server problem",
                                   data: data)
            }
            return ProbeResult(verdict: "dns_failure",
                               detail: "DNS lookup of \(host) failed (\(e)) and no TCP target is reachable: gateway or upstream link is likely down",
                               data: data)
        }

        // 4. HTTP (catches captive portals / web filters)
        let http = httpCheck()
        data["http_status"] = orNull(http.status)
        data["http_ms"] = http.ms
        data["http_body_ok"] = http.bodyOK
        if let e = http.error { data["http_error"] = e }
        if let c = http.code { data["http_error_code"] = c }

        if http.error == nil && !http.bodyOK {
            return ProbeResult(verdict: "captive_portal_or_proxy",
                               detail: "Probe URL answered HTTP \(http.status ?? 0) with unexpected content: a captive portal, web filter or proxy is intercepting traffic",
                               data: data)
        }
        if let e = http.error {
            if tcpOK == 0 {
                return ProbeResult(verdict: "internet_unreachable",
                                   detail: "DNS works but HTTP and all TCP targets fail (\(e)): no route upstream or blocked by firewall",
                                   data: data)
            }
            return ProbeResult(verdict: "http_failure", detail: "HTTP probe failed (\(e)) while some TCP targets work", data: data)
        }
        if !failedTargets.isEmpty {
            return ProbeResult(verdict: "target_unreachable",
                               detail: "Internet works but cannot reach: \(failedTargets.joined(separator: ", "))",
                               data: data)
        }
        return ProbeResult(verdict: "ok",
                           detail: "IP \(wifiV4 ?? otherV4.first ?? "?"), DNS \(dns.ms)ms, HTTP \(http.ms)ms",
                           data: data)
    }

    // MARK: - Steps

    private func resolve(_ host: String, timeout: TimeInterval) -> (ms: Int, addresses: [String], error: String?) {
        let start = Date()
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var addresses: [String] = []
        var error: String?

        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, nil, &hints, &res)
            var found: [String] = []
            var err: String?
            if rc != 0 {
                err = String(cString: gai_strerror(rc))
            } else {
                var p = res
                while let ai = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        found.append(String(cString: buf))
                    }
                    p = ai.pointee.ai_next
                }
                freeaddrinfo(res)
            }
            lock.lock()
            addresses = Array(Set(found)).sorted()
            error = err
            lock.unlock()
            sem.signal()
        }

        let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if timedOut { return (ms, [], "timeout after \(Int(timeout))s") }
        lock.lock()
        defer { lock.unlock() }
        return (ms, addresses, error)
    }

    private func tcpConnect(_ target: ProbeTarget, timeout: TimeInterval) -> (ms: Int, error: String?) {
        let start = Date()
        let sem = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "netwatch.tcp")
        var result: String?
        var finished = false

        let conn = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port) ?? 443,
            using: .tcp)

        func finish(_ error: String?) {
            guard !finished else { return }
            finished = true
            result = error
            sem.signal()
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(nil)
            case .failed(let e): finish(e.debugDescription)
            case .waiting(let e): finish("waiting: \(e.debugDescription)")
            default: break
            }
        }
        conn.start(queue: q)

        let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
        conn.cancel()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return q.sync { (ms, timedOut ? "timeout after \(Int(timeout))s" : result) }
    }

    private func httpCheck() -> (status: Int?, ms: Int, error: String?, code: Int?, bodyOK: Bool) {
        var req = URLRequest(url: config.probeURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.setValue("NetWatch", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        let start = Date()
        var status: Int?
        var err: Error?
        var body: Data?
        let task = session.dataTask(with: req) { d, r, e in
            status = (r as? HTTPURLResponse)?.statusCode
            err = e
            body = d
            sem.signal()
        }
        task.resume()

        let timedOut = sem.wait(timeout: .now() + 15) == .timedOut
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if timedOut {
            task.cancel()
            return (nil, ms, "timeout", nil, false)
        }
        if let err {
            let ns = err as NSError
            return (status, ms, ns.localizedDescription, ns.code, false)
        }

        let bodyOK: Bool
        if let expect = config.probeExpectBody {
            bodyOK = body.map { String(decoding: $0, as: UTF8.self).contains(expect) } ?? false
        } else {
            bodyOK = (200..<400).contains(status ?? 0)
        }
        return (status, ms, nil, nil, bodyOK)
    }
}

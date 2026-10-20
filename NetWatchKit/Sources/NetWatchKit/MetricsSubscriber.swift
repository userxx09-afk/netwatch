import Foundation
import MetricKit

/// iOS's own record of why the app died (crash, memory limit, watchdog, ...).
/// Diagnostics arrive on the next launch; exit counts arrive about once a day.
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            var data: [String: Any] = ["range_start": p.timeStampBegin, "range_end": p.timeStampEnd]
            if let exits = p.applicationExitMetrics { data["exits"] = json(exits.jsonRepresentation()) }
            if let net = p.networkTransferMetrics { data["network_transfer"] = json(net.jsonRepresentation()) }
            EventLog.shared.log("metrickit_daily", "Daily app-exit report from iOS", data: data)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                let reason = c.terminationReason ?? "-"
                let exception = c.exceptionType?.stringValue ?? "-"
                let signal = c.signal?.stringValue ?? "-"
                EventLog.shared.log("metrickit_crash",
                                    "App crashed (exception \(exception), signal \(signal)): \(reason)",
                                    level: .error,
                                    data: ["diagnostic": json(c.jsonRepresentation())])
            }
            for h in p.hangDiagnostics ?? [] {
                EventLog.shared.log("metrickit_hang", "App hung for \(h.hangDuration)", level: .warn,
                                    data: ["diagnostic": json(h.jsonRepresentation())])
            }
        }
    }

    private func json(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    }
}

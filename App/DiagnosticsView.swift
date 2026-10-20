import NetWatchKit
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var status: NetWatchStatus
    let canReturnToKiosk: Bool
    let returnToKiosk: () -> Void
    @State private var files: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Now") {
                    row("Device", NetWatch.shared.config.deviceLabel)
                    row("Network path", status.pathStatus)
                    row("Interfaces", status.interfaces.isEmpty ? "none" : status.interfaces)
                    row("Wi-Fi", status.ssid.map { "\($0)  (AP \(status.bssid ?? "?"))" } ?? "unknown")
                    row("Wi-Fi IPv4", status.ipv4 ?? "none")
                    row("Last check", status.lastVerdict)
                    if !status.lastDetail.isEmpty {
                        Text(status.lastDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let checked = status.lastProbeTime {
                        row("Checked at", checked.formatted(date: .omitted, time: .standard))
                    }
                    if let since = status.outageSince {
                        row("Outage since", since.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.red)
                    }
                }
                Section("Events (newest first)") {
                    ForEach(status.recentEvents) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.time, style: .time).font(.caption.monospacedDigit())
                                Text(event.type).font(.caption.bold()).foregroundStyle(color(event.level))
                            }
                            Text(event.message).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("NetWatch")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Check now") { NetWatch.shared.probeNow() }
                    ShareLink(items: files) { Label("Export logs", systemImage: "square.and.arrow.up") }
                    if canReturnToKiosk {
                        Button("Back to kiosk", action: returnToKiosk)
                    }
                }
            }
            .onAppear { files = NetWatch.shared.logFiles }
            .refreshable {
                files = NetWatch.shared.logFiles
                NetWatch.shared.probeNow()
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

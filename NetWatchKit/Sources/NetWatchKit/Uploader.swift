import Foundation

/// Ships log lines to the collector. Keeps a (file, byte offset) cursor so
/// everything recorded during an outage is sent once the network is back.
final class Uploader {
    private let endpoint: URL
    private let deviceLabel: String
    private let token: String?
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "netwatch.upload")
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private let maxChunk = 256 * 1024
    private let cursorFileKey = "NetWatch.upload.file"
    private let cursorOffsetKey = "NetWatch.upload.offset"

    init(endpoint: URL, deviceLabel: String, token: String?, interval: TimeInterval) {
        self.endpoint = endpoint
        self.deviceLabel = deviceLabel
        self.token = token
        self.interval = interval
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: interval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.uploadNext() }
        t.resume()
        timer = t
    }

    func kick() {
        queue.async { self.uploadNext() }
    }

    private func uploadNext() {
        guard !inFlight else { return }
        let files = EventLog.shared.logFiles()
        guard !files.isEmpty else { return }

        let defaults = UserDefaults.standard
        var offset = UInt64(max(0, defaults.integer(forKey: cursorOffsetKey)))
        var index = 0
        if let name = defaults.string(forKey: cursorFileKey) {
            if let i = files.firstIndex(where: { $0.lastPathComponent == name }) {
                index = i
            } else {
                // Cursor file was pruned: resume at the next newer file.
                index = files.firstIndex { $0.lastPathComponent > name } ?? 0
                offset = 0
            }
        } else {
            offset = 0
        }

        while index < files.count {
            let url = files[index]
            let isLast = index == files.count - 1
            guard let chunk = readChunk(url, offset: offset), !chunk.isEmpty else {
                if isLast { return }
                index += 1
                offset = 0
                continue
            }
            // Only send whole lines; the active file may end mid-write.
            guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
                if isLast || chunk.count >= maxChunk { return }
                index += 1
                offset = 0
                continue
            }
            let body = Data(chunk[chunk.startIndex...lastNewline])
            send(body, file: url.lastPathComponent, newOffset: offset + UInt64(body.count))
            return
        }
    }

    private func readChunk(_ url: URL, offset: UInt64) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            return try h.read(upToCount: maxChunk)
        } catch {
            return nil
        }
    }

    private func send(_ body: Data, file: String, newOffset: UInt64) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceLabel, forHTTPHeaderField: "X-NetWatch-Device")
        if let token { req.setValue(token, forHTTPHeaderField: "X-NetWatch-Token") }
        req.httpBody = body
        inFlight = true

        session.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.inFlight = false
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200..<300).contains(code) else { return }
                UserDefaults.standard.set(file, forKey: self.cursorFileKey)
                UserDefaults.standard.set(Int(newOffset), forKey: self.cursorOffsetKey)
                self.uploadNext()
            }
        }.resume()
    }
}

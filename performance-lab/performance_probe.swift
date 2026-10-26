// CI-only instrumentation. Append to OpenClientPerformanceDiagnostics.swift and
// call startIfEnabled() on the main actor before the existing watchdog guard.
// This is a responsiveness probe, not a rendered-frame/FPS measurement.
#if canImport(UIKit)
import QuartzCore

@MainActor
final class OpenClientLabPerformanceProbe: NSObject {
    // CI-only runtime switch: both benchmark labels use the same app binary.
    static let baselinePublication = ProcessInfo.processInfo.environment["OPENCLIENT_LAB_PROBE_VARIANT"] == "baseline"
    private static var instance: OpenClientLabPerformanceProbe?
    private let writer: OpenClientLabProbeWriter
    private var displayLink: CADisplayLink?
    private var lastCallback: TimeInterval?
    private var isActive = true

    static func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["OPENCLIENT_LAB_PROBE"] == "1", instance == nil,
              let writer = OpenClientLabProbeWriter() else { return }
        instance = OpenClientLabPerformanceProbe(writer: writer)
    }

    private init(writer: OpenClientLabProbeWriter) {
        self.writer = writer
        super.init()
        let environment = ProcessInfo.processInfo.environment
        let uptimeBefore = ProcessInfo.processInfo.systemUptime
        let epoch = Date().timeIntervalSince1970
        let media = CACurrentMediaTime()
        let uptimeAfter = ProcessInfo.processInfo.systemUptime
        let metadata: [String: Any] = [
            "kind": "metadata", "schema": 1,
            "variant": environment["OPENCLIENT_LAB_PROBE_VARIANT"] ?? "unspecified",
            "trial": environment["OPENCLIENT_LAB_PROBE_TRIAL"] ?? "unspecified",
            "publication_path": Self.baselinePublication ? "legacy_normalized" : "reduced_direct",
            "uptime_before_s": uptimeBefore, "epoch_s": epoch,
            "media_time_s": media, "uptime_after_s": uptimeAfter,
            "requested_callback_hz": 60, "heartbeat_interval_ms": 50,
            "scope": "Simulator callback entry gaps and sampled main-queue scheduling delays; not rendered FPS, keyboard latency, device heat, or Release-device performance."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { writer.append(line) }

        let link = CADisplayLink(target: self, selector: #selector(frameCallback(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        startHeartbeat()
    }

    @objc private func frameCallback(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastCallback = isActive ? now : nil }
        guard isActive, let previous = lastCallback else { return }
        let gapMS = (now - previous) * 1_000
        let intervalMS = (link.targetTimestamp - link.timestamp) * 1_000
        writer.append("{\"kind\":\"callback\",\"start_uptime_s\":\(previous),\"end_uptime_s\":\(now),\"gap_ms\":\(gapMS),\"display_interval_ms\":\(intervalMS)}")
    }

    @objc private func resignActive() {
        isActive = false
        lastCallback = nil
        writer.append("{\"kind\":\"inactive\",\"uptime_s\":\(ProcessInfo.processInfo.systemUptime)}")
    }

    @objc private func becomeActive() {
        isActive = true
        lastCallback = nil
        writer.append("{\"kind\":\"active\",\"uptime_s\":\(ProcessInfo.processInfo.systemUptime)}")
    }

    private func startHeartbeat() {
        let writer = writer
        let thread = Thread { [weak self] in
            while true {
                let posted = ProcessInfo.processInfo.systemUptime
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { [weak self] in
                    defer { semaphore.signal() }
                    guard let self, self.isActive else { return }
                    let handled = ProcessInfo.processInfo.systemUptime
                    writer.append("{\"kind\":\"heartbeat\",\"start_uptime_s\":\(posted),\"end_uptime_s\":\(handled),\"delay_ms\":\((handled - posted) * 1_000)}")
                }
                // One outstanding heartbeat avoids flooding a blocked main queue.
                semaphore.wait()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "OpenClientLabHeartbeat"
        thread.qualityOfService = .utility
        thread.start()
    }
}

// A dedicated serial queue owns the handle and buffer. The main thread only
// formats a small numeric record and enqueues it; no synchronous per-frame I/O.
private final class OpenClientLabProbeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OpenClientLabProbeWriter", qos: .utility)
    private let handle: FileHandle
    private var buffer = Data()
    private var timer: DispatchSourceTimer?

    init?() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("OpenClientPerformanceLab", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(UUID().uuidString + ".jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            handle = try FileHandle(forWritingTo: url)
        } catch { return nil }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume()
        timer = source
    }

    func append(_ line: String) {
        queue.async { [self] in
            buffer.append(contentsOf: (line + "\n").utf8)
            if buffer.count >= 65_536 { flush() }
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            // Failed instrumentation must not alter app behavior. The analyzer
            // requires records for every scoped phase and rejects missing data.
            buffer.removeAll(keepingCapacity: true)
        }
    }
}
#endif

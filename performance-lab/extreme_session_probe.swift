// CI-only phase timing. Appended to the existing diagnostics compilation unit.
// No payloads, prompts, credentials, or per-row records are written.
#if canImport(UIKit)
import UIKit

final class OpenClientExtremeSessionProbe: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["OPENCLIENT_EXTREME_PROBE"] == "1"
    static let shared = OpenClientExtremeSessionProbe()
    private static let publishedPhases: Set<String> = ["metadata", "appearance_configured",
        "connection_overlay_dismissed", "startup_cache_published", "selection_started", "canonical_published",
        "transcript_reveal_completed", "bottom_refresh_method_completed"]
    private let lock = NSLock()
    private let writer: OpenClientExtremeSessionWriter?
    private var operation = 0
    private var operationKind = "startup"
    private var awaitingCanonical = false
    private var canonical = false
    private var input = false
    private var afterCanonicalInput = false
    private var configuredGroup = true

    private init() {
        writer = Self.enabled ? OpenClientExtremeSessionWriter() : nil
        guard Self.enabled else { return }
        let env = ProcessInfo.processInfo.environment
        record("metadata", details: ["schema": 1, "case": env["OPENCLIENT_EXTREME_CASE"] ?? "",
            "trial": env["OPENCLIENT_EXTREME_TRIAL"] ?? "", "grouping_requested": env["OPENCLIENT_EXTREME_GROUPED"] == "1",
            "scope": "Native monotonic phase timestamps and sampled main queue delay. Reveal callback is not a presented-frame guarantee. Typed acceptance is observed when the UI test attempts input, not earliest possible input readiness."])
        let worker = Thread { [self] in
            while true {
                let posted = ProcessInfo.processInfo.systemUptime
                let signal = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { [self] in
                    let handled = ProcessInfo.processInfo.systemUptime
                    record("heartbeat", details: ["posted_uptime_s": posted, "handled_uptime_s": handled,
                        "delay_ms": (handled - posted) * 1000])
                    signal.signal()
                }
                signal.wait()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        worker.name = "OpenClientExtremeSessionHeartbeat"
        worker.qualityOfService = .utility
        worker.start()
    }

    static func record(_ phase: String, sessionID: String = "ses_extreme", details: [String: Any] = [:]) {
        guard enabled, sessionID == "ses_extreme" else { return }
        shared.record(phase, details: details)
    }

    private func record(_ phase: String, details: [String: Any] = [:]) {
        let before = ProcessInfo.processInfo.systemUptime
        let epoch = Date().timeIntervalSince1970
        let after = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let index = operation, kind = operationKind, grouped = configuredGroup
        lock.unlock()
        var row = details
        row["phase"] = phase
        row["operation"] = index
        row["operation_kind"] = kind
        if phase != "metadata" { row["grouping_actual"] = grouped }
        row["uptime_before_s"] = before
        row["uptime_after_s"] = after
        row["epoch_s"] = epoch
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            writer?.append(data)
        }
        if Self.publishedPhases.contains(phase) {
            let env = ProcessInfo.processInfo.environment
            row["schema"] = 1
            row["case"] = env["OPENCLIENT_EXTREME_CASE"] ?? ""
            row["trial"] = env["OPENCLIENT_EXTREME_TRIAL"] ?? ""
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                writer?.publishNativeEvent(data)
            }
        }
    }

    @MainActor
    static func configureAppearance(_ store: AppCustomizationStore) {
        guard enabled else { return }
        let grouped = ProcessInfo.processInfo.environment["OPENCLIENT_EXTREME_GROUPED"] == "1"
        store.setGroupsToolCalls(grouped)
        store.setShowsToolCalls(true)
        store.setShowsReasoningBlocks(true)
        shared.lock.lock(); shared.configuredGroup = store.groupsToolCalls; shared.lock.unlock()
        record("appearance_configured", details: ["grouping_actual": store.groupsToolCalls,
            "tools_actual": store.showsToolCalls, "reasoning_actual": store.showsReasoningBlocks])
    }

    @MainActor
    static func beginSelection(sessionID: String) {
        guard enabled, sessionID == "ses_extreme" else { return }
        shared.lock.lock()
        guard !shared.awaitingCanonical else { shared.lock.unlock(); return }
        shared.operation += 1
        shared.operationKind = "selection"
        shared.awaitingCanonical = true
        shared.canonical = false; shared.input = false; shared.afterCanonicalInput = false
        shared.lock.unlock()
        record("selection_started")
    }

    @MainActor
    static func beginRefresh(sessionID: String) {
        guard enabled, sessionID == "ses_extreme" else { return }
        shared.lock.lock()
        shared.operation += 1
        shared.operationKind = "bottom_refresh"
        shared.awaitingCanonical = true
        shared.canonical = false; shared.input = false; shared.afterCanonicalInput = false
        shared.lock.unlock()
        record("bottom_refresh_started")
    }

    @MainActor
    static func canonicalPublished(sessionID: String, count: Int) {
        guard enabled, sessionID == "ses_extreme" else { return }
        shared.lock.lock()
        shared.canonical = true
        shared.awaitingCanonical = false
        shared.lock.unlock()
        record("canonical_published", details: ["loaded_messages": count])
    }

    @MainActor
    static func revealStarted(rows: Int) {
        guard enabled else { return }
        record("transcript_reveal_started", details: ["visible_snapshot_rows": rows])
    }

    @MainActor
    static func revealCompleted() {
        guard enabled else { return }
        record("transcript_reveal_completed")
    }

    @MainActor
    static func refreshCompleted(sessionID: String) {
        guard enabled, sessionID == "ses_extreme" else { return }
        record("bottom_refresh_method_completed")
        DispatchQueue.main.async { record("bottom_refresh_next_main_turn") }
    }

    @MainActor
    static func inputChanged(_ text: String) {
        guard enabled, let prefix = ProcessInfo.processInfo.environment["OPENCLIENT_EXTREME_INPUT_PREFIX"] else { return }
        shared.lock.lock()
        let index = shared.operation, already = shared.input, afterAlready = shared.afterCanonicalInput
        let isCanonical = shared.canonical, kind = shared.operationKind
        shared.lock.unlock()
        guard index > 0 else { return }
        let expected = "\(prefix)_\(index)"
        if !already, text.contains(expected) {
            shared.lock.lock(); shared.input = true; shared.lock.unlock()
            record("typed_token_accepted", details: ["expected_token": expected])
        }
        let afterToken = kind == "bottom_refresh" ? expected : expected + "_C"
        if isCanonical, !afterAlready, text.contains(afterToken) {
            shared.lock.lock(); shared.afterCanonicalInput = true; shared.lock.unlock()
            record("post_canonical_typed_token_accepted", details: ["expected_token": afterToken])
        }
    }
}

private final class OpenClientExtremeSessionWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OpenClientExtremeSessionWriter", qos: .utility)
    private let handle: FileHandle
    private var buffer = Data()
    private var timer: DispatchSourceTimer?

    // The test runner's owned fixture is the only permitted phase destination.
    private let nativeEndpoint: URL? = {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENCLIENT_EXTREME_PROBE"] == "1",
              ["cold", "seeded-relaunch", "seeded-revisit"].contains(env["OPENCLIENT_EXTREME_CASE"] ?? ""),
              env["OPENCLIENT_EXTREME_PASSWORD"] == "ci-fixture-only",
              let base = URL(string: env["OPENCLIENT_EXTREME_URL"] ?? ""),
              base.scheme == "http", base.host == "127.0.0.1", base.port == 14097,
              base.path.isEmpty, base.query == nil, base.fragment == nil,
              base.user == nil, base.password == nil else { return nil }
        return base.appendingPathComponent("_lab/native-phase")
    }()

    init?() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("OpenClientExtremeSession", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else { return nil }
            handle = try FileHandle(forWritingTo: path)
        } catch { return nil }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume(); timer = source
    }

    func append(_ data: Data) {
        queue.async { [self] in
            buffer.append(data); buffer.append(10)
            if buffer.count >= 65_536 { flush() }
        }
    }

    func publishNativeEvent(_ data: Data) {
        guard let nativeEndpoint else { return }
        queue.async {
            var request = URLRequest(url: nativeEndpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic " + Data("opencode:ci-fixture-only".utf8).base64EncodedString(),
                forHTTPHeaderField: "Authorization")
            URLSession.shared.uploadTask(with: request, from: data).resume()
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        do { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        catch { buffer.removeAll(keepingCapacity: true) }
    }
}
#endif

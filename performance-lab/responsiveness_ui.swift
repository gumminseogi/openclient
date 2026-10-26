// CI-only extension, appended AFTER long_transcript_ui.swift to reuse its native
// navigation helpers. Measures app-internal probe samples, never XCTest timings.
@MainActor
extension ToolGroupingUITests {
    func testNativeResponsivenessLab() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let password = try XCTUnwrap(env["OPENCLIENT_LAB_UI_PASSWORD"])
        let baseURL = try XCTUnwrap(URL(string: env["OPENCLIENT_LAB_UI_URL"] ?? "http://127.0.0.1:14097"))
        guard baseURL.scheme == "http", baseURL.host == "127.0.0.1", baseURL.path.isEmpty,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil else {
            throw labFailure("Responsiveness tests require the owned loopback fixture.")
        }
        let variant = try XCTUnwrap(env["OPENCLIENT_LAB_UI_VARIANT"])
        let trial = try XCTUnwrap(env["OPENCLIENT_LAB_UI_TRIAL"])
        let grouped = env["OPENCLIENT_LAB_UI_GROUPED"] == "1"
        let warmupOnly = env["OPENCLIENT_LAB_UI_WARMUP_ONLY"] == "1"
        let sessionID = "ses_2000"
        let statusAtStart = try await labRequest(baseURL, password: password, path: "/_lab/status")
        XCTAssertEqual(statusAtStart["synthetic"] as? Bool, true)
        let requestBaseline = labLastRequestID(statusAtStart)
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in app.terminate() }
        app.launchEnvironment = [
            "OPENCODE_UI_TEST_MODE": "1", "OPENCODE_UI_TEST_AUTO_CONNECT": "1",
            "OPENCODE_UI_TEST_BASE_URL": baseURL.absoluteString,
            "OPENCODE_UI_TEST_USERNAME": "opencode", "OPENCODE_UI_TEST_PASSWORD": password,
            "OPENCODE_UI_TEST_DIRECTORY": "/openclient-performance-lab",
            "OPENCODE_UI_TEST_SERVER_NAME": "Owned performance lab",
            "OPENCLIENT_PERF_DIAGNOSTICS": "0", "OPENCLIENT_LAB_PROBE": "1",
            "OPENCLIENT_LAB_PROBE_VARIANT": variant, "OPENCLIENT_LAB_PROBE_TRIAL": trial
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try await labWait("Connected home", timeout: 60) { app.buttons["projects.configurations"].isHittable }
        try await labSetGrouping(grouped, app: app)
        let search = app.textFields["projects.searchChats"]
        try await labWait("Home search") { search.isHittable }
        search.tap()
        search.typeText("Lab: 2000 messages")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lab: 2000 messages")).firstMatch
        try await labWait("Seeded session") { result.isHittable }
        result.tap()
        let transcript = app.collectionViews["chat.scroll"]
        let input = app.textViews["chat.input"]
        try await labWait("Native transcript", timeout: 60) { transcript.exists && input.exists && transcript.cells.count > 0 }

        var coverage = 0
        var historyRequests: [[String: Any]] = []
        for swipe in 0...600 {
            let status = try await labRequest(baseURL, password: password, path: "/_lab/status")
            let rows = (status["recent_requests"] as? [[String: Any]] ?? []).filter {
                ($0["request_id"] as? Int ?? 0) > requestBaseline
                    && $0["path"] as? String == "/session/\(sessionID)/message" && $0["status"] as? Int == 200
            }
            let known = Set(historyRequests.compactMap { $0["request_id"] as? Int })
            historyRequests += rows.filter { !known.contains($0["request_id"] as? Int ?? -1) }
            coverage = max(coverage, labCoverage(rows, sessionID: sessionID, seedCount: 2000))
            if coverage >= 2000 { break }
            if !warmupOnly {
                guard swipe < 40 else { throw labFailure("Restored cache did not hydrate 2000 canonical messages; refusing a small-history measurement.") }
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard swipe < 600 else { throw labFailure("Warmup paging failed to load all 2000 messages.") }
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await labReturnToBottom(app: app, transcript: transcript)
        let refreshBaseline = labLastRequestID(try await labRequest(baseURL, password: password, path: "/_lab/status"))
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        var canonicalProof: [[String: Any]] = []
        for _ in 0..<120 {
            let status = try await labRequest(baseURL, password: password, path: "/_lab/status")
            canonicalProof = (status["recent_requests"] as? [[String: Any]] ?? []).filter {
                let query = $0["query"] as? [String: [String]] ?? [:]
                return ($0["request_id"] as? Int ?? 0) > refreshBaseline
                    && $0["path"] as? String == "/session/\(sessionID)/message"
                    && $0["status"] as? Int == 200 && query["before"] == nil
                    && (Int(query["limit"]?.first ?? "0") ?? 0) >= 2000
            }
            if !canonicalProof.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard !canonicalProof.isEmpty else { throw labFailure("No canonical refresh proving a 2000-message active store.") }
        try await Task.sleep(for: .seconds(5))
        if warmupOnly {
            try await Task.sleep(for: .seconds(5))
            app.terminate()
            return
        }

        // One unmeasured stream warms the same native event/rendering paths.
        _ = try await labRequest(baseURL, password: password, path: "/_lab/stream", body: [
            "sessionID": sessionID, "chunks": 40, "interval_ms": 50, "chunk_bytes": 32, "part_type": "text"
        ])
        _ = try await responsivenessWaitForCompletion(baseURL, password: password, sessionID: sessionID)
        try await Task.sleep(for: .seconds(3))
        var phases: [[String: Any]] = []
        var streams: [[String: Any]] = []
        let stop = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.stream.stop", "chat.stop"])).firstMatch
        for partType in ["text", "reasoning"] {
            try await labReturnToBottom(app: app, transcript: transcript)
            let accepted = try await labRequest(baseURL, password: password, path: "/_lab/stream", body: [
                "sessionID": sessionID, "chunks": 800, "interval_ms": 50, "chunk_bytes": 64, "part_type": partType
            ])
            try await labWait("Live native stream", timeout: 15) { stop.exists }
            var start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(4))
            phases.append(responsivenessPhase("\(partType)_steady", start: start))

            start = ProcessInfo.processInfo.systemUptime
            input.tap()
            app.typeKey("a", modifierFlags: .command)
            let draft = "performance draft \(partType)"
            input.typeText(draft)
            XCTAssertEqual(input.value as? String, draft, "Streaming must preserve typed input.")
            phases.append(responsivenessPhase("\(partType)_typing", start: start))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let dismissStart = origin.withOffset(CGVector(dx: transcript.frame.midX, dy: input.frame.minY - 100))
            let dismissEnd = origin.withOffset(CGVector(dx: transcript.frame.midX, dy: app.frame.maxY - 30))
            dismissStart.press(forDuration: 0.05, thenDragTo: dismissEnd, withVelocity: .slow, thenHoldForDuration: 0.1)
            try await labWait("Keyboard dismissed") { !app.keyboards.firstMatch.exists }

            start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<2 {
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)),
                           withVelocity: .slow, thenHoldForDuration: 0.1)
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                           withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            phases.append(responsivenessPhase("\(partType)_scrolling", start: start))
            let afterInteractions = try await labRequest(baseURL, password: password, path: "/_lab/status")
            XCTAssertTrue((afterInteractions["active"] as? [String] ?? []).contains(sessionID),
                          "The measured interactions must occur while server deltas are still streaming.")
            try await labReturnToBottom(app: app, transcript: transcript)
            let completed = try await responsivenessWaitForCompletion(baseURL, password: password, sessionID: sessionID)
            let run = (completed["runs"] as? [String: [String: Any]])?[sessionID] ?? [:]
            streams.append(["part_type": partType, "accepted": accepted, "completed_run": run])
            start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(8))
            phases.append(responsivenessPhase("\(partType)_after_completion", start: start))
            XCTAssertEqual(input.value as? String, draft)
        }
        let uptimeBefore = ProcessInfo.processInfo.systemUptime
        let epoch = Date().timeIntervalSince1970
        let uptimeAfter = ProcessInfo.processInfo.systemUptime
        let evidence: [String: Any] = [
            "schema": 1, "variant": variant, "trial": trial, "grouping": grouped,
            "seed_messages": 2000, "minimum_loaded_messages": coverage,
            "canonical_refresh_proof": canonicalProof, "phases": phases, "streams": streams,
            "clock": ["uptime_before_s": uptimeBefore, "epoch_s": epoch, "uptime_after_s": uptimeAfter],
            "scope": "Pair native probe intervals with these phase boundaries. XCTest action durations are not input latency. Simulator callback gaps are not presented FPS or physical iPhone performance."
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "responsiveness-\(trial)-\(variant)-grouped-\(grouped)"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await Task.sleep(for: .seconds(3)) // Let the background probe writer flush.
        app.terminate()
    }

    private func responsivenessPhase(_ name: String, start: TimeInterval) -> [String: Any] {
        ["name": name, "start_uptime_s": start, "end_uptime_s": ProcessInfo.processInfo.systemUptime]
    }

    private func responsivenessWaitForCompletion(_ baseURL: URL, password: String, sessionID: String) async throws -> [String: Any] {
        for _ in 0..<120 {
            let status = try await labRequest(baseURL, password: password, path: "/_lab/status")
            if !(status["active"] as? [String] ?? []).contains(sessionID) { return status }
            try await Task.sleep(for: .seconds(1))
        }
        throw labFailure("Synthetic stream did not finish.")
    }
}

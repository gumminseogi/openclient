// CI-only real project -> session -> chat loading experiment. Appended after the
// existing lab UI helpers; no screenshot scene or fixture-only app path is used.
import Foundation

@MainActor
extension ToolGroupingUITests {
    func testExtremeSessionLoading() async throws {
        continueAfterFailure = false
        ExtremeCanonicalObservation.requests = []
        let env = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(URL(string: env["OPENCLIENT_EXTREME_URL"] ?? "http://127.0.0.1:14097"))
        let password = try XCTUnwrap(env["OPENCLIENT_EXTREME_PASSWORD"])
        let count = try XCTUnwrap(Int(env["OPENCLIENT_EXTREME_COUNT"] ?? "5000"))
        let mode = try XCTUnwrap(env["OPENCLIENT_EXTREME_CASE"])
        let trial = env["OPENCLIENT_EXTREME_TRIAL"] ?? "trial1"
        let grouped = env["OPENCLIENT_EXTREME_GROUPED"] == "1"
        guard base.scheme == "http", base.host == "127.0.0.1", base.port == 14097,
              base.path.isEmpty, base.query == nil, base.user == nil, base.password == nil,
              (64...10000).contains(count), ["cold", "seeded-relaunch", "seeded-revisit"].contains(mode) else {
            throw labFailure("Invalid owned extreme lab settings.")
        }
        let initial = try await extremeStatus(base, password: password)
        let profile = try XCTUnwrap(initial["extreme_profile"] as? [String: Any])
        XCTAssertEqual(profile["session_id"] as? String, "ses_extreme")
        XCTAssertEqual(profile["messages"] as? Int, count)
        XCTAssertEqual((initial["sessions"] as? [String: Int])?.count, 1)
        let sentinel = try XCTUnwrap(profile["ready_sentinel"] as? String)
        let modeTag = mode == "cold" ? "C" : mode == "seeded-revisit" ? "V" : "R"
        let tokenPrefix = "EX\(modeTag)\(trial.filter { $0.isNumber })G\(grouped ? 1 : 0)"
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            // Async thrown failures may not update testRun.failureCount yet.
            await self.extremeCaptureFailure(app: app, base: base, password: password)
            app.terminate()
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "OPENCODE_UI_TEST_MODE": "1", "OPENCODE_UI_TEST_AUTO_CONNECT": "1",
            "OPENCODE_UI_TEST_BASE_URL": base.absoluteString, "OPENCODE_UI_TEST_USERNAME": "opencode",
            "OPENCODE_UI_TEST_PASSWORD": password, "OPENCODE_UI_TEST_DIRECTORY": "/openclient-performance-lab",
            "OPENCODE_UI_TEST_SERVER_NAME": "Owned extreme session lab",
            "OPENCLIENT_PERF_DIAGNOSTICS": "0", "OPENCLIENT_EXTREME_PROBE": "1",
            "OPENCLIENT_EXTREME_SEED_ONLY": "0", "OPENCLIENT_EXTREME_CASE": mode,
            "OPENCLIENT_EXTREME_TRIAL": trial, "OPENCLIENT_EXTREME_GROUPED": grouped ? "1" : "0",
            "OPENCLIENT_EXTREME_URL": base.absoluteString, "OPENCLIENT_EXTREME_PASSWORD": password,
            "OPENCLIENT_EXTREME_INPUT_PREFIX": tokenPrefix
        ]
        var actions: [[String: Any]] = []
        let launchStart = ProcessInfo.processInfo.systemUptime
        app.launch()
        print("EXTREME launch returned; waiting for native connection completion")
        _ = try await extremeNativePhase(base, password: password, phase: "appearance_configured", operation: 0)
        _ = try await extremeNativePhase(base, password: password, phase: "connection_overlay_dismissed", operation: 0)
        var warmCacheReadyObserved: Double?
        if mode != "cold" {
            let startup = try await extremeNativePhase(base, password: password, phase: "startup_cache_published", operation: 0,
                minimumLoaded: count)
            XCTAssertEqual(startup["loaded_messages"] as? Int, count)
            warmCacheReadyObserved = ProcessInfo.processInfo.systemUptime
            print("EXTREME full retained warm state published messages=\(count)")
        }
        print("EXTREME native connection completed; inspecting connected root")
        try await extremeWait("Connected project or session list") {
            let project = app.buttons["projects.project.lab"], session = app.buttons["session.row.ses_extreme"]
            let configurations = app.buttons["projects.configurations"]
            return (project.exists && project.isHittable) || (session.exists && session.isHittable)
                || (configurations.exists && configurations.isHittable)
        }
        try await extremeShowProjectSidebar(app)
        let homeObserved = ProcessInfo.processInfo.systemUptime
        print("EXTREME connected case=\(mode) trial=\(trial) grouping=\(grouped)")
        let projectTap = ProcessInfo.processInfo.systemUptime
        app.buttons["projects.project.lab"].tap()
        let row = app.buttons["session.row.ses_extreme"]
        try await extremeWait("Sole extreme session row") { row.exists && row.isHittable }
        var projectTiming = ["project_tap_uptime_s": projectTap, "session_row_observed_uptime_s": ProcessInfo.processInfo.systemUptime]
        if let warmCacheReadyObserved { projectTiming["warm_cache_ready_observed_uptime_s"] = warmCacheReadyObserved }

        let expectedMinimum = mode == "cold" ? 20 : count
        let first = try await extremeOpen(app: app, row: row, base: base, password: password,
            sentinel: sentinel, token: tokenPrefix + "_1", operation: 1, expectedMinimum: expectedMinimum,
            expectedGrouping: grouped, stage: "first_open") { partial, stage in
                try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
                    actions: actions + [partial], launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming,
                    checkpoint: stage, complete: false)
            }
        actions.append(first)
        try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
            actions: actions, launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming, checkpoint: "first-open", complete: false)

        var refreshOperation = 2
        if mode == "seeded-revisit" {
            // Leave the actual route, not merely re-tap an already visible chat.
            try await extremeShowProjectSidebar(app)
            app.buttons["projects.project.lab"].tap() // Production beginProjectNavigation clears selectedSession.
            try await extremeWait("Previous chat route unmounted before revisit") { !extremeTranscript(app).exists }
            try await extremeWait("Session list after leaving chat") { row.exists && row.isHittable }
            let second = try await extremeOpen(app: app, row: row, base: base, password: password,
                sentinel: sentinel, token: tokenPrefix + "_2", operation: 2, expectedMinimum: count,
                expectedGrouping: grouped, stage: "same_process_revisit") { partial, stage in
                    try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
                        actions: actions + [partial], launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming,
                        checkpoint: stage, complete: false)
                }
            actions.append(second)
            try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
                actions: actions, launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming, checkpoint: "revisit", complete: false)
            refreshOperation = 3
        }

        let transcript = extremeTranscript(app)
        try await extremeWait("Transcript viewport exists") { transcript.exists }
        let input = app.textViews["chat.input"]
        // Use the native interactive keyboard dismissal. No Cmd+A/delete or
        // assumptions about an empty composer or caret position are made.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: transcript.frame.midX, dy: input.frame.minY - 90))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: transcript.frame.midX, dy: app.frame.maxY - 30)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        try await extremeWait("Keyboard dismissed before bottom refresh") { !app.keyboards.firstMatch.exists }
        let jump = app.buttons["chat.scrollToBottom"]
        if jump.exists && jump.isHittable { jump.tap() }
        try await extremeWait("Transcript at pinned tail") { !jump.exists }
        let baseline = extremeLastRequestID(try await extremeStatus(base, password: password))
        let refreshStart = ProcessInfo.processInfo.systemUptime
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
            actions: actions + [["stage": "bottom_refresh", "operation": refreshOperation, "start_uptime_s": refreshStart]],
            launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming, checkpoint: "refresh-gesture", complete: false)
        let refreshEvent = try await extremeNativePhase(base, password: password, phase: "bottom_refresh_method_completed", operation: refreshOperation)
        let refreshCanonicalEvent = try await extremeNativePhase(base, password: password, phase: "canonical_published", operation: refreshOperation,
            minimumLoaded: expectedMinimum)
        let refreshProof = try await extremeCanonicalProof(base, password: password, after: baseline, minimum: expectedMinimum)
        let refreshCompleteObserved = ProcessInfo.processInfo.systemUptime
        let refreshToken = tokenPrefix + "_\(refreshOperation)"
        input.tap(); input.typeText(refreshToken)
        XCTAssertTrue((input.value as? String ?? "").contains(refreshToken))
        actions.append(["stage": "bottom_refresh", "operation": refreshOperation,
            "start_uptime_s": refreshStart, "canonical_and_method_observed_uptime_s": refreshCompleteObserved,
            "typed_token_observed_uptime_s": ProcessInfo.processInfo.systemUptime,
            "requests": refreshProof, "minimum_expected_loaded": expectedMinimum,
            "typed_token": refreshToken, "native_probe_status": ["refresh": refreshEvent, "canonical": refreshCanonicalEvent]])
        try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
            actions: actions, launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming, checkpoint: "complete", complete: true)
        try await Task.sleep(for: .seconds(3)) // Background phase writer flush, excluded from timing.
        print("EXTREME complete case=\(mode) trial=\(trial) grouping=\(grouped)")
    }

    private func extremeOpen(app: XCUIApplication, row: XCUIElement, base: URL, password: String,
                             sentinel: String, token: String, operation: Int, expectedMinimum: Int,
                             expectedGrouping: Bool, stage: String,
                             checkpoint: ([String: Any], String) throws -> Void) async throws -> [String: Any] {
        let baseline = extremeLastRequestID(try await extremeStatus(base, password: password))
        let opened = ProcessInfo.processInfo.systemUptime
        print("EXTREME selection tap stage=\(stage)")
        row.tap()
        let input = app.textViews["chat.input"]
        // HTTP phase polling leaves the app's initial layout alone. Readiness still
        // requires the real answer on screen and input accepted by the real composer.
        let revealEvent = try await extremeNativePhase(base, password: password, phase: "transcript_reveal_completed", operation: operation)
        XCTAssertEqual(revealEvent["grouping_actual"] as? Bool, expectedGrouping)
        let transcript = extremeTranscript(app)
        try await extremeWait("Pinned-tail answer token visibly available") {
            let match = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", sentinel, sentinel)
            let selectable = transcript.textViews.matching(match).firstMatch
            let plain = transcript.staticTexts.matching(match).firstMatch
            return (selectable.exists && selectable.isHittable) || (plain.exists && plain.isHittable)
        }
        let contentObserved = ProcessInfo.processInfo.systemUptime
        try checkpoint(["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "native_probe_status": revealEvent], stage + "-visible")
        try await extremeWait("Composer is available") { input.exists && input.isHittable }
        input.tap(); input.typeText(token)
        XCTAssertTrue((input.value as? String ?? "").contains(token), "A unique plain token must survive typing.")
        let typedObserved = ProcessInfo.processInfo.systemUptime
        try checkpoint(["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "typed_token_observed_uptime_s": typedObserved,
            "typed_token": token, "native_probe_status": revealEvent], stage + "-typed")
        let canonicalEvent = try await extremeNativePhase(base, password: password, phase: "canonical_published", operation: operation,
            minimumLoaded: expectedMinimum)
        let proof = try await extremeCanonicalProof(base, password: password, after: baseline, minimum: expectedMinimum)
        let canonicalObserved = ProcessInfo.processInfo.systemUptime
        try checkpoint(["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "typed_token_observed_uptime_s": typedObserved,
            "canonical_observed_uptime_s": canonicalObserved, "requests": proof,
            "native_probe_status": ["reveal": revealEvent, "canonical": canonicalEvent]], stage + "-canonical")
        let postToken = token + "_C"
        input.tap(); input.typeText(postToken)
        XCTAssertTrue((input.value as? String ?? "").contains(postToken))
        return ["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "typed_token_observed_uptime_s": typedObserved,
            "canonical_observed_uptime_s": canonicalObserved,
            "post_canonical_typed_token_observed_uptime_s": ProcessInfo.processInfo.systemUptime,
            "post_canonical_typed_token": postToken,
            "requests": proof, "minimum_expected_loaded": expectedMinimum,
            "typed_token": token, "native_probe_status": ["reveal": revealEvent, "canonical": canonicalEvent]]
    }

    private func extremeNativePhase(_ base: URL, password: String, phase: String, operation: Int,
                                    minimumLoaded: Int = 0) async throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = try await extremeStatus(base, password: password)
            let events = status["native_events"] as? [[String: Any]] ?? []
            if let event = events.last(where: {
                $0["phase"] as? String == phase && $0["operation"] as? Int == operation
                    && $0["case"] as? String == env["OPENCLIENT_EXTREME_CASE"]
                    && $0["trial"] as? String == (env["OPENCLIENT_EXTREME_TRIAL"] ?? "trial1")
                    && $0["grouping_actual"] as? Bool == (env["OPENCLIENT_EXTREME_GROUPED"] == "1")
                    && (phase != "connection_overlay_dismissed" || $0["connected_actual"] as? Bool == true)
                    && (minimumLoaded == 0 || ($0["loaded_messages"] as? Int ?? 0) >= minimumLoaded)
            }) { return event }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw labFailure("Native phase not observed: \(phase), operation \(operation)")
    }

    private func extremeCaptureFailure(app: XCUIApplication, base: URL, password: String) async {
        print("EXTREME preserving failure evidence before app termination")
        if let status = try? await extremeStatus(base, password: password),
           let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            let item = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            item.name = "extreme-failure-native-status"; item.lifetime = .keepAlways; add(item)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "extreme-failure-screen"; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "extreme-failure-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
        let transcript = extremeTranscript(app)
        let value = transcript.exists ? String(describing: transcript.value) : "native chat transcript absent"
        let native = XCTAttachment(string: value)
        native.name = "extreme-failure-native-ax-status"; native.lifetime = .keepAlways; add(native)
    }

    private func extremeTranscript(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.scroll").firstMatch
    }

    private func extremeCanonicalProof(_ base: URL, password: String, after baseline: Int, minimum: Int) async throws -> [[String: Any]] {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while ProcessInfo.processInfo.systemUptime < deadline {
            _ = try await extremeStatus(base, password: password)
            let found = ExtremeCanonicalObservation.requests.filter { row in
                let query = row["query"] as? [String: [String]] ?? [:]
                return (row["request_id"] as? Int ?? 0) > baseline && row["method"] as? String == "GET"
                    && row["path"] as? String == "/session/ses_extreme/message" && row["status"] as? Int == 200
                    && query["before"] == nil && (Int(query["limit"]?.first ?? "") ?? 0) >= minimum
            }
            if !found.isEmpty { return found }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw labFailure("No canonical HTTP proof at the expected loaded-history size.")
    }

    private func extremeStatus(_ base: URL, password: String) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("_lab/status"))
        request.timeoutInterval = 180
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw labFailure("Owned fixture status failed.") }
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Preserve actual observed request summaries across slow phase waits; the
        // server's short recent-request window also contains our status polls.
        let known = Set(ExtremeCanonicalObservation.requests.compactMap { $0["request_id"] as? Int })
        ExtremeCanonicalObservation.requests += (status["recent_requests"] as? [[String: Any]] ?? []).filter {
            $0["method"] as? String == "GET" && $0["path"] as? String == "/session/ses_extreme/message"
                && $0["status"] as? Int == 200 && !known.contains($0["request_id"] as? Int ?? -1)
        }
        return status
    }

    private func extremeLastRequestID(_ status: [String: Any]) -> Int {
        ((status["recent_requests"] as? [[String: Any]] ?? []) + (status["inflight"] as? [[String: Any]] ?? []))
            .compactMap { $0["request_id"] as? Int }.max() ?? 0
    }

    private func extremeWait(_ label: String, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw labFailure(label)
    }

    private func extremeShowProjectSidebar(_ app: XCUIApplication) async throws {
        for attempt in 0...3 {
            let project = app.buttons["projects.project.lab"]
            if project.exists && project.isHittable { return }
            guard attempt < 3 else { throw labFailure("Native back navigation did not reveal the owned project.") }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func extremeAttach(mode: String, trial: String, grouped: Bool, profile: [String: Any],
                               actions: [[String: Any]], launchStart: Double, homeObserved: Double, projectTiming: [String: Double],
                               checkpoint: String, complete: Bool) throws {
        let before = ProcessInfo.processInfo.systemUptime
        let epoch = Date().timeIntervalSince1970
        let after = ProcessInfo.processInfo.systemUptime
        let evidence: [String: Any] = ["schema": 1, "experiment": "extreme_session_load", "case": mode,
            "trial": trial, "grouping": grouped, "checkpoint": checkpoint, "complete": complete,
            "profile": profile, "actions": actions, "launch_start_uptime_s": launchStart,
            "home_observed_uptime_s": homeObserved, "project_navigation": projectTiming,
            "clock": ["uptime_before_s": before, "epoch_s": epoch, "uptime_after_s": after],
            "scope": "Seeded cases await normal startup publication of the full retained cache before navigation; launch/op0 timings are separate. UI-observed action times include XCTest/Accessibility overhead. Native callbacks are separate; typed acceptance is not earliest readiness or per-key latency."]
        let item = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        item.name = "extreme-\(mode)-\(trial)-g\(grouped ? 1 : 0)-\(checkpoint)"; item.lifetime = .keepAlways; add(item)
        print("EXTREME checkpoint \(checkpoint) actions=\(actions.count)")
    }
}

@MainActor
private enum ExtremeCanonicalObservation {
    static var requests: [[String: Any]] = []
}

// CI-only real project -> session -> chat loading experiment. Appended after the
// existing lab UI helpers; no screenshot scene or fixture-only app path is used.
import Foundation

@MainActor
extension ToolGroupingUITests {
    func testExtremeSessionLoading() async throws {
        continueAfterFailure = false
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
        addTeardownBlock { @MainActor in app.terminate() }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "OPENCODE_UI_TEST_MODE": "1", "OPENCODE_UI_TEST_AUTO_CONNECT": "1",
            "OPENCODE_UI_TEST_BASE_URL": base.absoluteString, "OPENCODE_UI_TEST_USERNAME": "opencode",
            "OPENCODE_UI_TEST_PASSWORD": password, "OPENCODE_UI_TEST_DIRECTORY": "/openclient-performance-lab",
            "OPENCODE_UI_TEST_SERVER_NAME": "Owned extreme session lab",
            "OPENCLIENT_PERF_DIAGNOSTICS": "0", "OPENCLIENT_EXTREME_PROBE": "1",
            "OPENCLIENT_EXTREME_SEED_ONLY": "0", "OPENCLIENT_EXTREME_CASE": mode,
            "OPENCLIENT_EXTREME_TRIAL": trial, "OPENCLIENT_EXTREME_GROUPED": grouped ? "1" : "0",
            "OPENCLIENT_EXTREME_INPUT_PREFIX": tokenPrefix
        ]
        var actions: [[String: Any]] = []
        let launchStart = ProcessInfo.processInfo.systemUptime
        app.launch()
        try await extremeWait("Connected project or session list") {
            app.buttons["projects.project.lab"].isHittable || app.buttons["session.row.ses_extreme"].isHittable
        }
        try await extremeShowProjectSidebar(app)
        let homeObserved = ProcessInfo.processInfo.systemUptime
        print("EXTREME connected case=\(mode) trial=\(trial) grouping=\(grouped)")
        let projectTap = ProcessInfo.processInfo.systemUptime
        app.buttons["projects.project.lab"].tap()
        let row = app.buttons["session.row.ses_extreme"]
        try await extremeWait("Sole extreme session row") { row.isHittable }
        let projectTiming = ["project_tap_uptime_s": projectTap, "session_row_observed_uptime_s": ProcessInfo.processInfo.systemUptime]

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
            try await extremeWait("Previous chat route unmounted before revisit") { !app.collectionViews["chat.scroll"].exists }
            try await extremeWait("Session list after leaving chat") { row.isHittable }
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

        let transcript = app.collectionViews["chat.scroll"]
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
        let refreshProof = try await extremeCanonicalProof(base, password: password, after: baseline, minimum: expectedMinimum)
        try await extremeWait("Native refresh method completed") {
            let value = transcript.value as? String ?? ""
            return value.contains("op=\(refreshOperation)|") && value.contains("canonical=1") && value.contains("refresh=1")
        }
        let refreshCompleteObserved = ProcessInfo.processInfo.systemUptime
        let refreshToken = tokenPrefix + "_\(refreshOperation)"
        input.tap(); input.typeText(refreshToken)
        XCTAssertTrue((input.value as? String ?? "").contains(refreshToken))
        try await extremeWait("Refresh input delegate accepted token") { (transcript.value as? String ?? "").contains("input=1") }
        actions.append(["stage": "bottom_refresh", "operation": refreshOperation,
            "start_uptime_s": refreshStart, "canonical_and_method_observed_uptime_s": refreshCompleteObserved,
            "typed_token_observed_uptime_s": ProcessInfo.processInfo.systemUptime,
            "requests": refreshProof, "minimum_expected_loaded": expectedMinimum,
            "typed_token": refreshToken, "native_probe_status": transcript.value as? String ?? ""])
        try extremeAttach(mode: mode, trial: trial, grouped: grouped, profile: profile,
            actions: actions, launchStart: launchStart, homeObserved: homeObserved, projectTiming: projectTiming, checkpoint: "complete", complete: true)
        try await Task.sleep(for: .seconds(3)) // Background phase writer flush, excluded from timing.
        print("EXTREME complete case=\(mode) trial=\(trial) grouping=\(grouped)")
        app.terminate()
    }

    private func extremeOpen(app: XCUIApplication, row: XCUIElement, base: URL, password: String,
                             sentinel: String, token: String, operation: Int, expectedMinimum: Int,
                             expectedGrouping: Bool, stage: String,
                             checkpoint: ([String: Any], String) throws -> Void) async throws -> [String: Any] {
        let baseline = extremeLastRequestID(try await extremeStatus(base, password: password))
        let opened = ProcessInfo.processInfo.systemUptime
        print("EXTREME selection tap stage=\(stage)")
        row.tap()
        let transcript = app.collectionViews["chat.scroll"]
        let input = app.textViews["chat.input"]
        try await extremeWait("Pinned-tail answer token visibly available") {
            let plain = transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", sentinel)).firstMatch
            let selectable = transcript.textViews.matching(NSPredicate(format: "value CONTAINS %@", sentinel)).firstMatch
            return (plain.exists && plain.isHittable) || (selectable.exists && selectable.isHittable)
        }
        let contentObserved = ProcessInfo.processInfo.systemUptime
        try checkpoint(["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "native_probe_status": transcript.value as? String ?? ""], stage + "-visible")
        try await extremeWait("Native transcript reveal callback") {
            let value = transcript.value as? String ?? ""
            return value.contains("op=\(operation)|") && value.contains("revealed=1")
        }
        XCTAssertTrue((transcript.value as? String ?? "").contains("grouping=\(expectedGrouping ? 1 : 0)|"))
        try await extremeWait("Composer is available") { input.isHittable }
        input.tap(); input.typeText(token)
        XCTAssertTrue((input.value as? String ?? "").contains(token), "A unique plain token must survive typing.")
        try await extremeWait("Native input delegate accepted token") { (transcript.value as? String ?? "").contains("input=1") }
        let typedObserved = ProcessInfo.processInfo.systemUptime
        try checkpoint(["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "typed_token_observed_uptime_s": typedObserved,
            "typed_token": token, "native_probe_status": transcript.value as? String ?? ""], stage + "-typed")
        let proof = try await extremeCanonicalProof(base, password: password, after: baseline, minimum: expectedMinimum)
        try await extremeWait("Native canonical publication") { (transcript.value as? String ?? "").contains("canonical=1") }
        let canonicalObserved = ProcessInfo.processInfo.systemUptime
        try checkpoint(["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "typed_token_observed_uptime_s": typedObserved,
            "canonical_observed_uptime_s": canonicalObserved, "requests": proof,
            "native_probe_status": transcript.value as? String ?? ""], stage + "-canonical")
        let postToken = token + "_C"
        input.tap(); input.typeText(postToken)
        XCTAssertTrue((input.value as? String ?? "").contains(postToken))
        try await extremeWait("Post-canonical input accepted") { (transcript.value as? String ?? "").contains("after_input=1") }
        return ["stage": stage, "operation": operation, "start_uptime_s": opened,
            "content_observed_uptime_s": contentObserved, "typed_token_observed_uptime_s": typedObserved,
            "canonical_observed_uptime_s": canonicalObserved,
            "post_canonical_typed_token_observed_uptime_s": ProcessInfo.processInfo.systemUptime,
            "post_canonical_typed_token": postToken,
            "requests": proof, "minimum_expected_loaded": expectedMinimum,
            "typed_token": token, "native_probe_status": transcript.value as? String ?? ""]
    }

    private func extremeCanonicalProof(_ base: URL, password: String, after baseline: Int, minimum: Int) async throws -> [[String: Any]] {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = try await extremeStatus(base, password: password)
            let found = (status["recent_requests"] as? [[String: Any]] ?? []).filter { row in
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
            if app.buttons["projects.project.lab"].isHittable { return }
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
            "scope": "UI-observed action times include XCTest scheduling and Accessibility observation. Use the separate native phase probe for app-internal intervals; typing is observed acceptance, not earliest readiness or per-key latency."]
        let item = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        item.name = "extreme-\(mode)-\(trial)-g\(grouped ? 1 : 0)-\(checkpoint)"; item.lifetime = .keepAlways; add(item)
        print("EXTREME checkpoint \(checkpoint) actions=\(actions.count)")
    }
}

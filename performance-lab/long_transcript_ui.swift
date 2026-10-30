// CI-only smoke test. Append to the existing ToolGroupingUITests.swift so no
// project target changes are needed. Compiled and run on iPhone/iPad simulators.
// This exercises the normal connected ChatView, not the screenshot fixture.
import Foundation

@MainActor
extension ToolGroupingUITests {
    func testNativeLongTranscriptLabSmoke() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let password = try XCTUnwrap(environment["OPENCLIENT_LAB_UI_PASSWORD"], "Start the owned lab fixture and export its UI-test password.")
        let baseURL = try XCTUnwrap(URL(string: environment["OPENCLIENT_LAB_UI_URL"] ?? "http://127.0.0.1:14097"))
        guard baseURL.scheme == "http", baseURL.host == "127.0.0.1", baseURL.user == nil,
              baseURL.password == nil, baseURL.path.isEmpty, baseURL.query == nil else {
            throw labFailure("Only the CI runner's loopback lab origin is allowed.")
        }
        let target = Int(environment["OPENCLIENT_LAB_UI_TARGET_LOADED"] ?? "80") ?? 0
        let maximumSwipes = Int(environment["OPENCLIENT_LAB_UI_MAX_SWIPES"] ?? "240") ?? 0
        guard (21...2000).contains(target), (1...600).contains(maximumSwipes) else {
            throw labFailure("Target must be 21...2000; gesture budget must be 1...600.")
        }
        let initial = try await labRequest(baseURL, password: password, path: "/_lab/status")
        guard initial["synthetic"] as? Bool == true else { throw labFailure("Not a synthetic lab fixture.") }
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in app.terminate() }

        for size in [20, 200, 2000] {
            let sessionID = "ses_\(size)"
            let requiredLoaded = min(size, target)
            for grouped in [true, false] {
                print("LAB scenario seed=\(size) grouping=\(grouped) target=\(requiredLoaded)")
                let scenarioBaseline = labLastRequestID(try await labRequest(baseURL, password: password, path: "/_lab/status"))
                app.launchEnvironment = [
                    "OPENCODE_UI_TEST_MODE": "1", "OPENCODE_UI_TEST_AUTO_CONNECT": "1",
                    "OPENCODE_UI_TEST_BASE_URL": baseURL.absoluteString,
                    "OPENCODE_UI_TEST_USERNAME": "opencode", "OPENCODE_UI_TEST_PASSWORD": password,
                    "OPENCODE_UI_TEST_DIRECTORY": "/openclient-performance-lab",
                    "OPENCODE_UI_TEST_SERVER_NAME": "Owned performance lab",
                    "OPENCLIENT_PERF_DIAGNOSTICS": "1"
                ]
                app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                try await labWait("Connected home", timeout: 45) { app.buttons["projects.configurations"].isHittable }
                try await labSetGrouping(grouped, app: app)
                let search = app.textFields["projects.searchChats"]
                try await labWait("Home search") { search.isHittable }
                search.tap()
                search.typeText("Lab: \(size) messages")
                let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lab: \(size) messages")).firstMatch
                try await labWait("Owned lab session search result") { result.isHittable }
                let openedAt = ProcessInfo.processInfo.systemUptime
                result.tap()
                let transcript = app.collectionViews["chat.scroll"]
                let input = app.textViews["chat.input"]
                try await labWait("Native transcript", timeout: 45) {
                    transcript.exists && transcript.frame.height > 100 && input.exists && transcript.cells.count > 0
                }
                let openSeconds = ProcessInfo.processInfo.systemUptime - openedAt

                // Infer page coverage only from requests made by the app. This test
                // never calls a /session/.../message endpoint itself.
                var observed: [[String: Any]] = []
                var coverage = 0
                for swipe in 0...maximumSwipes {
                    let status = try await labRequest(baseURL, password: password, path: "/_lab/status")
                    let rows = (status["recent_requests"] as? [[String: Any]] ?? []).filter {
                        ($0["request_id"] as? Int ?? 0) > scenarioBaseline
                            && $0["path"] as? String == "/session/\(sessionID)/message" && $0["status"] as? Int == 200
                    }
                    let seen = Set(observed.compactMap { $0["request_id"] as? Int })
                    observed += rows.filter { !seen.contains($0["request_id"] as? Int ?? -1) }
                    coverage = max(coverage, labCoverage(rows, sessionID: sessionID, seedCount: size))
                    if coverage >= requiredLoaded { break }
                    guard swipe < maximumSwipes else { throw labFailure("Paging did not reach \(requiredLoaded) messages; observed lower bound \(coverage).") }
                    transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                        .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                               withVelocity: .slow, thenHoldForDuration: 0.2)
                    try await Task.sleep(for: .milliseconds(250))
                }
                if size > 20 && grouped {
                    XCTAssertTrue(observed.contains { (($0["query"] as? [String: [String]])?["before"]?.first) != nil },
                                  "The fresh grouped run must actually request an older page, not merely have a 2000-message server seed.")
                }
                print("LAB loaded seed=\(size) grouping=\(grouped) coverage=\(coverage)")
                try await labReturnToBottom(app: app, transcript: transcript)
                let beforeRefresh = try await labRequest(baseURL, password: password, path: "/_lab/status")
                let baselineID = labLastRequestID(beforeRefresh)
                let refreshAt = ProcessInfo.processInfo.systemUptime
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
                var refreshEvidence: [[String: Any]] = []
                for _ in 0..<160 {
                    let status = try await labRequest(baseURL, password: password, path: "/_lab/status")
                    refreshEvidence = (status["recent_requests"] as? [[String: Any]] ?? []).filter { row in
                        let query = row["query"] as? [String: [String]] ?? [:]
                        return (row["request_id"] as? Int ?? 0) > baselineID
                            && row["path"] as? String == "/session/\(sessionID)/message"
                            && row["status"] as? Int == 200
                            && query["before"] == nil && (Int(query["limit"]?.first ?? "") ?? 0) >= requiredLoaded
                    }
                    if !refreshEvidence.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard !refreshEvidence.isEmpty else { throw labFailure("Bottom pull produced no observed canonical refresh at the required loaded-history size.") }
                try await labWait("Composer survives refresh") { input.isHittable }
                let refreshSeconds = ProcessInfo.processInfo.systemUptime - refreshAt

                var status = try await labRequest(baseURL, password: password, path: "/_lab/status")
                guard (status["sse_connections"] as? Int ?? 0) > 0 else { throw labFailure("No live SSE consumer before streaming.") }
                let streamAt = ProcessInfo.processInfo.systemUptime
                let chunkBytes = grouped ? 16 : 17
                _ = try await labRequest(baseURL, password: password, path: "/_lab/stream", body: [
                    "sessionID": sessionID, "chunks": 120, "interval_ms": 100, "chunk_bytes": chunkBytes, "part_type": "text"
                ])
                let stop = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.stream.stop", "chat.stop"])).firstMatch
                try await labWait("Native streaming state", timeout: 10) { stop.exists }
                input.tap()
                let draft = "lab draft \(size) \(grouped)"
                app.typeKey("a", modifierFlags: .command)
                let beforeTyping = try await labRequest(baseURL, password: password, path: "/_lab/status")
                input.typeText(draft)
                let afterTyping = try await labRequest(baseURL, password: password, path: "/_lab/status")
                XCTAssertEqual(input.value as? String, draft, "Typing during streaming must not lose the draft.")
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let dismissStart = origin.withOffset(CGVector(dx: transcript.frame.midX, dy: input.frame.minY - 100))
                let dismissEnd = origin.withOffset(CGVector(dx: transcript.frame.midX, dy: app.frame.maxY - 30))
                dismissStart.press(forDuration: 0.05, thenDragTo: dismissEnd,
                                   withVelocity: .slow, thenHoldForDuration: 0.1)
                try await labWait("Interactive keyboard dismissal") { !app.keyboards.firstMatch.exists }
                try await labReturnToBottom(app: app, transcript: transcript)
                let finalText = String(repeating: "d", count: 120 * chunkBytes)
                try await labWait("Complete stream rendered", timeout: 35) {
                    let selectable = transcript.textViews.matching(NSPredicate(format: "value == %@", finalText)).firstMatch.exists
                    let plain = transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", finalText)).firstMatch.exists
                    return (selectable || plain) && !stop.exists
                }
                XCTAssertEqual(input.value as? String, draft)
                status = try await labRequest(baseURL, password: password, path: "/_lab/status")
                XCTAssertFalse((status["active"] as? [String] ?? []).contains(sessionID))
                let evidence: [String: Any] = [
                    "seed_messages": size, "minimum_loaded_messages": requiredLoaded, "observed_coverage_lower_bound": coverage,
                    "grouping": grouped, "open_to_observed_native_view_seconds": openSeconds,
                    "bottom_gesture_to_observed_refresh_response_seconds": refreshSeconds,
                    "stream_control_to_final_text_seconds": ProcessInfo.processInfo.systemUptime - streamAt,
                    "stream_active_before_typing": (beforeTyping["active"] as? [String] ?? []).contains(sessionID),
                    "stream_active_after_typing": (afterTyping["active"] as? [String] ?? []).contains(sessionID),
                    "paging_requests": observed, "refresh_requests": refreshEvidence, "fixture_status": status,
                    "scope": "Prototype UI smoke. Wall times include XCTest control/observation overhead; they are not FPS, CPU time, exact render completion, or Release-device performance. Seed size is not loaded size."
                ]
                let evidenceName = "native-lab-\(size)-grouping-\(grouped)"
                let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
                attachment.name = evidenceName
                attachment.lifetime = .keepAlways
                add(attachment)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = evidenceName + "-complete"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                print("LAB complete seed=\(size) grouping=\(grouped)")
                app.terminate()
            }
        }
    }

    private func labSetGrouping(_ enabled: Bool, app: XCUIApplication) async throws {
        app.buttons["projects.configurations"].tap()
        let appearance = app.buttons["configurations.connection-appearance"]
        try await labWait("Connection appearance") { appearance.isHittable }
        appearance.tap()
        let toggle = app.switches["configurations.group-tool-calls"]
        let control = toggle.switches.firstMatch
        for _ in 0..<12 {
            if control.exists && control.isHittable { break }
            var form: XCUIElement?
            try await labWait("Active appearance form") {
                form = [XCUIElement.ElementType.collectionView, .scrollView, .table].lazy.flatMap { type in
                    app.descendants(matching: type).allElementsBoundByIndex
                }.first { container in
                    container.frame.intersects(app.windows.firstMatch.frame)
                        && container.descendants(matching: .any)
                            .matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "appearance.", "configurations."))
                            .allElementsBoundByIndex.contains { $0.isHittable }
                }
                return form != nil
            }
            let scroll = try XCTUnwrap(form)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        try await labWait("Grouping setting") { control.exists && control.isHittable }
        if (toggle.value as? String == "1") != enabled {
            control.tap()
            try await labWait("Grouping setting changed") { toggle.value as? String == (enabled ? "1" : "0") }
        }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        let back = app.navigationBars["Appearance Settings"].buttons.firstMatch
        try await labWait("Appearance back button") { back.isHittable }
        back.tap()
        let done = app.buttons["Done"]
        try await labWait("Connection settings Done") { done.isHittable }
        done.tap()
    }

    private func labReturnToBottom(app: XCUIApplication, transcript: XCUIElement) async throws {
        let jump = app.buttons["chat.scrollToBottom"]
        if jump.exists && jump.isHittable { jump.tap() }
        try await labWait("Transcript at pinned tail", timeout: 15) { transcript.exists && !jump.exists }
    }

    private func labCoverage(_ rows: [[String: Any]], sessionID: String, seedCount: Int) -> Int {
        rows.reduce(0) { result, row in
            let query = row["query"] as? [String: [String]] ?? [:]
            let limit = Int(query["limit"]?.first ?? "0") ?? 0
            guard let before = query["before"]?.first else { return max(result, min(seedCount, limit)) }
            let prefix = "msg_\(sessionID)_"
            guard before.hasPrefix(prefix), let index = Int(before.dropFirst(prefix.count)) else { return result }
            return max(result, min(seedCount, seedCount - index + limit))
        }
    }

    private func labLastRequestID(_ status: [String: Any]) -> Int {
        ((status["recent_requests"] as? [[String: Any]] ?? []) + (status["inflight"] as? [[String: Any]] ?? []))
            .compactMap { $0["request_id"] as? Int }.max() ?? 0
    }

    private func labRequest(_ baseURL: URL, password: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard path.hasPrefix("/_lab/") else { throw labFailure("Only lab control requests are allowed from the UI runner.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.timeoutInterval = 10
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw labFailure("Lab control HTTP request failed at \(path).")
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func labWait(_ message: String, timeout: TimeInterval = 15, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw labFailure(message)
    }

    private func labFailure(_ message: String) -> NSError {
        NSError(domain: "OpenClientNativeLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

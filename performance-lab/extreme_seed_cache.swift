// CI-only unmeasured warm-cache preparation. Appended to the native repository tests.
import Foundation

extension OpenCodeLocalCacheRepositoryTests {
    func testPrepareExtremeSessionCache() async throws {
        let env = ProcessInfo.processInfo.environment
        let origin = try XCTUnwrap(env["OPENCLIENT_EXTREME_URL"])
        let password = try XCTUnwrap(env["OPENCLIENT_EXTREME_PASSWORD"])
        let count = try XCTUnwrap(Int(env["OPENCLIENT_EXTREME_COUNT"] ?? "5000"))
        let base = try XCTUnwrap(URL(string: origin))
        guard base.scheme == "http", base.host == "127.0.0.1", base.port == 14097,
              base.user == nil, base.password == nil, base.path.isEmpty, base.query == nil,
              (64...10000).contains(count), env["OPENCLIENT_EXTREME_SEED_ONLY"] == "1" else {
            throw NSError(domain: "OpenClientExtremeSeed", code: 1)
        }
        let originalRecent = UserDefaults.standard.data(forKey: "recentServerConfigs")
        defer {
            if let originalRecent { UserDefaults.standard.set(originalRecent, forKey: "recentServerConfigs") }
            else { UserDefaults.standard.removeObject(forKey: "recentServerConfigs") }
        }
        let config = OpenCodeServerConfig(baseURL: base.absoluteString, username: "opencode", password: password)
        var components = try XCTUnwrap(URLComponents(url: base.appendingPathComponent("session/ses_extreme/message"), resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "directory", value: "/openclient-performance-lab"),
            URLQueryItem(name: "limit", value: String(count))]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.timeoutInterval = 180
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let setup: (bytes: Int, first: String, last: String, http: Double, decode: Double, write: Double, writtenAt: Double)
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let downloaded = ProcessInfo.processInfo.systemUptime
            let messages = try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: data)
            XCTAssertEqual(messages.count, count)
            XCTAssertTrue(messages.allSatisfy { $0.info.sessionID == "ses_extreme" })
            let decoded = ProcessInfo.processInfo.systemUptime
            let repository = OpenCodeLocalCacheRepositoryFactory.makeDefault()
            try await repository.clear(serverID: config.recentServerID)
            let timestamp = Date().addingTimeInterval(-600)
            try await repository.saveChatMessages(messages, serverID: config.recentServerID, sessionID: "ses_extreme",
                refreshedAt: timestamp, writtenAt: .now, coverage: .newestPage(hasOlder: false))
            let written = ProcessInfo.processInfo.systemUptime
            setup = (data.count, try XCTUnwrap(messages.first?.info.id), try XCTUnwrap(messages.last?.info.id),
                downloaded - started, decoded - downloaded, written - decoded, written)
        } // Release the response Data, decoded envelopes, and writer before disk readback.
        let readRepository = OpenCodeLocalCacheRepositoryFactory.makeDefault()
        let loaded = try await readRepository.loadChat(serverID: config.recentServerID, sessionID: "ses_extreme")
        let reread = try XCTUnwrap(loaded)
        XCTAssertEqual(reread.preparedMessages.messages.count, count)
        XCTAssertEqual(reread.preparedMessages.messages.first?.id, setup.first)
        XCTAssertEqual(reread.preparedMessages.messages.last?.id, setup.last)
        XCTAssertFalse(reread.areMessagesFresh())
        let result: [String: Any] = ["schema": 1, "synthetic": true, "setup_only": true,
            "session_id": "ses_extreme", "server_id": config.recentServerID,
            "messages": count, "readback_messages": reread.preparedMessages.messages.count,
            "readback_used_second_repository": true, "encoded_response_bytes": setup.bytes,
            "http_seconds": setup.http, "decode_seconds": setup.decode,
            "production_cache_write_seconds": setup.write,
            "production_cache_readback_seconds": ProcessInfo.processInfo.systemUptime - setup.writtenAt,
            "repository_factory": "OpenCodeLocalCacheRepositoryFactory.makeDefault; persistent SwiftData through production deferred factory",
            "scope": "Unmeasured preparation of an explicitly seeded, stale full-history warm cache; not naturally paged history and not a UI loading measurement."]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try encoded.write(to: documents.appendingPathComponent("OpenClientExtremeCacheSeed.json"), options: .atomic)
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "extreme-cache-seed-production-writer"; attachment.lifetime = .keepAlways; add(attachment)
        print("EXTREME seed complete messages=\(count) bytes=\(setup.bytes)")
    }
}

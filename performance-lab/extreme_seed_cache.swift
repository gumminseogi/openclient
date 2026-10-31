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
              (64...50000).contains(count), env["OPENCLIENT_EXTREME_SEED_ONLY"] == "1" else {
            throw NSError(domain: "OpenClientExtremeSeed", code: 1)
        }
        let countOfHistory = count
        func checkpoint(_ phase: String, count: Int? = nil, bytes: Int? = nil) throws {
            var value: [String: Any] = ["schema": 1, "setup_only": true, "phase": phase,
                "requested_messages": countOfHistory, "uptime_s": ProcessInfo.processInfo.systemUptime]
            if let count { value["observed_messages"] = count }
            if let bytes { value["response_bytes"] = bytes }
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: documents.appendingPathComponent("OpenClientExtremeCacheSeedProgress.json"), options: .atomic)
            print("EXTREME seed checkpoint \(phase)")
        }
        try checkpoint("directory_request_started")
        let originalRecent = UserDefaults.standard.data(forKey: "recentServerConfigs")
        defer {
            if let originalRecent { UserDefaults.standard.set(originalRecent, forKey: "recentServerConfigs") }
            else { UserDefaults.standard.removeObject(forKey: "recentServerConfigs") }
        }
        let config = OpenCodeServerConfig(baseURL: base.absoluteString, username: "opencode", password: password)
        let authorization = "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
        var directoryComponents = try XCTUnwrap(URLComponents(url: base.appendingPathComponent("session"), resolvingAgainstBaseURL: false))
        directoryComponents.queryItems = [URLQueryItem(name: "directory", value: "/openclient-performance-lab"),
            URLQueryItem(name: "roots", value: "true"), URLQueryItem(name: "limit", value: "100")]
        var directoryRequest = URLRequest(url: try XCTUnwrap(directoryComponents.url))
        directoryRequest.timeoutInterval = 300
        directoryRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        let directoryStarted = ProcessInfo.processInfo.systemUptime
        let (directoryData, directoryResponse) = try await URLSession.shared.data(for: directoryRequest)
        XCTAssertEqual((directoryResponse as? HTTPURLResponse)?.statusCode, 200)
        let directoryDownloaded = ProcessInfo.processInfo.systemUptime
        let sessions = try JSONDecoder().decode([OpenCodeSession].self, from: directoryData)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "ses_extreme")
        XCTAssertEqual(sessions.first?.directory, "/openclient-performance-lab")
        let directoryDecoded = ProcessInfo.processInfo.systemUptime
        var components = try XCTUnwrap(URLComponents(url: base.appendingPathComponent("session/ses_extreme/message"), resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "directory", value: "/openclient-performance-lab"),
            URLQueryItem(name: "limit", value: String(count))]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.timeoutInterval = 300
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let setup: (bytes: Int, first: String, last: String, http: Double, decode: Double,
            write: Double, directoryWrite: Double, writtenAt: Double)
        do {
            try checkpoint("history_request_started")
            let started = ProcessInfo.processInfo.systemUptime
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            try checkpoint("history_downloaded", bytes: data.count)
            let downloaded = ProcessInfo.processInfo.systemUptime
            let messages = try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: data)
            XCTAssertEqual(messages.count, count)
            XCTAssertTrue(messages.allSatisfy { $0.info.sessionID == "ses_extreme" })
            try checkpoint("history_decoded", count: messages.count, bytes: data.count)
            let decoded = ProcessInfo.processInfo.systemUptime
            let repository = OpenCodeLocalCacheRepositoryFactory.makeDefault()
            try await repository.clear(serverID: config.recentServerID)
            let timestamp = Date().addingTimeInterval(-600)
            let directoryWriteStarted = ProcessInfo.processInfo.systemUptime
            try await repository.saveDirectorySessions(sessions, serverID: config.recentServerID,
                directory: "/openclient-performance-lab", refreshedAt: timestamp, writtenAt: .now)
            let directoryWritten = ProcessInfo.processInfo.systemUptime
            try checkpoint("cache_write_started", count: messages.count)
            try await repository.saveChatMessages(messages, serverID: config.recentServerID, sessionID: "ses_extreme",
                refreshedAt: timestamp, writtenAt: .now, coverage: .newestPage(hasOlder: false))
            try checkpoint("cache_written", count: messages.count)
            let written = ProcessInfo.processInfo.systemUptime
            setup = (data.count, try XCTUnwrap(messages.first?.info.id), try XCTUnwrap(messages.last?.info.id),
                downloaded - started, decoded - downloaded, written - directoryWritten,
                directoryWritten - directoryWriteStarted, written)
        } // Release the response Data, decoded envelopes, and writer before disk readback.
        let readRepository = OpenCodeLocalCacheRepositoryFactory.makeDefault()
        let loadedDirectory = try await readRepository.loadDirectorySessions(serverID: config.recentServerID,
            directory: "/openclient-performance-lab")
        let directoryReread = try XCTUnwrap(loadedDirectory)
        XCTAssertEqual(directoryReread.sessions.count, 1)
        XCTAssertEqual(directoryReread.sessions.first?.id, "ses_extreme")
        let loaded = try await readRepository.loadChat(serverID: config.recentServerID, sessionID: "ses_extreme")
        let reread = try XCTUnwrap(loaded)
        try checkpoint("cache_readback_finished", count: reread.preparedMessages.messages.count)
        XCTAssertEqual(reread.preparedMessages.messages.count, count)
        XCTAssertEqual(reread.preparedMessages.messages.first?.id, setup.first)
        XCTAssertEqual(reread.preparedMessages.messages.last?.id, setup.last)
        XCTAssertFalse(reread.areMessagesFresh())
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let storeURL = support.appendingPathComponent("OpenCodeLocalSnapshotCache.store")
        let storeBytes = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? NSNumber)?.uint64Value)
        XCTAssertGreaterThan(storeBytes, 0)
        let result: [String: Any] = ["schema": 1, "synthetic": true, "setup_only": true,
            "session_id": "ses_extreme", "server_id": config.recentServerID,
            "messages": count, "readback_messages": reread.preparedMessages.messages.count,
            "readback_used_second_repository": true, "encoded_response_bytes": setup.bytes,
            "directory_sessions": sessions.count, "readback_directory_sessions": directoryReread.sessions.count,
            "readback_directory_session_ids": directoryReread.sessions.map(\.id),
            "directory_metadata_encoded_response_bytes": directoryData.count,
            "directory_metadata_http_seconds": directoryDownloaded - directoryStarted,
            "directory_metadata_decode_seconds": directoryDecoded - directoryDownloaded,
            "production_directory_metadata_write_seconds": setup.directoryWrite,
            "cache_store_relative_path": "Library/Application Support/OpenCodeLocalSnapshotCache.store",
            "cache_store_bytes": storeBytes,
            "http_seconds": setup.http, "decode_seconds": setup.decode,
            "production_cache_write_seconds": setup.write,
            "production_cache_readback_seconds": ProcessInfo.processInfo.systemUptime - setup.writtenAt,
            "repository_factory": "OpenCodeLocalCacheRepositoryFactory.makeDefault; persistent SwiftData through production deferred factory",
            "scope": "Unmeasured preparation of stale full-history chat and real directory-session metadata through the production persistent writer; not naturally paged history or a UI loading measurement."]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try encoded.write(to: documents.appendingPathComponent("OpenClientExtremeCacheSeed.json"), options: .atomic)
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "extreme-cache-seed-production-writer"; attachment.lifetime = .keepAlways; add(attachment)
        print("EXTREME seed complete messages=\(count) bytes=\(setup.bytes)")
    }
}


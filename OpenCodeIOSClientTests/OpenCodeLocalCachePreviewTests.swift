import XCTest
import SwiftData
@testable import OpenClient

final class OpenCodeLocalCachePreviewTests: XCTestCase {
    func testBoundedPreviewKeepsRetainedHistoryAndDoesNotValidateItsOlderRows() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = try (0..<600).map { try message($0) }
        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(100), writtenAt: date(100))
        let firstValue = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.snapshot.messages.count, 400)
        XCTAssertEqual(first.retainedMessageCount, 600)
        XCTAssertTrue(first.hasRetainedHistory)
        XCTAssertTrue(first.hasOlderMessages)

        var latest = Array(original.suffix(399))
        latest[latest.count - 1] = try message(599, text: "Latest edit")
        latest.append(try message(600))
        try await repository.saveChatPreview(latest, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(200), writtenAt: date(200), coverage: .newestPage(hasOlder: true))
        let previewValue = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        let preview = try XCTUnwrap(previewValue)
        let fullValue = try await repository.loadChat(serverID: "server", sessionID: "s")
        let full = try XCTUnwrap(fullValue)
        XCTAssertEqual(preview.snapshot.messages.count, 400)
        XCTAssertEqual(preview.snapshot.messagesRefreshedAt, date(200))
        XCTAssertEqual(full.messages.count, 601)
        XCTAssertEqual(full.messages.first, original.first)
        XCTAssertEqual(full.messages.last, latest.last)
        XCTAssertEqual(full.messages.first { $0.id == "m0599" }, latest[latest.count - 2])
        XCTAssertEqual(full.messagesRefreshedAt, date(100), "A recent window must not validate the retained archive")
    }

    func testCanonicalWindowPruningSurvivesLaterPartialPreviewWrites() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = try (0..<4).map { try message($0) }
        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10))
        let latest = [original[2], try message(4)]
        try await repository.saveChatPreview(latest, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: true))
        try await repository.saveChatPreview([try message(4, text: "Live update")], hasOlderMessages: true,
            serverID: "server", sessionID: "s", refreshedAt: date(20), writtenAt: date(30))
        let loadedValue = try await repository.loadChat(serverID: "server", sessionID: "s")
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.messages.map(\.id), ["m0000", "m0001", "m0002", "m0004"])
        XCTAssertEqual(loaded.messages.last, try message(4, text: "Live update"))
        XCTAssertEqual(loaded.messagesRefreshedAt, date(10))
    }

    func testMessageAndPartRemovalsCannotReappearFromTheArchiveOrDelayedPreview() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = try (0..<3).map { try message($0) }
        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10))
        try await repository.applyChatRemoval(serverID: "server", sessionID: "s",
            messageID: "m0001", partID: nil, writtenAt: date(30))
        try await repository.applyChatRemoval(serverID: "server", sessionID: "s",
            messageID: "m0002", partID: "p2", writtenAt: date(40))
        try await repository.saveChatPreview(original, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: true))
        // A newer partial write is still not authority to undo a known removal.
        try await repository.saveChatPreview(original, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(50), writtenAt: date(50))
        let loadedValue = try await repository.loadChat(serverID: "server", sessionID: "s")
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.messages.map(\.id), ["m0000", "m0002"])
        XCTAssertEqual(loaded.messages.last?.parts, [])
        let previewValue = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        let preview = try XCTUnwrap(previewValue)
        XCTAssertEqual(preview.snapshot.messages.map(\.id), loaded.messages.map(\.id))
        XCTAssertNil(preview.retainedMessageCount)

        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(60), writtenAt: date(60), coverage: .newestPage(hasOlder: false))
        let canonical = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(canonical?.messages, original, "Only a newer complete canonical snapshot can supersede removals")
    }

    func testAdvancingAndRecedingHTTPWindowsKeepEarlierDeletionEvidence() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = try (0..<1_000).map { try message($0) }
        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10))
        let first = try (599..<1_000).filter { $0 != 700 }.map { try message($0) }
        try await repository.saveChatPreview(first, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: true))
        let second = try (800..<1_200).map { try message($0) }
        try await repository.saveChatPreview(second, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(30), writtenAt: date(30), coverage: .newestPage(hasOlder: true))
        let advancedValue = try await repository.loadChat(serverID: "server", sessionID: "s")
        let advanced = try XCTUnwrap(advancedValue)
        XCTAssertEqual(advanced.messages.count, 1_199)
        XCTAssertFalse(advanced.messages.contains { $0.id == "m0700" })
        let third = try (100..<500).map { try message($0) }
        try await repository.saveChatPreview(third, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(40), writtenAt: date(40), coverage: .newestPage(hasOlder: true))
        let receded = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(receded?.messages.map(\.id), Array(original.prefix(500)).map(\.id))
        XCTAssertEqual(receded?.messagesRefreshedAt, date(10))
    }

    func testCompleteEmptySnapshotWinsAndSessionDeletionRejectsDelayedWrites() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = try (0..<5).map { try message($0) }
        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10))
        try await repository.saveChatPreview([], hasOlderMessages: false, serverID: "server", sessionID: "s",
            refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: false))
        let empty = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(empty?.messages, [])
        try await repository.removeSession(serverID: "server", sessionID: "s", removedAt: date(40))
        try await repository.saveChatPreview(original, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(30), writtenAt: date(30), coverage: .newestPage(hasOlder: true))
        let removed = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        let full = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertNil(removed)
        XCTAssertNil(full)
    }

    func testNewestCoveredHTTPProofWinsEvenWhenItsMessagesAgeOutOfThePreview() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = try (0..<1_000).map { try message($0) }
        try await repository.saveChatMessages(original, serverID: "server", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10))
        let present = Array(original.suffix(400))
        let absent = present.filter { $0.id != "m0700" }
        // A -> B -> A must refresh A's chronology rather than keeping its old timestamp.
        for (seconds, window) in [(20.0, present), (30.0, absent), (40.0, present)] {
            try await repository.saveChatPreview(window, hasOlderMessages: true, serverID: "server", sessionID: "s",
                refreshedAt: date(seconds), writtenAt: date(seconds), coverage: .newestPage(hasOlder: true))
        }
        let newer = try (1_000..<1_400).map { try message($0) }
        try await repository.saveChatPreview(newer, hasOlderMessages: true, serverID: "server", sessionID: "s",
            refreshedAt: date(40), writtenAt: date(50))
        let preview = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        XCTAssertFalse(preview?.snapshot.messages.contains { $0.id == "m0700" } == true)
        let full = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(full?.messages.count, 1_400)
        XCTAssertEqual(full?.messages.first { $0.id == "m0700" }, original[700])
    }

    func testPreviewOnlyCacheTodosAndClearRemainIsolatedByServer() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        try await repository.saveChatPreview([try message(1)], hasOlderMessages: true, serverID: "a", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10), coverage: .newestPage(hasOlder: true))
        try await repository.saveChatPreview([try message(2)], hasOlderMessages: true, serverID: "b", sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10), coverage: .newestPage(hasOlder: true))
        let todos = [OpenCodeTodo(content: "Latest", status: "pending", priority: "high")]
        try await repository.saveTodos(todos, serverID: "a", sessionID: "s", refreshedAt: date(20), writtenAt: date(20))
        let firstValue = try await repository.loadChatPreview(serverID: "a", sessionID: "s")
        let first = try XCTUnwrap(firstValue)
        XCTAssertFalse(first.hasRetainedHistory)
        XCTAssertNil(first.retainedMessageCount)
        XCTAssertEqual(first.snapshot.todos, todos)
        let full = try await repository.loadChat(serverID: "a", sessionID: "s")
        XCTAssertEqual(full?.messages.map(\.id), ["m0001"])
        XCTAssertNil(full?.messagesRefreshedAt)
        try await repository.clear(serverID: "a")
        try await repository.saveChatPreview([try message(3)], hasOlderMessages: true, serverID: "a", sessionID: "s",
            refreshedAt: date(30), writtenAt: date(30))
        let cleared = try await repository.loadChatPreview(serverID: "a", sessionID: "s")
        let retained = try await repository.loadChatPreview(serverID: "b", sessionID: "s")
        XCTAssertNil(cleared)
        XCTAssertEqual(retained?.snapshot.messages.map(\.id), ["m0002"])
    }

    func testV2PreviewMethodsDoNotAlterCanonicalV2Cache() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let namespace = OpenCodeLocalCacheIdentity.namespace(serverID: "server", profile: .v2)
        let original = [try message(1)]
        try await repository.saveChatMessages(original, serverID: namespace, sessionID: "s",
            refreshedAt: date(10), writtenAt: date(10))
        try await repository.saveChatPreview([], hasOlderMessages: false, serverID: namespace, sessionID: "s",
            refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: false))
        try await repository.applyChatRemoval(serverID: namespace, sessionID: "s",
            messageID: "m0001", partID: nil, writtenAt: date(30))
        let preview = try await repository.loadChatPreview(serverID: namespace, sessionID: "s")
        let full = try await repository.loadChat(serverID: namespace, sessionID: "s")
        XCTAssertNil(preview)
        XCTAssertEqual(full?.messages, original)
    }

    @MainActor
    func testBoundedPageNeverReplacesOrRequiresDecodingTheRetainedBlob() async throws {
        let schema = Schema(versionedSchema: OpenCodeLocalCacheSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let originalPayload = Data("archive retained without decoding".utf8)
        let context = ModelContext(container)
        context.insert(OpenCodeCachedChatRecord(key: "s6:servers1:s", serverID: "server", sessionID: "s",
            messagesPayload: originalPayload, messagesRefreshedAt: date(10), messagesWrittenAt: date(10)))
        try context.save()
        let repository = SwiftDataOpenCodeLocalCacheRepository(modelContainer: container)
        let latest = try (0..<450).map { try message($0) }
        try await repository.saveChatMessages(latest, serverID: "server", sessionID: "s",
            refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: true))
        let previewValue = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        let preview = try XCTUnwrap(previewValue)
        XCTAssertEqual(preview.snapshot.messages, Array(latest.suffix(400)))
        XCTAssertTrue(preview.hasOlderMessages)
        for seconds in [30.0, 40.0] {
            try await repository.saveChatPreview(latest, hasOlderMessages: true, serverID: "server", sessionID: "s",
                refreshedAt: date(seconds), writtenAt: date(seconds), coverage: .newestPage(hasOlder: true))
        }
        let readback = ModelContext(container)
        let records = try readback.fetch(FetchDescriptor<OpenCodeCachedChatRecord>())
        XCTAssertEqual(records.first?.messagesPayload, originalPayload)
        XCTAssertEqual(records.first?.messagesRefreshedAt, date(10))
        let previews = try readback.fetch(FetchDescriptor<OpenCodeCachedChatPreviewRecord>())
        let proofPayload = try XCTUnwrap(previews.first?.newestProofsPayload)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: proofPayload) as? [Any])?.count, 1)
        let recovered = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(recovered?.messages.count, 400)
        XCTAssertNil(recovered?.messagesRefreshedAt, "Preview recovery cannot validate a corrupt retained archive")
    }

    @MainActor
    func testV1DiskStoreMigratesWithoutDecodingOrDiscardingItsArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.store")
        let original = try (0..<500).map { try message($0) }
        do {
            let schema = Schema(versionedSchema: OpenCodeLocalCacheSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(OpenCodeCachedChatRecord(key: "s6:servers1:s", serverID: "server", sessionID: "s",
                messagesPayload: try JSONEncoder().encode(original), messagesRefreshedAt: date(10), messagesWrittenAt: date(10)))
            try context.save()
        }
        let schema = Schema(versionedSchema: OpenCodeLocalCacheSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: OpenCodeLocalCacheMigrationPlan.self, configurations: [configuration])
        let repository = SwiftDataOpenCodeLocalCacheRepository(modelContainer: container)
        let before = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        XCTAssertNil(before, "A migrated archive must not be decoded merely to invent its preview")
        let retained = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(retained?.messages, original)
        try await repository.saveChatPreview(Array(original.suffix(400)), hasOlderMessages: true,
            serverID: "server", sessionID: "s", refreshedAt: date(20), writtenAt: date(20), coverage: .newestPage(hasOlder: true))
        let previewValue = try await repository.loadChatPreview(serverID: "server", sessionID: "s")
        let preview = try XCTUnwrap(previewValue)
        XCTAssertTrue(preview.hasRetainedHistory)
        XCTAssertNil(preview.retainedMessageCount, "A V1 archive has no count metadata until explicitly read or rewritten")
        let after = try await repository.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(after?.messages, original)
        XCTAssertEqual(after?.messagesRefreshedAt, date(10))
        let reopened = SwiftDataOpenCodeLocalCacheRepository(modelContainer: container)
        try await reopened.saveChatMessages(Array(original.prefix(1)), serverID: "server", sessionID: "s",
            refreshedAt: date(15), writtenAt: date(15))
        let protected = try await reopened.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(protected?.messages, original, "The preview's persisted write precedence survives a new repository")
        try await reopened.removeSession(serverID: "server", sessionID: "s", removedAt: date(15))
        let removalProtected = try await reopened.loadChat(serverID: "server", sessionID: "s")
        XCTAssertEqual(removalProtected?.messages, original, "A stale removal must not delete older rows behind a newer preview")
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func message(_ index: Int, text: String? = nil) throws -> OpenCodeMessageEnvelope {
        let id = String(format: "m%04d", index)
        let object: [String: Any] = [
            "info": ["id": id, "sessionID": "s", "role": "assistant", "time": ["created": index + 1]],
            "parts": [["id": "p\(index)", "messageID": id, "sessionID": "s", "type": "text", "text": text ?? "Message \(index)"]]
        ]
        return try JSONDecoder().decode(OpenCodeMessageEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

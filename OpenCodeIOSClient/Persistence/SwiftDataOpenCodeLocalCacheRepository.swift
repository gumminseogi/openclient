import Foundation
import SwiftData

private struct OpenCodeCachedDirectoryPayload: Codable {
    let sessions: [OpenCodeSession]
    let statuses: [String: String]?
    let permissions: [OpenCodePermission]?
    let questions: [OpenCodeQuestionRequest]?
}

private struct OpenCodeCachedChatRemovals: Codable {
    var messages: [String: Date] = [:]
    var parts: [String: [String: Date]] = [:]

    func applying(to source: [OpenCodeMessageEnvelope]) -> [OpenCodeMessageEnvelope] {
        source.filter { messages[$0.id] == nil }.map { envelope in
            guard let removed = parts[envelope.id] else { return envelope }
            var envelope = envelope
            envelope.parts.removeAll { part in part.id.map { removed[$0] != nil } ?? false }
            return envelope
        }
    }

    mutating func discard(through date: Date) {
        messages = messages.filter { $0.value > date }
        parts = parts.mapValues { $0.filter { $0.value > date } }.filter { !$0.value.isEmpty }
    }
}

private struct OpenCodeCachedNewestWindowProof: Codable {
    let firstMessage: OpenCodeMessage
    let messageIDs: Set<String>
    let writtenAt: Date
}

@Model
final class OpenCodeCachedProjectsRecord {
    @Attribute(.unique) var key: String
    var serverID: String
    var payload: Data
    var refreshedAt: Date
    var writtenAt: Date = Date.distantPast

    init(key: String, serverID: String, payload: Data, refreshedAt: Date, writtenAt: Date) {
        self.key = key
        self.serverID = serverID
        self.payload = payload
        self.refreshedAt = refreshedAt
        self.writtenAt = writtenAt
    }
}

@Model
final class OpenCodeCachedDirectorySessionsRecord {
    @Attribute(.unique) var key: String
    var serverID: String
    var payload: Data
    var refreshedAt: Date
    var writtenAt: Date = Date.distantPast

    init(key: String, serverID: String, payload: Data, refreshedAt: Date, writtenAt: Date) {
        self.key = key
        self.serverID = serverID
        self.payload = payload
        self.refreshedAt = refreshedAt
        self.writtenAt = writtenAt
    }
}

@Model
final class OpenCodeCachedChatRecord {
    @Attribute(.unique) var key: String
    var serverID: String
    var sessionID: String
    var messagesPayload: Data?
    var todosPayload: Data?
    var messagesRefreshedAt: Date?
    var todosRefreshedAt: Date?
    var messagesWrittenAt: Date = Date.distantPast
    var todosWrittenAt: Date = Date.distantPast
    var deletedAt: Date?

    init(
        key: String,
        serverID: String,
        sessionID: String,
        messagesPayload: Data? = nil,
        todosPayload: Data? = nil,
        messagesRefreshedAt: Date? = nil,
        todosRefreshedAt: Date? = nil,
        messagesWrittenAt: Date = .distantPast,
        todosWrittenAt: Date = .distantPast,
        deletedAt: Date? = nil
    ) {
        self.key = key
        self.serverID = serverID
        self.sessionID = sessionID
        self.messagesPayload = messagesPayload
        self.todosPayload = todosPayload
        self.messagesRefreshedAt = messagesRefreshedAt
        self.todosRefreshedAt = todosRefreshedAt
        self.messagesWrittenAt = messagesWrittenAt
        self.todosWrittenAt = todosWrittenAt
        self.deletedAt = deletedAt
    }
}

@Model
final class OpenCodeCachedChatPreviewRecord {
    @Attribute(.unique) var key: String
    var serverID: String
    var sessionID: String
    var messagesPayload: Data?
    var todosPayload: Data?
    var messagesRefreshedAt: Date?
    var todosRefreshedAt: Date?
    var messagesWrittenAt: Date = Date.distantPast
    var todosWrittenAt: Date = Date.distantPast
    var deletedAt: Date?
    var hasOlderMessages: Bool = false
    var retainedMessageCount: Int?
    var newestProofsPayload: Data?
    var removalsPayload: Data?

    init(key: String, serverID: String, sessionID: String) {
        self.key = key
        self.serverID = serverID
        self.sessionID = sessionID
    }
}

enum OpenCodeLocalCacheSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            OpenCodeCachedProjectsRecord.self,
            OpenCodeCachedDirectorySessionsRecord.self,
            OpenCodeCachedChatRecord.self,
        ]
    }
}

enum OpenCodeLocalCacheSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        OpenCodeLocalCacheSchemaV1.models + [OpenCodeCachedChatPreviewRecord.self]
    }
}

enum OpenCodeLocalCacheMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [OpenCodeLocalCacheSchemaV1.self, OpenCodeLocalCacheSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: OpenCodeLocalCacheSchemaV1.self, toVersion: OpenCodeLocalCacheSchemaV2.self)]
    }
}

@ModelActor
actor SwiftDataOpenCodeLocalCacheRepository: OpenCodeLocalCacheRepository {
    private var latestMessagesWrittenAtByKey: [String: Date] = [:]
    private var latestTodosWrittenAtByKey: [String: Date] = [:]
    private var clearedAtByNamespace: [String: Date] = [:]

    func loadProjects(serverID: String) async throws -> OpenCodeCachedProjectsSnapshot? {
        let key = OpenCodeLocalCacheKey.make([serverID])
        guard let record = try projectsRecord(forKey: key) else { return nil }
        return OpenCodeCachedProjectsSnapshot(
            projects: try decode([OpenCodeProject].self, from: record.payload),
            refreshedAt: record.refreshedAt
        )
    }

    func saveProjects(
        _ projects: [OpenCodeProject],
        serverID: String,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {
        guard writtenAt > (clearedAtByNamespace[serverID] ?? .distantPast) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID])
        let payload = try encode(OpenCodeLocalCacheIdentity.isV2(serverID) ? Array(projects.prefix(100)) : projects)
        if let record = try projectsRecord(forKey: key) {
            guard writtenAt >= record.writtenAt else { return }
            record.serverID = serverID
            record.payload = payload
            record.refreshedAt = refreshedAt
            record.writtenAt = writtenAt
        } else {
            modelContext.insert(
                OpenCodeCachedProjectsRecord(
                    key: key,
                    serverID: serverID,
                    payload: payload,
                    refreshedAt: refreshedAt,
                    writtenAt: writtenAt
                )
            )
        }
        try modelContext.save()
    }

    func loadDirectorySessions(
        serverID: String,
        directory: String?
    ) async throws -> OpenCodeCachedDirectorySessionsSnapshot? {
        let key = OpenCodeLocalCacheKey.make([serverID, directory])
        guard let record = try directorySessionsRecord(forKey: key) else { return nil }
        let payload = try directoryPayload(from: record.payload)
        return OpenCodeCachedDirectorySessionsSnapshot(
            sessions: payload.sessions,
            statuses: OpenCodeLocalCacheIdentity.isV2(serverID) ? nil : payload.statuses,
            permissions: OpenCodeLocalCacheIdentity.isV2(serverID) ? nil : payload.permissions,
            questions: OpenCodeLocalCacheIdentity.isV2(serverID) ? nil : payload.questions,
            refreshedAt: OpenCodeLocalCacheIdentity.isV2(serverID) ? .distantPast : record.refreshedAt
        )
    }

    func saveDirectorySessions(
        _ sessions: [OpenCodeSession],
        serverID: String,
        directory: String?,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {
        guard writtenAt > (clearedAtByNamespace[serverID] ?? .distantPast) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID, directory])
        let existing = try directorySessionsRecord(forKey: key)
            .flatMap { try? directoryPayload(from: $0.payload) }
        let payload = try encode(
            OpenCodeCachedDirectoryPayload(
                sessions: sessions,
                statuses: existing?.statuses,
                permissions: existing?.permissions,
                questions: existing?.questions
            )
        )
        if let record = try directorySessionsRecord(forKey: key) {
            guard writtenAt >= record.writtenAt else { return }
            record.serverID = serverID
            record.payload = payload
            record.refreshedAt = refreshedAt
            record.writtenAt = writtenAt
        } else {
            modelContext.insert(
                OpenCodeCachedDirectorySessionsRecord(
                    key: key,
                    serverID: serverID,
                    payload: payload,
                    refreshedAt: refreshedAt,
                    writtenAt: writtenAt
                )
            )
        }
        try modelContext.save()
    }

    func saveDirectoryMetadata(
        statuses: [String: String],
        permissions: [OpenCodePermission],
        questions: [OpenCodeQuestionRequest],
        serverID: String,
        directory: String?,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {
        guard writtenAt > (clearedAtByNamespace[serverID] ?? .distantPast),
              !OpenCodeLocalCacheIdentity.isV2(serverID) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID, directory])
        if let record = try directorySessionsRecord(forKey: key) {
            guard writtenAt >= record.writtenAt else { return }
            let existing = try directoryPayload(from: record.payload)
            record.serverID = serverID
            record.payload = try encode(
                OpenCodeCachedDirectoryPayload(
                    sessions: existing.sessions,
                    statuses: statuses,
                    permissions: permissions,
                    questions: questions
                )
            )
            record.refreshedAt = refreshedAt
            record.writtenAt = writtenAt
        } else {
            modelContext.insert(
                OpenCodeCachedDirectorySessionsRecord(
                    key: key,
                    serverID: serverID,
                    payload: try encode(
                        OpenCodeCachedDirectoryPayload(
                            sessions: [],
                            statuses: statuses,
                            permissions: permissions,
                            questions: questions
                        )
                    ),
                    refreshedAt: refreshedAt,
                    writtenAt: writtenAt
                )
            )
        }
        try modelContext.save()
    }

    private func directoryPayload(from data: Data) throws -> OpenCodeCachedDirectoryPayload {
        if let payload = try? decode(OpenCodeCachedDirectoryPayload.self, from: data) {
            return payload
        }
        return OpenCodeCachedDirectoryPayload(
            sessions: try decode([OpenCodeSession].self, from: data),
            statuses: nil,
            permissions: nil,
            questions: nil
        )
    }

    func loadChat(
        serverID: String,
        sessionID: String
    ) async throws -> OpenCodeCachedChatSnapshot? {
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        guard let record = try chatRecord(forKey: key), record.deletedAt == nil else {
            guard !OpenCodeLocalCacheIdentity.isV2(serverID),
                  let preview = try await loadChatPreview(serverID: serverID, sessionID: sessionID) else { return nil }
            return OpenCodeCachedChatSnapshot(preparedMessages: preview.snapshot.preparedMessages,
                todos: preview.snapshot.todos, messagesRefreshedAt: nil,
                todosRefreshedAt: preview.snapshot.todosRefreshedAt)
        }

        var messages = record.messagesPayload
            .flatMap { try? decode([OpenCodeMessageEnvelope].self, from: $0) }
        let decodedRetainedMessages = messages != nil
        let todos = record.todosPayload
            .flatMap { try? decode([OpenCodeTodo].self, from: $0) }
        var loadedTodos = todos ?? []
        var todosRefreshedAt = todos == nil ? nil : record.todosRefreshedAt
        if !OpenCodeLocalCacheIdentity.isV2(serverID),
           let preview = try previewRecord(forKey: key), preview.deletedAt == nil {
            let removals = removals(in: preview)
            let proofs = newestProofs(in: preview).filter { $0.writtenAt >= record.messagesWrittenAt }
            messages = messages.map { existing in
                existing.filter { message in
                    guard let proof = proofs.last(where: {
                        !OpenCodeMessage.isOrderedBefore(message.info, $0.firstMessage)
                    }) else { return true }
                    return proof.messageIDs.contains(message.id)
                }
            }
            if preview.messagesWrittenAt >= record.messagesWrittenAt,
               let payload = preview.messagesPayload,
               let window = try? decode([OpenCodeMessageEnvelope].self, from: payload) {
                messages = mergingPreview(window, into: messages ?? [])
            }
            if preview.todosWrittenAt >= record.todosWrittenAt,
               let payload = preview.todosPayload,
               let previewTodos = try? decode([OpenCodeTodo].self, from: payload) {
                loadedTodos = previewTodos
                todosRefreshedAt = preview.todosRefreshedAt
            }
            messages = messages.map { removals.applying(to: $0) }
        }

        return OpenCodeCachedChatSnapshot(
            preparedMessages: OpenCodeCachedMessageState(
                envelopes: messages ?? [],
                sessionID: sessionID,
                preservingOrder: OpenCodeLocalCacheIdentity.isV2(serverID)
            ),
            todos: OpenCodeLocalCacheIdentity.isV2(serverID) ? [] : loadedTodos,
            messagesRefreshedAt: OpenCodeLocalCacheIdentity.isV2(serverID) || !decodedRetainedMessages ? nil : record.messagesRefreshedAt,
            todosRefreshedAt: OpenCodeLocalCacheIdentity.isV2(serverID) ? nil : todosRefreshedAt
        )
    }

    func loadChatPreview(serverID: String, sessionID: String) async throws -> OpenCodeCachedChatPreview? {
        guard !OpenCodeLocalCacheIdentity.isV2(serverID) else { return nil }
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        guard let record = try previewRecord(forKey: key), record.deletedAt == nil,
              let payload = record.messagesPayload,
              let messages = try? decode([OpenCodeMessageEnvelope].self, from: payload) else { return nil }
        let todos = record.todosPayload.flatMap { try? decode([OpenCodeTodo].self, from: $0) }
        let visibleMessages = removals(in: record).applying(to: messages)
        let hasRetainedHistory = try hasRetainedChat(forKey: key)
        return OpenCodeCachedChatPreview(
            snapshot: OpenCodeCachedChatSnapshot(
                preparedMessages: OpenCodeCachedMessageState(envelopes: visibleMessages, sessionID: sessionID),
                todos: todos ?? [], messagesRefreshedAt: record.messagesRefreshedAt,
                todosRefreshedAt: todos == nil ? nil : record.todosRefreshedAt
            ),
            hasOlderMessages: record.hasOlderMessages,
            retainedMessageCount: hasRetainedHistory ? record.retainedMessageCount : nil,
            hasRetainedHistory: hasRetainedHistory
        )
    }

    func saveChatPreview(
        _ messages: [OpenCodeMessageEnvelope], hasOlderMessages: Bool,
        serverID: String, sessionID: String, refreshedAt: Date, writtenAt: Date,
        coverage: OpenCodeLocalCacheTranscriptCoverage
    ) async throws {
        guard !OpenCodeLocalCacheIdentity.isV2(serverID),
              try canWritePreview(serverID: serverID, sessionID: sessionID, writtenAt: writtenAt) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        let record = try previewRecord(forKey: key) ?? insertPreviewRecord(key: key, serverID: serverID, sessionID: sessionID)
        var removals = removals(in: record)
        let isNewest: Bool
        if case .newestPage = coverage { isNewest = true } else { isNewest = false }
        if isNewest, !hasOlderMessages { removals.discard(through: writtenAt) }
        var source = messages
        if !isNewest, let payload = record.messagesPayload,
           let existing = try? decode([OpenCodeMessageEnvelope].self, from: payload) {
            source = mergingPreview(messages, into: existing)
        }
        source = removals.applying(to: source)
        let window = Array(source.filter { $0.info.sessionID == sessionID }
            .sorted { OpenCodeMessage.isOrderedBefore($0.info, $1.info) }
            .suffix(OpenCodeCachedChatPreview.messageLimit))
        record.messagesPayload = try encode(window)
        record.removalsPayload = try encode(removals)
        record.messagesRefreshedAt = refreshedAt
        record.messagesWrittenAt = writtenAt
        record.hasOlderMessages = hasOlderMessages || source.count > window.count || (!isNewest && record.hasOlderMessages)
        if isNewest {
            var proofs = newestProofs(in: record)
            if !hasOlderMessages { proofs = [] }
            else if let first = window.first {
                let ids = Set(window.map(\.id))
                proofs.removeAll {
                    $0.messageIDs == ids
                        && !OpenCodeMessage.isOrderedBefore($0.firstMessage, first.info)
                        && !OpenCodeMessage.isOrderedBefore(first.info, $0.firstMessage)
                }
                // ponytail: distinct proofs grow until full reconciliation; coalesce ranges if long uninterrupted sessions need it.
                proofs.append(OpenCodeCachedNewestWindowProof(firstMessage: first.info,
                    messageIDs: ids, writtenAt: writtenAt))
            }
            record.newestProofsPayload = try encode(proofs)
        }
        record.deletedAt = nil
        // An authoritative complete response may replace an obsolete archive without decoding it.
        if isNewest, !hasOlderMessages {
            try replaceRetainedMessages(source, serverID: serverID, sessionID: sessionID,
                refreshedAt: refreshedAt, writtenAt: writtenAt)
            record.retainedMessageCount = source.count
        }
        try modelContext.save()
        latestMessagesWrittenAtByKey[key] = writtenAt
    }

    func applyChatRemoval(
        serverID: String, sessionID: String, messageID: String, partID: String?, writtenAt: Date
    ) async throws {
        guard !OpenCodeLocalCacheIdentity.isV2(serverID),
              try canWritePreview(serverID: serverID, sessionID: sessionID, writtenAt: writtenAt) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        let record = try previewRecord(forKey: key) ?? insertPreviewRecord(key: key, serverID: serverID, sessionID: sessionID)
        var removed = removals(in: record)
        if let partID {
            var parts = removed.parts[messageID] ?? [:]
            parts[partID] = max(parts[partID] ?? .distantPast, writtenAt)
            removed.parts[messageID] = parts
        } else {
            removed.messages[messageID] = max(removed.messages[messageID] ?? .distantPast, writtenAt)
        }
        record.removalsPayload = try encode(removed)
        if let payload = record.messagesPayload,
           let messages = try? decode([OpenCodeMessageEnvelope].self, from: payload) {
            record.messagesPayload = try encode(removed.applying(to: messages))
        }
        record.retainedMessageCount = nil
        record.messagesWrittenAt = writtenAt
        try modelContext.save()
        latestMessagesWrittenAtByKey[key] = writtenAt
    }

    func saveChatMessages(
        _ messages: [OpenCodeMessageEnvelope],
        serverID: String,
        sessionID: String,
        refreshedAt: Date,
        writtenAt: Date,
        coverage: OpenCodeLocalCacheTranscriptCoverage
    ) async throws {
        guard writtenAt > (clearedAtByNamespace[serverID] ?? .distantPast) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        guard writtenAt >= (latestMessagesWrittenAtByKey[key] ?? .distantPast) else { return }
        if !OpenCodeLocalCacheIdentity.isV2(serverID) {
            guard try canWritePreview(serverID: serverID, sessionID: sessionID, writtenAt: writtenAt) else { return }
        }
        if !OpenCodeLocalCacheIdentity.isV2(serverID), case .newestPage(hasOlder: true) = coverage {
            try await saveChatPreview(messages, hasOlderMessages: true, serverID: serverID,
                sessionID: sessionID, refreshedAt: refreshedAt, writtenAt: writtenAt, coverage: coverage)
            return
        }
        let record = try chatRecord(forKey: key)
        if let record {
            let latestWrittenAt = max(record.messagesWrittenAt, latestMessagesWrittenAtByKey[key] ?? .distantPast)
            guard writtenAt >= latestWrittenAt,
                  record.deletedAt.map({ writtenAt > $0 }) ?? true else { return }
        }
        // Reuse this decode for both V2 page merging and the unchanged-write check.
        let existingMessages = record?.messagesPayload.flatMap {
            try? decode([OpenCodeMessageEnvelope].self, from: $0)
        }
        var messages = messages
        if !OpenCodeLocalCacheIdentity.isV2(serverID), let preview = try previewRecord(forKey: key) {
            var removed = removals(in: preview)
            if case .newestPage(hasOlder: false) = coverage { removed.discard(through: writtenAt) }
            messages = removed.applying(to: messages)
        }
        if OpenCodeLocalCacheIdentity.isV2(serverID) {
            // A bounded HTTP page is not a deletion manifest for unloaded history.
            // Merge canonical IDs; oldest entries may be evicted for capacity,
            // but hydration never claims complete or validated v2 history.
            let existing = existingMessages ?? []
            let incomingIDs = Set(messages.map(\.info.id))
            let merged: [OpenCodeMessageEnvelope]
            switch coverage {
            case .newestPage(hasOlder: false):
                merged = messages
            case .newestPage(hasOlder: true):
                if let first = messages.first, let anchor = existing.firstIndex(where: { $0.id == first.id }) {
                    merged = existing.prefix(anchor).filter { !incomingIDs.contains($0.id) } + messages
                } else {
                    merged = existing.filter { !incomingIDs.contains($0.id) } + messages
                }
            case let .olderPage(beforeMessageID):
                if let first = existing.firstIndex(where: { incomingIDs.contains($0.id) }),
                   let last = existing.lastIndex(where: { incomingIDs.contains($0.id) }) {
                    // Disk can contain history older than this newly loaded page.
                    // Replace its anchored range in place, not at the start.
                    merged = Array(existing[..<first]) + messages + Array(existing[(last + 1)...])
                } else if let boundary = existing.firstIndex(where: { $0.id == beforeMessageID }) {
                    merged = Array(existing[..<boundary]) + messages + Array(existing[boundary...])
                } else {
                    merged = messages + existing
                }
            case .partial:
                merged = existing.filter { !incomingIDs.contains($0.id) } + messages
            }
            messages = OpenCodeCachedMessageState(
                envelopes: merged,
                sessionID: sessionID,
                preservingOrder: true
            ).envelopes
            messages = Array(messages.suffix(2_000))
        }
        if let record {
            if record.serverID == serverID,
               record.sessionID == sessionID,
               existingMessages == messages,
               record.deletedAt == nil {
                latestMessagesWrittenAtByKey[key] = writtenAt
                record.messagesWrittenAt = writtenAt
                if !OpenCodeLocalCacheIdentity.isV2(serverID) {
                    try mirrorFullChatPreview(messages, serverID: serverID, sessionID: sessionID,
                        refreshedAt: refreshedAt, writtenAt: writtenAt, coverage: coverage)
                }
                try modelContext.save()
                return
            }
            let payload = try encode(messages)
            record.serverID = serverID
            record.sessionID = sessionID
            record.messagesPayload = payload
            record.messagesRefreshedAt = refreshedAt
            record.messagesWrittenAt = writtenAt
            record.deletedAt = nil
        } else {
            modelContext.insert(
                OpenCodeCachedChatRecord(
                    key: key,
                    serverID: serverID,
                    sessionID: sessionID,
                    messagesPayload: try encode(messages),
                    messagesRefreshedAt: refreshedAt,
                    messagesWrittenAt: writtenAt
                )
            )
        }
        if !OpenCodeLocalCacheIdentity.isV2(serverID) {
            try mirrorFullChatPreview(messages, serverID: serverID, sessionID: sessionID,
                refreshedAt: refreshedAt, writtenAt: writtenAt, coverage: coverage)
        }
        try modelContext.save()
        latestMessagesWrittenAtByKey[key] = writtenAt
    }

    func saveTodos(
        _ todos: [OpenCodeTodo],
        serverID: String,
        sessionID: String,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {
        guard writtenAt > (clearedAtByNamespace[serverID] ?? .distantPast),
              !OpenCodeLocalCacheIdentity.isV2(serverID) else { return }
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        let payload = try encode(todos)
        if let record = try chatRecord(forKey: key) {
            let latestWrittenAt = max(record.todosWrittenAt, latestTodosWrittenAtByKey[key] ?? .distantPast)
            guard writtenAt >= latestWrittenAt,
                  record.deletedAt.map({ writtenAt > $0 }) ?? true else { return }
            if record.serverID == serverID,
               record.sessionID == sessionID,
               record.todosPayload.flatMap({ try? decode([OpenCodeTodo].self, from: $0) }) == todos,
               record.deletedAt == nil {
                latestTodosWrittenAtByKey[key] = writtenAt
                record.todosWrittenAt = writtenAt
                try mirrorPreviewTodos(record, key: key)
                try modelContext.save()
                return
            }
            record.serverID = serverID
            record.sessionID = sessionID
            record.todosPayload = payload
            record.todosRefreshedAt = refreshedAt
            record.todosWrittenAt = writtenAt
            record.deletedAt = nil
        } else {
            modelContext.insert(
                OpenCodeCachedChatRecord(
                    key: key,
                    serverID: serverID,
                    sessionID: sessionID,
                    todosPayload: payload,
                    todosRefreshedAt: refreshedAt,
                    todosWrittenAt: writtenAt
                )
            )
        }
        if let record = try chatRecord(forKey: key) { try mirrorPreviewTodos(record, key: key) }
        try modelContext.save()
        latestTodosWrittenAtByKey[key] = writtenAt
    }

    func removeSession(serverID: String, sessionID: String, removedAt: Date) async throws {
        if !OpenCodeLocalCacheIdentity.isV2(serverID) {
            let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
            if let preview = try previewRecord(forKey: key),
               removedAt < max(preview.messagesWrittenAt, preview.todosWrittenAt) { return }
        }
        for record in try directorySessionRecords(serverID: serverID) {
            guard removedAt >= record.writtenAt else { continue }
            let payload = try directoryPayload(from: record.payload)
            let remaining = payload.sessions.filter { $0.id != sessionID }
            if remaining.count != payload.sessions.count {
                record.payload = try encode(
                    OpenCodeCachedDirectoryPayload(
                        sessions: remaining,
                        statuses: payload.statuses?.filter { $0.key != sessionID },
                        permissions: payload.permissions?.filter { $0.sessionID != sessionID },
                        questions: payload.questions?.filter { $0.sessionID != sessionID }
                    )
                )
            }
            record.writtenAt = removedAt
        }

        let chatKey = OpenCodeLocalCacheKey.make([serverID, sessionID])
        if let record = try chatRecord(forKey: chatKey) {
            if removedAt >= max(record.messagesWrittenAt, record.todosWrittenAt),
               removedAt >= max(latestMessagesWrittenAtByKey[chatKey] ?? .distantPast, latestTodosWrittenAtByKey[chatKey] ?? .distantPast),
               record.deletedAt.map({ removedAt >= $0 }) ?? true {
                record.messagesPayload = nil
                record.todosPayload = nil
                record.messagesRefreshedAt = nil
                record.todosRefreshedAt = nil
                record.messagesWrittenAt = removedAt
                record.todosWrittenAt = removedAt
                record.deletedAt = removedAt
            }
        } else {
            modelContext.insert(
                OpenCodeCachedChatRecord(
                    key: chatKey,
                    serverID: serverID,
                    sessionID: sessionID,
                    messagesWrittenAt: removedAt,
                    todosWrittenAt: removedAt,
                    deletedAt: removedAt
                )
            )
        }
        if !OpenCodeLocalCacheIdentity.isV2(serverID) {
            let preview = try previewRecord(forKey: chatKey)
                ?? insertPreviewRecord(key: chatKey, serverID: serverID, sessionID: sessionID)
            if removedAt >= max(preview.messagesWrittenAt, preview.todosWrittenAt),
               removedAt >= max(latestMessagesWrittenAtByKey[chatKey] ?? .distantPast,
                                latestTodosWrittenAtByKey[chatKey] ?? .distantPast),
               preview.deletedAt.map({ removedAt >= $0 }) ?? true {
                preview.messagesPayload = nil
                preview.todosPayload = nil
                preview.removalsPayload = nil
                preview.newestProofsPayload = nil
                preview.messagesRefreshedAt = nil
                preview.todosRefreshedAt = nil
                preview.messagesWrittenAt = removedAt
                preview.todosWrittenAt = removedAt
                preview.deletedAt = removedAt
                preview.retainedMessageCount = nil
            }
        }
        try modelContext.save()
        latestMessagesWrittenAtByKey[chatKey] = max(
            latestMessagesWrittenAtByKey[chatKey] ?? .distantPast,
            removedAt
        )
        latestTodosWrittenAtByKey[chatKey] = max(
            latestTodosWrittenAtByKey[chatKey] ?? .distantPast,
            removedAt
        )
    }

    func clear(serverID: String) async throws {
        clearedAtByNamespace[serverID] = Date()
        for record in try projectRecords(serverID: serverID) {
            modelContext.delete(record)
        }
        for record in try directorySessionRecords(serverID: serverID) {
            modelContext.delete(record)
        }
        for record in try chatRecords(serverID: serverID) {
            latestMessagesWrittenAtByKey[record.key] = nil
            latestTodosWrittenAtByKey[record.key] = nil
            modelContext.delete(record)
        }
        let targetServerID = serverID
        let previews = FetchDescriptor<OpenCodeCachedChatPreviewRecord>(predicate: #Predicate { $0.serverID == targetServerID })
        for record in try modelContext.fetch(previews) {
            latestMessagesWrittenAtByKey[record.key] = nil
            latestTodosWrittenAtByKey[record.key] = nil
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    private func previewRecord(forKey key: String) throws -> OpenCodeCachedChatPreviewRecord? {
        let targetKey = key
        var descriptor = FetchDescriptor<OpenCodeCachedChatPreviewRecord>(predicate: #Predicate { $0.key == targetKey })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func insertPreviewRecord(key: String, serverID: String, sessionID: String) -> OpenCodeCachedChatPreviewRecord {
        let record = OpenCodeCachedChatPreviewRecord(key: key, serverID: serverID, sessionID: sessionID)
        modelContext.insert(record)
        return record
    }

    private func hasRetainedChat(forKey key: String) throws -> Bool {
        let targetKey = key
        let descriptor = FetchDescriptor<OpenCodeCachedChatRecord>(
            predicate: #Predicate { $0.key == targetKey && $0.deletedAt == nil && $0.messagesPayload != nil })
        return try modelContext.fetchCount(descriptor) > 0
    }

    private func canWritePreview(serverID: String, sessionID: String, writtenAt: Date) throws -> Bool {
        guard writtenAt > (clearedAtByNamespace[serverID] ?? .distantPast) else { return false }
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        guard writtenAt >= (latestMessagesWrittenAtByKey[key] ?? .distantPast) else { return false }
        if let record = try previewRecord(forKey: key) {
            guard writtenAt >= record.messagesWrittenAt,
                  record.deletedAt.map({ writtenAt > $0 }) ?? true else { return false }
        }
        // COUNT checks metadata without materializing a live archive's potentially huge Data blob.
        let targetKey = key
        let incoming = writtenAt
        let newer = FetchDescriptor<OpenCodeCachedChatRecord>(
            predicate: #Predicate { $0.key == targetKey && $0.messagesWrittenAt > incoming })
        guard try modelContext.fetchCount(newer) == 0 else { return false }
        var deleted = FetchDescriptor<OpenCodeCachedChatRecord>(
            predicate: #Predicate { $0.key == targetKey && $0.deletedAt != nil })
        deleted.fetchLimit = 1
        if let deletion = try modelContext.fetch(deleted).first?.deletedAt, writtenAt <= deletion { return false }
        return true
    }

    private func removals(in record: OpenCodeCachedChatPreviewRecord) -> OpenCodeCachedChatRemovals {
        record.removalsPayload.flatMap { try? decode(OpenCodeCachedChatRemovals.self, from: $0) }
            ?? OpenCodeCachedChatRemovals()
    }

    private func newestProofs(in record: OpenCodeCachedChatPreviewRecord) -> [OpenCodeCachedNewestWindowProof] {
        record.newestProofsPayload.flatMap { try? decode([OpenCodeCachedNewestWindowProof].self, from: $0) } ?? []
    }

    private func mirrorPreviewTodos(_ retained: OpenCodeCachedChatRecord, key: String) throws {
        let preview = try previewRecord(forKey: key)
            ?? insertPreviewRecord(key: key, serverID: retained.serverID, sessionID: retained.sessionID)
        guard retained.todosWrittenAt >= preview.todosWrittenAt else { return }
        preview.todosPayload = retained.todosPayload
        preview.todosRefreshedAt = retained.todosRefreshedAt
        preview.todosWrittenAt = retained.todosWrittenAt
        preview.deletedAt = nil
    }

    private func mergingPreview(
        _ window: [OpenCodeMessageEnvelope], into existing: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        let incomingIDs = Set(window.map(\.id))
        return (existing.filter { !incomingIDs.contains($0.id) } + window)
            .sorted { OpenCodeMessage.isOrderedBefore($0.info, $1.info) }
    }

    private func replaceRetainedMessages(
        _ messages: [OpenCodeMessageEnvelope], serverID: String, sessionID: String,
        refreshedAt: Date, writtenAt: Date
    ) throws {
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        if let record = try chatRecord(forKey: key) {
            record.messagesPayload = try encode(messages)
            record.messagesRefreshedAt = refreshedAt
            record.messagesWrittenAt = writtenAt
            record.deletedAt = nil
        } else {
            modelContext.insert(OpenCodeCachedChatRecord(key: key, serverID: serverID, sessionID: sessionID,
                messagesPayload: try encode(messages), messagesRefreshedAt: refreshedAt, messagesWrittenAt: writtenAt))
        }
    }

    private func mirrorFullChatPreview(
        _ messages: [OpenCodeMessageEnvelope], serverID: String, sessionID: String,
        refreshedAt: Date?, writtenAt: Date, coverage: OpenCodeLocalCacheTranscriptCoverage
    ) throws {
        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])
        let preview = try previewRecord(forKey: key) ?? insertPreviewRecord(key: key, serverID: serverID, sessionID: sessionID)
        var removed = removals(in: preview)
        if case .newestPage(hasOlder: false) = coverage { removed.discard(through: writtenAt) }
        let visible = removed.applying(to: messages)
        preview.messagesPayload = try encode(Array(visible.sorted {
            OpenCodeMessage.isOrderedBefore($0.info, $1.info)
        }.suffix(OpenCodeCachedChatPreview.messageLimit)))
        preview.messagesRefreshedAt = refreshedAt
        preview.messagesWrittenAt = writtenAt
        preview.hasOlderMessages = visible.count > OpenCodeCachedChatPreview.messageLimit
        preview.retainedMessageCount = visible.count
        preview.newestProofsPayload = nil
        preview.removalsPayload = try encode(removed)
        preview.deletedAt = nil
        if let retained = try chatRecord(forKey: key), retained.todosWrittenAt >= preview.todosWrittenAt {
            preview.todosPayload = retained.todosPayload
            preview.todosRefreshedAt = retained.todosRefreshedAt
            preview.todosWrittenAt = retained.todosWrittenAt
        }
    }

    private func projectsRecord(forKey key: String) throws -> OpenCodeCachedProjectsRecord? {
        let targetKey = key
        var descriptor = FetchDescriptor<OpenCodeCachedProjectsRecord>(
            predicate: #Predicate { $0.key == targetKey }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func directorySessionsRecord(forKey key: String) throws -> OpenCodeCachedDirectorySessionsRecord? {
        let targetKey = key
        var descriptor = FetchDescriptor<OpenCodeCachedDirectorySessionsRecord>(
            predicate: #Predicate { $0.key == targetKey }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func chatRecord(forKey key: String) throws -> OpenCodeCachedChatRecord? {
        let targetKey = key
        var descriptor = FetchDescriptor<OpenCodeCachedChatRecord>(
            predicate: #Predicate { $0.key == targetKey }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func projectRecords(serverID: String) throws -> [OpenCodeCachedProjectsRecord] {
        let targetServerID = serverID
        let descriptor = FetchDescriptor<OpenCodeCachedProjectsRecord>(
            predicate: #Predicate { $0.serverID == targetServerID }
        )
        return try modelContext.fetch(descriptor)
    }

    private func directorySessionRecords(serverID: String) throws -> [OpenCodeCachedDirectorySessionsRecord] {
        let targetServerID = serverID
        let descriptor = FetchDescriptor<OpenCodeCachedDirectorySessionsRecord>(
            predicate: #Predicate { $0.serverID == targetServerID }
        )
        return try modelContext.fetch(descriptor)
    }

    private func chatRecords(serverID: String) throws -> [OpenCodeCachedChatRecord] {
        let targetServerID = serverID
        let descriptor = FetchDescriptor<OpenCodeCachedChatRecord>(
            predicate: #Predicate { $0.serverID == targetServerID }
        )
        return try modelContext.fetch(descriptor)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

struct NoOpOpenCodeLocalCacheRepository: OpenCodeLocalCacheRepository {
    func loadProjects(serverID: String) async throws -> OpenCodeCachedProjectsSnapshot? { nil }

    func saveProjects(
        _ projects: [OpenCodeProject],
        serverID: String,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {}

    func saveDirectoryMetadata(
        statuses: [String: String],
        permissions: [OpenCodePermission],
        questions: [OpenCodeQuestionRequest],
        serverID: String,
        directory: String?,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {}

    func loadDirectorySessions(
        serverID: String,
        directory: String?
    ) async throws -> OpenCodeCachedDirectorySessionsSnapshot? { nil }

    func saveDirectorySessions(
        _ sessions: [OpenCodeSession],
        serverID: String,
        directory: String?,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {}

    func loadChat(
        serverID: String,
        sessionID: String
    ) async throws -> OpenCodeCachedChatSnapshot? { nil }

    func saveChatMessages(
        _ messages: [OpenCodeMessageEnvelope],
        serverID: String,
        sessionID: String,
        refreshedAt: Date,
        writtenAt: Date,
        coverage: OpenCodeLocalCacheTranscriptCoverage
    ) async throws {}

    func saveTodos(
        _ todos: [OpenCodeTodo],
        serverID: String,
        sessionID: String,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws {}

    func removeSession(serverID: String, sessionID: String, removedAt: Date) async throws {}

    func clear(serverID: String) async throws {}
}

enum OpenCodeLocalCacheRepositoryFactory {
    static func makeDefault() -> any OpenCodeLocalCacheRepository {
        // DispatchQueue.sync can execute inline on the calling (main) thread. Construct
        // the ModelContext in a detached task instead; callers await readiness without
        // blocking startup or binding the model executor to the UI queue.
        DeferredOpenCodeLocalCacheRepository {
            do {
                return SwiftDataOpenCodeLocalCacheRepository(
                    modelContainer: try makeContainer(isStoredInMemoryOnly: false)
                )
            } catch {
                return NoOpOpenCodeLocalCacheRepository()
            }
        }
    }

    static func makeInMemory() throws -> any OpenCodeLocalCacheRepository {
        SwiftDataOpenCodeLocalCacheRepository(
            modelContainer: try makeContainer(isStoredInMemoryOnly: true)
        )
    }

    private static func makeContainer(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenCodeLocalCacheSchemaV2.self)
        // Keep this experimental cache app-private and disconnected from CloudKit.
        let configuration = ModelConfiguration(
            "OpenCodeLocalSnapshotCache",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: OpenCodeLocalCacheMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

/// Shares one asynchronously constructed repository across all reads and writes.
/// Cache timestamps still determine write precedence when callers resume concurrently.
struct DeferredOpenCodeLocalCacheRepository: OpenCodeLocalCacheRepository {
    private let repository: Task<any OpenCodeLocalCacheRepository, Never>

    init(make: @escaping @Sendable () -> any OpenCodeLocalCacheRepository) {
        repository = Task.detached(priority: .utility) { make() }
    }

    func loadProjects(serverID: String) async throws -> OpenCodeCachedProjectsSnapshot? {
        try await repository.value.loadProjects(serverID: serverID)
    }

    func saveProjects(_ projects: [OpenCodeProject], serverID: String, refreshedAt: Date, writtenAt: Date) async throws {
        try await repository.value.saveProjects(projects, serverID: serverID, refreshedAt: refreshedAt, writtenAt: writtenAt)
    }

    func loadDirectorySessions(serverID: String, directory: String?) async throws -> OpenCodeCachedDirectorySessionsSnapshot? {
        try await repository.value.loadDirectorySessions(serverID: serverID, directory: directory)
    }

    func saveDirectorySessions(_ sessions: [OpenCodeSession], serverID: String, directory: String?, refreshedAt: Date, writtenAt: Date) async throws {
        try await repository.value.saveDirectorySessions(sessions, serverID: serverID, directory: directory, refreshedAt: refreshedAt, writtenAt: writtenAt)
    }

    func saveDirectoryMetadata(statuses: [String: String], permissions: [OpenCodePermission], questions: [OpenCodeQuestionRequest], serverID: String, directory: String?, refreshedAt: Date, writtenAt: Date) async throws {
        try await repository.value.saveDirectoryMetadata(statuses: statuses, permissions: permissions, questions: questions, serverID: serverID, directory: directory, refreshedAt: refreshedAt, writtenAt: writtenAt)
    }

    func loadChat(serverID: String, sessionID: String) async throws -> OpenCodeCachedChatSnapshot? {
        try await repository.value.loadChat(serverID: serverID, sessionID: sessionID)
    }

    func loadChatPreview(serverID: String, sessionID: String) async throws -> OpenCodeCachedChatPreview? {
        try await repository.value.loadChatPreview(serverID: serverID, sessionID: sessionID)
    }

    func saveChatPreview(
        _ messages: [OpenCodeMessageEnvelope], hasOlderMessages: Bool,
        serverID: String, sessionID: String, refreshedAt: Date, writtenAt: Date,
        coverage: OpenCodeLocalCacheTranscriptCoverage
    ) async throws {
        try await repository.value.saveChatPreview(messages, hasOlderMessages: hasOlderMessages,
            serverID: serverID, sessionID: sessionID, refreshedAt: refreshedAt, writtenAt: writtenAt, coverage: coverage)
    }

    func applyChatRemoval(
        serverID: String, sessionID: String, messageID: String, partID: String?, writtenAt: Date
    ) async throws {
        try await repository.value.applyChatRemoval(serverID: serverID, sessionID: sessionID,
            messageID: messageID, partID: partID, writtenAt: writtenAt)
    }

    func saveChatMessages(_ messages: [OpenCodeMessageEnvelope], serverID: String, sessionID: String, refreshedAt: Date, writtenAt: Date, coverage: OpenCodeLocalCacheTranscriptCoverage) async throws {
        try await repository.value.saveChatMessages(messages, serverID: serverID, sessionID: sessionID, refreshedAt: refreshedAt, writtenAt: writtenAt, coverage: coverage)
    }

    func saveTodos(_ todos: [OpenCodeTodo], serverID: String, sessionID: String, refreshedAt: Date, writtenAt: Date) async throws {
        try await repository.value.saveTodos(todos, serverID: serverID, sessionID: sessionID, refreshedAt: refreshedAt, writtenAt: writtenAt)
    }

    func removeSession(serverID: String, sessionID: String, removedAt: Date) async throws {
        try await repository.value.removeSession(serverID: serverID, sessionID: sessionID, removedAt: removedAt)
    }

    func clear(serverID: String) async throws {
        try await repository.value.clear(serverID: serverID)
    }
}

private enum OpenCodeLocalCacheKey {
    /// Nil and strings use distinct tags; string lengths are measured in UTF-8 bytes.
    static func make(_ components: [String?]) -> String {
        components.map { component in
            guard let component else { return "n" }
            return "s\(component.utf8.count):\(component)"
        }.joined()
    }
}

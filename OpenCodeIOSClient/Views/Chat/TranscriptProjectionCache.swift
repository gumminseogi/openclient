import Foundation

/// Cache complete, independent transcript segments (normally user turns).
/// Inputs include canonical values, so history edits invalidate only affected segments.
@MainActor
final class TranscriptProjectionCache<Input: Equatable, Context: Equatable, Output> {
    private struct Entry {
        let input: [Input]
        let context: Context
        let output: [Output]
    }
    private var entries: [String: Entry] = [:]

    func output(id: String, input: [Input], context: Context, build: () -> [Output]) -> [Output] {
        if let entry = entries[id], entry.input == input, entry.context == context {
            return entry.output
        }
        let output = build()
        entries[id] = Entry(input: input, context: context, output: output)
        return output
    }

    func retain(_ ids: Set<String>) {
        for id in entries.keys where !ids.contains(id) { entries[id] = nil }
    }
}

enum TranscriptProjectionSegments {
    /// Compaction can associate a boundary with a later summary across prompts.
    /// Keep that prefix intact; only split subsequent, visible user-turn barriers.
    static func ranges(messages: [OpenCodeMessageEnvelope], isVisible: (OpenCodeMessageEnvelope) -> Bool) -> [Range<Int>] {
        guard !messages.isEmpty else { return [] }
        var requiredPrefixEnd = messages.lastIndex {
            $0.info.isCompactionSummary || $0.parts.contains(where: \.isCompaction)
        } ?? -1
        let promptIndices = messages.indices.reduce(into: [String: Int]()) { indices, index in
            let message = messages[index]
            if message.info.role?.lowercased() == "user", !message.parts.contains(where: \.isCompaction) {
                indices[message.id] = index
            }
        }
        var latestPromptID: String?
        for (index, message) in messages.enumerated() {
            if promptIndices[message.id] == index { latestPromptID = message.id }
            if message.info.role?.lowercased() == "assistant", let parentID = message.info.parentID,
               parentID != latestPromptID, let promptIndex = promptIndices[parentID] {
                // Steered/queued prompts can precede an answer to an older prompt.
                // Preserve that prompt's duration/copy context in the same segment.
                requiredPrefixEnd = max(requiredPrefixEnd, max(index, promptIndex))
            }
        }
        var starts = [0]
        for index in messages.indices.dropFirst() where index > requiredPrefixEnd {
            let message = messages[index]
            if message.info.role?.lowercased() == "user", isVisible(message) {
                starts.append(index)
            }
        }
        return starts.enumerated().map { offset, start in
            start..<(offset + 1 < starts.count ? starts[offset + 1] : messages.count)
        }
    }
}

/// Reuses expensive presentation preparation when only viewport geometry changes.
@MainActor
final class TranscriptSnapshotCache<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    func value(for key: Key, build: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = build()
        cached = (key, value)
        return value
    }
}

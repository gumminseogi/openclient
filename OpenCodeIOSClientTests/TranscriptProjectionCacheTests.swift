import XCTest
@testable import OpenClient

@MainActor
final class TranscriptProjectionCacheTests: XCTestCase {
    private func message(_ id: String, role: String = "assistant", text: String = "Answer", type: String = "text") -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(info: OpenCodeMessage(id: id, role: role, sessionID: "session", time: nil, agent: nil, model: nil),
            parts: [OpenCodePart(id: "part-\(id)", messageID: id, sessionID: "session", type: type,
                mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text)])
    }

    func testStreamingRebuildsOnlyChangedTurnAndSettingsInvalidateAllTurns() {
        let cache = TranscriptProjectionCache<OpenCodeMessageEnvelope, Bool, String>()
        var messages = (0..<100).flatMap { [message("user-\($0)", role: "user"), message("assistant-\($0)")] }
        var builds = 0
        func project(_ showsTools: Bool) -> [String] {
            let ranges = TranscriptProjectionSegments.ranges(messages: messages, isVisible: { _ in true })
            var ids: Set<String> = []
            let result = ranges.flatMap { range in
                let input = Array(messages[range])
                ids.insert(input[0].id)
                return cache.output(id: input[0].id, input: input, context: showsTools) {
                    builds += 1
                    return input.map { $0.parts.first?.text ?? "" }
                }
            }
            cache.retain(ids)
            return result
        }
        XCTAssertEqual(project(true).count, 200)
        XCTAssertEqual(builds, 100)
        messages[199].parts[0].text = "Live answer"
        XCTAssertEqual(project(true).last, "Live answer")
        XCTAssertEqual(builds, 101)
        _ = project(true) // viewport-only changes must not prepare the history again
        XCTAssertEqual(builds, 101)
        _ = project(false)
        XCTAssertEqual(builds, 201)
        messages[1].parts[0].text = "Corrected history"
        XCTAssertEqual(project(false)[1], "Corrected history")
        XCTAssertEqual(builds, 202)
    }

    func testSegmentsKeepHiddenPromptsAndCompactionAssociationsTogether() {
        var messages = [message("u1", role: "user"), message("a1"), message("hidden", role: "user"),
                        message("a2"), message("u3", role: "user"), message("a3")]
        XCTAssertEqual(TranscriptProjectionSegments.ranges(messages: messages, isVisible: { $0.id != "hidden" }), [0..<4, 4..<6])
        messages[1] = message("a1", type: "compaction")
        messages[3].info = OpenCodeMessage(id: "a2", role: "assistant", sessionID: "session", time: nil, agent: nil, model: nil, summary: true)
        XCTAssertEqual(TranscriptProjectionSegments.ranges(messages: messages, isVisible: { _ in true }), [0..<4, 4..<6])
        XCTAssertTrue(TranscriptProjectionSegments.ranges(messages: [], isVisible: { _ in true }).isEmpty)
    }

    func testPartitionedGroupingAndCaptionsMatchWholeTranscript() {
        var messages: [OpenCodeMessageEnvelope] = []
        for turn in 0..<4 {
            messages.append(message("u\(turn)", role: "user"))
            for index in 0..<3 {
                let activity = message("r\(turn)-\(index)", type: "reasoning")
                messages.append(activity)
            }
            messages.append(message("a\(turn)"))
        }
        let ranges = TranscriptProjectionSegments.ranges(messages: messages, isVisible: { _ in true })
        let allSlices = TranscriptActivityGrouping.slices(messages)
        let partitioned = ranges.flatMap { TranscriptActivityGrouping.slices(Array(messages[$0])) }
        XCTAssertEqual(partitioned.map(\.id), allSlices.map(\.id))
        XCTAssertEqual(partitioned.map(\.sourceMessageIDs), allSlices.map(\.sourceMessageIDs))
        XCTAssertEqual(partitioned.map(\.message), allSlices.map(\.message))
        for busy in [false, true] {
            let allTurns = AssistantResponseTurn.project(messages: messages,
                displayedMessageIDs: Set(messages.map(\.id)), isSessionBusy: busy)
            let turns = ranges.flatMap { range in
                let segment = Array(messages[range])
                return AssistantResponseTurn.project(messages: segment,
                    displayedMessageIDs: Set(segment.map(\.id)), isSessionBusy: busy && range.upperBound == messages.count)
            }
            XCTAssertEqual(turns, allTurns)
        }
    }

    func testAnswerToEarlierPromptRetainsItsContextAcrossQueuedPrompt() {
        var answer = message("answer")
        answer.info = OpenCodeMessage(id: "answer", role: "assistant", sessionID: "session",
            time: nil, agent: nil, model: nil, parentID: "first")
        let messages = [message("first", role: "user"), message("queued", role: "user"), answer,
                        message("next", role: "user"), message("next-answer")]
        XCTAssertEqual(TranscriptProjectionSegments.ranges(messages: messages, isVisible: { _ in true }),
            [0..<3, 3..<5])
    }

    func testSnapshotCacheReusesGeometryChangesAndInvalidatesRevisions() {
        let cache = TranscriptSnapshotCache<Int, String>()
        var builds = 0
        for _ in 0..<100 {
            XCTAssertEqual(cache.value(for: 1) { builds += 1; return "one" }, "one")
        }
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(cache.value(for: 2) { builds += 1; return "two" }, "two")
        XCTAssertEqual(builds, 2)
    }

    func testInventoryMatchingPreservesFullEnvelopeAndDuplicateIDSemantics() {
        let original = message("same", text: "Original")
        var changed = original
        changed.parts[0].text = "Changed"
        let other = message("other")
        let committed = [changed, original, other, original]
        for inventory in [[original], [changed, original], [other, changed], []] {
            XCTAssertEqual(ChatStore.matchingCommittedMessages(committed, in: inventory),
                committed.filter { inventory.contains($0) })
        }
    }

    func testMeasureIndexedInventoryMatching() {
        let messages = (0..<2_000).map { message("message-\($0)") }
        var matched: [OpenCodeMessageEnvelope] = []
        measure { matched = ChatStore.matchingCommittedMessages(messages, in: messages) }
        XCTAssertEqual(matched, messages)
    }

    func testMeasureLegacyInventoryMatching() {
        let messages = (0..<2_000).map { message("message-\($0)") }
        var matched: [OpenCodeMessageEnvelope] = []
        measure { matched = messages.filter { messages.contains($0) } }
        XCTAssertEqual(matched, messages)
    }
}

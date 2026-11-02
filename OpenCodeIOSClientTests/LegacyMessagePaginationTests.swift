import Foundation
import XCTest
@testable import OpenClient

@MainActor
final class LegacyMessagePaginationTests: XCTestCase {
    override func tearDown() async throws {
        LegacyPaginationURLProtocol.handler = nil
    }

    func testHeaderlessServerExpandsCumulativeWindowAndStopsOnShortPage() async throws {
        var requests: [URLRequest] = []
        LegacyPaginationURLProtocol.handler = { request in
            requests.append(request)
            let query = Self.query(request)
            XCTAssertEqual(request.url?.path, "/session/ses_history/message")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(query["directory"], "/repo with space")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/repo%20with%20space")
            XCTAssertNil(query["before"])
            let limit = try XCTUnwrap(Int(try XCTUnwrap(query["limit"])))
            return (200, [:], try Self.page(total: 825, limit: limit))
        }
        let client = makeClient()
        let first = try await client.listMessagePage(sessionID: "ses_history", limit: 400, directory: "/repo with space")
        XCTAssertEqual(first.messages.count, 400)
        XCTAssertEqual(first.messages.first?.id, "msg_425")
        let second = try await client.listMessagePage(sessionID: "ses_history", limit: 400,
            before: XCTUnwrap(first.nextCursor), directory: "/repo with space")
        XCTAssertEqual(second.messages.count, 800)
        XCTAssertEqual(second.messages.first?.id, "msg_25")
        let last = try await client.listMessagePage(sessionID: "ses_history", limit: 400,
            before: XCTUnwrap(second.nextCursor), directory: "/repo with space")
        XCTAssertEqual(last.messages.count, 825)
        XCTAssertEqual(last.messages.first?.id, "msg_0")
        XCTAssertNil(last.nextCursor)
        XCTAssertEqual(requests.map { Self.query($0)["limit"] }, ["400", "800", "1200"])
    }

    func testCumulativeContinuationAdvancesByAtLeastFourHundred() async throws {
        var limits: [String?] = []
        LegacyPaginationURLProtocol.handler = { request in
            let query = Self.query(request)
            limits.append(query["limit"])
            XCTAssertNil(query["before"])
            let limit = try XCTUnwrap(Int(try XCTUnwrap(query["limit"])))
            return (200, [:], try Self.page(total: 50, limit: limit))
        }
        let client = makeClient()
        let first = try await client.listMessagePage(sessionID: "ses_history", limit: 20)
        let next = try await client.listMessagePage(sessionID: "ses_history", limit: 20,
            before: XCTUnwrap(first.nextCursor))
        XCTAssertEqual(limits, ["20", "420"])
        XCTAssertEqual(next.messages.count, 50)
        XCTAssertNil(next.nextCursor)
    }

    func testServerHeaderCursorRemainsBeforePaginationAndTerminalHeaderIsAuthoritative() async throws {
        let cursor = "server+/cursor?boundary=1&older=true"
        var requests: [URLRequest] = []
        LegacyPaginationURLProtocol.handler = { request in
            requests.append(request)
            let query = Self.query(request)
            XCTAssertEqual(query["limit"], "2")
            if requests.count == 1 {
                XCTAssertNil(query["before"])
                return (200, ["X-Next-Cursor": cursor], try Self.page(total: 2, limit: 2))
            }
            XCTAssertEqual(query["before"], cursor)
            return (200, [:], try Self.page(total: 2, limit: 2))
        }
        let client = makeClient()
        let first = try await client.listMessagePage(sessionID: "ses_history", limit: 2)
        XCTAssertEqual(first.nextCursor, cursor)
        let last = try await client.listMessagePage(sessionID: "ses_history", limit: 2, before: first.nextCursor)
        XCTAssertNil(last.nextCursor, "Do not switch an exhausted real-cursor server to cumulative pagination.")
        XCTAssertEqual(requests.count, 2)
    }

    func testServerCursorCanUseTheInternalNamespaceWithoutBeingReinterpreted() async throws {
        let cursor = "openclient-legacy-limit-v1:400"
        var requests: [URLRequest] = []
        LegacyPaginationURLProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 {
                return (200, ["X-Next-Cursor": cursor], try Self.page(total: 2, limit: 2))
            }
            XCTAssertEqual(Self.query(request)["before"], cursor)
            XCTAssertEqual(Self.query(request)["limit"], "2")
            return (200, [:], try Self.page(total: 1, limit: 1))
        }
        let client = makeClient()
        let first = try await client.listMessagePage(sessionID: "ses_history", limit: 2)
        let last = try await client.listMessagePage(sessionID: "ses_history", limit: 2,
            before: XCTUnwrap(first.nextCursor))
        XCTAssertNil(last.nextCursor)
        XCTAssertEqual(requests.count, 2)
    }

    func testUnboundedInventoryOmitsLimitAndDoesNotInventContinuation() async throws {
        LegacyPaginationURLProtocol.handler = { request in
            XCTAssertNil(Self.query(request)["limit"])
            XCTAssertNil(Self.query(request)["before"])
            return (200, [:], try Self.page(total: 800, limit: 800))
        }
        let page = try await makeClient().listMessagePage(sessionID: "ses_history")
        XCTAssertEqual(page.messages.count, 800)
        XCTAssertNil(page.nextCursor)
    }

    func testMalformedOrUnsafeLocalCursorAndLimitFailBeforeSendingRequest() async throws {
        var requests = 0
        LegacyPaginationURLProtocol.handler = { _ in
            requests += 1
            return (200, [:], Data("[]".utf8))
        }
        let client = makeClient()
        for cursor in ["openclient-legacy-limit-v1:", "openclient-legacy-limit-v1:no-number",
                       "openclient-legacy-limit-v1:-1", "openclient-legacy-limit-v1:0",
                       "openclient-legacy-limit-v1:0400", "openclient-legacy-limit-v1:9007199254740991",
                       "openclient-legacy-limit-v1:9223372036854775807", "openclient-legacy-server-v1:not-base64"] {
            do {
                _ = try await client.listMessagePage(sessionID: "ses_history", limit: 400, before: cursor)
                XCTFail("Invalid local cursor was accepted: \(cursor)")
            } catch OpenCodeAPIError.invalidResponse {
            }
        }
        for limit in [0, -1, Int.max, 9_007_199_254_740_992] {
            do {
                _ = try await client.listMessagePage(sessionID: "ses_history", limit: limit)
                XCTFail("Unsafe limit was accepted: \(limit)")
            } catch OpenCodeAPIError.invalidResponse {
            }
        }
        XCTAssertEqual(requests, 0)
    }

    func testHTTPFailureDoesNotBecomeAnEmptyOrCompletedPage() async throws {
        LegacyPaginationURLProtocol.handler = { request in
            XCTAssertEqual(Self.query(request)["directory"], "/repo")
            return (503, [:], Data(#"{"message":"temporarily unavailable"}"#.utf8))
        }
        do {
            _ = try await makeClient().listMessagePage(sessionID: "ses_history", limit: 400, directory: "/repo")
            XCTFail("HTTP failure was accepted as a page.")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 503)
        }
    }

    private func makeClient() -> OpenCodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LegacyPaginationURLProtocol.self]
        return OpenCodeAPIClient(config: .init(baseURL: "https://legacy-pagination.invalid", apiPreference: .legacy),
            session: URLSession(configuration: configuration))
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, value in value })
    }

    private static func page(total: Int, limit: Int) throws -> Data {
        let messages: [[String: Any]] = (0..<total).suffix(limit).map { id in
            let info: [String: Any] = ["id": "msg_\(id)", "sessionID": "ses_history", "role": "user", "time": ["created": id]]
            return ["info": info, "parts": [Any]()]
        }
        return try JSONSerialization.data(withJSONObject: messages)
    }
}

private final class LegacyPaginationURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) throws -> (Int, [String: String], Data))?
    private struct Delivery: @unchecked Sendable { let loader: LegacyPaginationURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "legacy-pagination.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, headers, body) = try handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: headers.merging(["Content-Type": "application/json"], uniquingKeysWith: { value, _ in value })))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: body)
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}

import os
import Foundation

@testable import SimpleDataLogs

/// One canned answer the mock ingest server plays back.
struct MockResponse: Sendable {
    /// The HTTP status code.
    var statusCode: Int

    /// Response headers, e.g. Retry-After.
    var headers: [String: String] = [:]

    /// Fail at the network layer with this code instead of answering.
    var networkErrorCode: URLError.Code?

    /// Holds the answer back until the test opens this gate, keeping the request in flight.
    var gate: RequestGate?

    /// A 202, the only success answer.
    static let accepted = MockResponse(statusCode: 202)

    /// An answer with a status code and an optional Retry-After header.
    static func status(_ statusCode: Int, retryAfter: String? = nil) -> MockResponse {
        MockResponse(statusCode: statusCode, headers: retryAfter.map { retryAfterValue in ["Retry-After": retryAfterValue] } ?? [:])
    }

    /// A network-layer failure, e.g. being offline.
    static func networkFailure(_ errorCode: URLError.Code) -> MockResponse {
        MockResponse(statusCode: 0, networkErrorCode: errorCode)
    }

    /// This answer, held back until `gate` opens.
    func held(by gate: RequestGate) -> MockResponse {
        var heldResponse = self
        heldResponse.gate = gate

        return heldResponse
    }
}

/// Keeps gated mock requests in flight until the test opens it.
final class RequestGate: Sendable {
    /// Signalled on opening, and passed on by each waiter so every held request is released.
    private let openSignal = DispatchSemaphore(value: 0)

    /// Releases every held request, now and later.
    func open() {
        openSignal.signal()
    }

    /// Blocks the calling thread until the gate opens, or 10 s pass so a broken test cannot hang.
    func waitUntilOpened() {
        _ = openSignal.wait(timeout: .now() + .seconds(10))
        openSignal.signal()
    }
}

/// One request the SDK sent to a mock server.
struct RecordedRequest: Sendable {
    /// The request URL.
    let url: URL?

    /// The HTTP method.
    let httpMethod: String?

    /// Every request header.
    let headers: [String: String]

    /// The request body, read back from the body stream.
    let body: Data

    /// The NDJSON body decoded line by line.
    var eventObjects: [[String: Any]] {
        EventOutbox.lines(in: body).compactMap { eventLine in
            (try? JSONSerialization.jsonObject(with: eventLine)) as? [String: Any]
        }
    }

    /// The `event_id` of every event in the body, in order.
    var eventIDs: [String] {
        eventObjects.compactMap { eventObject in eventObject["event_id"] as? String }
    }

    /// The `event` name of every event in the body, in order.
    var eventNames: [String] {
        eventObjects.compactMap { eventObject in eventObject["event"] as? String }
    }

    /// How many events the body holds.
    var eventCount: Int {
        EventOutbox.lines(in: body).count
    }
}

/// An in-process stand-in for ingest that decides each response and records each request.
final class MockIngestServer: Sendable {
    /// Decides the answer for a request, given its zero-based position in the request sequence.
    typealias Responder = @Sendable (_ request: RecordedRequest, _ requestIndex: Int) -> MockResponse

    /// Every live mock server, keyed by its unique host name.
    private static let serversByHost = OSAllocatedUnfairLock<[String: MockIngestServer]>(initialState: [:])

    /// A host under the reserved `.invalid` TLD, so an unmocked request can never reach a real network.
    let host = "mock-\(UUID().uuidString.lowercased()).invalid"

    /// Every request received so far, in order.
    private let recordedRequests = OSAllocatedUnfairLock<[RecordedRequest]>(initialState: [])

    /// Decides each answer.
    private let responder: Responder

    /// Creates a server that answers 202 unless told otherwise.
    init(responder: @escaping Responder = { _, _ in .accepted }) {
        self.responder = responder
    }

    /// The endpoint to configure the SDK with.
    var endpoint: URL {
        URL(string: "http://\(host)")!
    }

    /// The full ingest URL the pipeline posts to.
    var ingestURL: URL {
        SimpleDataLogs.ingestURL(for: endpoint)
    }

    /// Every request received so far, in order.
    var requests: [RecordedRequest] {
        recordedRequests.withLock { requests in requests }
    }

    /// Makes this server reachable through `MockURLProtocol`.
    func register() {
        Self.serversByHost.withLock { serversByHost in
            serversByHost[host] = self
        }
    }

    /// Removes this server from the routing table.
    func unregister() {
        Self.serversByHost.withLock { serversByHost in
            serversByHost[host] = nil
        }
    }

    /// A session whose every request is answered by a mock server instead of the network.
    func makeSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]

        return URLSession(configuration: sessionConfiguration)
    }

    /// Records a request and returns the responder's answer for it.
    func respond(to request: RecordedRequest) -> MockResponse {
        let requestIndex = recordedRequests.withLock { requests in
            requests.append(request)
            return requests.count - 1
        }

        return responder(request, requestIndex)
    }

    /// The server registered for a host, if any.
    static func server(forHost host: String) -> MockIngestServer? {
        serversByHost.withLock { serversByHost in serversByHost[host] }
    }
}

/// Routes every request from a mocked session to the `MockIngestServer` that owns its host.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Set once URLSession stops the request, so a held answer is never delivered after a cancel.
    private let isStopped = OSAllocatedUnfairLock(initialState: false)

    /// Claims every request, since only mocked sessions list this protocol.
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    /// Leaves requests unchanged.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Answers the request from its mock server.
    override func startLoading() {
        // An unknown host fails like DNS would.
        guard let requestURL = request.url, let host = requestURL.host(), let server = MockIngestServer.server(forHost: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        // Record the request and ask the server for its answer.
        let recordedRequest = RecordedRequest(
            url: requestURL,
            httpMethod: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request)
        )
        let mockResponse = server.respond(to: recordedRequest)

        // An ungated answer goes back at once.
        guard let gate = mockResponse.gate else {
            deliver(mockResponse, for: requestURL)
            return
        }

        // A gated answer waits on another thread, leaving this one free for URLSession to stop the request.
        DispatchQueue.global().async {
            gate.waitUntilOpened()
            self.deliver(mockResponse, for: requestURL)
        }
    }

    /// Marks the request stopped, e.g. after the pipeline cancelled it.
    override func stopLoading() {
        isStopped.withLock { isStopped in
            isStopped = true
        }
    }

    /// Hands the canned answer to URLSession, unless the request was already stopped.
    private func deliver(_ mockResponse: MockResponse, for requestURL: URL) {
        guard !isStopped.withLock({ isStopped in isStopped }) else {
            return
        }

        // Fail at the network layer when asked to.
        if let networkErrorCode = mockResponse.networkErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(networkErrorCode))
            return
        }

        // Otherwise answer with the canned status and headers.
        let httpResponse = HTTPURLResponse(url: requestURL, statusCode: mockResponse.statusCode, httpVersion: "HTTP/1.1", headerFields: mockResponse.headers)
        if let httpResponse {
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        }

        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Reads a request body, which URLSession hands protocols as a stream.
    private static func readBody(of request: URLRequest) -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let bodyStream = request.httpBodyStream else {
            return Data()
        }

        // Drain the stream in chunks.
        bodyStream.open()
        defer { bodyStream.close() }

        var body = Data()
        var readBuffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bodyStream.hasBytesAvailable {
            let readByteCount = bodyStream.read(&readBuffer, maxLength: readBuffer.count)
            guard readByteCount > 0 else {
                break
            }

            body.append(readBuffer, count: readByteCount)
        }

        return body
    }
}

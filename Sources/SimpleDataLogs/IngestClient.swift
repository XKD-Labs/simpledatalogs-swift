import Foundation

/// What one ingest response means for the batch that was sent (ingest API "Responses").
enum IngestOutcome: Sendable, Equatable {
    /// 202: durably stored, so the batch leaves the outbox.
    case accepted

    /// 401: the key is unknown, revoked or not yet live, so sending pauses and re-probes slowly.
    case invalidKey

    /// 413: the body was too large, so the batch is split in half.
    case payloadTooLarge

    /// 415: ingest can never take this batch as it is, so it is set aside, never resent unchanged.
    case unsupported

    /// 429, 503, any other status, a timeout or a network error: keep the batch and retry.
    case retryable(retryAfter: TimeInterval?, reason: String)

    /// Maps an HTTP status and its Retry-After header onto the ingest API response table.
    init(statusCode: Int, retryAfterHeader: String?, now: Date) {
        switch statusCode {
        case 202:
            self = .accepted
        case 401:
            self = .invalidKey
        case 413:
            self = .payloadTooLarge
        case 415:
            self = .unsupported
        default:
            // Anything else, including other 2xx codes, was not stored, so it is retried.
            let retryAfter = RetryAfterHeader.delay(fromHeaderValue: retryAfterHeader, now: now)
            self = .retryable(retryAfter: retryAfter, reason: "HTTP \(statusCode)")
        }
    }
}

/// Posts NDJSON batches to `<endpoint>/v1/ingest` with the ingest API headers.
struct IngestClient: Sendable {
    /// The User-Agent every request carries.
    static let userAgent = "simpledatalogs-swift/\(SimpleDataLogs.sdkVersion)"

    /// The session every request goes through; tests inject a mocked one.
    let session: URLSession

    /// The full ingest URL.
    let ingestURL: URL

    /// The bearer key.
    let ingestKey: String

    /// How long one request may take.
    let requestTimeout: TimeInterval

    /// The production session: ephemeral, cookie-free, cache-free, and failing fast when offline.
    static func makeDefaultSession(requestTimeout: TimeInterval) -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral

        // Offline sends fail at once and back off, instead of hanging until a connection appears.
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = requestTimeout
        sessionConfiguration.timeoutIntervalForResource = requestTimeout * 2

        // Ingest is write-only, so nothing is worth caching or remembering.
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false

        return URLSession(configuration: sessionConfiguration)
    }

    /// Builds the POST request for one batch body.
    func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: ingestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)

        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        return request
    }

    /// Sends one batch and classifies the answer; it never throws.
    func send(_ body: Data) async -> IngestOutcome {
        do {
            // Send the batch and wait for the status.
            let (_, response) = try await session.data(for: makeRequest(body: body))

            // A non-HTTP answer cannot confirm storage, so it counts as a failure.
            guard let httpResponse = response as? HTTPURLResponse else {
                return .retryable(retryAfter: nil, reason: "a non-HTTP response")
            }

            let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
            return IngestOutcome(statusCode: httpResponse.statusCode, retryAfterHeader: retryAfterHeader, now: Date())
        } catch {
            // Timeouts, offline and cancellation all leave the batch unconfirmed.
            return .retryable(retryAfter: nil, reason: error.localizedDescription)
        }
    }
}

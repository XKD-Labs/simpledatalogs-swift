import Foundation

/// Exponential backoff with full jitter, from 1 s up to 5 min, that never retries sooner than Retry-After.
struct RetryPolicy: Sendable {
    /// The backoff ceiling after the first failure.
    var initialDelay: TimeInterval = 1

    /// The largest backoff ceiling (ingest API: 5 min).
    var maximumDelay: TimeInterval = 300

    /// The shortest wait, so a jitter draw near zero can never spin the send loop.
    var minimumDelay: TimeInterval = 0.25

    /// The longest Retry-After honored, so a broken header cannot stall sending for days.
    var maximumRetryAfter: TimeInterval = 3600

    /// The first re-probe after a 401, soon enough to catch a brand-new key going live (~30 s).
    var invalidKeyFirstProbeDelay: TimeInterval = 60

    /// Every later re-probe while the key keeps answering 401 (ingest API: every ~10 min).
    var invalidKeyProbeInterval: TimeInterval = 600

    /// The wait before the next 401 re-probe, pushed later by a Retry-After from a probe that got 429 or 503.
    func invalidKeyProbeDelay(afterProbeCount probeCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let scheduledProbeDelay = probeCount == 0 ? invalidKeyFirstProbeDelay : invalidKeyProbeInterval

        return honoringRetryAfter(retryAfter, atLeast: scheduledProbeDelay)
    }

    /// The jitter-free ceiling after this many consecutive failures: 1 s, 2 s, 4 s … 5 min.
    func backoffCeiling(afterFailureCount failureCount: Int) -> TimeInterval {
        // Cap the exponent so the doubling can never overflow.
        let doublingCount = min(max(failureCount - 1, 0), 30)

        return min(maximumDelay, initialDelay * pow(2, Double(doublingCount)))
    }

    /// The wait before the next attempt: a full-jitter backoff of at least 250 ms, but never less than Retry-After.
    func delay(afterFailureCount failureCount: Int, retryAfter: TimeInterval?, jitterFraction: Double) -> TimeInterval {
        // Full jitter picks uniformly between zero and the ceiling, then the floor applies.
        let clampedJitterFraction = min(max(jitterFraction, 0), 1)
        let jitteredBackoff = max(minimumDelay, backoffCeiling(afterFailureCount: failureCount) * clampedJitterFraction)

        return honoringRetryAfter(retryAfter, atLeast: jitteredBackoff)
    }

    /// Treats the server's Retry-After as a floor over `delay`, within a sane bound.
    private func honoringRetryAfter(_ retryAfter: TimeInterval?, atLeast delay: TimeInterval) -> TimeInterval {
        guard let retryAfter else {
            return delay
        }

        return max(delay, min(retryAfter, maximumRetryAfter))
    }
}

/// Parses an HTTP Retry-After header, given as delay-seconds or an HTTP-date (RFC 9110).
enum RetryAfterHeader {
    /// The HTTP-date layouts RFC 9110 recipients accept: IMF-fixdate, RFC 850 and asctime.
    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    /// Seconds to wait from `now`, or nil when the header is missing or unreadable.
    static func delay(fromHeaderValue headerValue: String?, now: Date) -> TimeInterval? {
        // A missing or blank header carries no hint.
        guard let trimmedValue = headerValue?.trimmingCharacters(in: .whitespaces), !trimmedValue.isEmpty else {
            return nil
        }

        // delay-seconds is a bare non-negative integer.
        if trimmedValue.allSatisfy({ character in character.isASCII && character.isNumber }) {
            return TimeInterval(trimmedValue)
        }

        // An HTTP-date in the past means retry now.
        guard let retryDate = parseHTTPDate(trimmedValue) else {
            return nil
        }

        return max(0, retryDate.timeIntervalSince(now))
    }

    /// Parses an HTTP-date in any of the three accepted layouts.
    private static func parseHTTPDate(_ dateText: String) -> Date? {
        // asctime pads single-digit days with a second space, so collapse runs of spaces first.
        let normalizedDateText = dateText.split(separator: " ").joined(separator: " ")

        // HTTP-dates are always English and always GMT.
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "GMT")

        // Try each layout in turn.
        for httpDateFormat in httpDateFormats {
            dateFormatter.dateFormat = httpDateFormat

            if let parsedDate = dateFormatter.date(from: normalizedDateText) {
                return parsedDate
            }
        }

        return nil
    }
}

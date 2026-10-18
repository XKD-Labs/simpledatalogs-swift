# SimpleDataLogs for Swift

The Swift SDK for [simpledatalogs](https://simpledatalogs.com): track events from macOS and iOS apps, and see them as counters and charts.

- macOS 13+ and iOS 16+, Swift 6 with strict concurrency, Swift Package Manager only.
- No dependencies.
- Follows every [sender rule](https://simpledatalogs.com/docs/api/sender-rules) of the ingest API.
- Full guide: [simpledatalogs.com/docs/sdks/swift](https://simpledatalogs.com/docs/sdks/swift).

## Install

- **Xcode:** File → Add Package Dependencies…, enter `https://github.com/XKD-Labs/simpledatalogs-swift`, choose "Up to Next Major Version", and add the `SimpleDataLogs` library to your app target.
- **Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/XKD-Labs/simpledatalogs-swift", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "SimpleDataLogs", package: "simpledatalogs-swift")]),
]
```

## Quick start

```swift
import SimpleDataLogs

// At launch: the opt-out first, then identity and default properties, then the key.
SimpleDataLogs.setEnabled(userAllowsUsageStatistics)
SimpleDataLogs.setDeviceID(anonymousDeviceID)
SimpleDataLogs.setDefaultProperties(["app_version": "1.1.0", "distribution": "website"])
SimpleDataLogs.configure(ingestKey: "sdl_pub_…")

// Anywhere, from any thread or actor; it returns at once.
SimpleDataLogs.track("screenshot_taken", properties: ["type": "area"])
```

To send to another ingest endpoint, such as a local one:

```swift
SimpleDataLogs.configure(ingestKey: "sdl_pub_…", endpoint: URL(string: "http://localhost:4001")!)
```

## Autocapture

One argument sends launches, sessions and crashes without any `track` call. It is off until you pass it.

```swift
SimpleDataLogs.configure(ingestKey: "sdl_pub_…", autocapture: .all)
```

| Option | What you get |
|---|---|
| `.appLaunches` | `app_launched` on every launch, with `is_first_launch` |
| `.sessions` | `session_start`, a `session_id` on every event, and `session_end` (`duration_s`) once the app has been away 30 minutes; macOS counts activation, iOS foreground and background |
| `.crashes` | An uncaught `NSException` is saved at the crash and sent as `app_crashed` (`exception_name`, `reason`, `stack`) on the next launch |

`.all` is all three; pass a set to pick, e.g. `[.sessions, .crashes]`.

- **Screen views** are opt-in per screen: `.trackScreenView("Settings")` on a SwiftUI view, or `SimpleDataLogs.trackScreen("Settings")` from UIKit/AppKit. Both send `screen_view` with a `screen` prop.
- Swift runtime traps (`fatalError`, force unwraps) and signals are not `NSException`s, so they are not captured.
- The opt-out applies: with `setEnabled(false)`, nothing is captured and a saved crash is discarded.

## API

| Call | What it does |
|---|---|
| `configure(ingestKey:endpoint:autocapture:)` | Starts the SDK once; `autocapture` defaults to none; `endpoint` defaults to `https://edge.simpledatalogs.com`. Later calls are ignored. |
| `trackScreen(_:properties:)` | Records `screen_view` with a `screen` prop. |
| `track(_:properties:)` | Records one event. `event_id` and `ts` are stamped now, when the event happens. |
| `setDeviceID(_:)` | Sets (or clears, with `nil`) the `device_id` on every later event. |
| `setDefaultProperties(_:)` | Replaces the properties merged into every event's `props`; the event's own properties win on a clash. |
| `setEnabled(_:)` | The opt-out. `false` ignores new events and **deletes every unsent event**; `true` collects again. |
| `flush() async` | Seals and sends everything now; returns when that attempt ends. Undelivered events stay on disk. |

`PropertyValue` is a string, integer, double or boolean, and literals work directly (`["count": 3, "is_pro": true]`).
`PropertyValue(bridging:)` converts a loosely typed `Any`, such as a Firebase parameter, and returns nil for anything else.

Call `setEnabled(_:)` **before** `configure`. A user who opted out then never sends a byte, and whatever an earlier launch left on disk is deleted instead of sent.
The opt-out is not persisted by the SDK; your app's own setting is the source of truth, so pass it on every launch.

## How it behaves

- **Batching.** Events go out in batches of 50, or 30 s after the first event of a partial batch. Every request is under 256 KB.
- **Crash-safe outbox.** Each event is appended to a journal on disk as it is tracked.
  - Batches are sealed into files and deleted only after a `202`.
  - The next launch resends anything left over, including a journal cut short by a crash.
  - A batch file that fails to read three times in a row is renamed `*.unreadable` and skipped, so it cannot block newer batches.
  - On iOS, outbox files use the data protection class `completeUntilFirstUserAuthentication`, so background work on a locked device can still track and send.
    Before the first unlock after a reboot, a locked file is only retried later, never set aside.
  - Files live in `Application Support/<bundle id>/SimpleDataLogs/`, inside the container for sandboxed apps, and are excluded from backups.
- **Bounded.** The outbox keeps at most 10,000 events, 10 MB or 500 batch files. Past that, the oldest batches are dropped, with a log line. While a backoff or a 401 pause holds sending, the batch timer seals nothing, so days offline never leave one file per event.
- **Never outruns the disk.** If more than 5,000 events wait to be journaled (a hot loop faster than the disk), new ones are skipped, with one log line, until it catches up.
- **`415`** sets the batch aside as `.unsupported` (never resent unchanged) and the next batch goes.
- **Retries.** Timeouts, network errors, `429`, `503` and any other non-`202` answer are retried with exponential backoff and full jitter, from 1 s up to 5 min, never sooner than 250 ms. `Retry-After` is honored, as seconds or an HTTP-date.
- **Bad key (`401`).** Sending pauses and one configuration error is logged; no event is lost.
  - The SDK re-probes with its smallest batch one minute later, then every 10 minutes, and again on the next launch.
  - Only a `202` or `413` answer ends the pause. A probe lost to the network or a `503` keeps it, and the next probe honors any `Retry-After`.
  - A brand-new key that needs ~30 s to go live is picked up by the first re-probe.
- **Too large (`413`).** The batch is split in half and resent. A single event that is still too large is dropped, with a log line.
- **Lifecycle.** The SDK flushes when the app terminates and when the Mac goes to sleep (macOS), or when the app moves to the background (iOS).
  Anything a flush cannot deliver in time stays on disk for the next launch.
- **Termination.** Events tracked in `applicationWillTerminate` are kept.
  - Once termination begins, the SDK holds the main thread until every queued event is in the journal.
  - The hold is capped at 1 s in total, and usually lasts a few milliseconds.
  - Before termination, `track` never waits.
- **Fail open.** Nothing throws or crashes the host app, and nothing blocks it outside the termination hold above. Problems are logged with `os.Logger`, subsystem `com.simpledatalogs.sdk`.

Watch the logs with:

```sh
log stream --predicate 'subsystem == "com.simpledatalogs.sdk"' --level debug
```

## Development

```sh
swift build                 # library
swift build --build-tests   # also compiles the XCTest target, without running it
```

The XCTest suite uses a `URLProtocol` mock, so it never touches the network; run it with `swift test`.

## Links

- Docs: https://simpledatalogs.com/docs
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Security: [SECURITY.md](SECURITY.md)
- License: [MIT](LICENSE)

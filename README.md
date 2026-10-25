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
    .package(url: "https://github.com/XKD-Labs/simpledatalogs-swift", from: "0.4.0"),
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
| `.sessions` | `session_start`, a `session_id` on every event, and `session_end` (`duration_s`) when the session ends; see [session modes](#session-modes) |
| `.crashes` | An uncaught `NSException` is saved at the crash and sent as `app_crashed` (`exception_name`, `reason`, `stack`) on the next launch |

`.all` is all three; pass a set to pick, e.g. `[.sessions, .crashes]`.

### Session modes

| `sessionMode:` | A session ends after | Suits |
|---|---|---|
| `.activation` (default) | 30 minutes away; macOS counts activation, iOS foreground and background | Regular windowed and iOS apps |
| `.inactivityTimeout(minutes: 30)` | That many minutes without a `track` call | Menu-bar and accessory apps, which are rarely frontmost |

```swift
SimpleDataLogs.configure(ingestKey: "sdl_pub_…", autocapture: .all, sessionMode: .inactivityTimeout(minutes: 30))
```

- In `.inactivityTimeout`, the first `track` after a quiet gap sends `session_end` (stamped at the last activity) and `session_start` before the event itself.
- Back-dated events (`track(_:at:)`) never move sessions.
- An app quit mid-session ends that session on the next launch, at its last activity.

### Crash reasons

By default the reason is sent word for word, up to 4,000 characters. Exception reasons can carry file paths, record ids or emails, so you can redact them:

```swift
SimpleDataLogs.configure(ingestKey: "sdl_pub_…", autocapture: .all, crashReasonRedaction: .standard)
```

- `.standard` replaces digits with `#`, UUIDs and hex values with `<uuid>` and `<hex>`, file paths and file URLs with `<path>`, and emails with `<email>`, then cuts the reason at 200 characters.
- Pick parts with `CrashReasonRedaction(shouldStripNumbers:shouldStripPaths:shouldStripEmails:maxLength:)`.
- File paths in `stack` frames are always cut to the file or module name, in every mode.

### Active and background

Every event tracked now says whether someone was using the app, so the dashboard can tell active sessions from passive ones:

- `app_state` is `active` while the app is in front, or on a Mac when there was keyboard or mouse input in the last 10 seconds (a menu-bar hotkey counts); otherwise `background`.
- `engaged_ms` is the time the app spent in front since the previous event.
- Mark background work yourself with `track("sync_finished", properties: ["app_state": "background"])`; your value wins.
- Turn it off with `configure(ingestKey: …, activity: .off)`. Back-dated events carry neither.

 `.trackScreenView("Settings")` on a SwiftUI view, or `SimpleDataLogs.trackScreen("Settings")` from UIKit/AppKit. Both send `screen_view` with a `screen` prop.
- Swift runtime traps (`fatalError`, force unwraps) and signals are not `NSException`s, so they are not captured.
- The opt-out applies: with `setEnabled(false)`, nothing is captured and a saved crash is discarded.

## API

| Call | What it does |
|---|---|
| `configure(ingestKey:endpoint:autocapture:sessionMode:crashReasonRedaction:)` | Starts the SDK once; `autocapture` defaults to none; `endpoint` defaults to `https://edge.simpledatalogs.com`. Later calls are ignored. |
| `trackScreen(_:properties:)` | Records `screen_view` with a `screen` prop. |
| `track(_:properties:)` | Records one event. `event_id` and `ts` are stamped now, when the event happens. |
| `track(_:properties:at:eventID:)` | Records an event that happened earlier, dated `at`; see [back-dated events](#back-dated-events). |
| `track(_:properties:eventID:)` | Records an event now with your own `event_id`, so a resend of the same event is counted once. |
| `setDeviceID(_:)` | Sets (or clears, with `nil`) the `device_id` on every later event. |
| `setDefaultProperties(_:)` | Replaces the properties merged into every event's `props`; the event's own properties win on a clash. |
| `setEnabled(_:)` | The opt-out. `false` ignores new events and **deletes every unsent event**; `true` collects again. |
| `flush() async` | Seals and sends everything now; returns when that attempt ends. Undelivered events stay on disk. |
| `disable()` | The same as `setEnabled(false)`: ignores new events and deletes every unsent event. |
| `flushAndDisable(timeLimit:) async`, `flushAndDisable(timeLimit:completion:)` | Ignores new events at once, sends what is queued (10 s by default), then turns collection off and deletes whatever is left. |

`PropertyValue` is a string, integer, double or boolean, and literals work directly (`["count": 3, "is_pro": true]`).
`PropertyValue(bridging:)` converts a loosely typed `Any`, such as a Firebase parameter, and returns nil for anything else.

### Back-dated events

Events recorded before the user agreed to share usage, such as onboarding steps, can be kept by your app and sent later with their real time:

```swift
for step in savedOnboardingSteps {
    SimpleDataLogs.track("onboarding_step", properties: ["step": .string(step.name)], at: step.completedAt, eventID: step.id)
}
```

- `at` may be up to 3,650 days back, inside the ingest API's 10-year window. Anything older is dropped with a log line; a future time is sent as now.
- `eventID` is optional. Pass a stable UUID when the same event might be sent twice, so ingest counts it once.

### Stopping collection

- `setEnabled(false)` or `disable()` stops at once and deletes everything not yet delivered.
- `flushAndDisable()` sends what is already queued first, then stops and deletes whatever did not make it:

```swift
await SimpleDataLogs.flushAndDisable()

// Or, from synchronous code:
SimpleDataLogs.flushAndDisable { print("collection is off") }
```

A pending backoff does not delay that last send; a send still running at the time limit is abandoned.

Call `setEnabled(_:)` **before** `configure`. A user who opted out then never sends a byte, and whatever an earlier launch left on disk is deleted instead of sent.
The opt-out is not persisted by the SDK; your app's own setting is the source of truth, so pass it on every launch.

## How it behaves

- **Batching.** Events go out in batches of 50, or after the first event of a partial batch has waited 5 s in debug builds (10 s in release). Every request is under 256 KB.
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
  - On iOS it asks for background time for that send, and gives it back when the send ends, or after 20 s at most.
  - Anything a flush cannot deliver in time stays on disk for the next launch.
- **Termination.** Events tracked in `applicationWillTerminate` are kept, and usually sent before the app quits.
  - Once termination begins, the SDK holds the main thread until every queued event is in the journal (at most 1 s).
  - Then it sends them, holding the quit until the send ends or 2 s have passed since termination began.
  - On a slow network the rest goes out on the next launch. Before termination, `track` never waits.
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

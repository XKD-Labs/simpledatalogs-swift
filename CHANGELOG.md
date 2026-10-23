# Changelog

All notable changes to the SimpleDataLogs Swift package. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the package uses [Semantic Versioning](https://semver.org/).

## [0.4.0] - Unreleased

### Added

- `track(_:properties:at:eventID:)` sends an event dated in the past, up to 3,650 days back; a future time is sent as now.
- `track(_:properties:eventID:)` and the `eventID:` argument let you pass your own `event_id`.
- `flushAndDisable(timeLimit:)` (async and callback forms) sends what is queued, then turns collection off and deletes the rest.
- `disable()`, the same as `setEnabled(false)`.
- `sessionMode: .inactivityTimeout(minutes:)` on `configure`, for menu-bar and accessory apps: sessions follow `track` calls instead of app activation.
- `crashReasonRedaction:` on `configure`; `.standard` strips numbers, paths and emails from crash reasons and cuts them at 200 characters.

### Changed

- A partial batch now goes out 5 s after its first event in debug builds and 10 s in release, instead of 30 s, so new events show on the dashboard within seconds.
- File paths in `app_crashed` stack frames are cut to the file or module name.
- On quit, the SDK now also sends the last events, holding termination for at most 2 s in total; before, they waited for the next launch.
- On iOS, the background flush asks for background time, for at most 20 s.

## [0.3.0] - Unreleased

The first public release.

### Added

- `SimpleDataLogs.configure`, `track`, `trackScreen`, `setDeviceID`, `setDefaultProperties`, `setEnabled` and `flush` for macOS 13+ and iOS 16+, with Swift 6 strict concurrency and no dependencies.
- A crash-safe disk outbox with batching, retries with jittered backoff, `Retry-After`, 401 pauses, 413 splitting and 415 set-asides.
- Bounded storage: at most 10,000 events, 10 MB or 500 batch files.
- iOS data protection until first unlock, and flushes on background, sleep and terminate.
- Opt-in autocapture of launches, sessions and crashes, plus `.trackScreenView` for SwiftUI.
- A privacy manifest (`PrivacyInfo.xcprivacy`).

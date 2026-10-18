# Changelog

All notable changes to the SimpleDataLogs Swift package. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the package uses [Semantic Versioning](https://semver.org/).

## [0.3.0] - Unreleased

The first public release.

### Added

- `SimpleDataLogs.configure`, `track`, `trackScreen`, `setDeviceID`, `setDefaultProperties`, `setEnabled` and `flush` for macOS 13+ and iOS 16+, with Swift 6 strict concurrency and no dependencies.
- A crash-safe disk outbox with batching, retries with jittered backoff, `Retry-After`, 401 pauses, 413 splitting and 415 set-asides.
- Bounded storage: at most 10,000 events, 10 MB or 500 batch files.
- iOS data protection until first unlock, and flushes on background, sleep and terminate.
- Opt-in autocapture of launches, sessions and crashes, plus `.trackScreenView` for SwiftUI.
- A privacy manifest (`PrivacyInfo.xcprivacy`).

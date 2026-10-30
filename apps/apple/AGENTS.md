# iPhone, iPhone Duo and iPad app: notes for agents

SwiftUI, iOS and iPadOS 27, Swift 6 with complete strict concurrency. Read [README.md](README.md) first; it has the build, test and fixture details.

## Where things are

| Path | What it holds |
|---|---|
| `Reel/Core` | Everything that is not a view: `JellyfinAPI` (requests, the preview write guard), `Session` (accounts in the Keychain), `PlaybackController` (AVPlayer, reports, track changes), `Downloads` and `HLSDownloads`, `MediaHub`, `LiveTV`, `Seerr`, `ServerPreferences`, `AudioFingerprint` and `IntroDetection`. |
| `Reel/Views` | Screens. `MainView` holds the tabs and the iPad sidebar (`ReelSidebar`); `Design.swift` holds colors, type, `FoldSpread` and the readable column. |
| `ReelTests` | Unit tests, some against the loopback fixtures in `qa/`. |
| `ReelUITests` | Journeys and the screen tour. They sign in to fixtures and clear saved accounts. |
| `qa/` | Python fixture servers and their contracts, with synthetic media from `prepare_synthetic_fixtures.py`. |

`apps/tvos/project.yml` compiles a listed subset of `Reel/Core`. A Core file used by shared code (for example from `Session.swift`) must be added to that list too, or the tvOS build fails.

## Commands

Generate the project after any file is added or removed: `xcodegen generate` in `apps/apple` (the `.xcodeproj` is not in git). From the repository root, `python3 scripts/ci-xcode.py ios test --output-dir <new folder>` creates a disposable simulator, starts the fixtures, runs the unit tests and deletes the simulator; `ios ui` runs the journeys, and `--device ipad` or `--only-testing <ids>` narrow them. Each run needs a new, empty `--output-dir`. After an interrupted run, `ios cleanup --output-dir <that folder>` removes what it left.

## Rules the code depends on

- Debug and simulator builds refuse writes (history, favorites, watched, requests) to servers that are not on loopback: `JellyfinAPI.isSimulatorPreview`. Do not loosen it; tests that need writes use the fixtures.
- Strict concurrency is on. Closures handed to `Task.detached` or other actors capture only `Sendable` values; build a value first instead of capturing a `var`.
- No signing team in `project.yml`. Choose it locally in Xcode.
- iPhone Duo: views read the crease through the `foldCrease` environment value and `FoldSpread`; the player uses `PlayerStage` for the tabletop and book postures. Keep text and controls off the crease.
- User-facing strings are plain and use curly apostrophes, as the existing ones do.
- Tests that sign in to a real server stay behind `REEL_LIVE_PREVIEW_TESTS=1`.

## Known flaky tests

`PlaybackStreamChangeTests.testAudioSubtitleAndOffKeepSelectedAudioPauseAndSleep` sometimes reads audio track 1 after a change to track 3. If it fails alone, re-run before looking for a regression, and treat a repeat as a real bug in the track change path.

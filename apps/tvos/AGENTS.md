# Apple TV app: notes for agents

SwiftUI on tvOS 27, driven by the Siri Remote. Read [README.md](README.md) and [PRIVACY.md](PRIVACY.md) first.

## Where things are

- `ReelTV/` holds the TV screens and stores: `TVRootView` and `TVSessionGate` (sign-in and account state), `TVHomeStore`/`TVHomeView`, `TVBrowseStore`/`TVLibraryView`, `TVDetailView`, `TVPlayerHost` (AVPlayerViewController with its menus and contextual actions), `TVEpisodePlayback` (previous and next, the season browser, Skip intro, Next episode at the credits, the countdown), `TVSettingsView`.
- Shared code comes from `../apple/Reel/Core`, file by file, as listed under `sources` in `project.yml`. Add a Core file there when shared code starts to use it.
- `ReelTVTests` (unit), `ReelTVUITests` (remote journeys with `XCUIRemote`), `TestSupport`, and `qa/` (fixture servers, synthetic media and their contract tests).

## Commands

`xcodegen generate` in `apps/tvos`, then from the repository root `python3 scripts/ci-xcode.py tvos test --output-dir <new folder>` (or `tvos ui`, with `--only-testing <ids>` to narrow it). The script creates a simulator named `Reel QA Apple TV`, the only name the test safety checks accept, starts the fixtures each class needs (ports 18966 to 18971) and removes everything afterwards. `python3 -m unittest discover -s qa -p 'test_*.py'` runs the fixture contracts without a simulator.

## Rules the code depends on

- Work that can take seconds (network scans, downloads) runs in its own task, cancelled in `invalidate()`. `TVEpisodePlayback.load` must return as soon as metadata is in; tests time playback against it.
- Episode fixture tests need `REEL_TV_EPISODE_JOURNEYS=1`, and mutable fixtures need `REEL_TV_QA_OWNER`; the script sets both.
- Focus and remote behavior are part of the contract. A new control needs a reachable focus path and, in the player, a menu entry or a contextual action rather than a custom overlay.
- The same preview write guard as the iPhone app applies to every debug and simulator build.

## Known flaky tests

`TVAudioRetentionTests.testEOFNativeSeekThenPlayCreatesOnlyOneFreshPlayingSession` has failed once on a busy CI runner. Re-run it before treating a single failure as a regression.

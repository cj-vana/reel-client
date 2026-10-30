# Reel for Apple TV

A SwiftUI app for Apple TV running tvOS 27.0 or later, built with Xcode 27. It shares a list of core files with the iPhone and iPad app and has its own remote-first navigation, focus layout and AVKit player. It has no Google Cast dependency.

## What it does

- Password sign-in and saved accounts across several servers.
- Home shelves, library filters and paging, search, and details for films, series, seasons and episodes.
- Version, audio and subtitle choice before playback; direct and HLS playback with resume, quality, speed and chapters.
- Previous and next episode, a season browser inside the player, Skip Intro and Next episode at the credits (from server markers, or found from the episodes' audio when there are none), and a cancellable next-episode countdown.
- Private viewing, which turns off watch reports.

Not included yet: Quick Connect, server discovery, music and audiobook queues, photos, books, Live TV and DVR, media requests, remote control of other players, SyncPlay, Picture in Picture and downloads. See [platform support](../../docs/platforms.md) and [privacy](PRIVACY.md).

## Build and run

The Xcode project is generated from `project.yml` and is not part of the repository. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then from this directory:

```sh
xcodegen generate
open ReelTV.xcodeproj
```

Run `xcodegen generate` again after pulling changes that add files or touch `project.yml`.

Choose the ReelTV scheme and an Apple TV simulator, then Run. Debug builds use the bundle identifier `app.reelclient.tv.qa` and Release builds use `app.reelclient.tv`. For a real Apple TV, choose your own team and a bundle identifier you control; no signing settings are committed. See [install on Apple TV](../../docs/install/apple.md#apple-tv).

## Test

Run `xcodegen generate` in this directory first. Then, from the repository root:

```sh
python3 scripts/ci-xcode.py tvos build
python3 scripts/ci-xcode.py tvos test
python3 scripts/ci-xcode.py tvos ui
python3 scripts/ci-xcode.py tvos ui --only-testing TVJourneys/testRemoteSignInHomeDetailsAndBack
```

`build` compiles for the simulator without signing. `test` runs the unit tests. `ui` runs remote journeys that drive the real app with `XCUIRemote`: with no `--only-testing` it runs a default set, otherwise the identifiers you list, separated by commas, such as `ReelTVUITests/TVJourneys` or `ReelTVUITests/TVJourneys/testRemoteSignInHomeDetailsAndBack`.

`test` and `ui` create a new Apple TV simulator named `Reel QA Apple TV`, the only name the tests' safety checks accept, and delete it at the end. Your other simulators, including any with the same name, are never used or changed; the script only acts on the identifier of the simulator it created. The build is signed ad hoc for that simulator, so no team or keychain prompt is involved and saved sign-ins work as in the app.

The script generates synthetic media in a new folder outside the repository and starts the fixtures from `qa/` that each test class needs, each with a fresh owner value, then stops them: `qa/run-fixture.py` on ports 18966 to 18968, `qa/run-multiaudio-fixture.py` on 18969, `qa/run-episode-fixture.py` on 18967 for the episode tests, and `qa/run-library-fixture.py` on 18970 and 18971 for browsing and watched journeys. Classes that need different servers on the same port run one after another. Stop anything else using those ports first. You need Python 3 with Pillow and ffmpeg with ffprobe 7.1 or later. Journeys in `TVLibraryJourneys` that need a staged storage phase are left out.

Results, screenshots and logs stay in the folder the script prints, or in `--output-dir`. After an interrupted run, `python3 scripts/ci-xcode.py tvos cleanup --output-dir THAT_FOLDER` removes the simulator and fixtures it left behind.

To run tests from Xcode or `xcodebuild` yourself, use a disposable simulator named `Reel QA Apple TV` and start the fixtures by hand:

```sh
python3 qa/prepare-fixtures.py --output YOUR_NEW_FIXTURE_DIRECTORY
python3 qa/run-fixture.py --port 18966 --media YOUR_NEW_FIXTURE_DIRECTORY
```

Use a new, empty output directory outside the repository. The fixture servers bind to loopback only. Mutable fixture controls need `REEL_TV_QA_OWNER` set to a fresh random value for the fixture and the tests, and the tests need `REEL_TV_QA_DEVICE_UDID` set to the simulator's identifier; pass test values to `xcodebuild` with a `TEST_RUNNER_` prefix, such as `TEST_RUNNER_REEL_TV_QA_OWNER`. Sign ad hoc with `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, because unsigned simulator builds cannot use the keychain. Run the UI tests with `-parallel-testing-enabled NO`.

The fixture contract tests run without servers:

```sh
python3 -m unittest discover -s qa -p 'test_*.py'
```

Debug and simulator builds refuse to change history or library state on servers that are not on loopback.

# Reel for iPhone and iPad

A SwiftUI app for iPhone, iPhone Duo and iPad running iOS or iPadOS 27.0 or later. It is built with Xcode 27.1. Video fills the player window, playback controls float above it, and advanced options open in a sheet.

## iPhone Duo

The app reads the fold of a book-style foldable from the window, so the same code covers the folded outer screen and the open inner one:

- `FoldSpread` (`Reel/Views/Design.swift`) splits an open screen into two pages either side of the crease when each page can hold a readable column. Home, Details and Library keep text and controls on one page; only artwork crosses the crease.
- `PlayerStage` (`Reel/Views/PlayerView.swift`) puts the video above the fold and the controls below it when the phone stands half open (tabletop), and keeps the transport clear of the fold when it is held like a book. It is plain geometry, so `ReelTests` checks it without the hardware.

## Build and run

The Xcode project is generated from `project.yml` and is not part of the repository. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then generate the project and open it:

```sh
brew install xcodegen
xcodegen generate
open Reel.xcodeproj
```

Run `xcodegen generate` again after pulling changes that add files or touch `project.yml`.

Choose the Reel scheme and a simulator, then Run. To run on a device, pick your own development team in Signing & Capabilities and use a bundle identifier you control. The default is `app.reelclient.ios`. No signing team, certificate or provisioning profile is included in the repository, and you should not commit yours. [Install on a device](../../docs/install/apple.md#iphone-and-ipad) covers the details.

## Test

Run `xcodegen generate` in this directory first. Then, from the repository root:

```sh
python3 scripts/ci-xcode.py ios build
python3 scripts/ci-xcode.py ios test
python3 scripts/ci-xcode.py ios ui
python3 scripts/ci-xcode.py ios ui --device ipad --only-testing ReelUITests/ScreenTourUITests
```

`build` compiles for the simulator without signing. `test` runs the unit tests and `ui` runs UI journeys: with no `--only-testing` it runs a default set, otherwise the identifiers you list, separated by commas, such as `ReelUITests/HomeCompactUITests` or `ReelUITests/ReelUITests/testDetailsFavoritesSearchAndSeries`.

`test` and `ui` create a new simulator for each run and delete it at the end. They never use, change or delete your other simulators; the script only acts on the identifier of the simulator it created. The build is signed ad hoc for that simulator, so no team, certificate or keychain prompt is involved and saved sign-ins work as in the app. The script also generates the fixture media, starts the fixture servers each test class needs on 127.0.0.1 (TCP 18766 to 18769, 18966 and 18969, UDP 17359) and stops them afterwards, so stop anything else using those ports first. You need Python 3 with `qa/requirements.txt` installed and ffmpeg with ffprobe 7.1 or later.

Results, screenshots, screen tour images and logs stay in the folder the script prints, or in `--output-dir`. After an interrupted run, `python3 scripts/ci-xcode.py ios cleanup --output-dir THAT_FOLDER` removes the simulator and fixtures it left behind. A few UI test classes, such as `BrowseIntegrityUITests` and the player presentation classes, need fixtures the script does not start; it names them and stops instead of running them half set up.

If you run `xcodebuild test` yourself, use a simulator you are happy to reset and pass `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` rather than `CODE_SIGNING_ALLOWED=NO`. Unsigned simulator builds cannot use the keychain, so sign-in and storage tests fail. Start the fixtures below first.

Run the tests on a simulator, not on a device you use. UI tests reset the app's saved accounts. Debug and simulator builds block history and library changes on servers that are not on loopback, so test writable features only against the local fixtures below.

## Synthetic fixtures

UI tests and some contract tests talk to small Jellyfin-like servers that bind to loopback only. They generate their own media, so nothing is downloaded and no real server is involved. You need Python 3, Pillow and ffmpeg.

```sh
python3 -m pip install -r qa/requirements.txt
python3 qa/prepare_synthetic_fixtures.py
python3 qa/fixture_server.py --port 18766
```

Run each server in its own terminal. A second Jellyfin fixture on port 18767, `qa/seerr_contract.py` and `qa/remote_contract.py --port 18769` cover multiple servers, media requests and remote sessions. Fixture accounts accept any username with the password `demo`. The generated files are git-ignored.

The Python contract tests run without the servers:

```sh
python3 -m unittest discover -s qa -p 'test_*.py'
```

The player stream tests use extra fixtures from `apps/tvos/qa`. Their setup is described in the source of `qa/run-player-fixture.py` and `qa/run-player-group-fixture.py`.

## Live tests

Tests that sign in to a real server are skipped unless `REEL_LIVE_PREVIEW_TESTS=1` is set. Leave them off unless you have a server and account of your own that you are happy to test against. See [privacy](../../PRIVACY.md) and [security](../../SECURITY.md).

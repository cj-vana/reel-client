# Guide for coding agents and contributors

Reel is an open-source Jellyfin client. Each app lives in its own folder under `apps/` and has a README with full instructions, and an AGENTS.md with what an agent needs before changing it: where things are, the commands, the rules the code depends on, and known flaky tests.

| Folder | Agent notes |
|---|---|
| `apps/web` | [apps/web/AGENTS.md](apps/web/AGENTS.md) |
| `apps/desktop` | [apps/desktop/AGENTS.md](apps/desktop/AGENTS.md) |
| `apps/apple` | [apps/apple/AGENTS.md](apps/apple/AGENTS.md) |
| `apps/tvos` | [apps/tvos/AGENTS.md](apps/tvos/AGENTS.md) |
| `apps/roku` | [apps/roku/AGENTS.md](apps/roku/AGENTS.md) |
| `apps/tizen` | [apps/tizen/AGENTS.md](apps/tizen/AGENTS.md) |
| `docker` | [docker/AGENTS.md](docker/AGENTS.md) |
| `scripts` | [scripts/AGENTS.md](scripts/AGENTS.md) |

## Layout

| Path | What it is |
|---|---|
| `apps/web` | TypeScript web client, PWA, and the LG webOS TV bundle (Vite, Playwright) |
| `apps/desktop` | Electron shell that packages the web client (macOS, Windows, Linux) |
| `apps/apple` | SwiftUI app for iPhone and iPad (XcodeGen) |
| `apps/tvos` | SwiftUI app for Apple TV (XcodeGen) |
| `apps/tizen` | Samsung TV adapter around the web TV bundle |
| `apps/roku` | BrightScript and SceneGraph channel |
| `docker`, `Dockerfile` | Static web host image |
| `docs` | User-facing install, feature and platform pages |
| `scripts` | CI helpers and the public-source privacy scan |
| `branding` | Logo source and exports |

## Build and test

Node 22.12 or newer. Run `npm ci --ignore-scripts` in an app folder first.

- Web, in `apps/web`: `npm run typecheck`, `npm test`, `npm run check:static`. The browser suite needs `npm run qa:prepare` and `node ../../scripts/run-web-browser-suite.mjs` with `REEL_CI_SYNTHETIC=1`.
- Desktop, in `apps/desktop`: `npm run check`, `npm test`, `npm run build`.
- Tizen, in `apps/tizen`: `npm test`. Build after `npm run webos:stage` in `apps/web`.
- Roku, in `apps/roku`: `npm run check`, `npm test`.
- iOS and tvOS: `xcodegen generate` in the app folder, then `python3 scripts/ci-xcode.py ios test` or `tvos test` from the root.
- Python helpers and fixtures: `python3 -m unittest discover -s scripts -p 'test_*.py'` (also `apps/apple/qa`, `apps/tvos/qa`).
- Privacy scan: `python3 scripts/check-public-source.py`. It must pass before you push.

CI runs all of this in `.github/workflows/verify.yml`. Version tags run `release.yml`, which builds the packages and opens a draft release.

## Pull requests

`main` changes only through pull requests that pass the `CI result` check, and they merge with a merge commit (squash and rebase are off). CI skips app jobs a change cannot reach; see [scripts/AGENTS.md](scripts/AGENTS.md).

## Features that span apps

- **Intro and credits detection** exists twice: `apps/web/src/audio-fingerprint.ts` and `intro-detection.ts`, and `apps/apple/Reel/Core/AudioFingerprint.swift` and `IntroDetection.swift` (used by iOS and tvOS). Keep the constants and steps the same in both, and the scan's request shape too: its own play session id and no device id, so Jellyfin never stops the video's transcode for it.
- **Watch history** is sent by default on every client; Private viewing turns it off.
- **Server writes** (history, favorites, watched, requests) are refused in web preview mode and in Apple debug and simulator builds against servers that are not on loopback. Keep those guards.

## Conventions

- Test only against the synthetic fixture servers in `apps/apple/qa` and `apps/tvos/qa`, or a throwaway server. Never a real library or account.
- Commit no personal data: names, emails other than GitHub noreply addresses, hostnames, private IPs, device identifiers, paths from your machine, tokens.
- Commit no signing settings. Choose the team and bundle identifier locally. `project.yml` stays free of `DEVELOPMENT_TEAM`.
- Generated output (`.cache`, `dist`, `build`, `DerivedData`, `*.ipk`, `*.wgt`, result bundles) is git-ignored. Keep it that way.
- Follow the surrounding code. Keep user-facing text plain, with no developer or test language.
- Do not add plans, status reports, coverage ledgers, test counts or revision pins to the repository.
- Tests that touch a real server must stay behind `REEL_LIVE_PREVIEW_TESTS=1`.

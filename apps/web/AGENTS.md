# Web client: notes for agents

The TypeScript client that runs in browsers, as an installable PWA, inside the desktop app (`platform: 'desktop'`), on LG webOS (`webos`) and inside the Samsung adapter (`tizen`). One codebase; `src/runtime.ts` reads `window.REEL_CONFIG` to pick the platform and the TV layout. Read [README.md](README.md) first.

## Where things are

| File | What it owns |
|---|---|
| `src/main.ts` | The whole shell: routes, screens, Settings, the player chrome, Skip intro and Next episode, toasts. Large on purpose; find a screen by its `render…` function. |
| `src/player.ts` | `ReelPlayer`: PlaybackInfo negotiation, direct play or HLS (hls.js unless native HLS), retries, server reports and transcode cleanup. |
| `src/api.ts` | `JellyfinAPI`: every request, the `protected` preview guard that refuses writes to non-loopback servers in preview builds, `readBlob`. |
| `src/media-capabilities.ts` | The device profile sent to Jellyfin, from what this engine can decode. |
| `src/playback-extras.ts` | Episode context (previous, next, seasons) and the server's Intro and Outro segments. |
| `src/audio-fingerprint.ts`, `src/intro-detection.ts` | Finding intros and credits from audio when the server has no segments. The algorithm is mirrored in `apps/apple/Reel/Core/AudioFingerprint.swift`; change both together. |
| `src/storage.ts` | Remembered connections (browser storage, or the desktop bridge), device id. |
| `src/library-*.ts` | Library browsing, filters, saved browse choices, watched actions. |
| `src/desktop*.ts` | The desktop bridges (`window.ReelDesktop`, `ReelBrowsePreferences`, `ReelUpdates`, `ReelOffline`), validated before use. `src/desktop-offline.ts` holds the download sizes and the request the page sends. |
| `src/tv-*.ts`, `src/player-presentation.ts` | Remote navigation, the TV connect form, overlay and focus rules. |
| `src/pwa*.ts`, `src/pwa-worker.js` | Install, update prompt and the offline cache of the public interface. |
| `src/styles/` | Tokens in `tokens.css`; TV overrides in `tv.css` under `html[data-layout="tv"]`. |

## Commands

From `apps/web`, after `npm ci --ignore-scripts`:

- `npm run typecheck`, `npm test` (every `tests/*.test.ts` through `node --test` with type stripping), `npm run check:static`.
- One unit file: `node --experimental-strip-types --test tests/intro-detection.test.ts`.
- Fixtures: `npm run qa:prepare` (needs ffmpeg with libx264 and libmp3lame) writes synthetic media to `.cache/fixture`. `npm run qa:serve` serves the test catalog on 127.0.0.1:18771; `npm run qa:prepare-demo` and `npm run qa:demo` serve the screenshot library instead.
- Browser suite: the Web job in `.github/workflows/verify.yml` lists the exact order (fixtures, `webos:stage`, the IPK inspection, then `node ../../scripts/run-web-browser-suite.mjs` with `REEL_CI_SYNTHETIC=1`). For one spec, start the fixture server and `npm run dev` yourself, then `node node_modules/playwright/cli.js test tests/browser/<file>.spec.ts`. The suite uses installed Chrome (`channel: 'chrome'`).

## The fixture server

`scripts/fixture-server.mjs` is a fake Jellyfin. The password is always `demo`, and the username picks the behavior: `slow`, `flaky`, `expired`, `segments-unavailable`, `intro-scan-…` (330 second episodes with a shared theme, served as MP3 for the scan), `recent-…` (episode shelf modes driven by `POST /qa/episodes`), and so on. Desktop download routes (`/Videos/<id>/master.m3u8`, `main.m3u8`, `hls1/main/<n>.ts`) answer only with the token in the Authorization header and a `reel-download-…` play session, as the desktop download manager sends them. `GET /qa/state` returns every call and playback report; `POST /qa/reset` clears them. Tests use their own username prefix so their state never mixes.

## Things that break quietly

- Watch history is on by default; `reel.history` stores `'false'` only when Private viewing is on. Tests that start playback must expect start and stop reports.
- Browser routes in tests: match segment and stream requests by path (`url => url.pathname.endsWith(...)`), not with a `?*` glob; requests do not always carry a query string.
- The TV layout keeps focus inside the player while it is open. New player buttons need `data-player-contextual` so they stay reachable when the overlay hides, and TV focus rules in `updateTransport()`.
- Text a person reads stays plain: no test or developer language, no em dashes.
- `src/audio-fingerprint.ts` thresholds were tuned on synthetic audio (`tests/synthetic-audio.ts`); a change needs those tests and the browser journey in `tests/browser/intro-scan.spec.ts`.

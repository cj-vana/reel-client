# Roku channel: notes for agents

BrightScript and SceneGraph, experimental, Roku OS 16 or newer. Read [README.md](README.md) first.

## Where things are

- `channel/source/`: `Main.brs` (start-up), `Core.brs` (server, accounts, requests, preferences), `Operations.brs` (the requests `ApiTask` runs, one per kind), `EpisodePlayback.brs` (previous, next, seasons, server Intro segments), `Format.brs` (text and time).
- `channel/components/`: `ReelScene` (the whole interface), `ApiTask` (network work off the render thread), and the row and card components.
- `tests/`: BrightScript unit tests (`RuntimeTests.brs`, `EpisodeSceneTests.brs`) run by `scripts/test-runtime.mjs` and `scripts/test-episode-scene.mjs` in the `brs` interpreter; `scripts/test-layout.py` checks layout geometry.
- `docs/` holds the pinned asset lists that `npm run check` compares against.

## Commands

From `apps/roku`, after `npm ci --ignore-scripts`: `npm run check` (BrighterScript compile, then the package contents), `npm test`, and `npm run package` for a sideload ZIP in `out/`.

## Rules the code depends on

- Network calls run in `ApiTask`, never on the render thread.
- Tokens and passwords stay in memory; only server and account labels and preferences persist.
- Roku has no audio fingerprinting: Skip intro needs the server's Intro segments. Do not port the intro scan here without a way to decode audio off the render thread.
- Nothing has been checked on physical Roku hardware. Say so when a change depends on device behavior.

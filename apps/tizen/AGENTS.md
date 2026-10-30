# Samsung TV adapter: notes for agents

A thin Tizen wrapper around the web client's TV bundle. Experimental: nothing here has run on a physical Samsung TV. Read [README.md](README.md) first.

## Where things are

- `src/adapter.mjs`: installs the remote bridge (`window.ReelTizen`), media keys, Back and the exit dialog, and on-screen keyboard handling, driving the web player by its `data-action` buttons.
- `src/policy.mjs`: the media key table and the pure rules the adapter applies, kept separate so `tests/` can check them without a TV.
- `src/config.xml`, `src/launch.html`, `src/reel-config.js`, `src/adapter.css`: the widget configuration, entry page, runtime settings and TV-only styles.
- `scripts/build.mjs` copies the staged web TV bundle and adds the adapter; `scripts/package.mjs` and `scripts/wgt.py` write the unsigned `.wgt`.

## Commands

The web TV bundle comes first: in `apps/web`, `npm ci --ignore-scripts && npm run webos:stage`. Then in `apps/tizen`: `npm ci --ignore-scripts`, `npm test`, `npm run build -- --web-root ../web`, `npm run package`.

## Rules the code depends on

- Interface changes belong in `apps/web`; the adapter only maps the platform onto it. If the web player renames or removes a `data-action`, update `adapter.mjs` in the same change.
- `build` checks every copied file against the web stage's manifest, so build after staging, never from a hand-edited copy.
- No certificates, profiles or device identifiers in the repository. Keep the application id `ReelClient.Reel` and package id `ReelClient`.

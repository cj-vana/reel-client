# Desktop app: notes for agents

An Electron shell around the web client (`apps/web`, `platform: 'desktop'`). The shell is small and hardened; most features belong in the web client. Read [README.md](README.md) and [docs/security.md](docs/security.md) first.

## Where things are

| File | What it owns |
|---|---|
| `src/main.mjs` | App start, the single window, its in-memory session, the `reel:` asset protocol, permissions, navigation lockdown, the close handshake. |
| `src/policy.mjs` | `APP_URL`, window options (sandbox, context isolation, an in-memory `reel-…` partition), fullscreen permission rules. |
| `src/assets.mjs` | Serves the staged web build over `reel:` and checks every file against its manifest. |
| `src/preload.cjs` | The only page APIs: `ReelDesktop` (connections, preferences, close), `ReelBrowsePreferences`, `ReelUpdates`. Each validates its input before IPC. |
| `src/bridge.mjs`, `src/browse-bridge.mjs`, `src/updates-bridge.mjs` | IPC handlers. Each accepts calls only from the window's own main frame at `APP_URL`. |
| `src/store.mjs` | `DesktopStore`: preferences (atomic, compare-and-swap by revision) and remembered connections, encrypted by `src/crypto-provider.mjs` through the OS. |
| `src/updates.mjs` | Release checks; a Developer ID-signed Mac build installs through Squirrel.Mac. |
| `scripts/build.mjs` | Builds the web client and stages it with the shell in `.cache/stage`. |
| `scripts/package.mjs` | electron-packager from a checksummed Electron download (`scripts/electron-checksums.json`), fuses, payload verification against the stage, and Mac signing when `REEL_MACOS_SIGN=1`. |
| `scripts/check.mjs` | Syntax, exact dependency pins and lock agreement. |
| `scripts/runtime-checks.mjs` | Launches a QA build and drives it. |

## Commands

From `apps/desktop`, after `npm ci --ignore-scripts`: `npm run check`, `npm test`, `npm run build`. `npm run package` needs a build first. `npm run test:runtime` (add `-- --visible` to watch) runs a QA package against loopback fixtures and writes results to `.cache/runtime/`.

## Rules the code depends on

- Dependencies are pinned to exact versions and `npm run check` fails otherwise. Add one with `npm install --save-dev --save-exact`.
- A new preference must be accepted by `preferenceFields` in `src/store.mjs` (optional switches are listed in `OPTIONAL_SWITCHES` so older preference files still load), saved by `savePreferences`, read in `apps/web/src/desktop.ts`, and covered in `tests/store.test.mjs` and `apps/web/tests/desktop.test.ts`.
- A new page API goes in `src/preload.cjs` with its own validation and a handler that checks the sender like `updates-bridge.mjs`. Never expose `ipcRenderer` or a generic channel.
- The QA flavor talks only to loopback; anything that reaches the network from the main process must be off in QA, as the update service is.
- Signing happens after the fuses are flipped; flipping them later would break the signature.
- The session is in memory: web storage does not survive a restart. Anything that must persist goes through `DesktopStore`.

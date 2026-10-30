# Contributing

Thanks for helping. Reel is early software, so keep changes small and say which platforms they touch.

## Getting started

1. For a large feature or a new platform, open an issue first so we can agree on the approach.
2. Branch from `main` with a short name such as `fix/playback-resume`.
3. Build and test the app you changed. Each app's README under `apps/` has the commands, and [AGENTS.md](AGENTS.md) lists them in one place.
4. Add a test for any behavior change, and try the real screen or player as well as the automated tests.
5. Open a pull request that says what changed, how you checked it, and what you could not check.

## Pull requests and CI

`main` only changes through pull requests. A pull request merges when the **CI result** check passes and the branch is up to date with `main`. Merges keep a merge commit; squash and rebase merges are off.

CI skips the app jobs a change cannot affect, so a pull request that only touches the Roku channel does not wait for the Apple builds. A change to `scripts/`, the workflows or any file outside the app folders runs everything. The iOS and tvOS UI journeys take a long time, so they run on demand: start the **Verify** workflow from the Actions tab and choose the platform.

## Rules for test data

- Use a throwaway server and account, or the synthetic fixture servers in `apps/apple/qa` and `apps/tvos/qa`. They bind to loopback and make up their own media.
- Do not run the iOS or tvOS UI tests on a device that holds your own sign-ins. They clear saved accounts.
- Do not change watched state, requests, DVR schedules or playback on a server that is not yours.
- Debug and simulator builds block changes to servers that are not on loopback. Leave that protection in place.
- Tests that sign in to a real server must stay behind `REEL_LIVE_PREVIEW_TESTS=1`.

## Keep these out of commits

Passwords, tokens, cookies, media files, library metadata, server logs, signing teams, certificates, provisioning profiles, device identifiers, and personal addresses or hostnames. Choose your signing team and bundle identifier locally, in Xcode or on the command line. Never in `project.yml`.

Run the privacy scan before you push:

```sh
python3 scripts/check-public-source.py
```

## Style

Follow the code around your change. Keep UI text plain and written for people who use the app. Do not add generated planning notes, status reports or test logs to the repository.

## Licensing

Contributions to original project code are under the repository's MIT license. Third-party code or artwork needs its own license and attribution in [THIRD_PARTY.md](THIRD_PARTY.md). Do not add media you do not have the right to redistribute.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

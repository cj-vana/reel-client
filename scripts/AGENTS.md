# CI and repository scripts: notes for agents

Helpers the workflows call, and the privacy and link checks every change runs. Each has unit tests beside it (`test_*.py`); run them with `python3 -m unittest discover -s scripts -p 'test_*.py'`.

| Script | What it does |
|---|---|
| `check-public-source.py` | The privacy scan: personal data, secrets, signing settings and stray artifacts must not ship. Run it before every push. |
| `check-doc-links.py` | Every relative link and heading anchor in the Markdown files must resolve. Run it after renaming a heading. |
| `ci-changed-areas.py` | Reads changed paths and prints `apple=`, `web=`, `roku=` lines so CI skips jobs a change cannot reach. Documentation alone runs only the source checks; anything outside the app folders runs everything. |
| `ci-xcode.py` | Builds and tests the iOS or tvOS app on a new simulator it creates and deletes, with the fixtures each test class needs (`ci-fixtures.py` maps classes to fixture profiles). |
| `ci-xcresult.py` | Prints what a result bundle ran and why tests failed. |
| `run-web-browser-suite.mjs`, `ci-processes.mjs` | Start the web fixture server, the dev server and the notices server, run the Playwright suite, and stop them. Needs `REEL_CI_SYNTHETIC=1`. |

## Using `ci-xcode.py`

- Generate the Xcode project first (`xcodegen generate` in `apps/apple` or `apps/tvos`). A project left over from another branch can still name files that no longer exist.
- `--output-dir` must be a new, empty folder for every run; the script refuses a used one. After an interrupted run, `cleanup --output-dir <that folder>` removes the simulator and fixtures it left.
- Stop anything else on the fixture ports first (iOS: 18766 to 18769, 18966, 18969 and UDP 17359; tvOS: 18966 to 18971).
- It needs Python with `apps/apple/qa/requirements.txt` installed, and ffmpeg with ffprobe 7.1 or later.

## The required check

Branch protection requires one check, `CI result`, from `.github/workflows/verify.yml`. It passes only when every job passed or was skipped because its area did not change. Add a new job to the `needs` list of the `result` job, or the result will not wait for it.

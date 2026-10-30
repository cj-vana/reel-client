#!/usr/bin/env python3
"""Decide which app areas a change touches, so CI can skip jobs that cannot be affected.

Reads changed paths, one per line, on stdin and prints one `area=true` or `area=false` line per
area, in the form GitHub Actions reads from $GITHUB_OUTPUT. With --all, every area is selected
without reading stdin (pushes to main and manual runs test everything).

The rule errs toward running: a path outside every known area selects every area, so scripts,
workflows, root files and anything new always run the full set. Only documentation is quiet.
"""
import sys

AREAS = {
    # tvOS compiles the iOS app's Core, so the two Apple apps move together.
    "apple": ("apps/apple/", "apps/tvos/"),
    # Desktop, Samsung and the Docker image all ship the web build.
    "web": ("apps/web/", "apps/desktop/", "apps/tizen/", "docker/", "Dockerfile", ".dockerignore"),
    "roku": ("apps/roku/",),
}

# Paths no build or test reads. The source checks job still runs for every change, so the doc
# link check covers these.
QUIET_PREFIXES = ("docs/", "branding/", ".github/ISSUE_TEMPLATE/")


def quiet(path: str) -> bool:
    return path.endswith(".md") or path.startswith(QUIET_PREFIXES)


def area_of(path: str) -> str | None:
    for name, prefixes in AREAS.items():
        if any(path == prefix or (prefix.endswith("/") and path.startswith(prefix)) for prefix in prefixes):
            return name
    return None


def select(paths: list[str]) -> dict[str, bool]:
    selected = {name: False for name in AREAS}
    for path in (line.strip() for line in paths):
        if not path or quiet(path):
            continue
        name = area_of(path)
        if name is None:
            return {name: True for name in AREAS}
        selected[name] = True
    return selected


def main(argv: list[str]) -> int:
    if argv == ["--all"]:
        result = {name: True for name in AREAS}
    elif not argv:
        result = select(sys.stdin.read().splitlines())
    else:
        print("usage: ci-changed-areas.py [--all] < changed-paths", file=sys.stderr)
        return 2
    for name, value in result.items():
        print(f"{name}={'true' if value else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Check that every relative link and heading anchor in the repository's Markdown files resolves."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)|!\[[^\]]*\]\(([^)\s]+)\)")
FENCE = re.compile(r"^\s*```")


def markdown_files(root):
    names = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md"]
    ).decode().split("\0")
    return sorted(root / name for name in names if name and (root / name).is_file())


def slug(heading):
    """GitHub's heading anchor: lowercase, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"[`*_]", "", heading.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path):
    found, in_fence = set(), False
    for line in path.read_text(encoding="utf-8").splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
        elif not in_fence and line.startswith("#"):
            found.add(slug(line.lstrip("#")))
    return found


def links(path):
    in_fence = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in LINK.finditer(re.sub(r"`[^`]*`", "", line)):
            yield number, match.group(1) or match.group(2)


def check(root):
    errors = []
    for path in markdown_files(root):
        for number, target in links(path):
            if re.match(r"[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith("//"):
                continue
            where = f"{path.relative_to(root)}:{number}"
            name, _, fragment = target.partition("#")
            destination = path if not name else (path.parent / name).resolve()
            if not destination.exists():
                errors.append(f"{where}: missing target {target}")
            elif fragment and destination.suffix == ".md" and slug(fragment) not in anchors(destination):
                errors.append(f"{where}: missing heading {target}")
    return errors


if __name__ == "__main__":
    problems = check(ROOT)
    if problems:
        print("Broken documentation links:\n" + "\n".join("- " + item for item in problems), file=sys.stderr)
        sys.exit(1)
    print("All relative documentation links resolve.")

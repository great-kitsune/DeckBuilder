"""Check the feature version against the PR base, including stacked PRs."""
import re
import subprocess
import sys
from pathlib import Path


def version(text):
    match = re.search(r"^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$", text, re.M)
    if not match:
        raise SystemExit("Expected MAJOR.MINOR.PATCH+BUILD in pubspec.yaml")
    return tuple(map(int, match.groups()))


old = version(subprocess.check_output(["git", "show", f"{sys.argv[1]}:pubspec.yaml"], text=True))
new = version(Path("pubspec.yaml").read_text())
if new != old or sys.argv[2].startswith("phase3/"):
    if new[:3] != (old[0], old[1] + 1, 0) or new[3] <= old[3]:
        raise SystemExit(f"Invalid feature version change: {old} -> {new}")

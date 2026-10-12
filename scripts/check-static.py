#!/usr/bin/env python3
"""Small, dependency-free input checks; no Docker daemon or runtime claims."""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
REQUIRED = (
    "Dockerfile",
    ".dockerignore",
    "sources.lock.json",
    "flake.nix",
    "flake.lock",
    ".github/workflows/image.yml",
    "scripts/entrypoint.sh",
    "scripts/verify-image.sh",
)


def check_hashes(value, location="sources.lock.json"):
    """Check declared SHA-256 fields without duplicating the source lock schema."""
    if isinstance(value, dict):
        for key, item in value.items():
            field = f"{location}.{key}"
            if key == "sha256" and (
                not isinstance(item, str) or not re.fullmatch(r"[0-9a-f]{64}", item)
            ):
                raise ValueError(f"{field}: expected a lowercase SHA-256 hex digest")
            check_hashes(item, field)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            check_hashes(item, f"{location}[{index}]")


def main():
    missing = [name for name in REQUIRED if not (ROOT / name).is_file()]
    if not list((ROOT / "scripts").glob("build-*")):
        missing.append("scripts/build-*")
    if not any((ROOT / "tests").glob("**/*")):
        missing.append("tests fixtures")
    if missing:
        raise ValueError("required files missing: " + ", ".join(missing))

    for name in ("sources.lock.json", "flake.lock"):
        with (ROOT / name).open(encoding="utf-8") as stream:
            value = json.load(stream)
        if not isinstance(value, dict):
            raise ValueError(f"{name}: expected a JSON object")
        if name == "sources.lock.json":
            check_hashes(value)

    workflows = sorted((ROOT / ".github/workflows").glob("*.yml"))
    for workflow in workflows:
        for action in re.findall(r"^\s*uses:\s*(\S+)", workflow.read_text(), re.MULTILINE):
            if not action.startswith("./") and not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", action):
                raise ValueError(f"{workflow.relative_to(ROOT)}: action is not commit-pinned: {action}")

    scripts = sorted((ROOT / "scripts").glob("*.sh"))
    scripts += sorted((ROOT / "tests").glob("**/*.sh"))
    for script in scripts:
        subprocess.run(["bash", "-n", str(script)], cwd=ROOT, check=True)
    if shutil.which("actionlint"):
        subprocess.run(["actionlint", *map(str, workflows)], cwd=ROOT, check=True)
    else:
        print("SKIP actionlint: unavailable; use nix develop for workflow linting")
    print(f"PASS static checks ({len(scripts)} shell scripts); runtime tests are separate")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

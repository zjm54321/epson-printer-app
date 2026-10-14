#!/usr/bin/env python3
"""Small, dependency-free input checks; no Docker daemon or runtime claims."""

import hashlib
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
    "THIRD_PARTY.md",
    ".github/workflows/image.yml",
    "runtime/queue-check.c",
    "discovery/avahi-daemon.conf.in",
    "discovery/dbus-system.conf",
    "scripts/build-dependencies.sh",
    "scripts/build-discovery.sh",
    "scripts/build-fetch.sh",
    "scripts/build-ppds.sh",
    "scripts/build-runtime.sh",
    "scripts/build-sources.sh",
    "scripts/build-stack.sh",
    "scripts/entrypoint.sh",
    "scripts/discovery-entrypoint.sh",
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


def check_patches(lock):
    upstream = {item["name"]: item["commit"] for item in lock["upstream"]}
    supported = {
        "cups", "pappl", "ghostscript", "libcupsfilters", "libppd",
        "cups-filters", "pappl-retrofit", "ghostscript-printer-app",
    }
    for index, item in enumerate(lock["patches"]):
        location = f"sources.lock.json.patches[{index}]"
        component = item.get("component")
        if component not in supported or component not in upstream:
            raise ValueError(f"{location}: unsupported source patch component: {component}")
        if item.get("commit") != upstream[component]:
            raise ValueError(f"{location}: source patch commit mismatch: {component}")
        patch = ROOT / item["path"]
        if hashlib.sha256(patch.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError(f"{location}: source patch digest mismatch: {item['path']}")


def main():
    missing = [name for name in REQUIRED if not (ROOT / name).is_file()]
    if missing:
        raise ValueError("required files missing: " + ", ".join(missing))

    with (ROOT / "sources.lock.json").open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError("sources.lock.json: expected a JSON object")
    check_hashes(value)
    check_patches(value)

    workflows = sorted((ROOT / ".github/workflows").glob("*.yml"))
    for workflow in workflows:
        for action in re.findall(r"^\s*uses:\s*(\S+)", workflow.read_text(), re.MULTILINE):
            if not action.startswith("./") and not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", action):
                raise ValueError(f"{workflow.relative_to(ROOT)}: action is not commit-pinned: {action}")

    scripts = sorted((ROOT / "scripts").glob("*.sh"))
    for script in scripts:
        subprocess.run(["bash", "-n", str(script)], cwd=ROOT, check=True)
    if shutil.which("actionlint"):
        subprocess.run(["actionlint", *map(str, workflows)], cwd=ROOT, check=True)
    else:
        print("SKIP actionlint: unavailable; use nix develop for workflow linting")
    print(f"PASS build input integrity and syntax checks ({len(scripts)} shell scripts)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

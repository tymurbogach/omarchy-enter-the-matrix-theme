#!/usr/bin/env python3
"""Derive a continuous Matrix screensaver from the installed Omarchy script."""

import argparse
import os
import sys
from pathlib import Path

MARKER = "# Managed by omarchy-rain. Re-run its installer after omarchy update.\n"
NEEDLE = "    --random-effect --no-eol --no-restore-cursor &"
REPLACEMENT = "    --no-eol --no-restore-cursor matrix --rain-time 86400 &"


def fail(message: str) -> None:
    print(f"omarchy-rain: {message}", file=sys.stderr)
    raise SystemExit(1)


def derive(source: str) -> str:
    count = source.count(NEEDLE)
    if count != 1:
        fail(
            "expected one random-effect call in Omarchy's screensaver, "
            f"found {count}. The installed API changed, so nothing was replaced."
        )
    if not source.startswith("#!/bin/bash\n"):
        fail("the installed screensaver no longer has the expected bash header")
    derived = source.replace(NEEDLE, REPLACEMENT)
    return derived.replace("#!/bin/bash\n", "#!/bin/bash\n" + MARKER, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    omarchy = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))
    source = args.source or omarchy / "bin/omarchy-screensaver"
    if not source.is_file():
        fail(f"cannot read {source}")

    result = derive(source.read_text())
    if args.check:
        return
    if args.output is None:
        fail("--output is required unless --check is used")
    args.output.write_text(result)


if __name__ == "__main__":
    main()

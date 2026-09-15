#!/usr/bin/env python3
"""Where the derivers get the provider's names from.

The pack is machinery plus one provider, and provider.json is the only file
that names the provider. The bash side resolves it the same way, in
`omarchy-matrix`: keep the two in step.

Resolution order, and why:

  $OMARCHY_MATRIX_PROVIDER          an explicit override, and what the tests use
  ~/.local/share/omarchy-matrix/    where install.sh puts it -- readable even
                                    while another theme is current, which is
                                    exactly when `suspend` runs
  next to this script                a working copy, with nothing installed yet
"""

import json
import os
import sys
from pathlib import Path

CANDIDATES = [
    Path(os.environ["OMARCHY_MATRIX_PROVIDER"])
    if os.environ.get("OMARCHY_MATRIX_PROVIDER") else None,
    Path.home() / ".local/share/omarchy-matrix/provider.json",
    Path(__file__).resolve().parent.parent / "provider.json",
]


def load():
    for candidate in CANDIDATES:
        if candidate and candidate.is_file():
            try:
                return json.loads(candidate.read_text())
            except ValueError as failure:
                print(f"provider: {candidate} is not valid JSON ({failure})",
                      file=sys.stderr)
                sys.exit(1)
    print("provider: cannot find provider.json. Re-run the pack's install.sh.",
          file=sys.stderr)
    sys.exit(1)


PROVIDER = load()

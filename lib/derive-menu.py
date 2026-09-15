#!/usr/bin/env python3
"""Derive Style > Unlock from the row Omarchy ships, so that the card of this
theme boots animated.

Omarchy's Unlock row runs `omarchy-plymouth-set-by-theme <theme>`. That
command installs colours and one still image, and no hook runs after it. So
the card of this theme could only give the still splash, never the animation.

Omarchy's menu lets the user's extension file replace a row by its id
(mergeMenuSources, MenuModel.js). This writes one replacement row there, in a
marked block:

- the card of this theme runs `<cli> boot on`, which installs the animation;
- every other choice runs Omarchy's own command, then `<cli> boot off`, which
  takes the animation away if it is there.

Both run in the one terminal that Omarchy opens, so sudo asks once. The row is
derived from $OMARCHY_PATH's menu on every run, never frozen, and each anchor
must occur exactly once. If Omarchy's row changes shape, this takes its block
out, so Omarchy's own row comes back, and says so.

  derive-menu.py            write or refresh the block
  derive-menu.py --remove   take the block out
"""

import json
import os
import re
import sys
import tempfile
from pathlib import Path

# Loaded by path rather than by name, like the other derivers: lib/ is not on
# sys.path when this runs from the share dir.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from provider import PROVIDER  # noqa: E402

HOME = Path.home()
OMARCHY = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))
DEFAULT_MENU = OMARCHY / "default/omarchy/omarchy-menu.jsonc"
TEMPLATE = OMARCHY / "config/omarchy/extensions/omarchy-menu.jsonc"
USER_MENU = HOME / ".config/omarchy/extensions/omarchy-menu.jsonc"

SLUG = PROVIDER["slug"]
CLI = HOME / ".local/bin" / PROVIDER["cli"]
ROW = "style.unlock"
BEGIN = f"// >>> {SLUG}: Style > Unlock, managed by {PROVIDER['cli']}. Do not edit."
END = f"// <<< {SLUG}"

# The three places that the patch goes, as Omarchy writes them today. Each one
# must occur exactly once in the row's action.
RESET = "omarchy-launch-floating-terminal-with-presentation omarchy-plymouth-reset;"
BY_THEME = 'omarchy-plymouth-set-by-theme $(printf %q "$unlock")"'
ANY_THEME = "elif [[ -n $unlock ]]; then"


def die(message):
    print(f"derive-menu: {message}", file=sys.stderr)
    sys.exit(1)


def strip_jsonc(raw):
    """Exactly what Omarchy's menu does before JSON.parse (stripJsonc in
    MenuModel.js): whole-line // comments go, then trailing commas. A file that
    parses here is a file that Omarchy's menu can read."""
    raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
    return re.sub(r",(\s*[}\]])", r"\1", raw)


def parse(raw):
    stripped = strip_jsonc(raw)
    if not stripped.strip():
        return {}
    value = json.loads(stripped)
    if not isinstance(value, dict):
        raise ValueError("the file is not one JSON object")
    return value


def omarchy_row():
    try:
        row = parse(DEFAULT_MENU.read_text(encoding="utf-8")).get(ROW)
    except (OSError, ValueError) as failure:
        die(f"cannot read Omarchy's menu at {DEFAULT_MENU}: {failure}")
    if not isinstance(row, dict) or not isinstance(row.get("action"), str):
        die(f"Omarchy's menu has no {ROW} row with an action")
    return row


def patch(action):
    for anchor in (RESET, BY_THEME, ANY_THEME):
        found = action.count(anchor)
        if found != 1:
            raise LookupError(f"expected `{anchor}` once in Omarchy's {ROW} "
                              f"action, found it {found} times")
    off = f"'{CLI}' boot off"
    on = f"omarchy-launch-floating-terminal-with-presentation \"'{CLI}' boot on\""
    action = action.replace(
        RESET,
        f'omarchy-launch-floating-terminal-with-presentation "omarchy-plymouth-reset && {off}";')
    action = action.replace(
        BY_THEME, f'omarchy-plymouth-set-by-theme $(printf %q "$unlock") && {off}"')
    return action.replace(ANY_THEME, f"elif [[ $unlock == {SLUG} ]]; then {on}; {ANY_THEME}")


def without_block(text):
    out, inside = [], False
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped == BEGIN:
            inside = True
        elif inside and stripped == END:
            inside = False
        elif not inside:
            out.append(line)
    if inside:
        die(f"{USER_MENU} has the line `{BEGIN}` but not `{END}`. "
            f"Fix the block by hand, or delete it.")
    return "".join(out)


def with_block(text, entry):
    """The block goes right after the opening brace. Its row ends with a comma,
    which Omarchy's parser allows, so the rows below it need no change."""
    row = json.dumps({ROW: entry}, ensure_ascii=False, separators=(",", ":"))[1:-1]
    block = f"  {BEGIN}\n  {row},\n  {END}\n"
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        if line.strip() != "{":
            die(f"{USER_MENU} does not open with `{{` on a line of its own; "
                f"not touching it")
        if not line.endswith("\n"):
            lines[i] = line + "\n"
        return "".join(lines[:i + 1]) + block + "".join(lines[i + 1:])
    die(f"{USER_MENU} has no opening `{{`; not touching it")


def write(text, mode):
    USER_MENU.parent.mkdir(parents=True, exist_ok=True)
    # One rename, so that the menu's file watcher never reads half a file.
    fd, tmp = tempfile.mkstemp(prefix=".omarchy-menu.", dir=USER_MENU.parent)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, USER_MENU)


def main():
    current = USER_MENU.read_text(encoding="utf-8") if USER_MENU.is_file() else None
    mode = USER_MENU.stat().st_mode & 0o777 if current is not None else 0o644

    if "--remove" in sys.argv[1:]:
        if current is not None and BEGIN in current:
            write(without_block(current), mode)
            print("Handed Style > Unlock back to Omarchy")
        return

    # Both names go into a shell command that the menu runs: allow only
    # characters that cannot end a quote.
    if not re.fullmatch(r"/[A-Za-z0-9._/-]+", str(CLI)):
        die(f"{CLI} holds characters that cannot go into a menu action safely")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._+-]*", SLUG):
        die(f"the slug {SLUG!r} cannot go into a menu action safely")

    row = omarchy_row()
    try:
        action = patch(row["action"])
    except LookupError as failure:
        if current is not None and BEGIN in current:
            write(without_block(current), mode)
        die(f"{failure}.\n"
            f"  Omarchy's Unlock menu has changed, so Style > Unlock is Omarchy's own "
            f"again. Its\n  {SLUG} card gives the still splash; "
            f"`{PROVIDER['cli']} boot on` still animates it.\n"
            f"  Please open an issue at {PROVIDER['repoUrl']} with your "
            f"`omarchy version`.")

    # icon and label come along: normalizeItem (MenuModel.js) fills in every
    # key before the merge, so a row without them would blank Omarchy's.
    entry = {key: row[key] for key in ("icon", "label", "aliases") if key in row}
    entry["action"] = action

    base = current
    if base is None:
        base = TEMPLATE.read_text(encoding="utf-8") if TEMPLATE.is_file() else "{\n}\n"
    rest = without_block(base)
    try:
        before = parse(rest)
    except ValueError as failure:
        die(f"{USER_MENU} does not parse ({failure}); not touching it")
    if ROW in before:
        print(f"derive-menu: {USER_MENU} already replaces {ROW} with a row of "
              f"your own. Leaving it alone.", file=sys.stderr)
        if current is not None and current != rest:
            write(rest, mode)
        return

    text = with_block(rest, entry)
    try:
        after = parse(text)
    except ValueError as failure:
        die(f"the derived menu does not parse ({failure}); {USER_MENU} is untouched")
    if after != {**before, ROW: entry}:
        die(f"the derived menu does not read back as written; {USER_MENU} is untouched")

    if text != current:
        write(text, mode)
        print(f"Style > Unlock: the {SLUG} card now boots animated")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Derive two rows of Omarchy's menu from the rows Omarchy ships.

Omarchy runs no hook after either row, so the pack cannot follow them in any
other way:

- Style > Unlock runs `omarchy-plymouth-set-by-theme <theme>`, which installs
  colours and one still image. The card of this theme could only give the
  still splash, never the animation.
- Remove > Theme runs `omarchy-theme-remove`, which deletes the theme's folder
  and nothing else. The pack stayed installed, with no theme to serve.

Omarchy's menu lets the user's extension file replace a row by its id
(mergeMenuSources, MenuModel.js). This writes the replacement rows there, in
one marked block:

- In Unlock, the card of this theme runs `<cli> boot on`, which installs the
  animation. Every other choice runs Omarchy's own command, then
  `<cli> boot off`, which takes the animation away if it is there. Both run in
  the one terminal that Omarchy opens, so sudo asks once.
- In Remove > Theme, Omarchy's own command runs first, unchanged. Then
  `<cli> hook theme-remove` checks whether this theme's folder is gone. If it
  is, the pack stands down and opens Omarchy's terminal with the full
  uninstall.

The rows are derived from $OMARCHY_PATH's menu on every run, never frozen, and
each anchor must occur exactly once. A row whose anchors no longer fit is left
to Omarchy: this says so and exits 1. A row that the user replaced in their
own file is left to the user.

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
BEGIN = f"// >>> {SLUG}: rows of Omarchy's menu, managed by {PROVIDER['cli']}. Do not edit."
# Up to 1.2.x the block held Style > Unlock alone, under this first line.
OLD_BEGIN = f"// >>> {SLUG}: Style > Unlock, managed by {PROVIDER['cli']}. Do not edit."
END = f"// <<< {SLUG}"

UNLOCK = "style.unlock"
REMOVE = "remove.theme"

# Style > Unlock: the three places that the patch goes, as Omarchy writes them
# today. Each one must occur exactly once in the row's action.
RESET = "omarchy-launch-floating-terminal-with-presentation omarchy-plymouth-reset;"
BY_THEME = 'omarchy-plymouth-set-by-theme $(printf %q "$unlock")"'
ANY_THEME = "elif [[ -n $unlock ]]; then"
# Remove > Theme: Omarchy's whole action. It runs first, and unchanged.
REMOVE_THEME = "omarchy-theme-remove"


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


def patch_unlock(action):
    for anchor in (RESET, BY_THEME, ANY_THEME):
        found = action.count(anchor)
        if found != 1:
            raise LookupError(
                f"expected `{anchor}` once in Omarchy's {UNLOCK} action, found it "
                f"{found} times. Style > Unlock is Omarchy's own again: its {SLUG} "
                f"card gives the still splash, and `{PROVIDER['cli']} boot on` still "
                f"animates it")
    off = f"'{CLI}' boot off"
    on = f"omarchy-launch-floating-terminal-with-presentation \"'{CLI}' boot on\""
    action = action.replace(
        RESET,
        f'omarchy-launch-floating-terminal-with-presentation "omarchy-plymouth-reset && {off}";')
    action = action.replace(
        BY_THEME, f'omarchy-plymouth-set-by-theme $(printf %q "$unlock") && {off}"')
    return action.replace(ANY_THEME, f"elif [[ $unlock == {SLUG} ]]; then {on}; {ANY_THEME}")


def patch_remove(action):
    if action.strip() != REMOVE_THEME:
        raise LookupError(
            f"expected Omarchy's {REMOVE} action to be `{REMOVE_THEME}`, found "
            f"`{action}`. Remove > Theme is Omarchy's own again: after it removes "
            f"{SLUG}, run `{PROVIDER['cli']} uninstall`")
    return f"{REMOVE_THEME}; [[ ! -x '{CLI}' ]] || '{CLI}' hook theme-remove"


PATCHES = {UNLOCK: patch_unlock, REMOVE: patch_remove}


def omarchy_menu():
    try:
        return parse(DEFAULT_MENU.read_text(encoding="utf-8"))
    except (OSError, ValueError) as failure:
        die(f"cannot read Omarchy's menu at {DEFAULT_MENU}: {failure}")


def derive(menu, row_id):
    """The replacement for one row. LookupError when Omarchy's row no longer fits."""
    row = menu.get(row_id)
    if not isinstance(row, dict) or not isinstance(row.get("action"), str):
        raise LookupError(f"Omarchy's menu has no {row_id} row with an action")
    # icon and label come along: normalizeItem (MenuModel.js) fills in every
    # key before the merge, so a row without them would blank Omarchy's.
    entry = {key: row[key] for key in ("icon", "label", "aliases") if key in row}
    entry["action"] = PATCHES[row_id](row["action"])
    return entry


def without_block(text):
    out, inside = [], False
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped in (BEGIN, OLD_BEGIN):
            inside = True
        elif inside and stripped == END:
            inside = False
        elif not inside:
            out.append(line)
    if inside:
        die(f"{USER_MENU} has the line `{BEGIN}` but not `{END}`. "
            f"Fix the block by hand, or delete it.")
    return "".join(out)


def with_block(text, entries):
    """The block goes right after the opening brace. Each row ends with a comma,
    which Omarchy's parser allows, so the rows below the block need no change."""
    rows = "".join(
        "  " + json.dumps({key: entry}, ensure_ascii=False, separators=(",", ":"))[1:-1] + ",\n"
        for key, entry in entries.items())
    block = f"  {BEGIN}\n{rows}  {END}\n"
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
        if current is not None and (BEGIN in current or OLD_BEGIN in current):
            write(without_block(current), mode)
            print("Handed Omarchy's menu rows back")
        return

    # Both names go into a shell command that the menu runs: allow only
    # characters that cannot end a quote.
    if not re.fullmatch(r"/[A-Za-z0-9._/-]+", str(CLI)):
        die(f"{CLI} holds characters that cannot go into a menu action safely")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._+-]*", SLUG):
        die(f"the slug {SLUG!r} cannot go into a menu action safely")

    base = current
    if base is None:
        base = TEMPLATE.read_text(encoding="utf-8") if TEMPLATE.is_file() else "{\n}\n"
    rest = without_block(base)
    try:
        before = parse(rest)
    except ValueError as failure:
        die(f"{USER_MENU} does not parse ({failure}); not touching it")

    menu = omarchy_menu()
    entries, failures = {}, []
    for row_id in PATCHES:
        if row_id in before:
            print(f"derive-menu: {USER_MENU} already replaces {row_id} with a row of "
                  f"your own. Leaving it alone.", file=sys.stderr)
            continue
        try:
            entries[row_id] = derive(menu, row_id)
        except LookupError as failure:
            failures.append(str(failure))

    text = with_block(rest, entries) if entries else rest
    try:
        after = parse(text)
    except ValueError as failure:
        die(f"the derived menu does not parse ({failure}); {USER_MENU} is untouched")
    if after != {**before, **entries}:
        die(f"the derived menu does not read back as written; {USER_MENU} is untouched")

    # With no file and nothing to put in one, a copy of the template is noise.
    if (entries or current is not None) and text != current:
        write(text, mode)
        print(f"Omarchy's menu: {', '.join(entries) or 'no'} rows derived")

    if failures:
        die(".\n  ".join(failures) + f".\n  Please open an issue at "
            f"{PROVIDER['repoUrl']} with your `omarchy version`.")


if __name__ == "__main__":
    main()

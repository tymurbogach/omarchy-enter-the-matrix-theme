# Contributing to omarchy-enter-the-matrix-theme

Write everything in English: code, docs, comments and commit messages. The
repo is public, and Omarchy works in English.

Run `./tools/check.sh` before you push. It runs every check that needs no
Omarchy session. The clean-room test at the end decides whether a change ships.

## Rules

Five rules decide every change. Each rule is here because a break of it cost
real time.

### 1. Omarchy is the source of truth, and it changes

Read Omarchy's own source. Do not guess. The source is readable:

```bash
cat $(which omarchy-theme-set)          # how a theme is staged
cat /usr/share/omarchy/shell/plugins/lock/LockView.qml
cat /usr/share/omarchy/default/plymouth/omarchy.script
omarchy commands --json                 # every command, machine-readable
```

Never edit a file under `/usr/share/omarchy/`. The package owns it, and
`omarchy update` overwrites it. Reading it is safe.

Pin the version that you tested against. `install.sh` carries `TESTED_ON`, and
the derivers abort when a patch no longer fits. Update those values after you
test a new version. Do not silence the aborts.

### 2. Verify the change as the user sees it

Check the result on screen, not only the code path. A menu row can launch the
right program and still show no icon and a raw id as its label. If you cannot
verify something, say so. Then verify what you can: syntax, generated output
and cross-references.

`tools/preview-plymouth.sh` runs the real boot splash in a window, and `grim`
photographs it. Only two things still need a reboot:

- whether `mkinitcpio` put the theme into the initramfs;
- whether the DRM renderer draws the splash panel the same way as the X11
  renderer.

### 3. Add, never overwrite. Derive, never freeze

The pack must not overwrite Omarchy's originals. Two pieces cannot work in
another way, and both derive from this machine's source:

- The lock, because a `WlSessionLock` is exclusive by protocol.
  `lib/derive-lock.py` starts from the installed `LockView.qml`.
- The boot splash, because a Plymouth theme takes colours and one still image.
  `lib/derive-plymouth.py` starts from the installed `omarchy.script`.

Each deriver applies a minimal patch and asserts that its anchor occurs
exactly once. If the anchor does not fit, the deriver aborts with a clear
message. The `post-update` hook derives both pieces again after every
`omarchy update`.

If a feature seems to need a frozen copy of Omarchy code, look for the
extension point that you have not found yet. For weeks, the desktop rain
seemed to need a clone of `omarchy.background`. It did not.

### 4. Never leave the machine unable to lock or boot

The two derived pieces are the two that can lock a user out.

- Lock: hand it back with `omarchy plugin remove <clone>`. That command
  enables `omarchy.lock` again. If you only disable the clone, no lock is
  enabled. Test with `omarchy-shell lock preview`, never with a real lock.
- Boot: on an encrypted disk, Plymouth also asks for the passphrase. The patch
  touches no password callback, and the theme installs beside Omarchy's theme.
  The two escape hatches are `omarchy plymouth reset`, and `plymouth.enable=0`
  on the kernel line in the boot loader.

### 5. Omarchy decides. Everything is a layer. Off must mean gone

- The pack has no switches. Each piece follows a choice that Omarchy already
  offers: Style › Background for the desktop, the idle service for the
  screensaver, the theme for the lock, Style › Unlock for the boot splash.
  Up to 1.2.x each piece also had a switch of its own. Two answers to one
  question could disagree, and the user had to learn both.
- Another theme stands everything down: nothing rains, and no plugin of the
  pack stays enabled. A return to the theme brings it all back. The boot
  splash is the one exception, because Plymouth belongs to the system and not
  to the theme.
- Off removes what the piece wrote, also outside `$HOME`. A user who never
  uninstalls must still end up with a clean machine.
- Nothing of Omarchy's stays disabled.

## Workflow

There are two clones, and each one has a different job:

| Where | Job |
|---|---|
| `~/Projects/omarchy-enter-the-matrix-theme` | The working copy. **Edit and commit here.** |
| `~/.config/omarchy/themes/enter-the-matrix` | The copy that `omarchy theme install` makes. Omarchy can replace it, and an edit here is then lost. |

```bash
cd ~/Projects/omarchy-enter-the-matrix-theme && git commit && git push
cd ~/.config/omarchy/themes/enter-the-matrix && git pull && ./install.sh
```

### Commit messages explain the why

`git diff` shows what changed. The message says why it changed, what you
tried, and which constraint applied. Some commits here are the only record of
a limitation, and without them somebody finds it again the hard way.

Do not add a credit line for an AI assistant, in commits or in PR
descriptions.

---

## Traps already paid for

Each trap cost real debugging time. The code does not show any of them.

### The shell and its plugins

Up to 1.2.x the pack had a bar widget. Its traps stay here, because they apply
to any bar widget.

**For a `bar-widget`, "enabled" means "present in `bar.layout`".**
`PluginRegistry.setEnabled` inserts the layout entry when you enable the
plugin. It removes the entry when you disable the plugin
(`PluginRegistry.qml:498-520`), and `isEnabled` answers from the entry.

So a plugin that is a widget and also something else cannot switch off without
the loss of its bar icon. That is why the rain and the old switchboard were two
plugins.

**A bar widget with no `implicitWidth` paints nothing, and nothing warns you.**
The bar sizes each slot from `activeItem.implicitWidth` (`Bar.qml:1565`). A
plain `Item` has no implicit width, so every bar widget sets
`implicitWidth: button.implicitWidth` on its root.

Without that line, the plugin loads, answers IPC and opens its panel, but it
occupies zero pixels. Every check that does not look at the screen passes. Only
a screenshot shows the fault.

**Hyprland 0.56 moved its dispatchers to a Lua API, and a stale selector fails
silently.**

- `hyprctl dispatch focuswindow class:Plymouthd` is a Lua syntax error.
- `hl.dsp.focus` wants a direction, not a window.
- `hl.dsp.window.fullscreen()` acts on the window that has the focus.

The last one did damage. A preview script assumed that the focus had moved,
and then used `wtype`. It typed a test passphrase and Return into the terminal
where the user worked.

**Never aim `wtype` at a window that you have not confirmed is focused.**
`wtype` has no target: it types into the window that has the keyboard.
`tools/preview-plymouth.sh` sends keys down plymouthd's own pty instead, and
nothing else can receive them.

**A summoned panel takes the keyboard only on the first summon after the shell
starts.** `omarchy-shell shell summon <id>` maps the panel. A later summon in
the same shell process leaves the keys with the window that had the focus.
Escape does not close the panel, and a second summon does not close it either.

Only a shell restart closes it. Omarchy's own `omarchy.bluetooth` behaves the
same way, so the cause is the environment and not the pack. When you test,
drive a panel's cursor with `wtype` right after `omarchy-restart-shell`.
Otherwise the panel ignores you, and that looks like a bug of ours.

**A hot reload does not resize the slot of a bar widget.** After the two
`implicit*` lines went into a live widget, the slot stayed 0 px wide through
several reloads. It took its size only after `omarchy-restart-shell`.

**A hot reload of plugin QML can leave two instances alive.** The old instance
keeps answering IPC while the new one paints. The symptom: IPC reports `false`
for a property that you just set to `true`, and the journal shows errors on a
line that is no longer in the file.

The fix is `omarchy restart shell`. `rescanPlugins` is not always enough.

**A plugin rescan that still runs when the shell restarts can crash
quickshell (SEGFAULT).** The scan finishes during the teardown and builds the
plugin services. Their `IpcHandler` then asks the engine generation for an IPC
registry that the teardown has already freed.

The crash is a `__dynamic_cast` on a dead `EngineGenerationExt`
(`ipchandler.cpp:318`). It comes from `Process::onFinished` (the scanner
exits), through the `createObject` call at `shell.qml:300`.

This is
[quickshell#972](https://github.com/quickshell-mirror/quickshell/issues/972),
and it is still open. **We cannot fix it from here.** It occurs in 0.3.0 and in
0.3.1, so do not look for a package update that "broke" it.

Our workload made it frequent. Up to 1.2.x `suspend` disabled two plugins,
removed the lock clone, pruned its backup and restarted the shell, all in one
second. There were
fifteen core dumps in three days, and each one came from a `theme set` away
from the pack.

`settle_plugin_scan` now waits until `listPlugins` gives the same answer three
times before any lock restart. That makes the race window smaller, but it does
not close it, and nothing here can close it.

The shell was going to restart anyway, so the visible symptom was only a dirty
exit and a crash notification. Do not conclude that the crash is harmless. A
segfault during teardown can do different damage on a different day.

The cheap way to keep the window shut: **never write into a live plugin
folder.** Omarchy watches `~/.config/omarchy/plugins` with `inotifywait -m -r`
(`PluginRegistry.qml:636`). It ignores entries whose names start with a dot
(`localPluginIdForPath`, `:707`).

So stage the plugin in `.<id>.staging` and rename it into place: Omarchy sees
nothing until the folder is complete. `rm -rf` on the live folder causes the
same burst in reverse. Rename the folder to `.<id>.retired` first, and then
delete that.

**Each shell restart is a flicker, so a command restarts once at most.** A
restart blanks the bar and the background for a moment. Up to 1.2.x each step
that needed a restart did its own. The journal of one reinstall showed two
reloads each of the rain plugin, the widget and the lock clone, and then one
or two restarts.

Now each command compares `pack_fingerprint` (`lib/pack.sh`) before and after
its work: the enabled lock plugins, and the bytes of the rain plugin and of the
lock clone. It restarts once at the end, and only if that changed.
`install.sh` and `derive-lock.py` leave a live folder alone when its files are
the same.

Measured on this machine: an update from 1.2.1 restarts once, a reinstall of
the same version restarts nothing, and a theme set away or back restarts once.
To count them yourself, run
`journalctl --user --since <time> | grep -cE 'Launching config|Local plugin changed'`.

**`omarchy refresh shell` rewrites all of `shell.json`.** That file records the
enabled plugins and the bar layout, and no hook runs after a refresh. To
recover, run `omarchy-matrix doctor` or apply the theme again.

This was verified on this machine. After a refresh, `doctor` restored the rain
plugin, the lock clone (with `omarchy.lock` disabled again) and, in 1.2.x, the
widget entry in the bar. It restores the pack and nothing else: the user's own plugins
and bar order come back from Omarchy's own `shell.json.bak.<timestamp>`.

**A tick must ask the machinery, not the settings.** The same refresh showed
this. With `shell.json` wiped, `status` printed `✓ lock` and `✓ wallpaper`,
but the rain plugin was disabled and Omarchy's own lock was in charge.

The settings were true and the theme was ours, but nothing happened. `status`
now asks whether the plugin is enabled, whether the lock clone is the enabled
lock, and whether Omarchy's own screensaver is on.

**A repair command that does not check the theme creates again the state that
it exists to fix.** The pack was found raining under everforest. `theme set`
had stood it down correctly at 14:52.

That evening, a manual `git pull && ./install.sh` stood it up again. The cause:
`install.sh` ends in `doctor`, and `doctor` applied every setting without a
check of the current theme. The hook never failed: the recovery path undid its
work.

Now, under another theme:

- `doctor` only syncs files, and stands down any piece that is still up.
- `status` says so when pieces are up while the pack is stood down.

The boot splash is the exception, because it belongs to the system.

### Updates, themes and menus

**`omarchy theme update` fires no hooks.** It runs `git pull` in each theme and
does nothing more (`cat $(which omarchy-theme-update)`). `omarchy update` never
calls it.

So after a pull, no hook can refresh the files that the pack installs outside
the theme directory. For that reason, `doctor` compares the files itself and
calls `install.sh --sync`.

**"Different" is not "outdated".** The first comparison used `cmp`. A working
copy installed over an older theme directory looks as different as a pulled
theme over an older install. So `cmp` copied the old files over the new ones.

The comparison now uses `-nt`. A `git pull` gives each file that it touches a
new mtime, and that is the event that this comparison is for.

**There are two background directories, and only one belongs to the theme.**

- `~/.config/omarchy/themes/<theme>/backgrounds/` is the carousel that the
  theme ships.
- `~/.config/omarchy/backgrounds/<theme>/` is where the user adds extras. It
  does not exist until the user adds one, or until the pack links the rain
  there.

`omarchy-theme-set:78` searches both. If you check "did my new backgrounds
arrive?" against the second path, you get a failure that is not real.

**A theme set starts on the first background, and the user's folder sorts
first.** `omarchy-theme-set` sorts the full paths of both folders. `~/.config/`
sorts before `~/.local/state/`, where Omarchy stages the theme's backgrounds.
So the user's folder comes first, in the C locale and in en_US.UTF-8.

That is the extension point for the rain. Up to 1.2.x, `doctor` forced the rain
after every theme set of this theme, and so fought Omarchy's rotation. Now the
rain's still lives outside `backgrounds/`, and the pack links it into the
user's folder. A theme set then starts on the rain by itself, and Style ›
Background lists it like any other background. The theme alone never offers a
still of rain that never moves.

`uninstall` removes the link and nothing else. Up to 1.2.x it deleted the whole
folder, together with the user's own backgrounds in it.

**A theme installed from git may not ship a `.lua` file.** It also may not ship
`alacritty.toml`, `foot.ini`, `ghostty.conf`, `kitty.conf` or `vscode.json`
(`omarchy-theme-set:142`). Lua runs code inside the compositor, so this theme
sets the border colours but not the thickness or the rounding.

**To override a menu row, repeat `icon` and `label`.** `normalizeItem`
(`MenuModel.js:13`) fills in every key before `mergeMenuSources` merges, with
`icon: value.icon || ""` and `label: value.label || id`. A row that carries
only `action` replaces the good icon and label with blanks. The comment in the
extensions file says otherwise, and it is wrong.

**No hook runs after Style › Unlock, so the pack replaces the row.** The Unlock
row runs `omarchy-plymouth-set-by-theme`, which installs colours and one still
image. No Plymouth command of Omarchy's calls `omarchy-hook`.

`lib/derive-menu.py` builds a replacement from Omarchy's own row. The Matrix
card runs `omarchy-matrix boot on`. Every other choice runs Omarchy's command
and then `boot off`, in the same terminal, so `sudo` asks once.

Three anchors in Omarchy's action must each occur exactly once. If one does
not, the deriver takes its block out, Omarchy's own row comes back, and the
`post-update` hook sends a notification.

Omarchy loads exactly one extension file, so the replacement is a marked block
in the user's file. Three rules keep that file readable:

- `stripJsonc` (`MenuModel.js:1`) removes only whole-line `//` comments, so the
  block uses whole-line comments only.
- The block goes right after the opening brace, and its row ends with a comma.
  Omarchy allows a trailing comma, so no line of the user's changes.
- If the user has a row of their own with the same id, the pack leaves it
  alone.

**Omarchy runs no hook when a theme is removed.** `omarchy-theme-remove` deletes
the theme's folder and nothing else. The pack stayed installed, with the lock
clone, the hooks and the boot splash of a theme that was gone.

So the same block replaces Remove › Theme too. Omarchy's own command runs
first, unchanged, and then `omarchy-matrix hook theme-remove`. If this theme's
folder is gone, that stands the pack down and opens Omarchy's floating
terminal with `omarchy-matrix uninstall`. The terminal is there for the
password that the boot splash needs.

`omarchy theme remove` from a terminal passes no menu. The theme-set hook
catches it at the next theme change and does the same.

**`grep -r` skips the commands in `/usr/share/omarchy/bin`.** They are
symlinks, and `-r` does not follow a symlink that it finds inside a directory.
A search for `omarchy-hook` with `-r` found nothing. Use `grep -R`.

**In jq, `(.[$k] // true)` returns `true` when the value is `false`.** Use
`if has($k) then .[$k] else true end` instead.

**An older install migrates on its next `doctor`, theme set or uninstall.**
Up to 1.2.x the pack kept a switch per piece in
`~/.config/omarchy/enter-the-matrix.json`. A bar widget came from the repo
`omarchy-matrix-widget`, pinned to one commit. `pack_migrate` (`lib/pack.sh`)
takes both back once:

- The settings file goes. The theme to return to on uninstall moves to
  `~/.local/share/omarchy-matrix/previous-theme`. The screensaver flag that
  1.2.0 set goes back first, because only the old file can tell whose flag it
  is.
- The widget plugin goes with `omarchy plugin remove`, and with it its entry
  on the bar. Its backups, its repo cache and the update answer that only its
  panel read go too. A checkout that somebody added with `omarchy plugin add`
  carries a `.git` and stays.

### The lock and the screensaver

**A swap of the lock plugin leaves both locks loaded, and you do not choose
which one wins.** While `omarchy.lock` and the clone are both alive, Quickshell
gives the `lock` IPC target to one of them. It refuses the other with
`Handler was registered but will not be used because another handler is
registered for target lock`, and the winner changed from run to run here.

When Omarchy's lock won, the screen locked to Omarchy's blurred wallpaper. At
the same time, `plugin list` said that the clone was enabled, `lock status`
answered, and the patched QML on disk was correct.

`rescanPlugins` does not unload the loser, but `omarchy-restart-shell` does.
`apply_lock` calls it whenever the set of enabled locks changes.

**`omarchy plugin remove` renames the folder. It does not delete it.** The
folder comes back as `.<id>.bak.<timestamp>`. If the folder contains a `.git`,
the command deletes it (`omarchy-plugin-remove:113`).

Our lock clone has no `.git` and is derived, so every `lock off` used to leave
a full copy behind. Nine copies had piled up here.

The pack knows its own clones by two marks. The manifest says that
`clonedFrom` is `omarchy.lock`. Also, `derivedBy` names the CLI, or the folder
holds `MatrixRain.qml`. A lock clone that somebody made for their own reasons
has the same name shape, and it must survive.

**A third-party service cannot see Stay Awake, the idle timings or the lock.**
A plain `service` plugin does not get the shell. It gets a scoped
`PluginShellApi` (`shell.qml:739-744`), and that API has no `shellConfig`.

Its `firstPartyServiceFor()` returns `null` unless the plugin is a bar or an
Indicators clone (`shell.qml:592-621`). The lock is never reachable, because
the shell keeps it in `AuthServiceStore` (`shell.qml:933-937`).

Up to 1.2.0, the screensaver had an idle monitor of its own, gated on those
lookups. Each lookup failed, and a failure meant "not allowed", so the monitor
never started. The pack had also set Omarchy's `screensaver-off` flag, so no
screensaver came up at all.

Every check that did not wait out the idle timer passed. `status` showed a
tick, and an IPC call drew the rain on demand.

**So the rain covers Omarchy's screensaver, and Omarchy decides when that
runs.** Omarchy's idle service opens its own screensaver: one fullscreen window
per monitor, with the app id `org.omarchy.screensaver`. The plugin draws the
rain on an overlay layer while such a window exists, and the layer takes no
keyboard and no pointer.

Stay Awake, the timings in `shell.json`, the idle inhibitors and the key that
ends the screensaver all stay Omarchy's. `omarchy-system-lock` closes the
screensaver, so the rain goes when the lock comes.

The `screensaver-off` flag is the user's switch again, and
`omarchy toggle screensaver` sets and clears it. The pack never touches it,
except once to hand back the flag that 1.2.0 set. `tools/check.sh` fails if
`Service.qml` starts to decide on its own again.

Two lessons of the old design still apply to any overlay that takes input:

- The Wayland idle protocol resets on any input, mouse included. A screensaver
  that closes when idle ends vanishes when the mouse moves.
- A fullscreen overlay maps under the cursor and gets a pointer event at once.
  Without a short grace period, it dismisses itself in its first frame.

**`omarchy toggle idle status` answers the opposite question.** It prints
`"enabled": true` when **Stay Awake** is on, which means that idle is off. The
tooltip `Allow Idle Lock & Screensaver` names the action that it offers, not
the state.

A script that read `enabled` as "idle is allowed" turned a user's Stay Awake
off when it restored the machine. Save `.enabled` as it is, and restore Stay
Awake only if it was `true`.

**`omarchy-launch-screensaver` does nothing if any command line holds its app
id.** It starts with `pgrep -f '[o]rg.omarchy.screensaver' && exit 0`. A test
command that names `org.omarchy.screensaver`, for example in a `jq` filter,
matches too. The launcher then exits 0, and no screensaver opens. `pkill -f`
with the same pattern kills that test shell.

Put such a test in a script file, and build the app id from two strings. The
command line of `bash test.sh` names neither.

**`qsb` is not on `PATH`: it is at `/usr/lib/qt6/bin/qsb`.** The shipped
`matrix.frag.qsb` was built with `--glsl 300es,330 --hlsl 50 --msl 12`. Other
targets silently produce a different set of shader variants.

### The boot splash

**Plymouth draws at the native resolution of the screen, not at the logical
one.** A point size chosen for 1080p is tiny on a 3072 px screen.
`derive-plymouth.py` used to calculate the size at derive time from `hyprctl`,
and it does not do that now.

At boot, the script measures its own text: it renders a probe, reads
`GetWidth()` back, and scales from there. That method is correct on every
screen, survives a dock, and needs no calibration constant.

In the X11 preview, `Window.GetWidth()` is half the width of the screen. So a
size fixed at derive time would also have made every preview wrong.

**An aspect ratio fixed at derive time can push the splash panel off the
bottom of a real screen.** BOX_ASPECT comes from this machine's font metrics,
at derive time. The vertical anchor of the panel (`entry.y`, where Omarchy
puts its dialog) is known only at boot.

That anchor can sit so low that there is not BOX_ASPECT's worth of room under
it. A photo of the real render at this screen's resolution, from
`tools/preview-plymouth.sh`, caught it: the box had no bottom border. The math
did not catch it.

There are two fixes:

- The panel sits a fixed fraction of the screen height above `entry.y`, not
  exactly on it.
- At boot, the script clamps the height against `Window.GetHeight()`, because
  the lift is still a guess about a screen that the deriver has never seen.

**In the initramfs, `Image.Text` ignores the font family. Only the size
survives.** The mkinitcpio hook copies exactly three font files, under fixed
names. `label-freetype` resolves a family with `/usr/bin/fc-match`, and the
initramfs does not contain `fc-match`.

So `"DejaVu Serif 30"` renders as a serif on your desktop and as
`/usr/share/fonts/Plymouth.ttf` at boot, and nothing warns you. Anything whose
exact shape matters must arrive as a PNG.

`tools/preview-plymouth.sh` reproduces all three restrictions. That is the
only reason why this was found before a release.

**But `Font=` in the `.plymouth` file does choose that TTF.** An older version
of the note above hid this. It said that a family "comes out as the theme's
mono font".

That was true only because `stage()` writes the same family into `Font=` and
`MonospaceFont=`, so the two files are identical. The hook resolves `Font=`
with `fc-match` and copies that one file in as `Plymouth.ttf`
(`/usr/lib/initcpio/install/plymouth`). `label-freetype` falls back to exactly
that file.

So the boot has one text face, and the theme chooses it. The theme cannot
choose a second face, or change the face per call.

**A font family named at derive time is a silent dependency.** `fc-match` does
not fail when it finds no match: it returns `monospace`. If you name a family
that the installing machine does not have, the splash gets the wrong face and
nothing says so.

For that reason, the face of the splash ships in `fonts/` as a file. The
fallback in `available_font()` can affect only the disk prompt, never a
picture.

**plymouthd crashes (SEGFAULT) when it can resolve no font at all.** Nothing
checks that `FT_New_Face` found a file. For that reason, `derive-plymouth.py`
asserts that the family resolves. The preview also fills
`/usr/share/fonts/Plymouth*.ttf`, and does not only hide `fc-match`.

**A number and a sprite object cannot share a name in a Plymouth script.** An
example: `global.mx_caps = -1` early in the file, and
`mx_caps.image = Image.Text(...)` later. The second assignment goes to a
number and does nothing, so the sprite draws nothing, with no error and no log
line.

This cost an hour. Add a suffix to the state (`mx_caps_state`), or rename the
object.

**`Image()` on a missing file still tests as true.** Plymouth does not abort
the script when you then call `Scale()` on it: the script continues. So a
guard must ask `Image("x.png").GetWidth() > 0`. Without that guard, a missing
asset gives a password prompt with no field to type into.

**plymouthd stops when nobody reads its pty.** It prints "redirecting debug
output to /dev/pts/N", also with `--debug-file`. If nothing reads the master
end, the daemon stops part way, with no error anywhere. That trace is also the
only place that reports a syntax error in a `.script` file.

**A block glyph for the passphrase looks like a progress bar, with any amount
of space between the blocks.** The mask was `▊` and not `█` for that reason:
seven eighths of a cell, so that the characters did not touch. It did not
work, because the progress readout is in the same row and was also made of
blocks.

A boot went `solid bar` (typing) -> `[░░░░] 0%` -> `[███░] 42%`. The eye read
all three as one meter that behaved oddly. The glyph separates the two, not
the space: dots for the passphrase, blocks for the track.

`░` beside `█` is a second version of the same mistake. One is a dither
pattern and the other is solid ink, so an empty bar and a half-full bar do not
look like the same object. The track is now one image, drawn twice at two
opacities.

**A missing glyph draws nothing. You get no `.notdef` and no box.** This
applies to all text that the splash still typesets: the boot lines, the
captions and the CAPS LOCK label. Freetype gives no hollow rectangle for a
glyph that the font lacks: it inks zero pixels and advances the cell.

For the passphrase mask, this risk is gone, because the mask is drawn now and
not typeset (see the next trap). Keep the guard for all text that is still
typeset. Ask the picture, not the font:
`magick ... -alpha extract -format "%[fx:mean]"`.

Make the guard fail below 1 % ink (nothing drawn), or above 60 % (a block
shape that looks like the progress track). The table that this note held
before was wrong for more than one glyph.

These values were measured in Terminus, the face that shipped before Courier
Prime: `-` 4.1 %, `·` 1.4 %, `•` 5.6 %, `▪` 0 % (missing in this font),
`*` 13.6 %, `●` 5.6 %, `■` 18.7 %, `▊` 73 %, `█` 94.6 %. The bounds above are
what matters, not the table; and the track is drawn now rather than typeset,
because Courier never had a full block at all.

**A font can render `●` as a blocky octagon, not a disc, and its ink share
does not show that.** TerminessNerdFont derives from Terminus, which is a
bitmap face at heart. Its `●` has only a little more ink than a plain `•` (see
the table above). It is visibly not round: it is a stepped, roughly square
blob, also at point size 120 with no antialiasing.

You see it only when you render the one glyph alone and look at it. Every
measurement of MASK in `derive-plymouth.py` is about coverage, and none is
about shape.

This cost real time. `kerning` and a faux-bold `-strokewidth` were tuned
against this glyph first, on the theory that bigger and bolder would
eventually look round. It does not: a dilated blocky octagon is a bigger
blocky octagon.

The passphrase mask now uses ImageMagick's own `circle` primitive, one per
cell, and it is not typeset at all. It is the one piece of text that stopped
being text. No glyph in the shipped font could give the requested shape.

The same trap affects the typed lines, and the guard of the mask does not
cover them. A whole line has plenty of ink with one character missing from the
middle. So the line is spelt wrong and passes every check.

An accent is the realistic way to hit this. A face that has `e` tells you
nothing about an accented `e`, and the reboot lines start with "Déjà vu".

So `splash_assets()` renders every character in use as one strip, and
measures the ink per cell. `-crop {cell}x{h} +repage -format "%[fx:mean] "`
gives all the cells in one magick call. The monospace assertion above makes
that safe.

That guard also rejected a candidate face during the font choice. The dashes
of Cascadia Code touch each other, so a row of them draws a continuous rule
and not a row of characters. Cascadia Code is also not monospace, and the
cell-drift check catches that.

A font sample shows neither fault. A picture of the real line shows both.

**`-draw` takes its colour from `-fill`, so `-fill none` draws nothing. It
does not erase.** The top rule of the splash panel has a gap where its caption
sits. The first version cut that gap with `-compose clear` over a
`-draw rectangle`. It did nothing and gave no error: the rule went straight
through the letters.

`-compose` controls `-draw image`, not `-draw rectangle`. The frame is now five
`line` strokes, and the gap is simply not drawn.

A gap painted in the background colour would be its own bug. The background
belongs to Omarchy's theme, and our guess would show as a patch on any other
theme.

**A preview scenario cannot reach the bullets or the progress bar.** Three
things block it, and this project hit all three:

- `send` goes down plymouthd's pty, but the daemon counts passphrase
  keystrokes from the renderer. So no key ever becomes a bullet.
- `display_normal_callback` starts Omarchy's fake progress when
  `password_shown` is set. That progress repaints over the dialog at 50 fps.
- In `--mode=boot`, plymouthd feeds real boot progress into
  `Plymouth.SetBootProgressFunction`, also when nothing boots. That progress
  overwrites any percent that you set.

What works is a doctored copy of the staged theme.
`preview-plymouth.sh --stage DIR` takes any directory. Append a probe that
calls `mx_password_callback` and `mx_progress` directly from
`refresh_callback`, again on every frame.

The probe also registers a no-op as the boot progress function, so real boot
progress does not overwrite the percent. The probe only calls the drawing code,
so the pictures still show the real thing.

**A probe must play the boot's own sequence, not jump to the state that you
want.** The first showcase probe called `mx_bar_show(1)` to put the progress
track on screen. The track came up, but its box did not: when plymouthd showed
the splash, `mx_normal_callback` hid the box, and nothing showed it again.

The picture showed a splash that no boot ever shows. It passed as real until
somebody remembered the ACCESS GRANTED box from a real boot.

`tools/capture-showcase.sh` now plays the real order once the lines are typed:
the dots, then `mx_normal_callback` (ACCESS GRANTED for `GRANTED_HOLD`
frames), then the track in its own box. It takes a burst, and you pick the
frames afterwards.

**The preview probe skips the asset guard, so it cannot test the fallback.**
The doctored stage calls `mx_password_callback` directly from
`refresh_callback`, and that is its purpose. But the `if (... GetWidth() > 0)`
that decides whether to register that callback never runs.

If you delete an asset and preview with the probe, you get a half-drawn dialog
of ours. That looks exactly like a broken fallback, but the fallback is not
broken.

To test the fallback, use `plymouth ask-for-password` in the scenario, with no
probe. Omarchy's own dialog then comes up whole. Both cases were photographed.

**Plymouth has only two exits, and `halt` is not one of them.**
`plymouth-halt.service`, `plymouth-poweroff.service` and
`plymouth-kexec.service` all run `plymouthd --mode=shutdown`. Only
`plymouth-reboot.service` is different
(`grep ExecStart /usr/lib/systemd/system/plymouth-*.service`).

`script.so` knows `shutdown`, `reboot`, `updates`, `system-upgrade` and
`firmware-upgrade`, and it contains no `halt` string to match. So a `.script`
cannot tell a halt from a power off. A `halt` key in `provider.json` would be
configuration that never runs.

**plymouthd also feeds boot progress on the way out, and a sprite that turns
itself on draws on an empty screen.** plymouthd calls
`Plymouth.SetBootProgressFunction` in `--mode=shutdown` and `--mode=reboot`,
as in `--mode=boot`. So `update_progress_bar` -> `mx_progress` runs at
shutdown.

No exit asks for a passphrase, so the script never reaches `mx_bar_show(1)`
and never shows the panel. But `mx_progress` owned the opacity of the fill,
because only it knows how wide the crop must be. It lit the fill anyway.

The photographed result: one cyan cell in the middle of a black screen, with
no panel and no track behind it. The fault was there before the exit lines
existed. Nobody saw it, because every earlier shot was cropped to the typed
line at the top.

`global.mx_bar_on` now gates `mx_progress`. It clears the fill and does not
only skip it, so a percent that arrives after the readout hides cannot leave
the last crop lit.

**Judge an exit from the whole frame.** The interesting failure is in the
middle of the screen, not where the words are.

**`Plymouth.GetMode()` is already correct at the top of the script, not only
inside a callback.** `omarchy.script` asks for it in `display_normal_callback`,
so it looks like only a callback can know it. That is not true: plymouthd sets
the mode before it loads the theme.

So the script can select the whole storyboard at load time, and it does not
need to swap it during the run. Probes at the first and the last line of the
file both read `shutdown` under `--mode=shutdown`.

`tools/preview-plymouth.sh --mode NAME` exists for this. It photographs the
exit splashes without a shutdown.

**`omarchy plymouth current` sees only Omarchy's own splash.** It identifies a
theme by a comparison of `logo.png` inside Omarchy's own folder, and our
animated theme installs separately. Use `plymouth-set-default-theme` with no
arguments.

So Style › Unlock does not mark the Matrix card while the animation boots. The
pack could: run Omarchy's `plymouth set by theme` first, then the animation.
That was tried. It cost a second rebuild of the initramfs and a second screen
of build log, for a highlight in a menu.

**Omarchy's Plymouth publisher refuses a theme folder that root does not own.**
`omarchy-plymouth-set` checks every folder on the path: owner root, and not
writable by group or others. On this machine, `/usr/share/plymouth/themes/omarchy`
was owned by the user with mode 700, from the day Omarchy was installed.

Every Style › Unlock choice then failed, with the pack and without it. The
floating terminal still printed "Done!", because it prints that whatever the
command returned. The pack's step after it never ran, so nothing else said so.

The repair is `sudo chown root:root` and `sudo chmod 755` on that folder. To
see the refusal, read the terminal above "Done!", or run
`omarchy plymouth set by theme <theme>` from a terminal of your own.

## Before you ship: the clean-room test

Run the cheap checks first:

```bash
bash -n install.sh uninstall.sh bin/omarchy-matrix lib/pack.sh tools/*.sh
python3 -m py_compile lib/*.py tools/*.py
./tools/check.sh              # cheap checks and coherence checks
omarchy-plugin-validate .     # must pass, or nobody can install it
```

Then run the test that decides whether the pack can be published: **install
the pack as a stranger does, on a machine that has never had it.** A read of
the diff is not this test. `./install.sh` from the working copy is not this
test either. That path runs with `~/.local/bin` already warm, the hooks already
in place, and a share dir that makes `install.sh` skip its question.

Run the six phases in order. Verify each phase as the user sees it: the result
on screen, not the output of the commands. A failure in any phase stops the
release.

1. **Strip the machine.** Do not remove the user's own hooks: `theme-set.d`
   holds more than ours. Run `omarchy-matrix uninstall`, and then look for
   residue by hand:
   - plugin backups that match `~/.config/omarchy/plugins/.*.bak.*`;
   - the `omarchy-matrix` symlink in `~/.local/bin`, and stale helpers there
     (`derive-lock.py`, `derive-plymouth.py`, `provider.py`,
     `omarchy-matrix-uninstall`);
   - `~/.local/share/omarchy-matrix/`;
   - `/usr/share/plymouth/themes/omarchy-matrix/`;
   - `/etc/initcpio/hooks/omarchy-matrix-backlight`;
   - `/etc/initcpio/install/omarchy-matrix-backlight`;
   - `/etc/mkinitcpio.conf.d/99-omarchy-matrix-backlight.conf`;
   - the link `~/.config/omarchy/backgrounds/enter-the-matrix/0-live-rain.png`;
   - from 1.2.x: the widget entry in the bar layout of `shell.json`, and
     `~/.config/omarchy/enter-the-matrix.json`;
   - the theme directory;
   - the flag `~/.local/state/omarchy/toggles/screensaver-off`, unless you set
     it yourself. The pack set it up to 1.2.0;
   - the `enter-the-matrix` block in `~/.config/omarchy/extensions/omarchy-menu.jsonc`;
   - Omarchy's own splash set to this theme: `omarchy plymouth current` must
     not print `enter-the-matrix`.

   The repo had the name `omarchy-matrix` until 2026-08-31. A machine with an
   older install also has `~/.config/omarchy/matrix.json`,
   `~/.config/omarchy/themes/matrix/` and `hooks/*.d/matrix`. Prove that all of
   it is gone before you continue: `omarchy-matrix` must give
   *command not found*.
2. **Install from the published URL**, never from the working copy. Follow the
   README literally, and do nothing that it does not say. The stranger does
   not know what the README leaves out.

   Answer the question with Enter, which is the red pill. Count the shell
   restarts in the journal: exactly one. Once per release, run the line with
   the blue pill first: nothing on the machine may change, except the theme.
3. **Verify on screen that the four pieces are on.** A configured piece is not
   enough.
   - Desktop: the background is the rain right after the install, and
     `hyprctl layers -j` lists `matrix-rain-wallpaper`.
   - Lock: take a **screenshot**, not a status query. Open
     `omarchy-shell lock preview` and photograph it with `grim`.
   - Screensaver: run `omarchy-launch-screensaver force` and photograph it. The
     rain must cover Omarchy's screensaver. Once per release, also wait out
     `idle.screensaver` without input, with Stay Awake off.
   - Boot splash: use `tools/preview-plymouth.sh`. Photograph the typed line,
     the passphrase dialog with some dots in it, and the progress track at
     0 %, part way and full. No scenario alone reaches the dots or the track:
     see the trap about the doctored stage. The two exit splashes are
     `--mode shutdown` and `--mode reboot`, and they need no reboot either.
   - Style › Unlock: pick the Matrix card. Omarchy's terminal must ask for the
     password once, rebuild the initramfs once, and look like any other card.
     Then `plymouth-set-default-theme` prints `omarchy-matrix`. Pick another
     card: it then prints `omarchy`, `omarchy plymouth current` names that
     card, and `/usr/share/plymouth/themes/omarchy-matrix/` is gone.

   Every non-visual check once passed while the machine locked to Omarchy's
   blurred wallpaper. Only the picture showed the fault.
4. **Change each of Omarchy's choices, one at a time.** Each time, check that
   the other pieces did not move.
   - Style › Background: pick a photograph. The desktop rain goes, and the
     lock and the screensaver still rain. Then pick the rain again.
   - `omarchy toggle screensaver`: no screensaver opens, so no rain either,
     and `status` says why. Toggle it back.
   - Style › Unlock: see phase 3.
5. **Switch to another theme and back.**
   - Away: nothing rains, nothing has a tick, and Omarchy's own lock and
     screensaver answer again. Nothing of Omarchy's stays disabled, and no
     `.bak` folder of ours remains.
   - Back: the background is the rain again with no command of ours, and the
     lock rains. Each way restarts the shell once.
6. **Uninstall, and compare the machine with phase 1.** Anything that is still
   there is a bug, not a detail. Once per release, uninstall through Style ›
   Remove › Theme instead of the command.

### Run the test without a keyboard or a password

The phases need no keyboard. These commands drive each piece, and `grim`
photographs the result:

| Piece | Show it | Put it away |
|---|---|---|
| Wallpaper | `hyprctl dispatch 'hl.dsp.focus({ workspace = "5" })'`, on an empty workspace | the same call with your own workspace |
| Screensaver | `omarchy-launch-screensaver force` | `pkill -f '[o]rg.omarchy.screensaver'`, as `omarchy-system-lock` does |
| Lock | `omarchy-shell lock preview` | `omarchy-shell lock hidePreview` |

`hyprctl layers -j` lists `matrix-rain-wallpaper` while the desktop rain is
mapped, and `matrix-rain-screensaver` while the rain covers the screensaver.
`omarchy-shell matrix status` answers from inside the plugin. So it shows which
background the plugin sees, and whether it sees Omarchy's screensaver.

Run the screensaver row from a script file, not from a one-line command: see
the trap about `omarchy-launch-screensaver` and `pgrep -f`.

`grim` needs a lit, unlocked screen. If the lid is closed or DPMS is off,
`grim` waits and never returns. If the session is locked, the lock covers the
pieces, and no screenshot can show them.

Without a terminal, `sudo` cannot ask for a password. The boot-splash steps
then fail cleanly: uninstall prints "skipped", and the installed splash stays.
So a run without a terminal cannot strip or reinstall the boot splash. Check
the splash with `tools/preview-plymouth.sh`, which needs no sudo. Run the boot
steps from a terminal before a release.

Right after a shell restart, `omarchy plugin remove` can print "omarchy-shell
is not responding". The removal still completes.

Put everything that this test finds into the repo, as a fix or as a written
limitation. A rediscovery on somebody else's machine costs far more.

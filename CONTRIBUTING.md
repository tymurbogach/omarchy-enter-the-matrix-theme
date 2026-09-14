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

### 5. Everything is a layer. Off must mean gone

- Each piece (`wallpaper`, `screensaver`, `lock`, `boot`) switches on and off
  alone. A switch has no effect on the other three pieces.
- Another theme stands everything down: nothing rains, nothing has a tick, and
  no plugin of the pack stays enabled. `enter-the-matrix.json` stays, so a
  return to the theme restores the same state. `boot` is the one exception,
  because Plymouth belongs to the system and not to the theme.
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

**For a `bar-widget`, "enabled" means "present in `bar.layout`".**
`PluginRegistry.setEnabled` inserts the layout entry when you enable the
plugin. It removes the entry when you disable the plugin
(`PluginRegistry.qml:498-520`), and `isEnabled` answers from the entry.

So a plugin that is a widget and also something else cannot switch off without
the loss of its bar icon. That is why the rain and the switchboard are two
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
drive the widget's cursor with `wtype` right after `omarchy-restart-shell`.
Otherwise the panel ignores you, and that looks like a bug of ours.

**A hot reload does not resize the slot of a bar widget.** After the two
`implicit*` lines went into a live widget, the slot stayed 0 px wide through
several reloads. It took its size only after `omarchy-restart-shell`. For this
reason, `install.sh` ends with one shell restart.

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

Our workload made it frequent. `suspend` disables two plugins, removes the lock
clone, prunes its backup and restarts the shell, all in one second. There were
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

**`omarchy refresh shell` rewrites all of `shell.json`.** That file records the
enabled plugins and the bar layout, and no hook runs after a refresh. To
recover, run `omarchy-matrix doctor` or apply the theme again.

This was verified on this machine. After a refresh, `doctor` restored the rain
plugin, the lock clone (with `omarchy.lock` disabled again) and the widget
entry in the bar. It restores the pack and nothing else: the user's own plugins
and bar order come back from Omarchy's own `shell.json.bak.<timestamp>`.

**A tick must ask the machinery, not the settings.** The same refresh showed
this. With `shell.json` wiped, `status` printed `✓ lock` and `✓ wallpaper`,
but the rain plugin was disabled and Omarchy's own lock was in charge.

The settings were true and the theme was ours, but nothing happened.
`is_active` now asks whether the plugin is enabled, whether the lock clone is
the enabled lock, and whether the screensaver flag is set.

The widget's panel follows the same rule: its switch shows what happens now. If
a piece is on in the settings but not in effect, the line under the switch
gives the reason, in the words that `status` uses.

**A repair command that does not check the theme creates again the state that
it exists to fix.** The pack was found raining under everforest. `theme set`
had stood it down correctly at 14:52.

That evening, a manual `git pull && ./install.sh` stood it up again. The cause:
`install.sh` ends in `doctor`, and `doctor` applied every setting without a
check of the current theme. The hook never failed: the recovery path undid its
work.

Now, under another theme:

- `doctor` only syncs files, and stands down any piece that is still up.
- A piece command writes the setting and leaves the apply to the next
  `theme set`.
- `status` says so when pieces are up while the pack is stood down.

`boot` is the exception, because it belongs to the system.

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
  does not exist until the user adds one.

`omarchy-theme-set:78` searches both. So the second directory looks like the
real one when you search, but usually it does not exist. If you check "did my
new backgrounds arrive?" against the second path, you get a failure that is
not real.

**A theme installed from git may not ship a `.lua` file.** It also may not ship
`alacritty.toml`, `foot.ini`, `ghostty.conf`, `kitty.conf` or `vscode.json`
(`omarchy-theme-set:142`). Lua runs code inside the compositor, so this theme
sets the border colours but not the thickness or the rounding.

**To override a menu row, repeat `icon` and `label`.** `normalizeItem`
(`MenuModel.js:13`) fills in every key before `mergeMenuSources` merges, with
`icon: value.icon || ""` and `label: value.label || id`. A row that carries
only `action` replaces the good icon and label with blanks. The comment in the
extensions file says otherwise, and it is wrong.

**In jq, `(.[$k] // true)` returns `true` when the value is `false`.** Use
`if has($k) then .[$k] else true end` instead.

**The widget comes from its own repo. It is not in a `widget/` folder here.**
It moved to `omarchy-matrix-widget`, so that the widget could be a plugin with
one manifest at its root. A merge into the manifest of the rain plugin would
break the independent on/off switch (see the `PluginRegistry.setEnabled` trap).
The marketplace lists only this repo, and the pack pins the widget to one
commit.

`install.sh` fetches the commit that `widget.ref` in `provider.json` names, a
full 40-character SHA. It caches the commit in
`~/.local/share/omarchy-matrix/widget-src`. If the cache is already at that
commit, `install.sh` does not use the network.

If the cache cannot reach the commit, `install.sh` keeps the widget that is
already staged. So `omarchy-matrix doctor`, which runs `install.sh --sync`,
still works offline.

A git submodule was rejected. The clean-room test clones with a plain
`git clone`, without `--recurse-submodules`, and a submodule would silently
leave that folder empty. For local work against an uncommitted checkout of the
widget repo, set `MATRIX_WIDGET_SRC=<path>`.

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

**The Wayland idle protocol resets on any input, mouse included.** The
screensaver first closed when idle ended, so a mouse movement made it vanish.
Omarchy's own screensaver does not do that, because its loop watches only the
keyboard.

**`omarchy toggle idle status` answers the opposite question.** It prints
`"enabled": true` when **Stay Awake** is on, which means that idle is off. The
tooltip `Allow Idle Lock & Screensaver` names the action that it offers, not
the state.

A script that read `enabled` as "idle is allowed" turned a user's Stay Awake
off when it restored the machine. Save `.enabled` as it is, and restore Stay
Awake only if it was `true`.

**A fullscreen overlay maps under the cursor** and gets a pointer event at
once. Without a short grace period, it dismisses itself in its first frame.

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

These values were measured again in Terminus, the face that ships: `-` 4.1 %,
`·` 1.4 %, `•` 5.6 %, `▪` 0 % (missing in this font), `*` 13.6 %, `●` 5.6 %,
`■` 18.7 %, `▊` 73 %, `█` 94.6 %.

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

**`omarchy plymouth current` cannot see our boot theme.** It identifies a theme
by a comparison of `logo.png` inside Omarchy's own folder, and our theme
installs separately. Use `plymouth-set-default-theme` with no arguments.

## Before you ship: the clean-room test

Run the cheap checks first:

```bash
bash -n install.sh uninstall.sh bin/omarchy-matrix lib/pack.sh tools/*.sh
python3 -m py_compile lib/*.py tools/*.py
./tools/check.sh                                     # cheap checks and coherence checks
./tools/check.sh --widget ../omarchy-matrix-widget   # the same for the widget repo
omarchy-plugin-validate .                            # must pass, or nobody can install it
```

Then run the test that decides whether the pack can be published: **install
the pack as a stranger does, on a machine that has never had it.** A read of
the diff is not this test. `./install.sh` from the working copy is not this
test either. That path runs with `~/.local/bin` already warm, the hooks already
in place, and an `enter-the-matrix.json` full of old answers.

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
   - the widget entry in the bar layout of `shell.json`;
   - `~/.config/omarchy/enter-the-matrix.json`;
   - the theme directory;
   - the flag `~/.local/state/omarchy/toggles/screensaver-off`.

   The repo had the name `omarchy-matrix` until 2026-08-31. A machine with an
   older install also has `~/.config/omarchy/matrix.json`,
   `~/.config/omarchy/themes/matrix/` and `hooks/*.d/matrix`. Prove that all of
   it is gone before you continue: `omarchy-matrix` must give
   *command not found*.
2. **Install from the published URL**, never from the working copy. Follow the
   README literally, and do nothing that it does not say. The stranger does
   not know what the README leaves out.
3. **Verify on screen that the four pieces are on.** A configured piece is not
   enough.
   - Lock: take a **screenshot**, not a status query. Open
     `omarchy-shell lock preview` and photograph it with `grim`.
   - Widget: take a screenshot of the bar **and** of the open panel. An icon
     that occupies zero pixels passes every other check.
   - Boot splash: use `tools/preview-plymouth.sh`. Photograph the typed line,
     the passphrase dialog with some dots in it, and the progress track at
     0 %, part way and full. No scenario alone reaches the dots or the track:
     see the trap about the doctored stage. The two exit splashes are
     `--mode shutdown` and `--mode reboot`, and they need no reboot either.

   Every non-visual check once passed while the machine locked to Omarchy's
   blurred wallpaper. Only the picture showed the fault.
4. **Switch each piece off and on again, one at a time.** Each time, check
   that the other pieces did not move. After `lock off`, `omarchy.lock` must
   not be in `disabledPlugins`, and no `.bak` folder must remain. Check
   `lock on` with a screenshot, not with a query.

   At least one switch must come from the widget itself, not only from the
   CLI. Before you use `wtype`, confirm that the panel has the keyboard.
   Then `wtype -k Down` and `wtype -k Return` drive its cursor without a
   mouse. Do this **immediately after `omarchy-restart-shell`**, or the panel
   does not have the keyboard (see the traps).
5. **Switch to another theme and back.**
   - Away: nothing rains, nothing has a tick, **no Matrix icon stays on the
     bar**, and Omarchy's own lock and screensaver answer again. Nothing of
     Omarchy's stays disabled.
   - Back: exactly the pieces that were on before are on again.
6. **Uninstall, and compare the machine with phase 1.** Anything that is still
   there is a bug, not a detail.

### Run the test without a keyboard or a password

The phases need no keyboard. These commands drive each piece, and `grim`
photographs the result:

| Piece | Show it | Put it away |
|---|---|---|
| Wallpaper | `hyprctl dispatch 'hl.dsp.focus({ workspace = "5" })'`, on an empty workspace | the same call with your own workspace |
| Screensaver | `omarchy-shell matrix screensaver start` | `omarchy-shell matrix screensaver stop` |
| Lock | `omarchy-shell lock preview` | `omarchy-shell lock hidePreview` |
| Widget panel | `omarchy-shell shell summon io.github.tymurbogach.enter-the-matrix.widget` | a shell restart (a second summon does not close it) |

`hyprctl layers -j` lists `matrix-rain-wallpaper` while the desktop rain is
mapped. `omarchy-shell matrix status` answers from inside the plugin. So it
proves that the plugin reads the settings that the CLI writes.

`grim` needs a lit, unlocked screen. If the lid is closed or DPMS is off,
`grim` waits and never returns. If the session is locked, the lock covers the
pieces, and no screenshot can show them.

Without a terminal, `sudo` cannot ask for a password. The boot-splash steps
then fail cleanly: uninstall prints "skipped", and the installed splash stays.
So a run without a terminal cannot strip or reinstall the boot splash. Check
the splash with `tools/preview-plymouth.sh`, which needs no sudo. Run the boot
steps from a terminal before a release.

Do not drive the widget with `wtype` unless you can confirm that the panel has
the keyboard. If another window has the focus, the keys go there, and a
terminal runs them. When you cannot confirm the focus, toggle through the CLI.
Then test the widget's commands through the launcher, with the same argument
that the widget sends:

```bash
"$OMARCHY_PATH/bin/omarchy-launch-floating-terminal-with-presentation" \
  "'$HOME/.local/bin/omarchy-matrix' status"
```

Right after a shell restart, `omarchy plugin remove` can print "omarchy-shell
is not responding". The removal still completes.

Put everything that this test finds into the repo, as a fix or as a written
limitation. A rediscovery on somebody else's machine costs far more.

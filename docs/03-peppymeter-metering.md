# 3 — PeppyMeter fork: meters + spectrum in one process, switching on track change

Status: **COMPLETE**, verified working on the original system.

This assumes you already have a PeppyMeter fork that composes meters and
spectrum in a single process cloned to `/home/moode/peppy-fork/` — see
`CREDITS.md`. This doc and script fix the problems that showed up wiring
*that specific class of fork* into moOde; they are not a PeppyMeter installer.

## Why a fork at all

Stock moOde's meter screensaver options are meters-only **or**
spectrum-only, driven by a fixed rotation timer regardless of what's
playing. A fork that imports and drives both PeppyMeter and PeppySpectrum in
one process is the only way to get both at once — and, as it turns out, the
fork already supports track-change-triggered skin switching natively; it
just needs the right config key.

## The cwd trap — read this before debugging any silent exit

The fork `chdir`s into its spectrum subdirectory at startup. **Any relative
path resolved after that point resolves against the wrong directory.** This
one root cause produces multiple distinct-looking symptoms:

### Symptom A — silent exit, code 0, empty log

The spectrum config loader does `os.path.join(os.getcwd(), FILE_CONFIG)`,
finds nothing, and calls `os._exit(0)` — which **bypasses stdout flushing**.
With stdout redirected to a log file (block-buffered), the error message
that would explain this never appears. Exit code 0, empty log, no clue.

**Always run the process with `python3 -u`** (unbuffered) — that's the only
way any of these symptoms are diagnosable at all.

**Fix:** copy the spectrum config into the directory the process will actually
be sitting in when it looks for it:

```bash
sudo cp /etc/peppyspectrum/config.txt \
  /home/moode/peppy-fork/screensaver/spectrum/config.txt
```

### Symptom B — meters and spectrum render but float on black

The meter config's `base.folder` key is empty, so the path used to load
static assets stays relative and resolves against the post-chdir spectrum
directory instead of the meter directory. It works at *parse* time (loading
`meters.txt` succeeds) and fails later, at *draw* time — same string,
different working directory when it's actually used.

**Fix — config only, no code change** — set `base.folder` to an **absolute**
path in the meter config's `[current]` section:

```ini
base.folder = /home/moode/peppy-fork/screensaver/peppymeter
```

A symlink can paper over this too, but isn't needed once the path is
absolute — don't leave both in place.

### Symptom C (not currently triggered here, but same class)

A second config loader in the fork uses the identical
`os.path.join(os.getcwd(), FILE_CONFIG)` pattern for a different config file.
It wasn't observed causing a problem on the original system, but it has the
same latent bug — if you add anything that reads config after the chdir,
check this first.

## Ruled out while chasing the above (don't re-chase)

- Folder-name format / file-existence checks in the config parser — parse
  clean.
- A marker-file race on the PeppyMeter "running" lock file — timing showed
  the marker was written, then the process died a second later; not a race.
- An `exit()` call elsewhere in the fork, instrumented with a traceback dump
  — never reached.
- `meters.txt` configparser errors — parses clean.
- Nine unrelated keys someone had added to the meter config on the mistaken
  belief the spectrum parser read the meter's working directory — they were
  inert; removed and confirmed inert by test.
- **Meter/spectrum pairing is by NAME, not by index.** A section's
  `spectrum.name = Free` in the meter config matches a `[Free]` section in
  the spectrum config — not "meter section 3 pairs with spectrum section 3."
  This was assumed to be by-index at first and cost time.

## Track-change switching — no patch needed

The fork's own rotation logic already supports switching on track change
instead of a fixed timer:

```ini
[current]
meter = random
random.change.title = True
```

Setting `random.change.title = True` disables the interval timer and hooks
into the fork's metadata-change callback. `meter` must be `random` (or a
comma-separated list) for this to take effect at all — if it's a single
fixed meter name, "random mode" never activates and the title-change hook
can never fire.

`random.meter.interval = 20` (or whatever value is present) becomes inert
once `random.change.title = True` — you don't need to remove it, it's just
ignored.

**Verified on the original system:** 40 seconds idle produced exactly one
meter load and no switches (i.e. it does not free-run on a timer once this
mode is active); three deliberate track skips produced three switches, each
0.6–1.5 seconds after the metadata source reported the title change.

## The launcher — surviving moOde updates

`/var/www/util/start-peppy.sh` is moOde's own launcher hook, and it's
reverted by every in-place moOde update. Rather than re-patch it after every
update, put the fork's launcher somewhere that survives:

`/usr/local/bin/moode-peppy-fork` (mode 755):

```bash
#!/bin/bash
export DISPLAY=:0
export PYTHONPATH="/home/moode/peppy-fork:/home/moode/peppy-fork/volumio_peppymeter:/home/moode/peppy-fork/screensaver/peppymeter:/home/moode/peppy-fork/screensaver/spectrum:/home/moode/peppy-fork/pylib"
rm -f /tmp/peppyrunning
cd /home/moode/peppy-fork || exit 1
exec python3 -u volumio_peppymeter/volumio_peppymeter.py
```

(Adjust the `PYTHONPATH` entries to match your fork's actual directory
layout — the five entries above reflect the structure documented for the
fork this was built against; verify with `find /home/moode/peppy-fork -maxdepth 2 -type d`.)

Then edit moOde's own `/usr/local/bin/moode-peppy-start` (this file itself
survives updates) so that wherever it currently calls
`/var/www/util/start-peppy.sh "$TYPE"`, it calls
`/usr/local/bin/moode-peppy-fork` instead. Keep passing `"$TYPE"` even though
the fork ignores it — moOde's existing sudoers rules match on the exact
command line moOde calls, and changing the argument list can break those
rules.

## Diagnosing dismiss/running state

**Never judge whether the process is running from what's on screen.**
`setDisplay()` (moOde's own display-management function) only restarts the
X session when Chromium's process count is zero — with Chromium alive, the
meter process can be killed while the last rendered frame stays frozen on
screen, which looks identical to a failed dismissal.

```bash
ps -ef | grep -c '[v]olumio_peppymeter'
```

is the reliable check (substitute your fork's actual entry-point script
name if different). `pgrep -c -f` was found to be unreliable for this
specific process on the original system — it returned inconsistent counts
for a demonstrably live process. Don't rely on it here.

Recovery if the screen is stuck: `sudo systemctl restart localdisplay`.

## What the script does

`scripts/03-fix-peppymeter-fork.sh` (assumes the fork is already at
`/home/moode/peppy-fork/` — edit the `FORK_DIR` variable at the top if
yours lives elsewhere):

1. Backs up the meter config and the fork's main entry-point script.
2. Copies `/etc/peppyspectrum/config.txt` into the fork's spectrum directory
   if it isn't already there.
3. Sets `base.folder` in the meter config's `[current]` section to the
   fork's absolute meter-template path, guarding against duplicate keys
   (see "Config-editing gotcha" below).
4. Sets `random.change.title = True` if `meter = random` (or a
   comma-separated list) is already configured; otherwise prints a warning
   and leaves `meter` untouched, since changing which meters you see is a
   preference, not a bug fix.
5. Installs `/usr/local/bin/moode-peppy-fork` from the template above,
   auto-detecting the `PYTHONPATH` entries from the fork's actual directory
   layout rather than hardcoding them.
6. Prints the one-line edit needed in `/usr/local/bin/moode-peppy-start` and
   the `ps -ef | grep -c '[v]olumio_peppymeter'` check — it does **not**
   edit `moode-peppy-start` itself, since that file wasn't captured verbatim
   in the original write-up and a content-blind edit to a script that also
   handles sudoers-matched command lines is exactly the kind of edit this
   project's own scripts avoid making without seeing the real file (see the
   top-level README).

## Config-editing gotcha

```
sed -i '/^\[current\]/a key = value'
```

**duplicates an existing key** if it's already present, and Python's
`configparser` hard-fails on a duplicate key — the process won't start at
all. Always `grep -c '^key' config.txt` first and only append if it's
absent; otherwise replace the existing line in place. The script does this
check before every config write.

## Fragility across moOde updates

REVERTED: `/var/www/util/start-peppy.sh` (left untouched by design — see
above), anything under `/var/www`.
SURVIVES: `/usr/local/bin/moode-peppy-fork`, `/usr/local/bin/moode-peppy-start`
(once edited), everything under `/home/moode/peppy-fork`.

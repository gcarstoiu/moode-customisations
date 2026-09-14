# 2 — Transport control (play/pause/next) responsiveness

Status: two confirmed, measured fixes; the underlying perceived-lag report is
**not conclusively resolved** — read "What this doesn't fix" before you
expect a miracle.

## Symptom

Play/pause/next controls feel like they lag roughly a second between the
press and the icon updating. Present on both the touchscreen panel and a
plain remote browser tab — i.e. this is **stock moOde behaviour**, not
something a customisation broke.

## Method

Traced with `MutationObserver` + `PerformanceObserver` in the browser
console, and with SSH-side timing of each PHP endpoint on the request path:

```
command/index.php?cmd=play      the command itself
engine-mpd.php                  long-poll, returns on MPD idle event
command/cfg-table.php           issued right after the push
ICON CHANGES                    exactly when cfg-table.php completes
```

The icon change is **not** gated on `engine-mpd.php` finishing — it's gated
on `cfg-table.php`. That redirected the investigation from "why is the MPD
long-poll slow" to "why is the config-table read slow," which turned out to
be the more fruitful question.

## Fix 1 — a retry loop that always fails and always sleeps

**File:** `/var/www/inc/alsa.php` — reverted by moOde in-place updates.

`enhanceMetadata()` in `inc/mpd.php` calls `alsaOutputStr()` on every
`engine-mpd.php` state push. On the original system this took ~215ms while
paused and **~2285ms while playing** — nearly all of it inside
`alsaOutputStr()`.

Root cause: `getAlsaCardNumForDevice()` was failing to match the configured
device name against what `getAlsaDeviceNames()` returns, so the lookup fell
into a **3-attempt retry loop with a 250ms sleep after every attempt**
(including the last one, which is dead time — the loop has already failed by
then). Each attempt also shells out to `aplay -l` per card, which is not
free.

**This is a symptom of a device-name mismatch, which is itself worth fixing
on its own** (see `getAlsaDeviceNames()` returning the wrong friendly name,
noted under "Related, not fixed" below) — but the retry-loop cost is real
regardless of whether the underlying mismatch is ever resolved, because a
transient/real failure still shouldn't cost 3 lookups and 750ms of sleep on
a **hot path that runs on every single playback state change**.

The patch reduces the retry count to 1 and removes the sleep:

```diff
- $maxLoops = 3;
+ $maxLoops = 1;
```

and deletes the `usleep($sleepTime);` call that follows the loop's `else`
branch (verify with `grep -n usleep /var/www/inc/alsa.php` before and after
— there may be more than one `usleep` call in the file; only the one inside
this retry loop should be removed).

Verify the file still parses after patching:

```bash
sudo php -l /var/www/inc/alsa.php
```

**Measured result on the original system** (SSH synthetic test hitting
`engine-mpd.php` directly):

| | before | after |
|---|---|---|
| pause | 360, 367 ms | 282, 285 ms |
| play | 2356, 2393 ms | 663, 1169 ms |

## Fix 2 — a shell-out to read a static string

**File:** `/var/www/inc/common.php` — reverted by moOde in-place updates.

`command/cfg-table.php?cmd=get_cfg_system` — the call the icon-change is
gated on — measured ~210ms over loopback for a response that's a 2.1ms SQLite
read of 175 rows. The remaining ~200ms was `getMoodeRel('verbose')`, which
ran:

```php
$result = sysCmd("moodeutl --mooderel | tr -d '\n'");
```

— spawning a whole PHP process (`moodeutl`) to read a literal string out of
a static file (`/var/www/footer.min.php`, which carries a line like
`<li>Release: 10.3.2 2026-08-03</li>`). Timed independently at ~130ms for
`moodeutl --mooderel` alone, plus ~30ms shell/pipe overhead.

The patch adds a per-request static cache and reads the file directly instead
of shelling out, keeping both the verbose (`10.3.2 2026-08-03`) and compact
(`r1032`) return forms `getMoodeRel()` is contracted to produce — **the
compact form matters**: `getUserID()` derives the moOde system user from it
(`substr(getMoodeRel(), 1, 2)` on this system correctly resolved to `moode`).
Verify both forms still work after patching, not just the one you're
optimising for.

**Measured result:**

| | before | after |
|---|---|---|
| `cfg-table.php` loopback | ~210 ms | ~58 ms |
| `cfg-table.php` from LAN | 280–615 ms | ~80 ms (after a ~440ms cold call) |
| `getMoodeRel('verbose')` alone | 160 ms | 0.1 ms |

`getMoodeRel()` has other, colder call sites (`worker.php`, `sys-config.php`,
`common.php`) that weren't on this hot path — the patch benefits all of them
for free, but only `cfg-table.php`'s call was actually measured before/after.

## What the script does

`scripts/02-apply-ui-responsiveness-fixes.sh`:

1. Backs up `/var/www/inc/alsa.php` and `/var/www/inc/common.php` to
   `/home/moode/backups/ui-responsiveness-<timestamp>/`.
2. Applies Fix 1 by matching the exact `$maxLoops = 3;` line and the
   `usleep($sleepTime);` line that follows the retry loop's `else` block —
   the patch is a content match, not a line-number match, so it **fails
   loudly and changes nothing** if your file's wording differs from what's
   documented above (which is expected on a different moOde version).
3. Applies Fix 2 the same way: matches the `sysCmd("moodeutl --mooderel...`
   line inside `getMoodeRel()` and replaces both the verbose and compact
   branches with a direct file read plus a static cache.
4. Runs `php -l` on both files and refuses to leave a broken file in place —
   if the lint fails, it restores the backup automatically.
5. Prints the restore commands.

## What this doesn't fix

- **Whether the perceived lag actually improved.** Both fixes are measured,
  real wins on the server side. No perceptible before/after difference was
  confirmed on the panel itself after applying them — treat this as "removes
  ~1.5s of real server-side cost," not "fixes the complaint."
- `cfg-table.php` server-side time-to-first-byte still varied 80–579ms across
  a 28-request capture with idle PHP-FPM workers and no queueing observed —
  source not identified.
- ~11% of one CPU core in continuous iowait was observed with no block-device
  I/O and no CIFS traffic caught in flight — source not identified.
- The underlying `getAlsaDeviceNames()` friendly-name mismatch that causes
  the retry loop to fail in the first place was **not fixed** — the patch
  only makes the failure cheap. If you want to chase the mismatch itself,
  start at `alsa.php` around where it falls back to a `$_SESSION['i2sdevice']`
  lookup when the card ID isn't in `cfg_audiodev`.

## Ruled out (do not re-chase these)

CSS transitions/animations, the `.active` button class, PHP session lock
contention, mDNS resolution, TCP connection setup/keepalive, browser request
queueing, PHP-FPM worker exhaustion, CIFS activity, and local disk I/O were
all measured and found not to be the cause. See the method notes in the
original write-up if you want the specific numbers for each.

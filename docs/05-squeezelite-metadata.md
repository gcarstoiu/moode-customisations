# 5 — Squeezelite (LMS) track metadata on the renderer screen and meters

Status: **COMPLETE**, verified working on the original system. Requires
`docs/04-idle-screen-and-vu-button.md` to already be installed (this extends
`idle.js`), and `docs/03-peppymeter-metering.md` if you want metadata on the
VU meters too (optional — the WebUI overlay metadata works independently).

## The problem

moOde writes almost nothing to `currentsong.txt` (the file every renderer
overlay and the PeppyMeter fork reads metadata from) when Squeezelite is the
active renderer. Observed content while Squeezelite was playing:

```
file=Squeezelite Active
outrate=PCM 32/44.1 kHz, 2ch
```

No title, artist, album, cover URL, duration, or state — and that line is
written **once**, when the renderer becomes active, not on track change. A
90-second `inotifywait` watch spanning several track skips produced **zero**
write events to the file. Consequence: the WebUI shows only
"Squeezelite Active / Turn off / Audio info," and if you've installed the
PeppyMeter fork from doc 3, it shows no metadata and never switches skins
either — its track-change guard depends on the file changing, and the file
never changes for Squeezelite.

## Metadata source: query LMS directly

moOde doesn't proxy Squeezelite/LMS metadata anywhere, so this bypasses
moOde for metadata purposes and queries your **Lyrion Music Server (LMS)**
instance's own JSON-RPC API directly.

You need three values, specific to your own network — do not hardcode
someone else's:

```
LMS_HOST     the IP or hostname of your LMS server
LMS_PORT     LMS's web/JSON-RPC port (default 9000)
PLAYER_ID    your Squeezelite player's MAC address, as LMS sees it —
             find it in LMS's own web UI under Settings > Information,
             or: curl -s http://LMS_HOST:LMS_PORT/jsonrpc.js \
               -d '{"id":1,"method":"slim.request","params":["-",["players","0","99"]]}'
```

If your LMS server's address is DHCP-assigned, a lease change will silently
break this — either give it a static reservation or be ready to update the
config.

### API shape

```
POST http://LMS_HOST:LMS_PORT/jsonrpc.js
Content-Type: application/json

{"id":1,"method":"slim.request",
 "params":["PLAYER_ID",["status","-",1,"tags:aAlcdujtyor"]]}
```

Reference: [lyrion.org/reference/cli](https://lyrion.org/reference/cli/).
**The docs don't publish a complete tag-letter table** — the tag set below
was determined empirically against LMS on the original system; treat the
letters as a starting point to verify against your own LMS version, not a
guaranteed-complete spec.

### Tag string

```
tags:aAlcdujtyor
```

gives title, artist, albumartist, album, year, duration, coverid, bitrate,
tracknum, url, `remote`, `current_title`, and (for remote/streamed tracks)
`remoteMeta` — enough for local files and internet radio. **For content
streamed from Plex through a hub like the one in doc 6, you additionally
need uppercase `K`** (`tags:aAlcdujtyorK`) to get a populated `artwork_url` —
lowercase `k` does nothing, and this distinction only matters for remote
(hub-streamed) tracks, not local files. See doc 6 for why.

### CORS — why you need a server-side proxy, not a direct browser call

An `OPTIONS` preflight against LMS's `jsonrpc.js` returns `200 OK` with no
`Access-Control-Allow-Origin` header, so a browser will block a direct call
from the moOde WebUI page. **A server-side proxy on the Pi is required** —
you cannot call LMS's API directly from `idle.js`. Images are not subject to
this: `<img src="http://LMS_HOST:LMS_PORT/music/<coverid>/cover.jpg">` works
fine directly from the browser.

## Artwork URLs

- **Local tracks:** `coverid` is album-level (constant across tracks on the
  same album, changes between albums) — verify this on your own library if
  it matters to you, since it determines whether you can cache by coverid.
  `http://LMS_HOST:LMS_PORT/music/<coverid>/cover.jpg` returns the image
  directly.
- **Remote streams (radio):** `coverart` is `"0"` and `coverid` is
  **negative**. The same cover URL pattern still returns a `200`, but it's
  LMS's generic placeholder image, not real artwork — that's expected, not
  a bug.

## Two independent consumers of this metadata

### 1. The WebUI renderer overlay — reuse moOde's own render function

moOde already has a metadata-render path for Spotify/AirPlay
(`updateInpsrcMeta(cmd, json)`, a **global** function in moOde's own minified
JS — verify with `typeof updateInpsrcMeta` in a browser console on the
panel). Its contract:

```
Required JSON keys: title, artist, album, duration, cover_url, sformat
duration divisor: 1000 if cmd includes '_aplmeta' or '_spotmeta', else 1
```

Calling it with a command name that does **not** contain `_aplmeta` or
`_spotmeta` (e.g. `update_slmeta`) gets you the divisor-1 branch, which
matches LMS's native seconds — no unit conversion needed on your end. Calling
this function directly makes the Squeezelite screen pixel-identical to
Spotify's, because it's literally the same render code — nothing about the
DOM layout needs to be reproduced.

If `title` or the formatted duration comes back empty, moOde's own function
renders a "Live" fallback variant — this is moOde's behaviour, not something
you need to build.

### 2. The PeppyMeter fork — fill `currentsong.txt`, don't patch the fork

Design decision: write metadata into `currentsong.txt` in the same format
Spotify/AirPlay already use, rather than patching the fork's code. Every
downstream piece — the WebUI display, the fork's own change-detection guard,
track-change skin switching from doc 3 — then works completely unmodified.

The fields the fork's own moOde-format parser reads:
`title, artist, album, coverurl, outrate, file, bitrate, elapsed, duration,
state, volume, mute`. Cast `duration` to an integer before writing it — a
float value raises a format error in at least one fork implementation.

## The daemon, not a PHP-side writer

**Write this as a standalone daemon, not something that runs from within a
PHP request.** A PHP-side writer only runs while the WebUI overlay is open
and actively polling it — which is exactly when the PeppyMeter screensaver
is *not* on screen. That fails the entire point of feeding the meters.

Daemon contract, as verified working on the original system:

- Polls LMS every ~2 seconds.
- Gates on whether Squeezelite is actually the active renderer — read this
  from moOde's own config store (`cfg_system` in its SQLite database),
  read-only, rather than maintaining your own separate state.
- Only rewrites `currentsong.txt` when `(title, artist, state)` changes — a
  frozen file modification time while nothing has changed is **correct**
  behaviour, not a stuck daemon. (This was misread as a failure once during
  development — check content, not just mtime, before concluding the daemon
  is stuck.)
- Preserves moOde's own `outrate=` line by reading the existing file back
  before overwriting it — don't clobber a field you don't own.
- Writes to a temp file then atomically renames it over the target, so
  readers never observe a partially-written file.
- Runs with `python3 -u` (unbuffered) — same reasoning as doc 3: a crash with
  buffered, redirected stdout can vanish without a trace under systemd.

## The wipe trap — read this before debugging an intermittent old screen

**Symptom:** the plain "Squeezelite Active" screen reappears intermittently,
with no obvious pattern, and skipping a track fixes it.

**Cause:** moOde's own minified JS periodically rebuilds the renderer
overlay DOM (`#inpsrc-msg`), wiping out the metadata you rendered into it. A
naive poll loop's own change-guard (`if (payload === lastPayload) return;`)
then suppresses the re-render, because *your data* hasn't changed even though
*the DOM* has been wiped. It stays wrong until the next track change forces
a re-render.

**Fix** — also re-render when the DOM shows signs of having been wiped,
detected via the CSS class moOde's own render function sets when it runs:

```js
var msgEl = document.getElementById('inpsrc-msg');
var wiped = !msgEl || !msgEl.classList.contains('inpsrc-msg-metadata');
if (payload === lastPayload && !wiped) return;
```

## The idle.js addition

Add to the idle.js built in doc 4 — gate strictly on the Squeezelite-active
flag from moOde's own session/config state (verify it tracks the overlay
correctly on your version before trusting it: it should read `1` exactly
while the overlay is showing and `0`/absent otherwise), poll your proxy
endpoint every ~3 seconds, and apply the wipe-trap guard above:

```js
var RENDERERS = [
  { flag: 'slactive', url: '/sl-meta.php', cmd: 'update_slmeta' },
];
// see docs/06 for how this list grows to support a second renderer
```

(This list structure is written to extend cleanly — doc 6 adds a second
entry to it rather than duplicating the polling logic.)

## What the script does

`scripts/05-install-squeezelite-metadata.sh` prompts for `LMS_HOST`,
`LMS_PORT`, and `PLAYER_ID` (or reads them from environment variables of the
same name, for non-interactive use) and then:

1. Installs `/usr/local/bin/moode-sl-meta` — the Python daemon described
   above, built from the documented contract (LMS polling, `cfg_system`
   read-only gate, atomic write, `outrate` preservation, `python3 -u`).
2. Installs `/var/www/sl-meta.php` — a thin PHP proxy exposing the same LMS
   query as a same-origin endpoint `idle.js` can call, working around the
   CORS restriction above. **Its logic must mirror the daemon's** — if you
   ever change the tag string or artwork handling, change it in both files
   or you'll get inconsistent metadata between the WebUI overlay and the VU
   meters, which happened during the original development and is confusing
   to debug.
3. Installs and enables a systemd unit for the daemon.
4. Appends the `RENDERERS` entry and the wipe-trap guard to
   `/var/www/js/idle.js` (from doc 4) if not already present — backs up the
   file first.
5. Prints the values it used (host/port/player ID) so you can double check
   them, and the command to tail the daemon's logs:
   `sudo journalctl -u moode-sl-meta.service -f`.

## Hardcoded values that will break silently if they change

`LMS_HOST`, `LMS_PORT`, `PLAYER_ID` appear in both
`/usr/local/bin/moode-sl-meta` and `/var/www/sl-meta.php`. If your LMS
server's IP changes (DHCP) or you swap the Pi's network hardware (changing
its MAC, which is what `PLAYER_ID` usually is), both files need updating.

## Fragility across moOde updates

REVERTED: `/var/www/sl-meta.php`, the Squeezelite additions to
`/var/www/js/idle.js`.
SURVIVES: `/usr/local/bin/moode-sl-meta`, its systemd unit.

## Open items, never resolved on the original system

- Radio station logos: LMS's `artwork_url` for radio streams points through
  an image-proxy path that itself redirects to a third-party CDN, which
  returned a 403 with a small XML error body when followed. Not retrievable
  as-is; adding the extra tag for this without handling the failure would
  replace a working placeholder image with a broken one, which is worse.
  Not pursued further.
- Styling the "Turn off" / "Audio info" buttons as icons — same open item as
  doc 4, not attempted here either.
- An intermittent daemon error resembling a type error on a list index was
  seen once in logs and not reproduced after adding exception logging. If
  you see something like `list indices must be integers or slices, not str`
  in your daemon's logs, it's a known-possible transient LMS response shape;
  check `sudo journalctl -u moode-sl-meta.service --no-pager | grep -i fail`
  and treat a single occurrence as inconclusive, not evidence of a
  systematic bug.

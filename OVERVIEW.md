# What this project does to the moOde experience

moOde out of the box is a very capable MPD front end: good audio path,
solid renderer support (Spotify Connect, AirPlay, Bluetooth, Squeezelite,
RoonBridge), a clean WebUI. The gaps this project closes are all in the same
place — **the parts of the experience that only show up once moOde is
running on a dedicated, always-on touchscreen panel** rather than being
driven purely from a phone or laptop browser. Six gaps, six fixes:

## 1. The library felt broken on a NAS (fix: one CIFS mount flag)

**Before:** scanning a network music library was so slow it looked hung —
small-file reads over the CIFS mount took ~10 seconds each, and a rescan of a
~50,000-track library was correspondingly bad.

**After:** changing `cache=none` to `cache=loose` in the CIFS mount options
cut small-read latency by roughly 12x in testing on this system (9.95s to
0.79s) and the visible symptom — library scans that felt hung — went away. No
moOde code changed at all; this is entirely a mount-option fix, applicable to
anyone running moOde's music library off a network share.

**Who benefits:** anyone with music on a NAS/SMB share rather than local
storage or USB.

## 2. Transport buttons felt laggy (fix: two stock-moOde patches)

**Before:** pressing play/pause/next had a consistent, measurable lag
between the press and the icon updating — not huge (under a second) but
persistent, and present on both the touchscreen panel and a remote browser
tab, so it wasn't a customisation-caused regression.

**After:** two stock moOde inefficiencies were found and patched:

- A namespace mismatch between how moOde looks up the current ALSA card and
  how `cfg_system.adevname` stores it meant every state update fell through a
  3-attempt retry loop with a 250ms sleep each time, adding roughly 2 seconds
  to every "now playing" push while audio was playing. Fixing the retry count
  and the leftover sleep cut that specific call from ~2.3s to ~0.5–1.2s in
  testing.
- The config-table endpoint that runs on every UI refresh was shelling out to
  a helper binary just to read a version string that's a static line in a
  file already on disk. Reading it directly cut that endpoint from ~210ms to
  ~58ms (loopback) in testing.

**Who benefits:** anyone running moOde, panel or browser — this is a stock
moOde performance issue, not specific to any customisation. It's the kind of
fix worth upstreaming.

**Honest caveat:** both fixes are measured, real wins on the server side.
Whether they make the *perceived* lag noticeably better was not confirmed
after applying them — see `docs/02-ui-responsiveness.md` for the open
questions this didn't resolve (there's still an unexplained ~500ms of TTFB
variance and an unexplained iowait source).

## 3. VU meters looked good but couldn't do both meters *and* spectrum, or react to track changes

**Before:** stock moOde's meter screensaver options are meters-only or
spectrum-only, and rotate on a fixed timer regardless of what's playing.

**After:** using a community PeppyMeter fork that composes meters and
spectrum in one process, plus a couple of path-resolution bugs fixed (a
working-directory trap that made the spectrum config invisible, and another
that made the background render but stay invisible), gets you meter+spectrum
display that switches skin **on track change** instead of a dumb timer — a
capability that already existed in the fork's code and just needed the right
one-line config key, not a patch.

**Who benefits:** anyone running a touchscreen or HDMI display who wants a
VU-meter screensaver, using this specific PeppyMeter fork.

## 4. The panel had no idle behaviour and no way to dismiss the meter screensaver from the touchscreen

**Before:** stock moOde has no idle/ambient screen and no dedicated
touch-friendly way to toggle the meter overlay independent of the normal
playback UI.

**After:** an idle overlay (for a photo/dashboard display like DAKboard) and
a VU-meter toggle button were added to the renderer overlay. The one bug
worth calling out for anyone attempting similar work: moOde's own
`setDisplay()` function decides which process to kill based on a **PHP
session variable**, not the database — so a naive implementation that
edits the session file directly works until the session is next rewritten,
then silently stops dismissing anything. The fix is to always go through the
same WebUI code path moOde itself uses to write both session and DB
together.

**Who benefits:** anyone running moOde on a dedicated always-on touchscreen
who wants ambient/idle behaviour and a physical way to toggle the VU meter.

## 5. Squeezelite (LMS) playback showed no metadata at all on the panel

**Before:** moOde's `currentsong.txt` — the file every renderer overlay and
the PeppyMeter fork read metadata from — is essentially empty for
Squeezelite. It gets written once when the renderer activates and never
again, so the panel just shows "Squeezelite Active" for the entire session,
regardless of what's playing.

**After:** a small always-on daemon polls LMS's own JSON-RPC API directly
(bypassing moOde entirely for this one purpose) and writes real metadata —
title, artist, album, cover art — into the same file structure the Spotify
and AirPlay renderers already use. Because the WebUI's own metadata-render
function is a global JS function, calling it with the LMS-sourced data makes
the Squeezelite screen **pixel-identical** to the Spotify one, by
construction, not by imitation.

**Who benefits:** anyone running Squeezelite/LMS as a renderer under moOde —
this closes a real, verifiable gap in stock moOde's Squeezelite support.

## 6. No good way to play Plex audio through moOde at all

**Before:** moOde has no Plex renderer. Getting Plex audio onto the same DAC
as everything else meant either casting to a separate device or running
something moOde has no concept of.

**After:** two approaches were tried. Plexamp headless as a first-class
renderer works but can't be cleanly disconnected (it's a persistent daemon
with no observable "session ended" signal at any endpoint checked — five
different signals were tried). The approach actually in use routes Plex
audio through **Squeeze Plex Hub**, which advertises your existing LMS
players to the Plexamp app; moOde then just sees ordinary Squeezelite
traffic and the metadata pipeline from item 5 covers it for free, with two
small additions (a tag-string case fix and unwrapping Plex's proxied
artwork URL to avoid a DNS dependency).

**Who benefits:** anyone with a Plex music library who wants to play it
through an existing moOde+LMS setup without adding a second renderer path.

## Net effect

Individually these are all "papering over a gap in stock moOde." Together,
the effect on a dedicated touchscreen panel is that **every renderer
(Spotify, AirPlay, Squeezelite, and Plex-via-Squeezelite) looks and behaves
the same way** — same metadata screen, same VU meter behaviour, same
dismiss button — instead of Squeezelite and Plex being visibly
second-class citizens next to Spotify. The library-scan and
transport-latency fixes are unrelated wins that apply regardless of which
renderers you use.

# 6 — Playing Plex audio through moOde

Status: **Route B is COMPLETE and in use** on the original system. Route A
(Plexamp headless as a direct moOde renderer) was fully built and works, but
is parked — kept for reference, not recommended as your starting point.

Requires `docs/05-squeezelite-metadata.md` to already be installed — Route B
reuses that entire pipeline and only adds two small changes to it.

## The two routes, and why Route B won

**Route A — Plexamp headless as a moOde renderer.** Works: audio, meters,
metadata, WebUI overlay all functioning. **Abandoned** because Plexamp
headless is a persistent background daemon with no observable "session
ended" signal at any endpoint tried (five different signals were checked —
see "What was tried for Route A disconnect detection" below) — so the
renderer overlay never clears and the DAC is never released when you stop
listening.

**Route B — Squeeze Plex Hub.** [Squeeze Plex
Hub](https://github.com/onmomo/squeeze-plex-hub) (see `CREDITS.md`) is a
small Docker service that discovers your LMS players and advertises them to
the Plexamp app over the network, so they appear as playback targets inside
Plexamp. Selecting one plays Plex audio through your existing
Squeezelite/LMS setup. moOde sees ordinary Squeezelite traffic — nothing
about moOde's own renderer detection needs to change — and the entire
metadata pipeline from doc 5 covers it, with two small additions below.

## Deploying the hub

From the [project's own
documentation](https://github.com/onmomo/squeeze-plex-hub) (verify current
details there before deploying — this is a third-party project you should
read the current instructions for, not just this summary):

```bash
docker run -d \
  --network host \
  --name squeeze-plex-hub \
  onmomo/squeeze-plex-hub:latest
```

Constraints worth knowing before you deploy, established while integrating
this specific hub with an existing LMS + moOde setup:

- It **must** run in Docker `host` network mode — client discovery relies on
  a UDP broadcast (GDM, port 32412) that Docker's bridge networking mode does
  not forward from host to container, so bridge mode silently breaks
  discovery from the Plexamp mobile app.
- If your Plex Media Server also runs in host network mode on the same
  machine, **start the hub first** — both can end up wanting port 32412, and
  PMS binding it before the hub starts causes the hub to eventually fail and
  crash. If PMS runs in bridge mode instead, don't map 32412 for it and this
  isn't a concern.
- The hub's own config surface is limited (listen port and log level); it
  has **no setting for player power or disconnect behaviour** — see "Route B
  known limits" below.

After it's running, `http://<hub-host>:3000` shows discovered LMS players.
Confirm your player is listed, then select it as a target from the Plexamp
app.

## The two changes needed on top of doc 5's pipeline

Hub-streamed tracks arrive at LMS as **remote** tracks (same class as an
internet radio stream from LMS's point of view), which changes two things:

- `coverid` is negative (same as radio) — the generic-placeholder cover URL
  from doc 5 would apply here too, showing a placeholder instead of real Plex
  artwork.
- The real Plex artwork lives in a different field, `remoteMeta.artwork_url`,
  which requires **uppercase `K`** in the tag string (`tags:aAlcdujtyorK` —
  this corrects doc 5's tag string, where lowercase suffices for local
  files but not for remote/hub-streamed tracks). Verify against your own LMS
  version — the available tag letters aren't fully documented upstream and
  this was determined empirically.

### Unwrap the artwork proxy URL

LMS's `artwork_url` for a hub-streamed track is its own proxy path
(`/imageproxy/<url-encoded target>/image.png`), which redirects to a
`*.plex.direct` hostname. That hostname resolves via Plex's own public DNS
and encodes your Plex server's IP as a dashed prefix (e.g.
`a-b-c-d.<hash>.plex.direct`) purely to get a working TLS certificate for an
internal IP.

Following that DNS-dependent redirect works, but it means your artwork
depends on internet DNS resolving even when everything else is purely LAN
traffic. Instead, **decode the dashed IP directly out of the hostname and
rebuild a plain-HTTP URL against your Plex Media Server on the LAN**:

```
plex.direct hostname:  a-b-c-d.<hash>.plex.direct
                         ↓ (dashes → dots)
rebuilt PMS address:   http://a.b.c.d:32400/library/metadata/<id>/thumb/<ver>?X-Plex-Token=<token>
```

This needs no DNS lookup and no TLS, and was verified to serve the same
image successfully over plain HTTP with a token, on the original system.
Local (non-hub) LMS tracks are unaffected — the doc-5 `coverid` path is
still used whenever `artwork_url` is absent, and a negative `coverid` with
no `artwork_url` now yields an **empty** cover rather than a placeholder
antenna icon — a missing image was judged more honest than a wrong one, but
that's a preference, not a correctness requirement; change it if you'd
rather keep the placeholder.

## Keep both consumers' artwork logic in sync

Same warning as doc 5, worth repeating here because it's exactly where it
bit during original development: the artwork-unwrap logic needs to exist in
**both** `sl-meta.php` (feeds the WebUI overlay) and `moode-sl-meta` (feeds
the PeppyMeter fork). Fixing it in one and not the other produces the
confusing state of correct album art on one and a placeholder on the other
at the same time — which happened during the original session. There is no
shared code path between the PHP and Python implementations; changing the
logic means changing it twice.

## What the script does

`scripts/06-install-plexamp-route-b.sh`:

1. Runs the `docker run` command above (or prints it and exits, if
   `--print-only` is passed, for anyone who wants to deploy the hub through
   their own compose/orchestration setup instead).
2. Updates the tag string in the `moode-sl-meta` and `sl-meta.php` files
   installed by doc 5's script from `tags:aAlcdujtyor` to
   `tags:aAlcdujtyorK`, backing up both first.
3. Adds the dashed-IP artwork-unwrap function to both files, mirrored.
4. Prints a reminder to verify the two files still produce identical
   artwork behaviour for both a local track and a hub-streamed track before
   moving on.

## Route B — known limits

- **Disconnecting from the Plexamp app does not clear the moOde renderer.**
  Only an LMS-level power-off does. A hub README search, LMS preference
  probing, and inspecting the LMS web UI all turned up no automatic trigger
  for "Plexamp disconnected → power off the LMS player." This was accepted
  as a limitation rather than solved — there is a working disconnect path
  (power the LMS player off manually, or from LMS's own UI/API), it's just
  not automatic.
- **Plex token expiry.** The hub's own documentation notes that resuming
  playback can fail with an authentication error after the Plex token
  expires, and that reloading the playlist in Plexamp fixes it. The
  artwork URLs built above embed that same transient token, so expect cover
  art to stop loading on long-running sessions — if that happens, suspect
  token expiry before suspecting the unwrap code. Actual token lifetime was
  not measured; treat "long session" as a real but unquantified risk.

## Route A — Plexamp headless (parked, not recommended as a starting point)

Kept for reference. If you don't already know why you'd want a
direct-renderer approach over the hub, use Route B.

### The two traps that make Route A hard, if you attempt it anyway

**Plexamp ignores its own audio device dropdown.** Its settings UI lists
generic device names (not the specific ALSA PCM device your DAC uses under
your alsa config) and picking one has **no effect** on playback — it always
follows the ALSA `default` PCM. If your system has no `default` PCM defined
anywhere (no `/etc/asound.conf`, no `~/.asoundrc`, nothing in
`/etc/alsa/conf.d/`), ALSA silently falls back to whatever card enumerates
as 0 — likely not your DAC.

**Format matters for the meters, silently.** On the original hardware,
routing Plexamp's `default` PCM through the fork's meter pipe at `S32_LE`
produced audio that played correctly through the DAC but an **all-zero
meter data feed** — the meter needles simply never moved, no error anywhere.
Pinning the format to `S24_LE` in the same ALSA definition fixed it. This
was one specific chain on one specific system; the general lesson —
**if a renderer's meters read silence while audio plays fine, check the
ALSA sample format the meter pipe is actually receiving, not just whether
audio is flowing** — is the transferable part. Whether S32_LE is the actual
problem on your hardware, or something else about how that particular
renderer's ALSA path differs from ones that already work, wasn't
investigated further; only three format/renderer combinations were compared,
scoped to one box and one meter pipe implementation.

**moOde doesn't know Plexamp exists**, in the version this was built
against — its own worker process that republishes `currentsong.txt` has a
fixed, short list of renderer types it checks, and Plexamp isn't in it. Any
metadata you write gets overwritten within about a second by moOde's own
fallback (stale MPD state) unless you patch moOde's worker process to add a
Plexamp branch — which means patching a file moOde reverts on every update.

### What was tried for Route A disconnect detection

None of these produced a usable "Plexamp session ended" signal:

| Signal checked | Result |
|---|---|
| Plexamp's local timeline/status endpoint | Paused and fully-quit states were indistinguishable |
| Plex Media Server's active-sessions list | Session still listed ~30s after force-quitting the app |
| Plexamp's own log file | No connection/disconnection events logged, only periodic status pushes |
| Guessed HTTP routes on Plexamp's local API | None of ~15 guessed route names existed |
| Increasing Plexamp's log verbosity | No more-verbose level was available to select |

The one signal that **did** work: counting active TCP connections to
Plexamp's local status port dropped to zero on disconnect and recovered on
reconnect, within a few seconds. That's a viable building block for a
"disconnect" detector if you want to build Route A properly, but doing so
wasn't attempted — Route B made it unnecessary. If you pursue it,
Plexamp's pubsub/WebSocket channel (not checked) and undiscovered HTTP
routes (only ~15 guessed names were tried, which rules nothing out) are
the two unchecked candidates worth looking at before building on the TCP
count alone.

## Fragility across moOde updates (Route B)

REVERTED: the two files modified from doc 5
(`/var/www/sl-meta.php` gets both changes; the moOde worker process is
**not** touched by Route B — that patch only applies to Route A).
SURVIVES: `/usr/local/bin/moode-sl-meta` (gets both changes), the hub itself
(it's an external Docker container, not a moOde file at all).

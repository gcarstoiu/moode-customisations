# 1 — Library scan performance over a NAS/CIFS share

Status: **COMPLETE**, verified working on the original system (moOde 10.3.2).

## Symptom

If your music library lives on a network share (SMB/CIFS — e.g. a NAS, an
Unraid share, a Samba server), library scans and even small file reads can
feel like moOde has hung. On the original system, a small-read timing test
went from **9.95s to 0.79s** — roughly a 12x improvement — after a single
mount-option change, and the library's visible song count went from 6,171 to
49,593 once the scan actually completed properly instead of timing out
partway.

## Root cause

moOde mounts CIFS shares with `cache=none` by default in some configurations.
`cache=none` disables the client-side read cache entirely, so every small
read (which is what a metadata scan is — thousands of small reads, not a few
big ones) pays the full network round trip.

## Fix

Change the cache mode to `cache=loose` for the mount in question. In moOde
this is stored in the `cfg_source` table (Configure → Library → the specific
source), not in `/etc/fstab` directly — moOde generates the mount from that
row.

`cache=loose` trades a small amount of cache coherency (the client may not
notice another host writing to the share for a few seconds) for a large
reduction in read latency. For a moOde library share that's read far more
often than it's written from elsewhere, this is a good trade.

## What the script does

`scripts/01-fix-cifs-cache.sh`:

1. Confirms it's running as root.
2. Reads the current CIFS mount options for a share you name.
3. Backs up the relevant `cfg_source` row (dumped to a timestamped file).
4. Updates the `mountoptions` value to swap `cache=none` for `cache=loose`
   (or appends `cache=loose` if no cache option is present).
5. Prints the remount command and asks you to trigger a library rescan from
   the WebUI afterwards (Configure → Library → Update Library) — the script
   does not trigger a rescan itself, since that can take a long time on a
   large library and you may want to do it at a convenient moment.

## Verifying it worked

Time a small read before and after, from an SSH session on the Pi:

```bash
time head -c 4096 "/mnt/<your-source-mount-point>/some-file.flac" > /dev/null
```

Run it once to warm any caches, then again — the second run should be fast
regardless. The comparison that matters is the *first* read after a reboot
or remount, before and after the change.

## What wasn't investigated

- Whether `cache=loose` causes any visible staleness if you add files to the
  share from another machine while moOde is browsing it. Not tested; if you
  hit it, a manual rescan clears it.
- Performance of `cache=strict` (the CIFS default when no `cache=` option is
  given at all) was not benchmarked against `cache=loose` — only against
  `cache=none`.

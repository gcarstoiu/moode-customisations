# moOde audio player customisations

A set of write-ups and installer scripts for six customisations built on top of
[moOde audio player](https://moodeaudio.org) 10.3.2 on a Raspberry Pi. Everything
here was developed and verified on one real system (Pi 4, HiFiBerry DAC2 HD,
1280x800 touchscreen) between 2026-08-27 and 2026-08-29, then written up and
genericised for sharing. See `OVERVIEW.md` for what problem each piece solves
and why it might be useful to you; see `CREDITS.md` for the upstream projects
this leans on.

**Read this first:** moOde changes fast and these notes are tied to
**moOde 10.3.2 (Trixie)**. If you are on a different version, treat every file
path, PHP function name, and line number below as a hypothesis to verify on
your own box, not a fact. Several of the write-ups in `docs/` record real
debugging dead ends specifically so you don't have to repeat them — read the
"ruled out" / "ranchase" sections before you start.

## What's here

| # | Topic | Doc | Script |
|---|---|---|---|
| 1 | CIFS/NAS library scan speed | [`docs/01-library-scan-performance.md`](docs/01-library-scan-performance.md) | [`scripts/01-fix-cifs-cache.sh`](scripts/01-fix-cifs-cache.sh) |
| 2 | Transport control (play/pause) latency | [`docs/02-ui-responsiveness.md`](docs/02-ui-responsiveness.md) | [`scripts/02-apply-ui-responsiveness-fixes.sh`](scripts/02-apply-ui-responsiveness-fixes.sh) |
| 3 | PeppyMeter fork: meter+spectrum in one process, track-change switching | [`docs/03-peppymeter-metering.md`](docs/03-peppymeter-metering.md) | [`scripts/03-fix-peppymeter-fork.sh`](scripts/03-fix-peppymeter-fork.sh) |
| 4 | Idle screen + on-screen VU meter toggle button | [`docs/04-idle-screen-and-vu-button.md`](docs/04-idle-screen-and-vu-button.md) | [`scripts/04-install-idle-and-vu-button.sh`](scripts/04-install-idle-and-vu-button.sh) |
| 5 | Squeezelite (LMS) track metadata on the renderer screen and on the meters | [`docs/05-squeezelite-metadata.md`](docs/05-squeezelite-metadata.md) | [`scripts/05-install-squeezelite-metadata.sh`](scripts/05-install-squeezelite-metadata.sh) |
| 6 | Playing Plex audio through moOde (Squeeze Plex Hub route) | [`docs/06-plexamp-integration.md`](docs/06-plexamp-integration.md) | [`scripts/06-install-plexamp-route-b.sh`](scripts/06-install-plexamp-route-b.sh) |

Every script:

- is idempotent where practical (safe to re-run),
- backs up every file it touches before changing it, under
  `/home/moode/backups/<script-name>-<timestamp>/`,
- refuses to run as a non-root user where root is required, and tells you so,
- prints what it did and what to check next — it does not silently declare
  success.

## Honesty about what's automated vs. what isn't

A few pieces of the original work edited moOde's own shipped files
(`header.php`, the minified `lib.min.js`/`styles.min.css`, `peppy-toggle.php`)
at points identified only by `grep` pattern, not by a captured diff, because
that's how the original debugging session recorded them. Rather than have a
script blindly `sed` a file it has never seen the current contents of — which
[`docs/`](docs/) repeatedly shows breaking silently on whitespace or version
drift — those steps are left as **documented manual steps** with the exact
grep/patch commands to run and what to check afterwards. Everything else is
scripted.

## Order of installation

The scripts are independent of each other except:

- `04-install-idle-and-vu-button.sh` creates the base `idle.js` that
  `05-install-squeezelite-metadata.sh` and `06-install-plexamp-route-b.sh`
  extend. Run 4 before 5 or 6 if you want those features.
- `03-fix-peppymeter-fork.sh` assumes a PeppyMeter fork is already cloned
  (see `docs/03-peppymeter-metering.md` and `CREDITS.md`). It is a
  post-install fix-up script, not an installer for the fork itself.

## Fragility across moOde updates

moOde's in-place updates revert most files under `/var/www`. Files created
under `/usr/local/bin`, `/etc/systemd/system`, `/home/moode`, and
`/etc/sudoers.d` survive. Each doc has a "Fragility" section listing exactly
which files fall into which bucket for that sub-project, and each script
prints the same list on completion.

## System this was built and verified against

moOde 10.3.2 (Trixie), Chromium 126.0.6478.164, pygame 2.6.1,
Python 3.13.5, nginx 1.26.3, PHP 8.4-FPM, Raspberry Pi 5. **Not re-verified
against any other version** — see the per-topic docs for exactly which claims
were tested and which weren't.

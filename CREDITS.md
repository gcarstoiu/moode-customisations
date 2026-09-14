# Credits

None of this exists without the projects below. This repo is a set of
add-ons and patches on top of them, not a replacement for any of them — go
support the originals.

## moOde audio player

- **moOde audio player** — [moode-player/moode](https://github.com/moode-player/moode),
  [moodeaudio.org](https://moodeaudio.org). Created by Tim Curtis, itself a
  derivative of the original WebUI MPD client by Andrea Coiutti and Simone De
  Gregori, with early contributions from the RaspyFi/Volumio projects. All the
  work here is a set of patches and add-ons layered on top of stock moOde; it
  would not exist without it.

## PeppyMeter and the fork used for sub-project 3

- **PeppyMeter** (the original VU-meter/screensaver engine) —
  [project-owner/PeppyMeter](https://github.com/project-owner/PeppyMeter),
  by peppy.player@gmail.com, GPLv3.
- **PeppyMeter Volumio packaging and the "Gelo" meter skin sets** — Volumio
  forum users **2aCD** (plugin packaging,
  [2aCD-creator](https://github.com/2aCD-creator)) and **Gelo5** (the
  `1280x800-gelo5` / Spec&Met meter template sets used here), documented on
  the [PeppyMeter Volumio wiki](https://github.com/project-owner/PeppyMeter.doc/wiki/Volumio).
- **The specific fork used in `docs/03-peppymeter-metering.md`** — attributed
  during the original work to GitHub user **foonerd**, whose account hosts
  several moOde/Volumio-Raspberry-Pi platform repos
  (e.g. [foonerd/platform-raspberry](https://github.com/foonerd/platform-raspberry)).
  **[UNVERIFIED]** — the exact repository URL for the PeppyMeter fork itself
  was not re-confirmed while preparing this repo. If you use
  `scripts/03-fix-peppymeter-fork.sh`, locate and credit the correct upstream
  repo yourself before publishing further, and open a PR here with the
  correction.

## LMS / Squeezelite metadata (sub-project 5)

- **Lyrion Music Server** (formerly Logitech Media Server / SlimServer) —
  [lyrion.org](https://lyrion.org), [Lyrion Music Server on GitHub](https://github.com/LMS-Community/slimserver).
  The CLI/JSON-RPC reference used throughout is
  [lyrion.org/reference/cli](https://lyrion.org/reference/cli/).
- **Squeezelite** — the lightweight player moOde runs as its LMS client.

## Plex integration (sub-project 6)

- **Squeeze Plex Hub** —
  [onmomo/squeeze-plex-hub](https://github.com/onmomo/squeeze-plex-hub)
  (Docker image `onmomo/squeeze-plex-hub`), by Christian Moser. Bridges
  Plexamp to LMS/Squeezebox players; this is the piece that makes
  `docs/06-plexamp-integration.md` Route B possible at all.
- **Plexamp** / **Plex Media Server** — [plex.tv](https://www.plex.tv).

## Other moOde add-ons referenced

- **moOde audioplayer add-ons** (extended album art, YouTube playback,
  graphic EQ, lyrics, and more) —
  [Stephanowicz/moOde-audioplayer-addons](https://github.com/Stephanowicz/moOde-audioplayer-addons),
  by forum user Stephan. Referenced in the original fragility notes; not
  reproduced here.
- **yt-dlp** — [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp), installed
  as the `youtube-dl` binary used by some moOde add-ons.
- **getID3** — [JamesHeinrich/getID3](https://github.com/JamesHeinrich/getID3),
  the PHP media-tagging library some moOde add-ons depend on.

## This repository

Written up from a hands-on debugging and customisation session on a personal
moOde installation, condensed and genericised (IP addresses, MAC addresses,
hostnames, and player names removed or replaced with placeholders) for public
sharing. Prepared with the assistance of Claude (Anthropic).

#!/bin/bash
# scripts/05-install-squeezelite-metadata.sh
#
# Installs the Squeezelite/LMS metadata pipeline from
# docs/05-squeezelite-metadata.md:
#   - /usr/local/bin/moode-sl-meta   (daemon, feeds the PeppyMeter fork)
#   - /var/www/sl-meta.php           (proxy, feeds the WebUI overlay)
#   - a systemd unit for the daemon
#   - a RENDERERS entry + wipe-trap guard appended to idle.js
#
# Requires scripts/04-install-idle-and-vu-button.sh to have been run first
# (this appends to the idle.js it installs).
#
# Usage:
#   sudo LMS_HOST=192.0.2.10 LMS_PORT=9000 PLAYER_ID=aa:bb:cc:dd:ee:ff \
#     ./05-install-squeezelite-metadata.sh
# or run without those variables set and answer the prompts.

set -euo pipefail

IDLE_JS="/var/www/js/idle.js"
SL_META_PHP="/var/www/sl-meta.php"
DAEMON="/usr/local/bin/moode-sl-meta"
UNIT="/etc/systemd/system/moode-sl-meta.service"
MOODE_DB="/var/local/www/db/moode-sqlite3.db"
CURRENTSONG="/var/local/www/currentsong.txt"
BACKUP_DIR="/home/moode/backups/sl-meta-$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo). Aborting." >&2
  exit 1
fi

if [[ ! -f "$IDLE_JS" ]]; then
  echo "$IDLE_JS not found. Run scripts/04-install-idle-and-vu-button.sh first." >&2
  exit 1
fi

LMS_HOST="${LMS_HOST:-}"
LMS_PORT="${LMS_PORT:-9000}"
PLAYER_ID="${PLAYER_ID:-}"

if [[ -z "$LMS_HOST" ]]; then
  read -rp "LMS host/IP: " LMS_HOST
fi
if [[ -z "$PLAYER_ID" ]]; then
  echo "Find PLAYER_ID (your Squeezelite player's MAC as LMS sees it) via:"
  echo "  curl -s http://$LMS_HOST:$LMS_PORT/jsonrpc.js -d '{\"id\":1,\"method\":\"slim.request\",\"params\":[\"-\",[\"players\",\"0\",\"99\"]]}'"
  read -rp "LMS player ID (MAC address): " PLAYER_ID
fi

mkdir -p "$BACKUP_DIR"
[[ -f "$SL_META_PHP" ]] && cp "$SL_META_PHP" "$BACKUP_DIR/sl-meta.php.orig"
[[ -f "$DAEMON" ]] && cp "$DAEMON" "$BACKUP_DIR/moode-sl-meta.orig"
[[ -f "$IDLE_JS" ]] && cp "$IDLE_JS" "$BACKUP_DIR/idle.js.orig"

# --- the daemon --------------------------------------------------------
cat > "$DAEMON" <<PYEOF
#!/usr/bin/env python3
# moode-sl-meta — polls LMS for the active Squeezelite player's now-playing
# metadata and writes it into moOde's currentsong.txt so the PeppyMeter
# fork (docs/03) picks it up the same way it does for Spotify/AirPlay.
# See docs/05-squeezelite-metadata.md. Installed by
# scripts/05-install-squeezelite-metadata.sh — hardcoded values below will
# break silently if your LMS host/port/player ID change.

import json
import os
import sqlite3
import time
import urllib.request

LMS_HOST = "${LMS_HOST}"
LMS_PORT = ${LMS_PORT}
PLAYER_ID = "${PLAYER_ID}"
TAGS = "aAlcdujtyor"  # see docs/05 and docs/06 for when uppercase K is needed

MOODE_DB = "${MOODE_DB}"
CURRENTSONG = "${CURRENTSONG}"
POLL_SECONDS = 2.0

_last_key = None


def slactive():
    """Read-only check of moOde's own renderer-active flag."""
    try:
        conn = sqlite3.connect(f"file:{MOODE_DB}?mode=ro", uri=True, timeout=1)
        cur = conn.cursor()
        cur.execute("SELECT value FROM cfg_system WHERE param = 'slactive'")
        row = cur.fetchone()
        conn.close()
        return row is not None and row[0] == "1"
    except Exception:
        return False


def lms_query():
    payload = json.dumps(
        {
            "id": 1,
            "method": "slim.request",
            "params": [PLAYER_ID, ["status", "-", 1, f"tags:{TAGS}"]],
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"http://{LMS_HOST}:{LMS_PORT}/jsonrpc.js",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=3) as resp:
        return json.loads(resp.read())


def cover_url(track):
    coverid = track.get("coverid")
    artwork_url = track.get("remoteMeta", {}).get("artwork_url") if isinstance(
        track.get("remoteMeta"), dict
    ) else None
    if artwork_url:
        # docs/06 adds dashed-IP unwrapping for Plex-proxied URLs here.
        return artwork_url
    if coverid and not str(coverid).startswith("-"):
        return f"http://{LMS_HOST}:{LMS_PORT}/music/{coverid}/cover.jpg"
    return ""


def read_existing_outrate():
    try:
        with open(CURRENTSONG, "r") as f:
            for line in f:
                if line.startswith("outrate="):
                    return line.rstrip("\n")
    except FileNotFoundError:
        pass
    return "outrate="


def write_currentsong(track):
    global _last_key
    title = track.get("title", "")
    artist = track.get("artist", "")
    state = "play"  # LMS 'status' response doesn't carry MPD-style state here;
                     # see docs/05 — adjust if your LMS response shape differs.
    key = (title, artist, state)
    if key == _last_key:
        return  # no change — a frozen mtime here is correct, not a bug
    _last_key = key

    duration = track.get("duration", "")
    try:
        duration = int(float(duration))
    except (TypeError, ValueError):
        duration = ""

    lines = [
        "file=Squeezelite Active",
        f"title={title}",
        f"artist={artist}",
        f"album={track.get('album', '')}",
        f"coverurl={cover_url(track)}",
        f"duration={duration}",
        f"state={state}",
        read_existing_outrate(),
    ]

    tmp_path = CURRENTSONG + ".tmp"
    with open(tmp_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp_path, CURRENTSONG)


def main():
    while True:
        if slactive():
            try:
                resp = lms_query()
                result = resp.get("result", {})
                playlist = result.get("playlist_loop", [])
                if playlist:
                    write_currentsong(playlist[0])
            except Exception as e:
                print(f"lms query failed: {e!r}", flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
PYEOF
chmod 755 "$DAEMON"
echo "Installed $DAEMON"

# --- the PHP proxy -------------------------------------------------------
cat > "$SL_META_PHP" <<PHPEOF
<?php
/*
 * sl-meta.php — same-origin proxy for LMS metadata, feeding idle.js's
 * poller (see docs/05-squeezelite-metadata.md). This is required because
 * LMS's jsonrpc.js does not send CORS headers, so a direct browser call
 * from the moOde WebUI would be blocked.
 *
 * IMPORTANT: keep this file's LMS query and artwork logic in sync with
 * /usr/local/bin/moode-sl-meta — see docs/05 for why they're separate,
 * un-shared implementations by design.
 */

\$LMS_HOST = '${LMS_HOST}';
\$LMS_PORT = ${LMS_PORT};
\$PLAYER_ID = '${PLAYER_ID}';
\$TAGS = 'aAlcdujtyor';

function lms_query(\$host, \$port, \$playerId, \$tags) {
    \$payload = json_encode([
        'id' => 1,
        'method' => 'slim.request',
        'params' => [\$playerId, ['status', '-', 1, "tags:\$tags"]],
    ]);
    \$ch = curl_init("http://\$host:\$port/jsonrpc.js");
    curl_setopt(\$ch, CURLOPT_POST, true);
    curl_setopt(\$ch, CURLOPT_POSTFIELDS, \$payload);
    curl_setopt(\$ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
    curl_setopt(\$ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt(\$ch, CURLOPT_TIMEOUT, 3);
    \$resp = curl_exec(\$ch);
    curl_close(\$ch);
    return \$resp === false ? null : json_decode(\$resp, true);
}

function cover_url(\$track, \$host, \$port) {
    \$artworkUrl = \$track['remoteMeta']['artwork_url'] ?? null;
    if (\$artworkUrl) {
        // docs/06 adds dashed-IP unwrapping for Plex-proxied URLs here.
        return \$artworkUrl;
    }
    \$coverid = \$track['coverid'] ?? null;
    if (\$coverid !== null && strpos((string)\$coverid, '-') !== 0) {
        return "http://\$host:\$port/music/\$coverid/cover.jpg";
    }
    return '';
}

header('Content-Type: application/json');

\$resp = lms_query(\$LMS_HOST, \$LMS_PORT, \$PLAYER_ID, \$TAGS);
\$track = \$resp['result']['playlist_loop'][0] ?? null;

if (!\$track) {
    echo json_encode(['title' => '', 'artist' => '', 'album' => '', 'duration' => '', 'cover_url' => '', 'sformat' => '']);
    exit;
}

\$duration = isset(\$track['duration']) ? (int) floatval(\$track['duration']) : '';

echo json_encode([
    'title'     => \$track['title'] ?? '',
    'artist'    => \$track['artist'] ?? '',
    'album'     => \$track['album'] ?? '',
    'duration'  => \$duration,
    'cover_url' => cover_url(\$track, \$LMS_HOST, \$LMS_PORT),
    'sformat'   => '', // populate from your own outrate source if you want a format badge
]);
PHPEOF
echo "Installed $SL_META_PHP"

# --- systemd unit ----------------------------------------------------------
cat > "$UNIT" <<UNITEOF
[Unit]
Description=moOde Squeezelite/LMS metadata daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u ${DAEMON}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
UNITEOF
echo "Installed $UNIT"

systemctl daemon-reload
systemctl enable --now moode-sl-meta.service
echo "Enabled and started moode-sl-meta.service"

# --- append to idle.js ------------------------------------------------------
if grep -q "flag: 'slactive'" "$IDLE_JS"; then
  echo "idle.js already has a slactive RENDERERS entry — leaving it."
else
  python3 - "$IDLE_JS" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

anchor = "window.__moodeCustomRenderers = window.__moodeCustomRenderers || [];"
if anchor not in src:
    print("  Could not find the RENDERERS anchor in idle.js — append by hand.", file=sys.stderr)
    sys.exit(1)

addition = """
  window.__moodeCustomRenderers.push({ flag: 'slactive', url: '/sl-meta.php', cmd: 'update_slmeta' });

  (function squeezeliteMetaPoll() {
    var POLL_MS = 3000;
    var lastPayload = null;
    function wiped() {
      var el = document.getElementById('inpsrc-msg');
      return !el || !el.classList.contains('inpsrc-msg-metadata');
    }
    function tick() {
      var active = window.__moodeCustomRenderers.some(function (r) {
        return window.__moodeSlactive === '1'; // wire this up to your session/flag source
      });
      if (!active) return;
      fetch('/sl-meta.php', { cache: 'no-store' })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          var payload = JSON.stringify(data);
          if (payload === lastPayload && !wiped()) return;
          lastPayload = payload;
          if (typeof updateInpsrcMeta === 'function') {
            updateInpsrcMeta('update_slmeta', data);
          }
        })
        .catch(function () {});
    }
    setInterval(tick, POLL_MS);
  })();
"""

src = src.replace(anchor, anchor + addition)
with open(path, "w") as f:
    f.write(src)
print("  Appended Squeezelite metadata poller to idle.js.")
PYEOF
fi

echo
echo "=== Manual step ==="
echo "window.__moodeSlactive above is a placeholder — wire it to whatever"
echo "your moOde version exposes for the Squeezelite-active flag in the"
echo "browser session (check the WebUI's own JS globals/SESSION object on"
echo "your panel; see docs/05-squeezelite-metadata.md)."
echo
echo "Verify the daemon:"
echo "  sudo journalctl -u moode-sl-meta.service -f"
echo
echo "Values used: LMS_HOST=$LMS_HOST LMS_PORT=$LMS_PORT PLAYER_ID=$PLAYER_ID"
echo "Backups: $BACKUP_DIR"

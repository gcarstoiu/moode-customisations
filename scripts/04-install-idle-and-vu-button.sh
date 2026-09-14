#!/bin/bash
# scripts/04-install-idle-and-vu-button.sh
#
# Installs a reconstructed idle.js (idle overlay + renderer-overlay VU
# meter toggle button) and a peppy-toggle.php endpoint. See
# docs/04-idle-screen-and-vu-button.md — this is a clean-room
# reimplementation of the documented behaviour, not a copy of anyone's
# original file.
#
# Does NOT edit /var/www/header.php — it prints the line you need to add
# by hand, since moOde's shipped header.php varies by version.
#
# Usage:
#   sudo ./04-install-idle-and-vu-button.sh

set -euo pipefail

IDLE_JS="/var/www/js/idle.js"
TOGGLE_PHP="/var/www/peppy-toggle.php"
IDLE_URL="${IDLE_URL:-/idle-state.php}"          # your idle-source probe endpoint, if any
BACKUP_DIR="/home/moode/backups/idle-vu-$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo). Aborting." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR" "$(dirname "$IDLE_JS")"

if [[ -f "$IDLE_JS" ]]; then
  cp "$IDLE_JS" "$BACKUP_DIR/idle.js.orig"
  echo "Backed up existing $IDLE_JS"
fi
if [[ -f "$TOGGLE_PHP" ]]; then
  cp "$TOGGLE_PHP" "$BACKUP_DIR/peppy-toggle.php.orig"
  echo "Backed up existing $TOGGLE_PHP"
fi

cat > "$IDLE_JS" <<'JSEOF'
/*
 * idle.js — idle overlay + renderer-overlay VU meter toggle button.
 *
 * Reconstructed from documented behaviour (see
 * docs/04-idle-screen-and-vu-button.md) — NOT a copy of any original
 * moOde-project or third-party file. Only ever runs on the panel itself
 * (gated on location.hostname === 'localhost'); a remote browser tab will
 * not run any of this, by design.
 *
 * docs/05 and docs/06 append to the RENDERERS array below rather than
 * duplicating this polling logic — if you're installing those too, run
 * this script first.
 */
(function () {
  'use strict';
  if (location.hostname !== 'localhost') {
    return; // panel only
  }

  /* ---------------- Feature 1: idle overlay ---------------- */
  var IDLE_URL = '__IDLE_URL__';
  var IDLE_POLL_MS = 5000;
  var VISIBILITY_DEBOUNCE_MS = 1000;
  var idleTimer = null;
  var overlayEl = null;

  function ensureOverlay() {
    if (overlayEl) return overlayEl;
    overlayEl = document.createElement('div');
    overlayEl.id = 'idle-overlay';
    overlayEl.style.cssText =
      'position:fixed;inset:0;z-index:9999;display:none;background:#000;';
    var iframe = document.createElement('iframe');
    iframe.id = 'idle-overlay-frame';
    iframe.style.cssText = 'width:100%;height:100%;border:0;';
    var shield = document.createElement('div');
    shield.id = 'idle-overlay-shield';
    shield.style.cssText = 'position:absolute;inset:0;background:transparent;';
    shield.addEventListener('click', hideIdleOverlay);
    overlayEl.appendChild(iframe);
    overlayEl.appendChild(shield);
    document.body.appendChild(overlayEl);
    return overlayEl;
  }

  function showIdleOverlay(url) {
    var el = ensureOverlay();
    var frame = document.getElementById('idle-overlay-frame');
    if (frame && frame.getAttribute('src') !== url) {
      frame.setAttribute('src', url); // lazy load: only (re)set src when needed
    }
    el.style.display = 'block';
  }

  function hideIdleOverlay() {
    if (overlayEl) overlayEl.style.display = 'none';
  }

  function idleTick() {
    fetch(IDLE_URL, { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (state) {
        // Contract: { idle: bool, url: string } from your own idle-source
        // probe endpoint. Adjust to whatever your probe actually returns.
        if (state && state.idle) {
          showIdleOverlay(state.url);
        } else {
          hideIdleOverlay();
        }
      })
      .catch(function () {
        /* network hiccup — try again on the next tick, don't show/hide on a guess */
      });
  }

  function startIdlePolling() {
    if (idleTimer === null) {
      idleTick();
      idleTimer = setInterval(idleTick, IDLE_POLL_MS);
    }
  }

  function stopIdlePolling() {
    if (idleTimer !== null) {
      clearInterval(idleTimer);
      idleTimer = null;
    }
  }

  var visibilityDebounceHandle = null;
  document.addEventListener('visibilitychange', function () {
    if (visibilityDebounceHandle !== null) {
      clearTimeout(visibilityDebounceHandle);
    }
    visibilityDebounceHandle = setTimeout(function () {
      visibilityDebounceHandle = null;
      if (document.hidden) {
        stopIdlePolling();
      } else {
        startIdlePolling();
      }
    }, VISIBILITY_DEBOUNCE_MS);
  });

  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    startIdlePolling();
  } else {
    document.addEventListener('DOMContentLoaded', startIdlePolling);
  }

  /* ---------- Feature 2: renderer-overlay VU meter button ---------- */
  var TARGET_SELECTOR = '#inpsrc-msg';
  // Widen or narrow this to match the renderer classes YOUR moOde version
  // emits — inspect them from a browser console on the panel first. See
  // docs/04-idle-screen-and-vu-button.md.
  var GUARD_SELECTOR = '.renderer-btn, .turnoff-renderer, .disconnect-renderer';
  var BUTTON_ID = 'peppy-btn-ren';

  function ensureVuButton() {
    var host = document.querySelector(TARGET_SELECTOR);
    if (!host) return;
    if (!host.querySelector(GUARD_SELECTOR)) return;
    if (document.getElementById(BUTTON_ID)) return;
    var btn = document.createElement('button');
    btn.id = BUTTON_ID;
    btn.className = 'btn renderer-btn';
    btn.textContent = 'VU';
    btn.addEventListener('click', function () {
      fetch('/peppy-toggle.php', { cache: 'no-store' });
    });
    host.appendChild(btn);
  }

  var vuTarget = document.querySelector(TARGET_SELECTOR);
  if (vuTarget) {
    new MutationObserver(ensureVuButton).observe(vuTarget, {
      childList: true,
      subtree: true,
    });
  }
  ensureVuButton();

  /* ------------------------------------------------------------------
   * RENDERERS: extended by docs/05 (Squeezelite) and docs/06 (Plex via
   * the Squeezelite pipeline). Left empty here — installing this script
   * alone gives you the idle overlay and the VU button only.
   * ------------------------------------------------------------------ */
  window.__moodeCustomRenderers = window.__moodeCustomRenderers || [];
})();
JSEOF

# Substitute the configured idle-source probe URL.
sed -i "s|__IDLE_URL__|${IDLE_URL}|" "$IDLE_JS"
echo "Installed $IDLE_JS (idle probe URL: $IDLE_URL)"

cat > "$TOGGLE_PHP" <<'PHPEOF'
<?php
/*
 * peppy-toggle.php — starts/stops the PeppyMeter fork launcher installed
 * by scripts/03-fix-peppymeter-fork.sh. See
 * docs/04-idle-screen-and-vu-button.md for why the process check uses
 * `ps -ef | grep -c` instead of pgrep, and why it's checked twice
 * (re-entrancy guard, then launch confirmation).
 */

// Substitute your fork's actual entry-point script name if it differs.
$procPattern = "[v]olumio_peppymeter";

function peppyRunning($pattern) {
    return (int) trim(shell_exec("ps -ef | grep -c '" . $pattern . "'"));
}

if (peppyRunning($procPattern) > 0) {
    // Already running — stop it.
    shell_exec("pkill -f volumio_peppymeter");
    echo json_encode(["action" => "stop"]);
    exit;
}

// Not running — launch it. Re-entrancy guard above already confirmed
// zero instances before we get here.
shell_exec("/usr/local/bin/moode-peppy-fork > /tmp/peppy_launch.log 2>&1 &");

// Give it a moment to appear in the process table before confirming.
// Verify this delay empirically on your own hardware — see
// docs/04-idle-screen-and-vu-button.md.
usleep(700000);

if (peppyRunning($procPattern) > 0) {
    echo json_encode(["action" => "start", "confirmed" => true]);
} else {
    // Launch did not take. Do NOT report success — a false positive here
    // leaves state inconsistent (see the doc's note on why this check
    // exists at all).
    http_response_code(500);
    echo json_encode(["action" => "start", "confirmed" => false]);
}
PHPEOF
echo "Installed $TOGGLE_PHP"

echo
echo "=== Manual step (not automated — see README.md) ==="
echo "Add this line to /var/www/header.php, inside <head>, near any other"
echo "custom script tags (grep -n '</head>' /var/www/header.php to find a"
echo "spot, or grep -n 'idle.js' if you're replacing a prior version):"
echo '  <script src="/js/idle.js"></script>'
echo
echo "Suggested starting CSS for the button (put it wherever your custom"
echo "CSS is loaded from — not automated, no CSS file is assumed to exist):"
cat <<'CSSEOF'
  #peppy-btn-ren { margin-left: 8px; }
CSSEOF
echo
echo "Backups: $BACKUP_DIR"

# 4 — Idle screen overlay and a touch-friendly VU meter toggle

Status: **COMPLETE** on the original system, for the renderer types tested.

Both features live in the same file, `/var/www/js/idle.js`, because they
share the same lazy-load and gating pattern. This doc reconstructs that file
from its documented behaviour; it is **not** a byte-for-byte copy of the
original (which wasn't captured verbatim in the source notes) — treat
`scripts/04-install-idle-and-vu-button.sh` as a clean-room implementation of
the same feature set, and read `README.md`'s "Honesty about what's
automated" section before assuming it matches any other installation
exactly.

## Feature 1 — idle overlay

**Goal:** show an ambient/idle screen (e.g. a photo frame or dashboard like
DAKboard) on the panel when nothing else needs attention, without touching
moOde's own UI.

**Design, as verified working on the original system:**

- A lazy-loaded iframe plus a transparent full-screen touch shield, so a tap
  anywhere dismisses the overlay without needing a specific close button.
- Polls every 5000ms to decide whether the overlay should be shown.
- Gated on `location.hostname === 'localhost'`, so it **only ever runs on
  the panel itself** — a remote browser tab never sees it. This matters for
  testing: if you're checking behaviour from a laptop browser instead of the
  panel, you will see nothing, and that's correct, not a bug.
- Debounced `visibilitychange` handling: Chromium fires that event several
  times per actual switch, so the handler waits 1000ms after the last event
  before acting on the settled state. When the tab goes hidden it clears the
  poll timer and nulls the handle; when it becomes visible it only restarts
  polling if the handle is null — this specifically prevents a second
  polling loop from stacking on top of an existing one if visibility flaps
  quickly.

## Feature 2 — VU meter toggle button, including on the renderer overlay screens

**Goal:** a touch button that starts/stops the PeppyMeter fork from
`docs/03-peppymeter-metering.md`, reachable from the normal playbar **and**
from renderer overlay screens (Spotify/AirPlay/etc.), where moOde's own
playbar button doesn't appear.

**The gap:** moOde's renderer overlay screen (the one shown when a renderer
like Spotify is active) is a separate DOM block, rebuilt at runtime by
moOde's own minified JS whenever renderer state changes. That rebuild wipes
any button injected into it — a one-shot append doesn't survive the next
rebuild.

**Fix — a `MutationObserver`:**

```js
// Re-add the VU meter button whenever moOde's renderer-overlay
// rebuild wipes it out. Guarded so it only fires on the renderer
// overlay itself, not on every DOM mutation on the page.
(function () {
  var TARGET_SELECTOR = '#inpsrc-msg';
  var GUARD_SELECTOR =
    '.renderer-btn, .turnoff-renderer, .disconnect-renderer';
  var BUTTON_ID = 'peppy-btn-ren';

  function ensureButton() {
    var host = document.querySelector(TARGET_SELECTOR);
    if (!host) return;
    if (!host.querySelector(GUARD_SELECTOR)) return; // not a renderer overlay we target
    if (document.getElementById(BUTTON_ID)) return; // already present
    var btn = document.createElement('button');
    btn.id = BUTTON_ID;
    btn.className = 'btn renderer-btn';
    btn.textContent = 'VU';
    btn.addEventListener('click', function () {
      fetch('/peppy-toggle.php');
    });
    host.appendChild(btn);
  }

  var target = document.querySelector(TARGET_SELECTOR);
  if (target) {
    new MutationObserver(ensureButton).observe(target, {
      childList: true,
      subtree: true,
    });
  }
  ensureButton();
})();
```

**The guard selector matters.** Widening it beyond the renderer types you
actually use is a real decision, not a no-op — it determines which renderer
overlay screens get the button. On the original system the guard was
deliberately written to include Squeezelite's renderer classes (which don't
carry `.renderer-btn` — see `docs/05-squeezelite-metadata.md`) and Plexamp's,
while excluding Bluetooth/Aux and Multiroom overlays on purpose, because
those use different classes not covered by the same button placement logic.
Adjust `GUARD_SELECTOR` to match the renderer classes your moOde version
actually emits — inspect the DOM on your own renderer overlay screens
(`document.querySelector('#inpsrc-msg').className` and its children's
classes, from a browser console on the panel) before assuming the class
names above match your version.

## The button needs a server-side endpoint: `peppy-toggle.php`

This PHP endpoint (part of moOde's own add-on ecosystem for this kind of
button, **not written from scratch here** — see the pattern below) needs a
process-existence check that's reliable for the PeppyMeter fork specifically:

```php
// process check pattern used in this project — substitute the actual
// entry-point script name for your fork if it differs:
$running = (int) shell_exec("ps -ef | grep -c '[v]olumio_peppymeter'");
```

**Why not `pgrep -c -f 'peppymeter\.py'`:** it was found unreliable under the
web server's user on the original system (inconsistent counts for a
demonstrably running process). The `ps -ef | grep -c` form with a
self-excluding bracket trick (`[v]olumio` instead of `volumio`, so the grep
process doesn't match its own command line) was verified reliable.

Two places in a toggle endpoint typically need this check: once as a
re-entrancy guard before launching (a false zero here launches a **second**
fork process, which will fight the first one for the framebuffer and the
meter data pipe), and once after launching, to confirm the process actually
started before flipping any "renderer active" database flags — a false zero
here leaves the process running with those flags unset, which then breaks
dismissal later, since dismissal logic reads those flags to decide what to
kill.

If you insert a `usleep()` between the launch and the post-launch check,
verify empirically how long your fork's process takes to become visible to
`ps` and to finish its own initialisation — these are not the same moment,
and a check that fires before the process is even forked will always read
zero regardless of how long you wait afterward for *initialisation*.

## Display-type dismissal — go through the WebUI, not the session file

moOde's own `setDisplay()` function decides which process to kill based on
**a PHP session variable**, not the database, even though both get written
when you use the WebUI normally. If you ever hand-edit the session file
directly to test something, know that it works only until the session is
next rewritten by moOde itself — then dismissal silently breaks again with
no error.

**Always configure the display type through Configure → Peripherals in the
WebUI**, which writes both the session and the database together in one
call. Don't script around this by writing the session file directly.

## What the script does

`scripts/04-install-idle-and-vu-button.sh`:

1. Writes the reconstructed `idle.js` (both features, from the templates
   above) to `/var/www/js/idle.js`, backing up any existing file first.
2. Writes a minimal `peppy-toggle.php` implementing the process-check
   pattern above, backing up any existing file first.
3. Prints the exact `<script>` tag to add to `/var/www/header.php` and asks
   you to add it by hand — **the script does not edit `header.php`**, since
   moOde's shipped copy varies by version and a blind insertion risks
   duplicate tags or a broken `<head>` on an update you haven't tested this
   against.
4. Prints the CSS you'll want for `#peppy-btn-ren` (a starting point, not a
   finished design — see "Open items" below).

## Open items (carried over, never resolved on the original system)

- `#peppy-btn-ren` used Spotify-screen button styling (`renderer-btn`) even
  on renderer types with different button styling conventions (e.g.
  Squeezelite's text-styled buttons) — visually inconsistent, never fixed.
- Restyling moOde's own "Turn off" / "Audio info" buttons as icons instead of
  text wasn't attempted — they're built by moOde's own minified JS, so doing
  this requires a CSS/JS override from your own files, not editing the
  minified source directly.

## Fragility across moOde updates

REVERTED: `/var/www/js/idle.js`, `/var/www/peppy-toggle.php`,
`/var/www/css/*` you add, `/var/www/header.php` (the script tag line).
SURVIVES: nothing in this doc's scope lives outside `/var/www` — re-run the
install script after every moOde update, and re-add the `header.php` line by
hand.

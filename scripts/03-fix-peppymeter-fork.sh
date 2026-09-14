#!/bin/bash
# scripts/03-fix-peppymeter-fork.sh
#
# Fixes the cwd-relative-path issues in a PeppyMeter fork that composes
# meters + spectrum in one process (see docs/03-peppymeter-metering.md and
# CREDITS.md), enables track-change skin switching, and installs an
# update-surviving launcher.
#
# Assumes the fork is ALREADY CLONED at FORK_DIR below. This is a fix-up
# script, not a fork installer.
#
# Usage:
#   sudo FORK_DIR=/home/moode/peppy-fork ./03-fix-peppymeter-fork.sh

set -euo pipefail

FORK_DIR="${FORK_DIR:-/home/moode/peppy-fork}"
SPECTRUM_CONFIG_SRC="${SPECTRUM_CONFIG_SRC:-/etc/peppyspectrum/config.txt}"
BACKUP_DIR="/home/moode/backups/peppymeter-fork-$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo). Aborting." >&2
  exit 1
fi

if [[ ! -d "$FORK_DIR" ]]; then
  echo "FORK_DIR ($FORK_DIR) does not exist. Clone your PeppyMeter fork" >&2
  echo "there first (see CREDITS.md), then re-run this script." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- locate the meter config and the entry-point script -------------------
METER_CONFIG=$(find "$FORK_DIR" -path '*peppymeter/config.txt' -print -quit || true)
SPECTRUM_DIR=$(find "$FORK_DIR" -type d -path '*screensaver/spectrum' -print -quit || true)
ENTRYPOINT=$(find "$FORK_DIR" -name 'volumio_peppymeter.py' -print -quit || true)

if [[ -z "$METER_CONFIG" || -z "$SPECTRUM_DIR" || -z "$ENTRYPOINT" ]]; then
  echo "Could not locate one or more expected paths under $FORK_DIR:" >&2
  echo "  meter config.txt:            ${METER_CONFIG:-NOT FOUND}" >&2
  echo "  screensaver/spectrum dir:     ${SPECTRUM_DIR:-NOT FOUND}" >&2
  echo "  volumio_peppymeter.py entry:  ${ENTRYPOINT:-NOT FOUND}" >&2
  echo "Your fork's layout differs from the one this script expects." >&2
  echo "See docs/03-peppymeter-metering.md and apply the fixes by hand." >&2
  exit 1
fi

METER_DIR=$(dirname "$METER_CONFIG")
echo "Found:"
echo "  meter config:    $METER_CONFIG"
echo "  spectrum dir:    $SPECTRUM_DIR"
echo "  entry point:     $ENTRYPOINT"
echo

cp "$METER_CONFIG" "$BACKUP_DIR/config.txt.orig"

# --- Symptom A: copy the spectrum config into the post-chdir cwd ----------
if [[ -f "$SPECTRUM_DIR/config.txt" ]]; then
  echo "Spectrum config already present at $SPECTRUM_DIR/config.txt — leaving it."
else
  if [[ -f "$SPECTRUM_CONFIG_SRC" ]]; then
    cp "$SPECTRUM_CONFIG_SRC" "$SPECTRUM_DIR/config.txt"
    echo "Copied $SPECTRUM_CONFIG_SRC -> $SPECTRUM_DIR/config.txt"
  else
    echo "WARNING: $SPECTRUM_CONFIG_SRC not found — could not seed the" >&2
    echo "spectrum config. Symptom A (silent exit) will likely recur." >&2
  fi
fi

# --- Symptom B: make base.folder absolute ----------------------------------
if grep -qE '^\s*base\.folder\s*=' "$METER_CONFIG"; then
  # Guard against configparser's DuplicateOptionError: replace the one
  # existing line rather than appending a second one.
  count=$(grep -cE '^\s*base\.folder\s*=' "$METER_CONFIG")
  if [[ "$count" -ne 1 ]]; then
    echo "Found $count 'base.folder =' lines in $METER_CONFIG — ambiguous." >&2
    echo "Edit it by hand: set it to base.folder = $METER_DIR" >&2
  else
    sed -i "s|^\s*base\.folder\s*=.*|base.folder = $METER_DIR|" "$METER_CONFIG"
    echo "Set base.folder = $METER_DIR"
  fi
else
  sed -i "/^\[current\]/a base.folder = $METER_DIR" "$METER_CONFIG"
  echo "Added base.folder = $METER_DIR"
fi

# --- track-change switching -------------------------------------------------
meter_line=$(grep -E '^\s*meter\s*=' "$METER_CONFIG" | head -n1 || true)
if [[ "$meter_line" == *"random"* ]]; then
  if grep -qE '^\s*random\.change\.title\s*=' "$METER_CONFIG"; then
    sed -i "s|^\s*random\.change\.title\s*=.*|random.change.title = True|" "$METER_CONFIG"
  else
    sed -i "/^\[current\]/a random.change.title = True" "$METER_CONFIG"
  fi
  echo "Set random.change.title = True (meter mode is already 'random')."
else
  echo "meter is not set to 'random' (found: '${meter_line:-<none>}')."
  echo "Track-change switching requires meter = random or a comma-separated"
  echo "list of meter names. Not changing your meter selection automatically"
  echo "— edit $METER_CONFIG by hand if you want this."
fi

python3 -c "import configparser; c=configparser.ConfigParser(); c.read('$METER_CONFIG')" \
  || { echo "ERROR: $METER_CONFIG no longer parses as valid config. Restoring backup." >&2
       cp "$BACKUP_DIR/config.txt.orig" "$METER_CONFIG"; exit 1; }

# --- launcher ---------------------------------------------------------------
PYPATH_DIRS=$(find "$FORK_DIR" -maxdepth 2 -type d ! -name '.*' | paste -sd ':' -)
LAUNCHER=/usr/local/bin/moode-peppy-fork

cat > "$LAUNCHER" <<EOF
#!/bin/bash
# Installed by scripts/03-fix-peppymeter-fork.sh — see
# docs/03-peppymeter-metering.md. Survives moOde updates (lives outside
# /var/www). Re-point moOde's own /usr/local/bin/moode-peppy-start at this
# script — see the printed instructions below; this script does not edit
# moode-peppy-start itself.
export DISPLAY=:0
export PYTHONPATH="$PYPATH_DIRS"
rm -f /tmp/peppyrunning
cd "$FORK_DIR" || exit 1
exec python3 -u "$ENTRYPOINT"
EOF
chmod 755 "$LAUNCHER"
echo "Installed $LAUNCHER"

echo
echo "=== Manual step (not automated — see README.md) ==="
echo "Edit /usr/local/bin/moode-peppy-start: wherever it calls"
echo "  /var/www/util/start-peppy.sh \"\$TYPE\""
echo "change that line to call:"
echo "  $LAUNCHER"
echo "(keep passing \"\$TYPE\" — moOde's sudoers rules match the exact command"
echo "line moOde itself invokes)."
echo
ENTRY_BASENAME=$(basename "$ENTRYPOINT" .py)
ENTRY_BRACKET="[${ENTRY_BASENAME:0:1}]${ENTRY_BASENAME:1}"
echo "Verify with:"
echo "  ps -ef | grep -c '${ENTRY_BRACKET}'"
echo "(pgrep -c -f was found unreliable for this process on the original"
echo "system — prefer the ps -ef | grep -c form above.)"
echo
echo "Backups: $BACKUP_DIR"
echo "Restore the meter config with:"
echo "  sudo cp $BACKUP_DIR/config.txt.orig $METER_CONFIG"

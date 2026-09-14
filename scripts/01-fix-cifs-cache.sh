#!/bin/bash
# scripts/01-fix-cifs-cache.sh
#
# Fixes slow library scans over a CIFS/SMB network share by switching the
# mount's cache mode from `none` (or unset) to `loose`.
# See docs/01-library-scan-performance.md for why.
#
# Usage:
#   sudo ./01-fix-cifs-cache.sh
#
# You will be shown the configured library sources and asked which one to
# fix. Non-interactive use:
#   sudo SOURCE_NAME="My NAS" ./01-fix-cifs-cache.sh

set -euo pipefail

DB="/var/local/www/db/moode-sqlite3.db"
BACKUP_DIR="/home/moode/backups/cifs-cache-$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo). Aborting." >&2
  exit 1
fi

if [[ ! -f "$DB" ]]; then
  echo "moOde database not found at $DB — is this a moOde system?" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is not installed. Install it with: sudo apt-get install sqlite3" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "Configured library sources (cfg_source table):"
sqlite3 -header -column "$DB" "SELECT id, name, mountoptions FROM cfg_source;"
echo

SOURCE_NAME="${SOURCE_NAME:-}"
if [[ -z "$SOURCE_NAME" ]]; then
  read -rp "Enter the exact 'name' of the source to fix: " SOURCE_NAME
fi

ROW=$(sqlite3 "$DB" "SELECT id || '|' || mountoptions FROM cfg_source WHERE name = '$SOURCE_NAME';")
if [[ -z "$ROW" ]]; then
  echo "No source found with name '$SOURCE_NAME'. Nothing changed." >&2
  exit 1
fi

SRC_ID="${ROW%%|*}"
CURRENT_OPTS="${ROW#*|}"

echo "Current mount options for '$SOURCE_NAME' (id=$SRC_ID):"
echo "  $CURRENT_OPTS"

# Back up the full row before touching anything.
sqlite3 "$DB" "SELECT * FROM cfg_source WHERE id = $SRC_ID;" \
  > "$BACKUP_DIR/cfg_source-id${SRC_ID}.bak"
echo "Backed up existing row to: $BACKUP_DIR/cfg_source-id${SRC_ID}.bak"

if [[ "$CURRENT_OPTS" == *"cache=loose"* ]]; then
  echo "Already set to cache=loose. Nothing to do."
  exit 0
elif [[ "$CURRENT_OPTS" == *"cache="* ]]; then
  NEW_OPTS=$(echo "$CURRENT_OPTS" | sed -E 's/cache=[a-z]+/cache=loose/')
else
  # No cache= option present at all — append one.
  if [[ -n "$CURRENT_OPTS" ]]; then
    NEW_OPTS="${CURRENT_OPTS},cache=loose"
  else
    NEW_OPTS="cache=loose"
  fi
fi

echo "New mount options:"
echo "  $NEW_OPTS"

sqlite3 "$DB" "UPDATE cfg_source SET mountoptions = '$NEW_OPTS' WHERE id = $SRC_ID;"

echo
echo "Done. To apply this, remount the source. Easiest path: from the moOde"
echo "WebUI, go to Configure -> Library, remove and re-add the source (or use"
echo "the source's own edit/reconnect action if your moOde version has one)."
echo
echo "Afterwards, trigger Configure -> Library -> Update Library to rescan."
echo
echo "Restore the previous value with:"
echo "  sudo sqlite3 $DB \"UPDATE cfg_source SET mountoptions = '$CURRENT_OPTS' WHERE id = $SRC_ID;\""

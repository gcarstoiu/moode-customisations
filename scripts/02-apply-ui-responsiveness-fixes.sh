#!/bin/bash
# scripts/02-apply-ui-responsiveness-fixes.sh
#
# Applies the two stock-moOde transport-latency patches from
# docs/02-ui-responsiveness.md:
#   Fix 1: /var/www/inc/alsa.php     — retry-loop cost
#   Fix 2: /var/www/inc/common.php   — getMoodeRel() shell-out
#
# Both patches are CONTENT matches, not line-number matches. If your
# moOde version's source doesn't contain the exact text this script
# looks for, that fix is skipped with a clear message and nothing is
# changed in that file — this script never blind-patches a file whose
# current content it hasn't verified.
#
# Usage:
#   sudo ./02-apply-ui-responsiveness-fixes.sh

set -euo pipefail

ALSA_PHP="/var/www/inc/alsa.php"
COMMON_PHP="/var/www/inc/common.php"
BACKUP_DIR="/home/moode/backups/ui-responsiveness-$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo). Aborting." >&2
  exit 1
fi

if ! command -v php >/dev/null 2>&1; then
  echo "php CLI not found — cannot verify patches with 'php -l'. Aborting." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

patch_ok=0
patch_fail=0

lint_or_restore() {
  local file="$1" backup="$2"
  if php -l "$file" >/dev/null 2>&1; then
    return 0
  else
    echo "  php -l FAILED on $file — restoring backup." >&2
    cp "$backup" "$file"
    return 1
  fi
}

echo "=== Fix 1: $ALSA_PHP ==="
if [[ ! -f "$ALSA_PHP" ]]; then
  echo "  File not found. Skipping Fix 1." >&2
  patch_fail=$((patch_fail+1))
else
  cp "$ALSA_PHP" "$BACKUP_DIR/alsa.php.orig"
  loop_count=$(grep -c '\$maxLoops = 3;' "$ALSA_PHP" || true)
  if [[ "$loop_count" -ne 1 ]]; then
    echo "  Expected exactly one '\$maxLoops = 3;' line, found $loop_count. Skipping — verify the source by hand." >&2
    patch_fail=$((patch_fail+1))
  else
    sed -i 's/\$maxLoops = 3;/\$maxLoops = 1;/' "$ALSA_PHP"
    sleep_count=$(grep -c 'usleep(\$sleepTime);' "$ALSA_PHP" || true)
    if [[ "$sleep_count" -eq 1 ]]; then
      sed -i '/usleep(\$sleepTime);/d' "$ALSA_PHP"
      echo "  Removed the trailing usleep(\$sleepTime); call."
    elif [[ "$sleep_count" -eq 0 ]]; then
      echo "  No 'usleep(\$sleepTime);' line found — \$maxLoops was patched, sleep removal skipped." >&2
    else
      echo "  Found $sleep_count 'usleep(\$sleepTime);' lines — ambiguous, NOT removing any of them. Review $ALSA_PHP by hand." >&2
    fi
    if lint_or_restore "$ALSA_PHP" "$BACKUP_DIR/alsa.php.orig"; then
      echo "  Fix 1 applied and verified with php -l."
      patch_ok=$((patch_ok+1))
    else
      patch_fail=$((patch_fail+1))
    fi
  fi
fi

echo
echo "=== Fix 2: $COMMON_PHP ==="
if [[ ! -f "$COMMON_PHP" ]]; then
  echo "  File not found. Skipping Fix 2." >&2
  patch_fail=$((patch_fail+1))
else
  cp "$COMMON_PHP" "$BACKUP_DIR/common.php.orig"
  call_count=$(grep -c 'sysCmd("moodeutl --mooderel' "$COMMON_PHP" || true)
  if [[ "$call_count" -lt 1 ]]; then
    echo "  No 'sysCmd(\"moodeutl --mooderel' calls found — nothing to patch, or your version differs. Skipping." >&2
    patch_fail=$((patch_fail+1))
  else
    python3 - "$COMMON_PHP" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r") as f:
    src = f.read()

func_re = re.compile(r"(function\s+getMoodeRel\s*\([^)]*\)\s*\{)")
m = func_re.search(src)
if not m:
    print("  Could not locate function getMoodeRel(...) { — leaving file untouched.", file=sys.stderr)
    sys.exit(2)

insert_point = m.end()
cache_block = (
    "\n    static $rel = null;"
    "\n    if ($rel === null) {"
    "\n        $footer = @file_get_contents('/var/www/footer.min.php');"
    "\n        $pos = $footer !== false ? strpos($footer, 'Release: ') : false;"
    "\n        $rel = $pos !== false ? substr($footer, $pos + 9, 17) : '';"
    "\n    }"
)
src = src[:insert_point] + cache_block + src[insert_point:]

# Replace sysCmd("moodeutl --mooderel ...) result assignments with the cached value.
src, n = re.subn(
    r"\$result\s*=\s*sysCmd\(\"moodeutl --mooderel[^\)]*\);",
    "$result = array($rel);",
    src,
)

with open(path, "w") as f:
    f.write(src)

print(f"  Replaced {n} sysCmd(\"moodeutl --mooderel...\") call(s); added static $rel cache.")
if n == 0:
    sys.exit(3)
PYEOF
    py_status=$?
    if [[ $py_status -ne 0 ]]; then
      echo "  Automated patch could not proceed safely — restoring backup. Apply Fix 2 by hand per docs/02-ui-responsiveness.md." >&2
      cp "$BACKUP_DIR/common.php.orig" "$COMMON_PHP"
      patch_fail=$((patch_fail+1))
    elif lint_or_restore "$COMMON_PHP" "$BACKUP_DIR/common.php.orig"; then
      echo "  Fix 2 applied and verified with php -l."
      echo "  IMPORTANT: verify BOTH return forms still work — see docs/02-ui-responsiveness.md."
      echo "    php -r \"require '$COMMON_PHP'; var_dump(getMoodeRel('verbose')); var_dump(getMoodeRel());\""
      patch_ok=$((patch_ok+1))
    else
      patch_fail=$((patch_fail+1))
    fi
  fi
fi

echo
echo "=== Summary ==="
echo "Applied: $patch_ok   Skipped/failed: $patch_fail"
echo "Backups: $BACKUP_DIR"
echo
echo "Restore either file with:"
echo "  sudo cp $BACKUP_DIR/alsa.php.orig $ALSA_PHP"
echo "  sudo cp $BACKUP_DIR/common.php.orig $COMMON_PHP"
echo
echo "Both files are reverted by moOde's own in-place updates — re-run this"
echo "script after every update."

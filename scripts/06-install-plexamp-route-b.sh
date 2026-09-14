#!/bin/bash
# scripts/06-install-plexamp-route-b.sh
#
# Deploys Squeeze Plex Hub (https://github.com/onmomo/squeeze-plex-hub,
# see CREDITS.md) and patches the Squeezelite metadata pipeline from
# scripts/05-install-squeezelite-metadata.sh for Plex-streamed artwork.
# See docs/06-plexamp-integration.md.
#
# Requires scripts/05-install-squeezelite-metadata.sh to have been run
# first (this patches the files it installs).
#
# Usage:
#   sudo ./06-install-plexamp-route-b.sh            # deploys the hub too
#   sudo ./06-install-plexamp-route-b.sh --print-only # skip docker run,
#                                                       just print it

set -euo pipefail

DAEMON="/usr/local/bin/moode-sl-meta"
SL_META_PHP="/var/www/sl-meta.php"
BACKUP_DIR="/home/moode/backups/plexamp-route-b-$(date +%Y%m%d-%H%M%S)"
PRINT_ONLY=0
[[ "${1:-}" == "--print-only" ]] && PRINT_ONLY=1

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo). Aborting." >&2
  exit 1
fi

for f in "$DAEMON" "$SL_META_PHP"; do
  if [[ ! -f "$f" ]]; then
    echo "$f not found. Run scripts/05-install-squeezelite-metadata.sh first." >&2
    exit 1
  fi
done

mkdir -p "$BACKUP_DIR"
cp "$DAEMON" "$BACKUP_DIR/moode-sl-meta.orig"
cp "$SL_META_PHP" "$BACKUP_DIR/sl-meta.php.orig"

HUB_CMD='docker run -d --network host --name squeeze-plex-hub onmomo/squeeze-plex-hub:latest'

echo "=== Squeeze Plex Hub ==="
echo "Constraints (see docs/06 before deploying):"
echo "  - must run in Docker host network mode (UDP discovery needs it)"
echo "  - if Plex Media Server also runs in host mode on this box, start"
echo "    the hub BEFORE PMS, or PMS may claim UDP 32412 first"
echo
if [[ "$PRINT_ONLY" -eq 1 ]]; then
  echo "Deploy command (not run — --print-only was passed):"
  echo "  $HUB_CMD"
else
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found. Install Docker first, or re-run with --print-only" >&2
    echo "and deploy the hub through your own orchestration." >&2
    exit 1
  fi
  echo "Running: $HUB_CMD"
  eval "$HUB_CMD"
  echo "Hub starting. Check http://<this-host>:3000 once it's up."
fi

echo
echo "=== Patching tag string: aAlcdujtyor -> aAlcdujtyorK ==="
for f in "$DAEMON" "$SL_META_PHP"; do
  count=$(grep -c "aAlcdujtyor'" "$f" 2>/dev/null || grep -c 'aAlcdujtyor"' "$f" 2>/dev/null || echo 0)
  if grep -q "aAlcdujtyorK" "$f"; then
    echo "  $f already patched — leaving it."
  elif grep -q "aAlcdujtyor" "$f"; then
    sed -i "s/aAlcdujtyor/aAlcdujtyorK/g" "$f"
    echo "  Patched $f"
  else
    echo "  WARNING: expected tag string not found in $f — check it by hand." >&2
  fi
done

echo
echo "=== Adding dashed-IP artwork unwrap (mirrored in both files) ==="

python3 - "$DAEMON" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

marker = "# docs/06 adds dashed-IP unwrapping for Plex-proxied URLs here."
if marker not in src:
    print("  Marker not found in daemon — insert the unwrap logic by hand per docs/06.", file=sys.stderr)
    sys.exit(0)

func = '''def unwrap_plex_direct(url):
    """Rebuild a plain-HTTP LAN URL from a *.plex.direct imageproxy
    redirect target, avoiding a public-DNS dependency for local artwork.
    See docs/06-plexamp-integration.md."""
    import re as _re
    m = _re.search(r"([0-9]+-[0-9]+-[0-9]+-[0-9]+)\\.[^./]+\\.plex\\.direct(:[0-9]+)?(/.*)", url)
    if not m:
        return url
    ip = m.group(1).replace("-", ".")
    port = (m.group(2) or ":32400").lstrip(":")
    path = m.group(3)
    return f"http://{ip}:{port}{path}"

'''

src = src.replace("def cover_url(", func + "def cover_url(")
src = src.replace(
    "    if artwork_url:\n        # docs/06 adds dashed-IP unwrapping for Plex-proxied URLs here.\n        return artwork_url",
    "    if artwork_url:\n        return unwrap_plex_direct(artwork_url)",
)

with open(path, "w") as f:
    f.write(src)
print("  Patched daemon with unwrap_plex_direct().")
PYEOF

python3 - "$SL_META_PHP" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

marker = "// docs/06 adds dashed-IP unwrapping for Plex-proxied URLs here."
if marker not in src:
    print("  Marker not found in sl-meta.php — insert the unwrap logic by hand per docs/06.", file=sys.stderr)
    sys.exit(0)

func = '''function unwrap_plex_direct($url) {
    // Rebuild a plain-HTTP LAN URL from a *.plex.direct imageproxy
    // redirect target, avoiding a public-DNS dependency for local
    // artwork. See docs/06-plexamp-integration.md.
    if (preg_match('#([0-9]+-[0-9]+-[0-9]+-[0-9]+)\\.[^./]+\\.plex\\.direct(:[0-9]+)?(/.*)#', $url, $m)) {
        $ip = str_replace('-', '.', $m[1]);
        $port = $m[2] !== '' ? ltrim($m[2], ':') : '32400';
        return "http://$ip:$port" . $m[3];
    }
    return $url;
}

'''

src = src.replace("function cover_url(", func + "function cover_url(")
src = src.replace(
    "    if ($artworkUrl) {\n        // docs/06 adds dashed-IP unwrapping for Plex-proxied URLs here.\n        return $artworkUrl;\n    }",
    "    if ($artworkUrl) {\n        return unwrap_plex_direct($artworkUrl);\n    }",
)

with open(path, "w") as f:
    f.write(src)
print("  Patched sl-meta.php with unwrap_plex_direct().")
PYEOF

php -l "$SL_META_PHP" || { echo "php -l failed on $SL_META_PHP — restoring backup." >&2; cp "$BACKUP_DIR/sl-meta.php.orig" "$SL_META_PHP"; exit 1; }
python3 -c "import ast; ast.parse(open('$DAEMON').read())" || { echo "Python syntax check failed on $DAEMON — restoring backup." >&2; cp "$BACKUP_DIR/moode-sl-meta.orig" "$DAEMON"; exit 1; }

systemctl restart moode-sl-meta.service 2>/dev/null || true

echo
echo "Verify BOTH consumers show correct artwork for a hub-streamed track"
echo "before trusting this — see docs/06-plexamp-integration.md ('Keep both"
echo "consumers' artwork logic in sync')."
echo
echo "Backups: $BACKUP_DIR"

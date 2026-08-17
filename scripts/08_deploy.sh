#!/usr/bin/env bash
# ============================================================================
# Step 8 (optional): Deploy the web bundle to the public host
# ============================================================================
# Rsyncs data/viz/web/ to DEPLOY_TARGET, data first and index.html last, so
# a new month is complete on the host before anything points at it.
#
# data/<month>/ is immutable (new month = new directory), so no --delete is
# passed and a month is never rewritten in place. Instead, after a successful
# deploy the newest KEEP_MONTHS month directories are kept and the rest are
# removed: ~96% of a bundle is the per-hex series, which every build ships
# complete for the full history, so an older month duplicates what the current
# one already carries. KEEP_MONTHS=2 (default) leaves the previous month for a
# rollback; 0 disables pruning and lets months accumulate at ~2.8 GB each.
#
# Usage:  scripts/08_deploy.sh user@host:/path [ssh-port]
#         (or set DEPLOY_TARGET / DEPLOY_PORT / KEEP_MONTHS — via the
#         environment or a gitignored .deploy.env in the repo root;
#         port defaults to 22)
#
# The host must serve the .gz siblings in place of the .bin files, answer
# range requests (the per-hex series files are read with Range: bytes=),
# cache data/ far-future and index.html not at all. These requirements are
# part of the bundle format contract — see lufterl-map/FORMAT.md §Host
# requirements; the blocks below are its reference implementations.
#
# Caddy — what the reference deployment runs:
#
#   :PORT {
#     root * /path/to/target
#     header /data/* Cache-Control "public, max-age=31536000, immutable"
#     @entry path / /index.html
#     header @entry Cache-Control "no-cache"
#     file_server {
#       precompressed gzip                 # serves the .gz siblings
#     }
#   }
#
# nginx, equivalently:
#
#   location /no2/ {
#     root /var/www;                       # -> /var/www/no2/...
#     location ~ \.bin$ {
#       gzip_static on;                    # serves the .gz siblings
#       expires max;
#       add_header Cache-Control "public, immutable";
#     }
#     location ~ /index\.html$ {
#       add_header Cache-Control "no-cache";
#     }
#   }
# ============================================================================
set -euo pipefail

SRC="$(dirname "$0")/../data/viz/web/"
ENV_FILE="$(dirname "$0")/../.deploy.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

TARGET="${1:-${DEPLOY_TARGET:-}}"
PORT="${2:-${DEPLOY_PORT:-22}}"

if [[ -z "$TARGET" ]]; then
  echo "No deploy target — pass user@host:/path or set DEPLOY_TARGET." >&2
  exit 1
fi

if [[ ! -f "$SRC/index.html" ]]; then
  echo "No web bundle at $SRC — run scripts/06_viz.R first." >&2
  exit 1
fi

# Deploy only on green (set -e aborts on red); SKIP_SMOKE=1 to bypass
if [[ "${SKIP_SMOKE:-0}" != 1 ]]; then
  node "$(dirname "$0")/09_smoketest.js"
fi

# data first (new month appears fully before the new index.html points at it)
rsync -av -e "ssh -p $PORT" --exclude index.html "$SRC" "$TARGET/"
rsync -av -e "ssh -p $PORT" "$SRC/index.html" "$TARGET/index.html"
echo "Deployed to $TARGET"

# --- Retention: drop month directories the shell no longer points at ---------
# Runs only after both rsyncs succeeded, so a failed deploy never prunes. The
# month just deployed is excluded explicitly, on top of being newest.
KEEP_MONTHS="${KEEP_MONTHS:-2}"

# Tolerates an unmatched glob: under `set -e` a bare `ls` on an empty data/
# would fail the script after both rsyncs had already succeeded — a red run on
# a good deploy. With no local month there is nothing to name as current, so
# the guard below skips rather than pruning blind.
NEWEST="$(ls -1d "$SRC"data/*/ 2>/dev/null | sort | tail -1)"
CURRENT="${NEWEST%/}"; CURRENT="${CURRENT##*/}"

if [[ "$KEEP_MONTHS" -gt 0 && "$TARGET" == *:* && -n "$CURRENT" ]]; then
  ssh -p "$PORT" "${TARGET%%:*}" bash -s -- "${TARGET#*:}" "$KEEP_MONTHS" "$CURRENT" <<'REMOTE'
root=$1; keep=$2; current=$3
cd "$root/data" 2>/dev/null || exit 0
stale=$(ls -1d 20[0-9][0-9]-[01][0-9] 2>/dev/null | sort -r | tail -n +$((keep + 1)))
[ -z "$stale" ] && exit 0
printf '%s\n' "$stale" | while IFS= read -r d; do
  [ "$d" = "$current" ] && continue
  [ -d "$d" ] || continue
  printf 'retention: removing %s (%s)\n' "$d" "$(du -sh "$d" | cut -f1)"
  rm -rf -- "$d"
done
REMOTE
fi

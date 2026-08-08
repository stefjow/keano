#!/usr/bin/env bash
# ============================================================================
# Step 8 (optional): Deploy the web bundle to the public host
# ============================================================================
# Rsyncs data/viz/web/ to DEPLOY_TARGET, data first and index.html last, so
# a new month is complete on the host before anything points at it.
#
# data/<month>/ is immutable (new month = new directory) and no --delete is
# passed, so past months stay on the host after index.html moves on. Nothing
# links to them once the shell points at the newer month — pruning is a
# manual decision for now (~2.8 GB per month).
#
# Usage:  scripts/08_deploy.sh user@host:/path [ssh-port]
#         (or set DEPLOY_TARGET / DEPLOY_PORT — via the environment or a
#         gitignored .deploy.env in the repo root; port defaults to 22)
#
# The host must serve the .gz siblings in place of the .bin files, answer
# range requests (the per-hex series files are read with Range: bytes=),
# cache data/ far-future and index.html not at all.
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

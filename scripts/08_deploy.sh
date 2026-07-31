#!/usr/bin/env bash
# ============================================================================
# Step 8 (optional): Deploy the web bundle to the public host
# ============================================================================
# Rsyncs data/viz/web/ to DEPLOY_TARGET. data/<month>/ directories are
# immutable (new month = new directory), so --delete only ever removes
# months you decided to drop, and index.html is replaced atomically last.
#
# Usage:  scripts/08_deploy.sh [user@host:/path]   (or set DEPLOY_TARGET)
#
# nginx for the target directory:
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
TARGET="${1:-${DEPLOY_TARGET:-}}"

if [[ -z "$TARGET" ]]; then
  echo "No target. Usage: scripts/08_deploy.sh user@host:/var/www/no2" >&2
  exit 1
fi
if [[ ! -f "$SRC/index.html" ]]; then
  echo "No web bundle at $SRC — run scripts/06_viz.R first." >&2
  exit 1
fi

# data first (new month appears fully before the new index.html points at it)
rsync -av --exclude index.html "$SRC" "$TARGET/"
rsync -av "$SRC/index.html" "$TARGET/index.html"
echo "Deployed to $TARGET"

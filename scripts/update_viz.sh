#!/usr/bin/env bash
# ============================================================================
# Vendor the lufterl-map build artifacts into this repo
# ============================================================================
# The web app lives in the lufterl-map repo; this pipeline consumes its build
# as three committed files, so a pipeline checkout runs without node/vite:
#   viz/template.html       app shell (placeholders intact; 06_viz.R splices it)
#   scripts/09_smoketest.js the smoke test (run_all.R / 08_deploy.sh gate on it)
#   viz/VIZ_VERSION         provenance (git describe of the lufterl-map build)
# Source checkout: $NO2_MAP_DIR, default ../lufterl-map next to this repo.
# After vendoring: rebuild the bundles (scripts/06_viz.R) and commit the three
# files together.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${NO2_MAP_DIR:-$HERE/../lufterl-map}"
[[ -f "$SRC/package.json" ]] || {
  echo "no lufterl-map checkout at $SRC — set NO2_MAP_DIR" >&2; exit 1; }

( cd "$SRC" && npm ci --silent && npm run build )

OLD="$(cat "$HERE/viz/VIZ_VERSION" 2>/dev/null || echo none)"
cp "$SRC/dist/template.html" "$HERE/viz/template.html"
cp "$SRC/dist/smoketest.js"  "$HERE/scripts/09_smoketest.js"
cp "$SRC/dist/VERSION"       "$HERE/viz/VIZ_VERSION"
echo "vendored lufterl-map: $OLD -> $(cat "$HERE/viz/VIZ_VERSION")"

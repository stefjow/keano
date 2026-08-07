# ============================================================================
# keano: full pipeline
# ============================================================================
# Incremental by design — safe to rerun after each new monthly release:
# 01 downloads only missing months, 03 aggregates only missing months,
# 04/05 recompute causally (identical history) from the archive.
# Script 02 runs only when the lookup does not exist yet.
# ============================================================================

source("scripts/01_download.R")

if (!file.exists(file.path("data/lookup", "pixel_cell.parquet"))) {
  source("scripts/02_build_lookup.R")
}

source("scripts/03_build_panel.R")
source("scripts/04_metrics.R")
source("scripts/05_rankings.R")
source("scripts/06_viz.R")

# Gate: drive the freshly built web bundle in headless Chrome before anything
# ships (needs `npm install` once; SKIP_SMOKE=1 in 08_deploy.sh to bypass there)
if (system2("node", "scripts/09_smoketest.js") != 0L)
  stop("Smoke test failed — fix the web bundle before publishing/deploying.")

source("scripts/07_publish.R")

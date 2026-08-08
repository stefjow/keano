# ============================================================================
# keano configuration
# ============================================================================
# Design decisions behind these parameters are documented in README.md.
# Rankings/composites are derived views; the panel and metric definitions
# below are the append-only, history-consistent core.
# ============================================================================

source("_share.r")

# --- Paths ------------------------------------------------------------------
# DATA_RAW and PUBLISH_DIR live on infrastructure outside this repo; set
# KEANO_DATA_RAW / KEANO_PUBLISH_DIR in .Renviron (gitignored). Lazy so
# scripts that don't touch the share (04-06) run without them.
env_path = function(var) {
  val = Sys.getenv(var)
  if (!nzchar(val)) stop(var, " is not set — add it to .Renviron")
  val
}
delayedAssign("DATA_RAW", env_path("KEANO_DATA_RAW"))  # append-only archive of monthly global GeoTIFFs (network share)
DATA_CACHE    = "data/raw_cache" # local staging copy for compute (safe to delete)
DATA_LOOKUP   = "data/lookup"    # one-time pixel -> H3 lookup + cell table
DATA_PANEL    = "data/panel"     # hive parquet: month=YYYY-MM/shard=<h3res0>
DATA_METRICS  = "data/metrics"   # hive parquet: shard=<h3res0>
DATA_RANKINGS = "data/rankings"  # derived views (CSV)
DATA_VIZ      = "data/viz"       # self-contained HTML map (derived view)
delayedAssign("PUBLISH_DIR", env_path("KEANO_PUBLISH_DIR"))  # published views (network share)
TMP_DIR       = "tmp"            # diagnostics, previews

# --- Data source ------------------------------------------------------------
S5P_COLLECTION = "terrascope-s5p-l3-no2-tm-v2"  # monthly global L3 NO2, µmol/m²
BBOX_GLOBAL    = c(-180, -85, 180, 85)           # Web-Mercator-compatible band
START_DATE     = "2018-05-01"                    # product start
END_DATE       = format(Sys.Date(), "%Y-%m-%d")

# --- Grid -------------------------------------------------------------------
H3_RESOLUTION    = 6   # ~36 km² hexagons; ~7 native 0.02° pixels per hex
SHARD_RESOLUTION = 0   # panel/metrics partition key: res-0 parent (122 shards)

# --- Compute ------------------------------------------------------------------
N_WORKERS = 32  # parallel workers for lookup/panel/metrics/rankings

# --- Metrics (causal; see README "History consistency") ----------------------
WINDOW_MONTHS           = 12    # trailing mean window; deseasonalizes by construction
MIN_MONTHS_IN_WINDOW    = 10    # required non-NA months, else m = NA
BASELINE_WINDOW_MONTHS  = 60    # expiring baseline: lowest m of the last 5 years...
BASELINE_EXCLUDE_MONTHS = 12    # ...excluding the freshest year, so the baseline
                                # doesn't chase m downward month by month (steady
                                # improvers must be able to clear the margin)
CREDIT_MARGIN           = 0.02  # relative undercut must exceed this noise gate
NO2_FLOOR               = 30    # µmol/m²; cells with m below are not eligible

# --- Sanity gate (script 05) --------------------------------------------------
# A new month must clear these before anything is built or published. Set from
# the observed history, not guessed — see sanity_findings() in _share.r for the
# measured ranges each one sits outside.
SANITY_COVERAGE_TOL = 0.15  # |n_cells_obs / trailing-12-month median - 1|
SANITY_ELIGIBLE_TOL = 0.15  # |n_eligible / previous month - 1|
SANITY_PERF_ABS     = 0.25  # |mean perf_short| among eligible cells
SANITY_PERF_STEP    = 0.15  # |month-over-month change| in that mean

# --- Derived views ------------------------------------------------------------
TOP_N = 100  # rows in the monthly top-credit ranking

# Month bundles under data/viz/web/data/ to keep (script 06, and the same
# default for the deploy host via KEEP_MONTHS). A bundle is ~2.8 GB and ~96%
# of it is the per-hex series, which every build regenerates for the full
# history — an older bundle duplicates what the newest one already carries,
# and its month-specific planes rebuild from the panel. 2 keeps the previous
# month around for a rollback; 0 disables pruning.
VIZ_KEEP_MONTHS = 2

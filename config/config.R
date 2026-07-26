# ============================================================================
# keano configuration
# ============================================================================
# Design decisions behind these parameters are documented in README.md.
# Rankings/composites are derived views; the panel and metric definitions
# below are the append-only, history-consistent core.
# ============================================================================

source("_share.r")

# --- Paths ------------------------------------------------------------------
DATA_RAW      = "data/raw"       # append-only archive of monthly global GeoTIFFs
DATA_LOOKUP   = "data/lookup"    # one-time pixel -> H3 lookup + cell table
DATA_PANEL    = "data/panel"     # hive parquet: month=YYYY-MM/shard=<h3res0>
DATA_METRICS  = "data/metrics"   # hive parquet: shard=<h3res0>
DATA_RANKINGS = "data/rankings"  # derived views (CSV)
TMP_DIR       = "tmp"            # diagnostics, previews

# --- Data source ------------------------------------------------------------
S5P_COLLECTION = "terrascope-s5p-l3-no2-tm-v2"  # monthly global L3 NO2, µmol/m²
BBOX_GLOBAL    = c(-180, -85, 180, 85)           # Web-Mercator-compatible band
START_DATE     = "2018-05-01"                    # product start
END_DATE       = format(Sys.Date(), "%Y-%m-%d")

# --- Grid -------------------------------------------------------------------
H3_RESOLUTION    = 6   # ~36 km² hexagons; matches native ~0.05° pixel size
SHARD_RESOLUTION = 0   # panel/metrics partition key: res-0 parent (122 shards)

# --- Metrics (causal; see README "History consistency") ----------------------
WINDOW_MONTHS           = 12    # trailing mean window; deseasonalizes by construction
MIN_MONTHS_IN_WINDOW    = 10    # required non-NA months, else m = NA
BASELINE_WINDOW_MONTHS  = 60    # expiring baseline: lowest m of the last 5 years...
BASELINE_EXCLUDE_MONTHS = 12    # ...excluding the freshest year, so the baseline
                                # doesn't chase m downward month by month (steady
                                # improvers must be able to clear the margin)
CREDIT_MARGIN           = 0.02  # relative undercut must exceed this noise gate
NO2_FLOOR               = 30    # µmol/m²; cells with m below are not eligible

# --- Derived views ------------------------------------------------------------
TOP_N = 100  # rows in the monthly top-credit ranking

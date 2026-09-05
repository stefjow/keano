# ============================================================================
# Lichterloh configuration
# ============================================================================
# Design decisions behind these parameters are documented in README.md.
# Rankings/composites are derived views; the panel and metric definitions
# below are the append-only, history-consistent core.
# ============================================================================

source("_share.r")

# --- Identity ---------------------------------------------------------------
# Single source of truth for the display name. Script 06 splices PROJECT_NAME
# into viz/template.html wherever the template prints __NAME__ (title,
# wordmark, About text), so a rebrand is one line here + a viz rebuild.
# NOT auto-propagated — grep and edit these too when renaming:
#   * prose in README.md / ROADMAP.md / notes/ and this file's comments
#   * package.json + package-lock.json ("name")
#   * the NO2_* env-var prefix (config keys; kept brand-neutral on purpose)
#   * the git remotes / GitHub repo name / the working-copy directory
PROJECT_NAME = "Lichterloh"

# --- Basemap ----------------------------------------------------------------
# Carto Basemaps API key (carto.com/basemaps/apikey; free up to 5M tile
# requests a month, CARTO + OpenStreetMap attribution must stay visible).
# Script 06 splices it into the map's tile URLs (__CARTO_KEY__ in
# viz/template.html); without it Carto serves the tiles with an "API key
# required" watermark. The key is public in the deployed page by nature but
# must not sit in this (public) repo — set NO2_CARTO_KEY in .Renviron.
CARTO_KEY = Sys.getenv("NO2_CARTO_KEY")

# --- Paths ------------------------------------------------------------------
# DATA_RAW and PUBLISH_DIR live on infrastructure outside this repo; set
# NO2_DATA_RAW / NO2_PUBLISH_DIR in .Renviron (gitignored). Lazy so
# scripts that don't touch the share (04-06) run without them.
env_path = function(var) {
  val = Sys.getenv(var)
  if (!nzchar(val)) stop(var, " is not set — add it to .Renviron")
  val
}
delayedAssign("DATA_RAW", env_path("NO2_DATA_RAW"))  # append-only archive of monthly global GeoTIFFs (network share)
DATA_CACHE    = "data/raw_cache" # local staging copy for compute (safe to delete)
DATA_LOOKUP   = "data/lookup"    # one-time pixel -> H3 lookup + cell table
DATA_PANEL    = "data/panel"     # hive parquet: month=YYYY-MM/shard=<h3res0>
DATA_METRICS  = "data/metrics"   # hive parquet: shard=<h3res0>
DATA_RANKINGS = "data/rankings"  # derived views (CSV)
DATA_VIZ      = "data/viz"       # self-contained HTML map (derived view)
delayedAssign("PUBLISH_DIR", env_path("NO2_PUBLISH_DIR"))  # published views (network share)
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

# Window for the medium-horizon trend layer (perf_5y). Same 60 months as the
# credit baseline, but deliberately its OWN constant: that one is the credit
# expiry, and changing it must not silently redefine a display layer.
# Why it exists alongside perf_long: perf_long anchors on the cell's first year
# and its window therefore grows forever (7.2 years as of 2026-06). Measured on
# 58k eligible cells, the two disagree by more than 1pp/yr for 66% of cells and
# on the direction of travel for 11.4% — perf_long averages in the 2019-2021
# COVID dip and rebound, so it understates recent progress by ~1.6pp/yr.
TREND_WINDOW_MONTHS     = 60
# The reference month is allowed to be this far off TREND_WINDOW_MONTHS. Demanding
# m at exactly t-60 leaves the layer blank wherever that one month is missing,
# which at high latitude is most cells: polar night pushes the observed count in
# the 12-month window below MIN_MONTHS_IN_WINDOW, and marginal cells flip in and
# out year to year. Measured on the exact-60 rule, only 4% of cells with an m
# today at 75degN and 45% at 60degN also had one in 2021-06, and perf_5y coverage
# tracked that exactly. So take the nearest available month instead and annualise
# by the real gap — the same thing perf_long does with its floating anchor, which
# is why perf_long has no holes. 0 restores the strict behaviour.
TREND_WINDOW_SLACK      = 6

# --- The shipped credit rule (credit_v3) ---------------------------------------
# Script 04 computes three generations side by side; only the newest is read
# downstream. These constants drive v2 and v3 both — v3 differs from v2 only in
# what the undercut is measured against, not in any parameter, so nothing here
# is duplicated per version.
#
# The baseline window is NOT held back a year: it ends at t-1, so a cell must
# undercut its own most recent low, not a low that has had a year to age.
# Consequence, measured and exact: a cell's lifetime credit telescopes to
# log(m_first / m_last) — paid once per unit of reduction, independent of pace
# or path — instead of paying the cumulative gap every month until the baseline
# catches up. Totals come out ~6x smaller for that reason, which is a change of
# unit, not of coverage.
#
# v3 then measures against the level the cell was last *paid* at rather than the
# lowest it has been, so a descent taken in steps each below the margin
# accumulates instead of being discarded. Measured: telescoping ratio 0.77 ->
# 0.87, ~12% more credit, to exactly the same set of cells. It also turns the
# plume guard into a deferral rather than a forfeit. See carry_credit() in
# scripts/04_metrics.R.
#
# EXCLUDE must be >= 1: at 0 the window contains the current month, the baseline
# is <= m by construction, and no cell can ever earn.
#
# The margin is retuned because the comparison changed. 2% was calibrated
# against a baseline at least a year old; measured on flat-trend cells, the p95
# of |1-month change in log m| is 1.63x smaller than the 12-month one, so the
# equivalent gate is 2% / 1.63 ~= 1.2%.
#
# The parent ramp is deliberately NOT tied to the margin (v1 shares one constant
# for both). Narrowing it with the margin would sharpen the plume guard just as
# v2 makes it less necessary — under v2 a wind-driven fluke is paid once and
# then becomes the cell's own baseline, where under v1 it collects for a year.
#
# Computed alongside `credit`, never instead of it: v1 columns are untouched, so
# the append-only contract still holds and both rules can be compared on real
# data before anything is switched.
CREDIT_V2_EXCLUDE_MONTHS = 1L    # baseline window ends at t-1, not t-12
CREDIT_V2_MARGIN         = 0.012 # retuned noise gate (see above)
CREDIT_V2_PARENT_RAMP    = 0.02  # plume-guard ramp half-width, kept at v1's

# --- Seasonal-coverage gate (credit_v4, prototype) -----------------------------
# A 12-month mean is only deseasonalized when the window actually covers the
# seasonal cycle. A window can clear MIN_MONTHS_IN_WINDOW by count and still be
# missing the *peak* months — high-latitude winters drop out of the retrieval
# (snow, low sun) in some years and not others — which biases m low and mints
# artificial record lows the moment the series resumes (measured: the all-time
# res-6 leader near Edmonton took a third of its total, a 25% "undercut", from
# a window missing Dec+Jan ≈ half its annual NO₂).
#
# The gate weighs a window's unobserved months by the cell's own causal
# climatology: the mean of its PAST observations of that calendar month. A
# month never observed before carries no weight, so structurally dark polar
# cells — whose windows miss the same months every year and stay comparable —
# are exempt. gap_share is the climatological share of the window the cell did
# not see:
#   gap_share > GAP_SHARE_M      -> the mean is not credible as a level: m = NA
#                                   (the artifact windows here score ~0.5)
#   gap_share > GAP_SHARE_CREDIT -> m renders, but no credit is paid that
#                                   month; the undercut stays banked and pays
#                                   at the next well-covered month (the same
#                                   deferral the plume guard uses)
GAP_SHARE_M      = 0.25
GAP_SHARE_CREDIT = 0.05
# The v4 parent (plume-guard) series averages the gated m over each res-4
# region's children — and when the gate blanks children unevenly, a month's
# mean over the surviving subset is not the same region (measured: 22 of 49
# children, mean 28.3 vs 36.5 with the full roster a month later; that subset
# low would sit in the parent baseline and block the guard for five years).
# So the parent mean only counts when at least this share of the region's
# largest-ever contributing roster is present; months below it are NA and the
# guard falls back to full weight, the same convention as an undefined parent.
PARENT_MIN_COVER = 0.8

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

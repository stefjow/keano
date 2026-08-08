# keano

**Global hexagonal NO₂ reduction panel and credit system.**

keano tracks tropospheric NO₂ for every H3 hexagon on the planet and scores
each cell's short- and long-term reduction performance. Cells earn *credits*
by undercutting their own historical minimum — the basis for a possible
incentive-driven system. Successor to the city-based
[camsmap](../camsmap) experiment, built on the data pipeline ideas from
[tropomi-timelapse](../tropomi-timelapse) and [vienna_no2](../vienna_no2).

## Design decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Data source | Terrascope S5P L3 **monthly** global NO₂ (`terrascope-s5p-l3-no2-tm-v2`, 0.02°) | One global GeoTIFF per month since 2018-05; QA-filtered upstream (qa > 0.75); right cadence for trends |
| Weights | **Spatial only**: hex means are weighted by the L3 coverage weight (`NO2_WEIGHT`); the 12-month window in `m` stays unweighted | Within-hex coverage varies sharply at the winter twilight edge (measured p95 estimator difference 1.1% on eligible cells vs. the 2% credit margin), so the weighted hex mean matters. Coverage-weighting *months* (as tropomi-timelapse does) would break `m`'s deseasonalization-by-construction — summers are systematically better observed, and coverage trends would alias into NO₂ trends. The polar-night case is handled by NA-dropping + `MIN_MONTHS_IN_WINDOW` instead |
| Grid | H3 resolution 6 (~36 km², ~3.7 km edge) | Fine enough to see structure *within* cities; ~7 native 0.02° pixels per hex |
| Workhorse series | `m` = trailing 12-month mean of monthly NO₂ | Deseasonalized *by construction* (full-year window); smooths retrieval noise; causal |
| Short-term score | `perf_short` = YoY change of `m` | Causal, comparable across cells |
| Long-term score | `perf_long` = annualized change of `m` vs. the cell's first full year | Causal |
| Credit baseline | Own-history minimum of `m` over the window **t−60 … t−12 months** ("best year that ended at least a year ago") | Expiring ratchet without the COVID trap: records age out after 5 years, so every cell periodically has something to earn. Excluding the freshest year keeps the baseline from chasing `m` down month by month — steady improvers keep clearing the margin (total credit ≈ proportional to total reduction, fast or slow), while a one-off drop stops earning once its low year ages into the baseline |
| Credit | Relative undercut `(B − m)/B`, gated at a **2% noise margin** | %-based, so clean and dirty cells compete symmetrically; margin avoids paying for retrieval noise |
| Credit weighting | Cell credit × `clamp01((U₄ + margin)/(2·margin))`, where `U₄` is the res-4 parent's (~1,770 km², mean of children `m`) undercut of its own identically constructed baseline | NO₂ is transport-driven at 36 km² (lifetime ~hours, plumes travel tens of km): a cell can hit a record low because this year's winds moved the neighbour's plume, not because anyone reduced. Full credit only when the neighbourhood is also ≥ margin below its baseline; zero when it is ≥ margin above. City-wide improvements pass untouched (parent moves with the cells); isolated implausible records don't — measured on real data, 5 of the June-2026 top 15 sat on parents 24–126% *above* baseline and are zeroed, while 84–96% of monthly credit volume is retained. `is_record` stays unweighted (the record is a fact; the payout is conditioned) |
| Eligibility | `m ≥ NO2_FLOOR` (default 30 µmol/m²) | %-changes are meaningless at background noise level; panel still keeps all cells (shipping lanes included) |

### History consistency (append-only contract)

Every score for month *t* uses only data up to *t*. New months **append**
rows; closed months never change. Three rules keep that true:

1. `data/raw/` is an **append-only archive** — the download script only
   requests months newer than the newest archived file and never overwrites.
   If Terrascope ever reprocesses the product, keep scoring from the archived
   vintage.
2. All metric definitions are causal, so recomputing the full history from
   the archive reproduces identical past values.
3. Script 01 records each archived file's upstream vintage in `vintage.csv`
   beside the archive — `processing:version`, the item's `created` and
   `updated`, and the asset's declared size — and re-checks it every run.
   Rule 1 keeps the right bytes but would never *tell* anyone upstream had
   moved, and Terrascope does reprocess: one campaign shifted `updated` and
   left `created` alone, another deleted and recreated the items so both
   moved. Recorded rows are never rewritten, so drift stays visible until
   someone re-vintages on purpose. On a mismatch the run **stops with a
   non-zero exit** — the archive stays authoritative and is never
   redownloaded, but choosing between keeping the old vintage and rebasing
   the history is a decision for a person, not for a timer. The same
   manifest catches a truncated or corrupted archive file, by checking the
   recorded size against the bytes on disk. `KEANO_VINTAGE_ACK=1`
   acknowledges and continues.

## Pipeline

```
scripts/01_download.R      Terrascope monthly GeoTIFFs (NO2 + weight) -> data/raw/ (append-only)
scripts/02_build_lookup.R  one-time: pixel centers -> H3 res-6 cells -> data/lookup/
scripts/03_build_panel.R   per new month: raster -> per-cell means -> data/panel/ (hive parquet)
scripts/04_metrics.R       per shard: m, perf_short, perf_long, baseline, credit -> data/metrics/
scripts/05_rankings.R      derived views: monthly records, top credits, summaries -> data/rankings/
scripts/06_viz.R           latest month -> interactive H3 hexagon map -> data/viz/index.html
scripts/07_publish.R       map + rankings CSVs + README -> PUBLISH_DIR (network share)
scripts/09_smoketest.js    gate: drives the built web bundle in headless Chrome
```

The panel is partitioned `month=YYYY-MM/shard=<h3-res0-parent>` so both
access patterns are cheap: append one month, or read one shard's full
history. Metrics are computed shard by shard (~115k cells × all months per
shard), so nothing ever needs the full ~1.3-billion-row panel in RAM.

Run everything: `Rscript run_all.R` (or source the scripts in order).
Scripts 01/03 are incremental — rerunning after a new month is published
downloads and processes just that month. Scripts 04/05 recompute from the
archive; causality guarantees the history comes out identical.

## Requirements

R ≥ 4.0 with `terrascoper` (Terrascope STAC download, with credentials
configured), plus CRAN packages `terra`, `data.table` (≥ 1.16 for
`frollmax`), `h3jsr`, `arrow`, `sf` — auto-installed via `loadPackages()`.

Storage: ~22 GB raw GeoTIFFs (95+ months, ~222 MB NO2 + ~9 MB weight each),
a few GB parquet.

### Configuration outside the repo

Credentials and the paths that name infrastructure are kept out of version
control. R reads `.Renviron` in the repo root (gitignored) at startup:

```
TERRASCOPE_USER=...       # Terrascope account, used by terrascoper (script 01)
TERRASCOPE_PASS=...
KEANO_DATA_RAW=...        # append-only GeoTIFF archive       (scripts 01-03)
KEANO_PUBLISH_DIR=...     # published derived views           (script 07)
```

`config/config.R` binds the two paths lazily, so a missing one is an error
only in the scripts that actually touch it — 04, 05 and 06 (metrics,
rankings, map) run with neither set.

`scripts/08_deploy.sh` takes its rsync destination from a gitignored
`.deploy.env` in the repo root (or from the environment, or as positional
arguments):

```
DEPLOY_TARGET=user@host:/path
DEPLOY_PORT=22
KEEP_MONTHS=2             # month directories to keep on the host (0 = never prune)
```

Each machine carries its own copy of both files. Neither is in any
repository, so back them up somewhere durable — a lost clone takes the only
copy of these values with it.

## Tuning knobs

All in `config/config.R`: `H3_RESOLUTION`, `WINDOW_MONTHS`,
`BASELINE_WINDOW_MONTHS`, `CREDIT_MARGIN`, `NO2_FLOOR`, `TOP_N`, and
`N_WORKERS` (scripts 02–05 parallelize over chunks/months/shards).
Rankings and composites are **derived views** — they can be redefined at any
time without touching the stored panel or metric history. So is the map:
script 06 renders it (MapLibre + h3-js, dark basemap) with res-3 hexagons
globally — each carrying its full monthly `m` series, shown as a mouse-over
trend panel — and full-coverage res-4/5/6 tiers as you zoom in (~0.3M /
1.8M / 12.4M cells), with layers for NO₂ level, YoY, long-term trend, and
credit. No per-cell ids, coordinates or geometry are shipped: each tier is
a per-res-3-parent occupancy bitmap plus delta-encoded quantized metric
planes, and the browser reconstructs H3 ids and hexagon outlines for the
current viewport only. One template, two builds:

* **`data/viz/index.html`** — single file, everything zlib-compressed and
  base64-embedded (~47 MB). For the network share, where no HTTP server
  exists; open it straight from the filesystem.
* **`data/viz/web/`** — for public hosting: a small app shell plus binary
  files fetched on demand (res-3 core ~1.4 MB up front; monthly series,
  res-4/5 tiers lazily; res-6 planes chunked by res-1 parent, ~50 KB per
  chunk, viewport-driven). Every `.bin` has a precompressed `.gz` sibling
  the host serves directly (`gzip_static` on nginx, `precompressed gzip` on
  Caddy); `data/<month>/` paths are immutable, so far-future cache headers
  apply, while `index.html` stays `no-cache`. The per-hex series files
  (`s4/s5/s6.bin`) are read with HTTP range requests, so the host has to
  answer 206. Deploy with `scripts/08_deploy.sh` (config for both servers
  in its header; the reference deployment runs Caddy). Only the newest month
  is ever referenced, so build and deploy each keep the newest few bundles
  (`VIZ_KEEP_MONTHS` / `KEEP_MONTHS`, default 2 — the second for rollback)
  and drop the rest: ~96% of a bundle is the per-hex series that every build
  reships for the full history, and the remaining ~108 MB of month-specific
  planes rebuilds from the panel.

Both `run_all.R` and the deploy script gate on `scripts/09_smoketest.js`: it
serves `data/viz/web/` locally and drives it in headless Chrome — hover /
pin / release, hex and viewport deep links, chart instances, zero page
errors — once with a hover-capable pointer and once as a touch device.
Needs `npm install` (puppeteer-core) and a Chrome under `~/.cache/puppeteer`
or `PUPPETEER_EXECUTABLE_PATH`; `SKIP_SMOKE=1` bypasses the deploy gate.

Script 05 gates the *numbers* the way the smoke test gates the *map* — a
wrong month renders into a perfectly working map, so passing one proves
nothing about the other. A new month must clear bounds taken from the
observed history (coverage against its own trailing-12-month median,
eligible cells against the previous month, the level and one-month step of
mean `perf_short`), set roughly 3× outside anything seen in 98 months so an
unusual month passes and a broken one does not. The same check re-verifies
rule 2 above: every closed month must come back unchanged from the
recompute. On failure nothing is written, the previous rankings stand, the
rejected summary lands in `tmp/monthly_summary_rejected.csv`, and
`KEANO_SANITY_ACK=1` accepts it. Thresholds are in `config/config.R`.

## Planned: daily nowcast layer

The scored history is monthly by design (the monthly L3 product is the sole
source of the panel, and credits are decided at month close, like camsmap's
period-close rule). Unlike camsmap's gap-free CAMS *model* data, TROPOMI is
observational — daily values have cloud gaps — so daily data adds engagement,
not accuracy.

Planned after v1 has proven itself on real data: a **provisional
"current month" layer** fed by the daily global product
(`terrascope-s5p-l3-no2-td-v2`) — a month-to-date mean per cell, clearly
marked provisional, discarded and replaced by the official monthly value at
month close. Purely a display layer: provisional values are never written to
the panel, so the append-only contract is untouched. Only the running month's
daily files are kept. Also worth checking on the first real run: the
publication lag of the monthly product — the longer the lag, the more this
layer matters.

## Name

*ke anu* (Hawaiian) ≈ "the coolness / the cool breeze" — also readable as
**kea** + **NO**: a clever mountain parrot and the molecule family we track.

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
| Credit baseline | The level the cell was **last actually paid at**, falling back to its own minimum `m` over **t−60 … t−1** when no payment is live (never paid, or the last one is older than the 5-year expiry) | Expiring ratchet: records age out after 5 years, so every cell periodically has something to earn. Including the freshest months is what makes each reduction paid **once**: a cell has to keep beating its own best, and over a full record its credit sums to ≈ `log(m_first / m_last)` — the same total for the same total reduction, fast or slow. The window must end at t−1, not t; at t the baseline is ≤ `m` by construction and nothing can ever earn. Measuring from the last *paid* level rather than the lowest reached means a descent taken in steps each below the margin accumulates instead of being discarded — measured, that lifts the sum from 0.77 to 0.87 of `log(m_first/m_last)` and pays ~12% more to exactly the same cells. It also makes the plume guard below a deferral rather than a forfeit: a blocked undercut stays on the books until the neighbourhood check passes |
| Credit | Relative undercut `(B − m)/B`, gated at a **1.2% noise margin**, where `B` is that reference | %-based, so clean and dirty cells compete symmetrically; margin avoids paying for retrieval noise. 1.2% rather than 2% because the comparison is against a baseline that may be one month old, not a year old: measured on flat-trend cells, p95 `|Δlog m|` at lag 1 is 1.63× smaller than at lag 12, so 2% / 1.63 ≈ 1.2% |
| Credit weighting | Cell credit × `clamp01((U₄ + ramp)/(2·ramp))` with `ramp = 2%`, where `U₄` is the res-4 parent's (~1,770 km², mean of children `m`) undercut of its own identically constructed baseline. The ramp is a **separate constant from the credit margin** — narrowing it in step with the margin would sharpen the plume guard exactly as the baseline change makes it less necessary (a fluke low now becomes the cell's own baseline next month, so it is paid once instead of for a year) | NO₂ is transport-driven at 36 km² (lifetime ~hours, plumes travel tens of km): a cell can hit a record low because this year's winds moved the neighbour's plume, not because anyone reduced. Full credit only when the neighbourhood is also ≥ margin below its baseline; zero when it is ≥ margin above. City-wide improvements pass untouched (parent moves with the cells); isolated implausible records don't. It binds harder against the current baseline than it did against the year-old one — full weight on 63% of paid months rather than 79%, with 8% zeroed outright — which is the remaining reason the sum above reaches ≈ 0.87·`log(m_first/m_last)` rather than 1.00: a month paid at partial weight still resets the reference, so the unpaid fraction is forfeited. `is_record` stays unweighted (the record is a fact; the payout is conditioned) |
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
`BASELINE_WINDOW_MONTHS`, `NO2_FLOOR`, `TOP_N`, and `N_WORKERS` (scripts
02–05 parallelize over chunks/months/shards). The shipped credit rule is
`CREDIT_V2_EXCLUDE_MONTHS` / `CREDIT_V2_MARGIN` / `CREDIT_V2_PARENT_RAMP`.

### The retired credit rules

Script 04 computes three generations of the rule side by side and only the
newest is read downstream. A rule change therefore never rewrites a column
anyone has already seen, and there is always an audit trail for what was
published before.

| column set | driven by | status |
|---|---|---|
| `baseline`, `parent_under`, `credit`, `is_record` | `BASELINE_EXCLUDE_MONTHS = 12`, `CREDIT_MARGIN = 0.02` | v1, retired |
| `baseline_v2`, `parent_under_v2`, `credit_v2` | the `CREDIT_V2_*` constants | v2, retired |
| `credit_v3`, `is_record_v3` | the same `CREDIT_V2_*` constants + `carry_credit()` | **shipped** |

`monthly_summary.csv` keeps v1's totals as `*_v1`; `n_records` and
`total_credit` are always the shipped rule.

**v1** held the baseline back a year, so a cell was paid the *cumulative* gap
every month until its own low aged in. Totals ran **~6× higher** for the same
reductions, and — contrary to the intent recorded when it was designed — it
did not deliver pace-independence: measured across 48k earning cells, the new
rule's share of v1 credit is 11% for cells improving faster than 8%/yr and 16%
for cells flatter than 1%/yr, i.e. v1 systematically over-paid fast improvers.
It also kept paying for up to a year after a cell had stopped improving, which
is what prompted the change.

**v2** fixed that but discarded any step smaller than the noise margin: a
gradual descent measured from a new, lower low each month never accumulated,
so its credit summed to only 0.77 of `log(m_first/m_last)`. **v3** measures
from the last *paid* level instead, which recovers most of that (0.87) for
~12% more credit to exactly the same set of cells — a strict superset of v2's
payments, since a cell's first payment always uses the v2 baseline as its
reference.
Rankings and composites are **derived views** — they can be redefined at any
time without touching the stored panel or metric history. So is the map:
script 06 renders it (MapLibre + h3-js, dark basemap) with res-3 hexagons
globally — each carrying its full monthly `m` series, shown as a mouse-over
trend panel — and full-coverage res-4/5/6 tiers as you zoom in (~0.3M /
1.8M / 12.4M cells), with layers for NO₂ level, YoY, long-term trend, and
credit. No per-cell ids, coordinates or geometry are shipped: each tier is
a per-res-3-parent occupancy bitmap plus delta-encoded quantized metric
planes, and the browser reconstructs H3 ids and hexagon outlines for the
current viewport only.

The trend panel also marks **which months the hovered hex was actually paid
credit in**, and how much, as dots on the line itself — colour steps up the
map's credit ramp, with the count and the peak in figures under the chart and
the exact month value on hover. 98%+ of hex-months earn nothing, so this
ships as *events*, not as a per-month plane: one `(month, level)` byte pair
per payout. res-3 events are a flat sorted key list in `series.bin` (both
builds); res-4/5/6 events live in `c<r>.bin` and are addressed by a per-cell
count plane carried inside the tier's own gzipped planes — the client
prefix-sums it, so no offset table is stored or shipped. That keeps the whole
feature under 1% of the bundle. The finer tiers are web-only, like the
per-hex `m` series they annotate; in the single-file build a hex below res 3
shows its region's payouts, marked `(region)`.

One template, two builds:

* **`data/viz/index.html`** — single file, everything zlib-compressed and
  base64-embedded (~47 MB). For the network share, where no HTTP server
  exists; open it straight from the filesystem.
* **`data/viz/web/`** — for public hosting: a small app shell plus binary
  files fetched on demand (res-3 core ~1.4 MB up front; monthly series,
  res-4/5 tiers lazily; res-6 planes chunked by res-1 parent, ~50 KB per
  chunk, viewport-driven). Every `.bin` has a precompressed `.gz` sibling
  the host serves directly (`gzip_static` on nginx, `precompressed gzip` on
  Caddy); `data/<month>/` paths are immutable, so far-future cache headers
  apply, while `index.html` stays `no-cache`. The per-hex series and credit
  files (`s4/s5/s6.bin`, `c4/c5/c6.bin`) are read with HTTP range requests,
  so the host has to answer 206 — and they are the only `.bin`s without a
  `.gz` sibling, since a range into a precompressed file is meaningless.
  Deploy with `scripts/08_deploy.sh` (config for both servers
  in its header; the reference deployment runs Caddy). Only the newest month
  is ever referenced, so build and deploy each keep the newest few bundles
  (`VIZ_KEEP_MONTHS` / `KEEP_MONTHS`, default 2 — the second for rollback)
  and drop the rest: ~96% of a bundle is the per-hex series that every build
  reships for the full history, and the remaining ~108 MB of month-specific
  planes rebuilds from the panel.

Both `run_all.R` and the deploy script gate on `scripts/09_smoketest.js`: it
serves `data/viz/web/` locally (`KEANO_WEB_DIR` overrides the bundle path)
and drives it in headless Chrome — hover / pin / release, hex and viewport
deep links, chart instances, the per-hex trend line joining the region line
at fine zoom, zero page errors — once with a hover-capable pointer and once
as a touch device. A third run walks the top-regions panel: all three credit
windows, and at every tier the map draws (res 3/4/5/6) that the list follows
that tier, that `→` flies to a hex of *that* resolution instead of dropping
back to res-3, and that the hex's credit-payout markers are drawn and agree
with the summary line.
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

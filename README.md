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
| Data source | Terrascope S5P L3 **monthly** global NO₂ (`terrascope-s5p-l3-no2-tm-v2`, ~0.05°) | One global GeoTIFF per month since 2018-05; QA-filtered upstream (qa > 0.75); right cadence for trends |
| Weights | Not used | Daily/monthly mid-latitude coverage is dense; the polar-night problem the weights solve in tropomi-timelapse doesn't affect per-cell time series with NA-dropping |
| Grid | H3 resolution 6 (~36 km², ~3.7 km edge) | Fine enough to see structure *within* cities; matches native pixel size (~1–2 pixels per hex) |
| Workhorse series | `m` = trailing 12-month mean of monthly NO₂ | Deseasonalized *by construction* (full-year window); smooths retrieval noise; causal |
| Short-term score | `perf_short` = YoY change of `m` | Causal, comparable across cells |
| Long-term score | `perf_long` = annualized change of `m` vs. the cell's first full year | Causal |
| Credit baseline | Own-history minimum of `m` over the window **t−60 … t−12 months** ("best year that ended at least a year ago") | Expiring ratchet without the COVID trap: records age out after 5 years, so every cell periodically has something to earn. Excluding the freshest year keeps the baseline from chasing `m` down month by month — steady improvers keep clearing the margin (total credit ≈ proportional to total reduction, fast or slow), while a one-off drop stops earning once its low year ages into the baseline |
| Credit | Relative undercut `(B − m)/B`, gated at a **2% noise margin** | %-based, so clean and dirty cells compete symmetrically; margin avoids paying for retrieval noise |
| Eligibility | `m ≥ NO2_FLOOR` (default 30 µmol/m²) | %-changes are meaningless at background noise level; panel still keeps all cells (shipping lanes included) |

### History consistency (append-only contract)

Every score for month *t* uses only data up to *t*. New months **append**
rows; closed months never change. Two rules keep that true:

1. `data/raw/` is an **append-only archive** — the download script only
   requests months newer than the newest archived file and never overwrites.
   If Terrascope ever reprocesses the product, keep scoring from the archived
   vintage.
2. All metric definitions are causal, so recomputing the full history from
   the archive reproduces identical past values.

## Pipeline

```
scripts/01_download.R      Terrascope monthly global GeoTIFFs -> data/raw/ (append-only)
scripts/02_build_lookup.R  one-time: pixel centers -> H3 res-6 cells -> data/lookup/
scripts/03_build_panel.R   per new month: raster -> per-cell means -> data/panel/ (hive parquet)
scripts/04_metrics.R       per shard: m, perf_short, perf_long, baseline, credit -> data/metrics/
scripts/05_rankings.R      derived views: monthly records, top credits, summaries -> data/rankings/
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

Storage: ~5 GB raw GeoTIFFs (95 months), a few GB parquet.

## Tuning knobs

All in `config/config.R`: `H3_RESOLUTION`, `WINDOW_MONTHS`,
`BASELINE_WINDOW_MONTHS`, `CREDIT_MARGIN`, `NO2_FLOOR`, `TOP_N`.
Rankings and composites are **derived views** — they can be redefined at any
time without touching the stored panel or metric history.

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

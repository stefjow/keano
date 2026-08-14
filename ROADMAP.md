# Roadmap notes

Ideas collected 2026-08-07 after the ECharts / selection-model session,
extended 2026-08-08 by the provenance / hardening session, 2026-08-10 by
the tier fly-to / credit-history session and 2026-08-12 by the daily-vs-
monthly measurement session.
Rough order inside each section is by value-for-effort, not commitment.

## Shipped 2026-08-10

### credit_v3: sub-margin steps are banked, not discarded
Same day, one map question later. Cell `862d63837ffffff` hit a new low of 42.1
in 2020-12 and was paid nothing. Cause was not the plume guard (the weight was
a full 1.000) but the noise margin, by 0.04 of a percentage point: the bar was
42.6 — a low it had set in 2020-08 and never been paid for — so the step was
1.16% against a 1.2% gate.

That is v2's leak in one cell. Of 25 months where it set a new running low, 14
earned nothing, 12 of them for steps under the margin; each was discarded and
the next measured from the new lower low, so 42.8 → 42.6 → 42.1 paid nothing
across two steps even though 1.6% in one step would have cleared.

v3 measures the undercut against the level the cell was last *paid* at instead,
so those steps accumulate. Measured on two shards before implementing:

* telescoping ratio 0.77 → 0.87 of `log(m_first/m_last)`
* +12% credit, +16% paid months
* **exactly the same cells earn** — 58,701 both. Not a coincidence: a cell's
  first payment always uses the v2 baseline as its reference, so v3 can only
  top up cells that were already earning.
* Spearman 0.992 on per-cell totals, 83% of the top-1000 retained

An effect that was not the goal: because the reference resets only when credit
was actually *paid*, a month the plume guard zeroed leaves its undercut on the
books. The guard became a deferral rather than a forfeit — visible on that same
cell, where 2021-01's guard-blocked 3.55% is recovered in 2021-02 at 10.99%.

The residual 13% is partial-weight months: paid at `u × w` but the reference
still resets, so the `(1 − w)` fraction is forfeited. Fixable by resetting
proportionally; not worth the complexity.

Shipped the same way as before — computed beside v1 and v2, both verified
byte-identical first, then the readers flipped. Gate fired once on 84 closed
months and only on the two credit columns; the *_v1 audit totals and every
m-based column came back identical, which is what makes the ack safe.

`carry_credit()` is a sequential per-cell scan, not a rolling window — the
reference depends on the payment history. Still strictly causal, so
recomputation is exact. Build 2m37s → 3m16s.

### The credit rule changed: the baseline no longer waits a year
Two questions from the map drove this. At res-3 (Chongqing) credit was paid
while the mean line rose — that turned out to be mean-vs-sum aggregation, 35
of 343 cells paid, every one of them genuinely improving. At res-6
(`8640a5a07ffffff`, Hunan) a cell was paid in 2020-11/12 after climbing from
50.0 back to 56.0, because its own 2020 lows sat inside the 12 months the
baseline was not allowed to see.

Investigated before touching anything. Measured facts that decided it:

* Credit never went to a deteriorating cell — **99.98%** of paid cell-months
  had `m` more than 2% below a year earlier. The blind spot was never "worse
  than last year", only "gave back a recent gain".
* Removing the exclusion turns out to be the same change as a
  no-backsliding gate at tol 0; they agree on 99.7% of paid months, and where
  they differ it is *always* because the all-time low predates the 5-year
  window. So the gate was the worse formulation of the same idea — it also
  destroys the 5-year expiry.
* Per-cell lifetime credit then telescopes to `log(m_first / m_last)`
  exactly (median ratio 1.00 unweighted). One sentence, path-independent.
* The old rule did **not** deliver the pace-independence its own design notes
  claimed: v2/v1 is 11% for the fastest improvers and 16% for the flattest,
  so v1 over-paid fast movers.
* The margin had to move with it. 2% was calibrated against a year-old
  baseline; on flat-trend cells p95 `|Δlog m|` at lag 1 is 1.63× smaller than
  at lag 12, so the equivalent gate is 1.2%. Measured, not guessed.

Shipped as `credit_v2` computed beside `credit` in script 04, so v1 stayed
byte-identical (verified: max abs diff 0.000e+00 on m, baseline,
parent_under, credit; zero `is_record` mismatches) and the append-only
contract was never at risk. Then everything user-facing was pointed at v2 in
one step — 05 and 06 read `credit_v2` under the name `credit`, so no
branching downstream. v1 columns remain as the audit trail.

Cost, stated plainly: credit volume is 13% of what it was, 42% of the
top-1000 cells reshuffle, and the same or slightly more cells earn. The
switch tripped the script-05 sanity gate exactly as designed — `n_records`
and `total_credit` changed on 86 closed months, nothing else — and was
accepted once with `NO2_SANITY_ACK=1`. That is the intended shape of a
deliberate re-vintage.

### Credit-payout markers in the trend chart

### Fly-to works at every tier, not just res-3 and res-6
`updateTopRegions()` switched to per-cell rows only at `displayRes() === 6`,
so in the res-4 and res-5 zoom bands the panel silently fell back to res-3
regions and `→` flew to zoom 4.8 — out of the tier the reader was in. Nothing
was missing from the data: `childId(parent, r, …)`, `dec`/`fmt["credit"+r]`
and `HEX_ZOOM[r]` were already generic, and `updateFine()` ran the identical
bitmap walk over any `r`. The branch just hardcoded `6` and a literal `9.2`.
res-4/5 rows read as Σ over their res-6 children (titled "Top areas"), res-6
keeps its per-cell %.

Closed the ROADMAP's own gap while there: the smoke test now walks all four
tiers and all three credit windows. Run against the *old* bundle first as a
negative control — exactly 6 failures, all and only the res-4/5 assertions,
reporting `zoom 4.80`.

### Credit-payout markers in the trend chart
The chart showed *what* a hex's NO₂ did but never *when it got paid*, and
per-cell credit history wasn't in the bundle at all. Measured first: only
0.18–0.46% of hex-months carry credit (97.8% of cells never earn), so a dense
per-month plane would have been 99.6% zeros and ~1.2 GB at res-6. Shipped as
events instead — one `(month, level)` pair per payout, with the per-cell
*count* riding the tier's already-gzipped planes so the client prefix-sums its
own offsets and nothing stores an index. 6.33M events for **+26 MB, +0.95%**
of the bundle; the first sizing estimate (a when-only bitmap) was 188 MB.

Amount is encoded up the map's own credit ramp in four steps, deliberately not
on a second y-axis — the dots sit on the line whose credit they describe, so a
marker's height is still `m`. Count and peak are in figures under the chart
and the exact value is on hover, so neither is readable by colour alone.
res-3 events ship in both builds; the finer tiers are web-only like the
per-hex `m` series they annotate, and single-file below res 3 shows the
region's payouts, marked `(region)`.

Verified both builds: single-file and web agree exactly on the res-3 top
region (63/98 months, peak Σ 44) via two different encodings, zero page
errors in either.

## Shipped 2026-08-08

### Source of truth moved to GitHub
The two remotes had diverged: the same 23 commits with different SHAs,
GitHub's copies scrubbed of internal paths, plus three commits only GitHub
had — the env-var externalization and the top-regions scope. Local reset to
`github/main`, Gitea force-synced to match. Nothing was lost: identical file
lists, no tags, no other branches, and the only content unique to the Gitea
line was the real paths, which now live outside the repo.

### Out-of-repo config and hosting documented
A fresh clone of the public repo used to hit `NO2_DATA_RAW is not set`
with nothing in the README to explain it. Scripts 01–03 need
`NO2_DATA_RAW`, 07 needs `NO2_PUBLISH_DIR`, 04–06 need neither. The
deploy header documented nginx while the reference host actually runs Caddy;
both configs are given now.

### Month bundle retention
`index.html` points at one month, so older `data/<month>/` directories were
dead weight growing ~2.8 GB a month on both sides. About 96% of a bundle is
the per-hex series, which every build reships complete for all months, so an
old bundle duplicates the newest one; the remaining ~108 MB rebuilds from
the panel. Script 06 keeps `VIZ_KEEP_MONTHS` locally, `08_deploy.sh` keeps
`KEEP_MONTHS` on the host and only after both rsyncs succeed. Default 2 —
the second month is the rollback.

### Vintage check
Append-only guaranteed we never overwrite, not that anyone would notice
Terrascope revising a month we had already scored. Script 01 records
`processing:version`, the item's `created`/`updated` and the asset's
`file:size` in `vintage.csv` beside the archive and re-checks every run.
Both observed reprocessing shapes are covered: 2025-10…12 moved `updated`
only, 2026-01…04 were recreated so `created` moved too. Bootstrapped from
verified state — all 196 archived files matched upstream.

### Sanity gate on the numbers
The smoke test proves the map works, and a wrong month renders into a
working map. Script 05 checks a new month against bounds taken from 98
months of history (coverage against its own trailing-12-month median,
eligible cells against the previous month, `perf_short` level and step),
each roughly 3× outside anything observed. The same pass verifies the
append-only contract's rule 2 — closed months must survive a recompute —
which nothing checked before. It holds: all 98 reproduced byte for byte.

## Shipped 2026-08-07

### Favicon — done 2026-08-07
The live site 404s on `/favicon.ico` on every load. Add one (the ⬡ mark
would do) and reference it from the template. Trivial, and it's the tab
identity of the site.
*Shipped as an inline data-URI SVG in the template head — no extra file,
covers the single-file build too, and stops the default `/favicon.ico`
request altogether.*

### Commit the smoke test — done 2026-08-07
An ad-hoc Puppeteer suite caught three real bugs this session before they
shipped: the ECharts piecewise-visualMap crash, res-3 deep links arriving
at a zoom where the hex isn't rendered, and the panel resizing when the
pin chip disappears. Turn it into `scripts/09_smoketest.js`:

* serve the built bundle locally, drive headless Chrome
  (`~/.cache/puppeteer` has the binary; `puppeteer-core` as dev dep)
* assert: page loads with zero pageerrors, three ECharts instances,
  hover shows the region panel, click pins, chip releases, deep link
  `#trend/<hex>` arrives pinned on exactly that hex
* desktop run needs
  `--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4`
  (headless reports `hover: none` by default); a second run without the
  flag covers the touch path
* run it between `06_viz.R` and `08_deploy.sh`; deploy only on green

Highest priority on this list — it protects everything else.
*Shipped as `scripts/09_smoketest.js` (`puppeteer-core` dev dep,
`npm install` once): desktop + touch runs, wired into `run_all.R` after
06 and as the deploy gate in `08_deploy.sh` (`SKIP_SMOKE=1` bypasses).
One gotcha for posterity: `page.setViewport()` resets the pointer/hover
media back to `hover: none`, silently undoing the blink-settings flag —
use `defaultViewport: null` + `--window-size`.*

### Viewport deep links — done 2026-08-07
The hash carries layer + hex (`#trend/<h3id>`) but not the view. Add
zoom/center (`#trend/@lat,lng,z` style) so "look at this view" is
shareable, not just "look at this hex". Keep the existing hex form
working.
*Shipped: `#<layer>/@lat,lng,z` parses on load, and after the first
pan/zoom the hash tracks the view via `history.replaceState` (layer
switches refresh it too). A hex deep link stays in the bar until the map
actually moves; hex links still come from the ⬡ copy button.*

## Product features

### Month scrubber
The map always shows the latest month, but the browser already has the
full res-3 monthly series (that's what the region chart draws). A time
slider scrubbing the res-3 layer through 2018→now would show e.g. the
COVID drop sweeping the globe. Scope cut for v1: res-3 only — the fine
tiers (4/5/6) only ship current-month planes, so either the slider
disables past months when zoomed in, or fine-tier history becomes a
(much bigger) data problem for later.
*Cheaper than it looks: measuring bundles for the retention work established
that `series.bin` ships the complete res-3 monthly history with every build,
so a res-3 scrubber needs no old month directories and no pipeline work at
all — it is front-end work against data the browser already holds.*

### Surface the 3D extrusion mode
Built and working, console-only since 0f28330. The `ctrl-3d` button CSS
already exists in the map control stack. Mostly a decision, not work:
is it ready for the public?

### Region compare
Pin two hexes, overlay both trend lines in the region chart. Per-hex
series fetching already exists (range requests into s<res>.bin). Mostly
panel UX: a second pinned slot, two chip colors, chart legend. Ranked
below the scrubber.

## Bigger / already planned

### Daily nowcast layer — measured 2026-08-12, implementation on hold
Planned in the README since 60b2237. New data cadence, new layer
semantics, pipeline work with viz implications. Deserves its own
session rather than a bullet here.

Measured before building anything (`tmp/compare_daily_monthly.R`: June
2026's 30 dailies from `terrascope-s5p-l3-no2-td-v2`, weight-weighted
composite vs. the archived monthly, 2M-pixel regular sample):

* **The monthly product is not the weighted mean of the published
  dailies.** On eligible pixels (monthly ≥ 30 µmol/m²): bias −0.31,
  median |rel| 1.31%, p95 9.1%, cor 0.978, ~0% bit-identical. The summed
  daily weights don't reproduce the monthly weight raster either (median
  3.7%, p95 20%), so the monthly is aggregated from L2 with its own
  day/orbit assignment or QA pass, not from the daily files.
* Not merely thin coverage: disagreement falls with monthly weight but
  the best-observed quartile still sits at median 1.0% / p95 5.3%.
  A minimum-weight gate on provisional values is validated anyway
  (thinnest quartile: median 1.9% / p95 13.4%).
* Coverage is asymmetric: the monthly holds 0.34% of pixels the daily
  composite lacks, 20× the reverse — the monthly aggregation recovers a
  fringe (twilight edge) the dailies don't carry.
* Consequence: the pixel-level disagreement is the same size as the
  1.2% credit margin, so the README rule (provisional values never touch
  the panel; credits decided only at month close from the monthly) is
  mandatory, not just conservative. For a *display* layer it's fine: as
  1/12 of a provisional `m` even the p95 error damps to ~0.8%, and hex
  means damp the random part further.
* Grid is pixel-identical to the monthly (18000×8960 @ 0.02°, same
  transform), so the script-02 lookup is reusable as-is. Same asset pair
  (NO2 + NO2_WEIGHT), ~125 MB/day, publication lag a steady 2 days
  (every August day so far), vs. month-close + 13 for the monthly.
  July's 31 dailies were complete on Aug 2 — 11 days before the official
  monthly.
* One download gotcha for the future script: `download_terrascope`
  treats `end_date` as exclusive — a range ending on the month's last
  day fetches 29 of 30 files. Script 01 never sees this because it
  always passes today's date.

Design sketch agreed in discussion, deliberately not built yet:
provisional `m` (11 closed months + month-to-date as the twelfth) as the
one nowcast metric, badged provisional and replaced at month close;
minimum-weight gate; res-3 only; shipped as a small daily sidecar plane
(few hundred KB, `no-cache`) so the 2.7 GB bundle rebuild stays monthly.
Staging in `tmp/daily_cmp/` (4.4 GB, composite cached) is safe to
delete; the comparison script stays.

## Housekeeping

### Automate the monthly run
Still manual, but the blockers are gone. Three gates now halt rather than
publish through a problem — vintage on the inputs (01), sanity on the
numbers (05), smoke on the bundle (09) — and the publication lag is a steady
13 days after month end (2025-10, 2026-05 and 2026-06 all landed on the
13th), so a timer on the 14th or 15th is comfortably clear of it.

Two things to settle. It has to run **here**: this machine holds the panel,
metrics and archive, while the deploy host only ever receives the finished
bundle. And the non-zero exits need somewhere to go — a gate nobody hears is
the same as no gate, so notification is part of this item rather than a
follow-on. Budget the run realistically: appending a month rewrites the
per-cell stride in the series files, so every deploy transfers ~2.7 GB no
matter what rsync's delta algorithm does.

### ~~Smoke coverage for the top-regions scope~~ — done 2026-08-10
Closed by the tier walk above: all three credit windows are asserted, plus
the tier the list follows and where `→` lands.

## Decisions taken (context)

* Gates halt, they do not merely warn. The vintage check (01) and the sanity
  gate (05) both `stop()`, so `run_all.R` exits non-zero and nothing
  downstream publishes; `NO2_VINTAGE_ACK=1` and `NO2_SANITY_ACK=1`
  acknowledge. Deliberate — keeping an old vintage or rebasing the history
  is a decision for a person, not for a timer.
* Sanity thresholds are measured, not guessed; `sanity_findings()` in
  `_share.r` records the observed range each bound sits outside. Records and
  total credit trend far too hard to bound at all (both roughly tripled
  during 2026) and are only checked for being present.
* A reprocessed month is never redownloaded. The archived vintage stays
  authoritative by contract; the check exists to make drift visible, not to
  resolve it.
* `data/raw_cache` is pure staging — script 03 stages only months missing
  from the panel, so it is safe to delete and costs ~230 MB to refill per
  month. Cleared 2026-08-08, reclaiming 27 GB.
* The credit rule is versioned, never edited. `credit_v2` was computed for a
  full history beside `credit` and verified not to move a single v1 value
  before anything switched over. Any future rule change goes the same way —
  a new column, both computed, compare on real data, then flip the readers.
  Editing a rule in place would silently rewrite every credit ever issued.
* `BASELINE_EXCLUDE_MONTHS` must be ≥ 1 in any variant. At 0 the baseline
  window includes the current month, so the baseline is ≤ `m` by construction
  and no cell can ever earn anything, anywhere.
* The plume-guard ramp is deliberately a separate constant from the credit
  margin (v1 shared one). Under v2 a wind-driven fluke is paid once and then
  becomes the cell's own baseline, so the guard is needed *less*, not more —
  narrowing it in step with the margin would have been backwards.
* Credit magnitude in the chart is colour on the line, never a second
  y-axis — a dual-scale plot invents a correlation the data doesn't have.
  The dots' height stays `m`; the amount is four steps of the credit ramp,
  starting one step up because the ramp's darkest step is chart-background
  dark. Figures live in the summary line and the tooltip, so nothing is
  colour-only. Don't "improve" this into a twin-axis chart.
* Credit history is stored as events, not planes, and carries no offset
  table: the per-cell event *count* rides the tier's gzipped planes and the
  client prefix-sums it. That is why `k<r>` is the one plane stored raw
  rather than delta-encoded — it is 99.8% zeros, and delta-ing turns those
  runs into alternating noise.
* Month bundle retention has still never actually pruned anything: it needs
  more than `VIZ_KEEP_MONTHS` bundles to fire, and there is one. 2026-07
  makes two (still no prune); the **2026-08 run is the first time either
  `VIZ_KEEP_MONTHS` or the host's `KEEP_MONTHS` deletes a directory**. Watch
  that run rather than trusting the code.
* Charts are Apache ECharts 6.1.0 from unpkg; piecewise `visualMap` is
  broken there — the diverging fill uses two silent zero-clamped series
  instead. Don't "simplify" it back.
* Desktop selection model: hover previews, click pins, click elsewhere
  re-pins; the `⌖ pinned` chip (or Esc) releases *without hiding* the
  panel. × is touch-only and dismisses. Right-click-to-release was
  discussed and rejected.
* Fly-to (top-10 →) and hex deep links select on arrival by exact H3 id,
  retrying across map `idle` events; silent-center if the hex never
  renders. Arrival zooms (`HEX_ZOOM`) must stay inside the tier that
  renders the hex's own resolution — `r3-fill` stops at `Z4 + 0.4`.
* Pushing `main` updates both remotes (origin has two push URLs). As of
  2026-08-08 the public GitHub repo is the source of truth and Gitea was
  force-synced to match it — the two lines had diverged, and only the
  GitHub one had the paths and hostnames moved out of the repo. Fetches
  still come from Gitea, so `origin` is the one that can go stale.
* Real paths, hosts and credentials live only in gitignored `.Renviron`
  and `.deploy.env`, never in either repo (see README, "Configuration
  outside the repo"). Both files exist per machine and nowhere else.

# Roadmap notes

Ideas collected 2026-08-07 after the ECharts / selection-model session,
extended 2026-08-08 by the provenance / hardening session.
Rough order inside each section is by value-for-effort, not commitment.

## Shipped 2026-08-08

### Source of truth moved to GitHub
The two remotes had diverged: the same 23 commits with different SHAs,
GitHub's copies scrubbed of internal paths, plus three commits only GitHub
had — the env-var externalization and the top-regions scope. Local reset to
`github/main`, Gitea force-synced to match. Nothing was lost: identical file
lists, no tags, no other branches, and the only content unique to the Gitea
line was the real paths, which now live outside the repo.

### Out-of-repo config and hosting documented
A fresh clone of the public repo used to hit `KEANO_DATA_RAW is not set`
with nothing in the README to explain it. Scripts 01–03 need
`KEANO_DATA_RAW`, 07 needs `KEANO_PUBLISH_DIR`, 04–06 need neither. The
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

### Daily nowcast layer
Planned in the README since 60b2237. New data cadence, new layer
semantics, pipeline work with viz implications. Deserves its own
session rather than a bullet here.

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

### Smoke coverage for the top-regions scope
`09_smoketest.js` asserts hover, pinning, deep links and chart instances,
but nothing about the trailing-12-months / all-time scope from e3e2453 —
the most recent UI change is the one with no assertion, and it is already
live. Worth closing before the next change layers on top of it.

## Decisions taken (context)

* Gates halt, they do not merely warn. The vintage check (01) and the sanity
  gate (05) both `stop()`, so `run_all.R` exits non-zero and nothing
  downstream publishes; `KEANO_VINTAGE_ACK=1` and `KEANO_SANITY_ACK=1`
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

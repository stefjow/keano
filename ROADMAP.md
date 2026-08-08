# Roadmap notes

Ideas collected 2026-08-07, after the ECharts / selection-model session.
Rough order inside each section is by value-for-effort, not commitment.

## Quick wins

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
`run_all.R` + deploy is manual. A cron/systemd timer (here or on the
deploy host) with the smoke test as deploy gate would close the loop.
Notify on failure rather than on success.

## Decisions taken this session (context)

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
* Pushing `main` updates both remotes (origin has two push URLs:
  Gitea = source of truth, GitHub mirror).

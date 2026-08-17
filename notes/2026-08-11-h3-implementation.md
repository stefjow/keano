# Does the H3 hexagon implementation make sense?

Discussion note, 2026-08-11. Conclusion up front: **yes.** The
implementation uses exactly the properties H3 is genuinely good at (stable
global IDs, near-equal area, a cheap ID-tree hierarchy) and the places
where H3 is known to be awkward happen not to touch this design. There is
one spot where the hierarchy's tree structure shows through as a real, if
measured-to-be-tolerable, modeling artifact: the parent-based plume guard.

## What the implementation gets right

**The static lookup is the right architecture.** Script 02 indexes 26M
pixel centers to res-6 cells exactly once; from then on a month is an
integer join + grouped mean, no geometry at runtime, with `grid_meta`
validating every file against the geometry the lookup was built for. This
is what makes the append-only contract cheap to honor: cell identity is
frozen, so `cell_id` is a stable key across the whole history.

**Res-6 is about as fine as the data supports, and no finer.** The 0.02°
grid gives ~7 pixels per hex at the equator, but the underlying L2
footprint is ~3.5×5.5 km — comparable to the hex diameter (~7.4 km). Res-7
would slice retrieval noise into smaller pieces without adding
information; res-5 (~250 km²) would average away the within-city structure
the README names as a goal. The choice is data-driven.

**The hierarchy does real work, and only relationally.** Three levels are
load-bearing: res-0 as the partition key (122 shards ≈ 115k cells each),
res-4 as the plume-guard neighbourhood (~1,770 km², a sensible plume scale
for a species with an hours-long lifetime), res-3/4/5 for display
aggregation. Every one uses parent-child relations on IDs, never geometric
containment — which is what makes H3's best-known flaw irrelevant here.

## H3's known quirks, and why they are benign here

- **Non-exact nesting.** Aperture-7 subdivision means children poke past
  their parent's geometric boundary. This bites systems that treat parents
  as spatial containers; lufterl never does. The parent's `m` is the mean
  over its children's series, the shard-completeness claim in
  `04_metrics.R` holds because ancestor relations form an exact tree on
  IDs regardless of geometry, and the viz walks the same ID tree. Nothing
  in the pipeline asks "is this point inside that hexagon."
- **Pentagons.** The 12 pentagons per resolution break code that assumes 7
  children or 6 neighbors. lufterl computes means over *actual* children via
  groupby and never traverses neighbors, so pentagons just make a few
  shards slightly smaller.
- **Area variation.** Res-6 cells vary roughly ±20% in area globally.
  Credit is a %-undercut of the cell's own baseline, so per-cell scores do
  not depend on area at all; it only faintly colors cross-cell comparisons
  of totals. Second-order — and vastly better than the lat/lon
  alternative, where a 75°N pixel covers a quarter of an equatorial one.
  For a system whose premise is that cells compete symmetrically,
  near-equal area is the single strongest reason H3 beat keeping the
  native grid.

Implementation detail to keep an eye on: `parent_r4()` computes the res-4
parent by bit-twiddling the H3 v4 string layout directly rather than
calling the library. It is self-tested against h3jsr in script 06, which
defuses most of the risk, but it is a hand-rolled dependency on an index
format — if the lookup is ever rebuilt with a different H3 major version,
re-verify that line first.

## The two genuine discussion points

**1. The plume guard inherits the tree's boundaries, not the cell's
neighbourhood.** The one place H3's structure leaks into the *model*
rather than the plumbing. A cell near the center of its res-4 parent gets
a neighbourhood centered on itself; a cell at the parent's edge gets one
lying mostly off to one side, and two adjacent res-6 cells straddling a
res-4 boundary get entirely different guards. The "correct" construction
is a k-ring (`grid_disk`, radius ~4) around each cell: self-centered,
similar size, no boundary discontinuity. The cost is real — overlapping
windows kill the one-groupby-per-parent shape, roughly an order of
magnitude more joins, and edge rings cross shard boundaries, breaking the
shard-local computation. Given the measured guard behavior (full weight on
63% of paid months, and v3 turning a blocked undercut into a deferral
rather than a forfeit, so a boundary-artifact block delays payment rather
than destroying it), the parent-based guard is a defensible trade. Revisit
if a systematic pattern of damping along res-4 seams ever shows up.
Cheaply checkable: plot `w_parent < 1` frequency by the cell's position
within its parent.

**2. Pixel-center assignment is lumpy, but static.** Each 0.02° pixel
contributes wholly to whichever hex contains its center, and with ~7–15
pixels per hex, boundary pixels are a big fraction of each hex's sample.
Area-weighted overlap would be "more correct" spatially. But the lookup is
frozen, so each hex's mean is a *fixed* spatial kernel applied identically
every month — the lumpiness is a constant of the cell and cancels in every
within-cell relative metric. Whatever noise it does contribute is priced
into the 1.2% margin, which was calibrated on this pipeline's actual
output. Fractional-overlap weights would cost a 26M-pixel polygon
intersection and buy essentially nothing.

A non-issue worth naming because it looks suspicious at first glance:
pixels per hex grows with latitude (the lat/lon grid shrinks in km while
hexes do not). Harmless for the mean — within one ~7 km hex, `cos(lat)` is
effectively constant, so equal pixel weighting is unbiased — and the
varying *observation* density is exactly what the `NO2_WEIGHT` spatial
weighting handles.

## Alternatives considered

Native lat/lon grid: fails the equal-area fairness requirement, no
hierarchy. S2: exact geometric nesting (which lufterl does not need) at the
price of worse area/shape uniformity and an awkward 4/8-neighbor
structure. Admin boundaries: unstable, politically defined, wildly unequal
(the camsmap lesson). H3 is the option that delivers stable global IDs,
near-equal area and a cheap ID-tree hierarchy simultaneously — and the
codebase uses precisely those three properties and no others.

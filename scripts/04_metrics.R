# ============================================================================
# Script 04: Causal performance metrics per cell
# ============================================================================
# Every value for month t uses only data up to t, so recomputing the full
# history from the archive reproduces identical past values (the append-only
# contract; see README). Computed shard by shard so the full panel never has
# to fit in RAM.
#
# Per cell and month:
#   m          trailing 12-month mean of no2 (deseasonalized by construction;
#              NA unless >= MIN_MONTHS_IN_WINDOW observed months in window)
#   perf_short YoY change of m
#   perf_long  annualized change of m vs the cell's first valid m (a window
#              that grows: 7.2 years as of 2026-06)
#   perf_5y    the same annualized rate over a FIXED TREND_WINDOW_MONTHS window,
#              so it stays comparable as the record lengthens. NA until a cell
#              has that much history
#   baseline   lowest m in the window t-BASELINE_WINDOW_MONTHS..t-BASELINE_
#              EXCLUDE_MONTHS ("best year that ended at least a year ago").
#              Excluding the freshest year keeps the baseline from chasing m
#              downward month by month, so sustained improvement clears the
#              margin; old records still expire after 5 years.
#   parent_under  relative undercut of the cell's res-4 parent region (~1770
#              km²): mean of children m, with the identical expiring-min
#              baseline construction one level up
#   is_record  the cell undercut its own baseline beyond CREDIT_MARGIN while
#              eligible (a fact about the cell, independent of the payout)
#   credit     relative undercut (baseline - m)/baseline, if the cell is
#              eligible (m >= NO2_FLOOR) and the undercut clears CREDIT_MARGIN,
#              weighted by the parent factor
#                w = clamp01((parent_under + margin) / (2 * margin))
#              NO2 is transport-driven at 36 km² scale — a cell can hit a
#              record low because this year's winds moved the neighbour's
#              plume, not because anyone reduced. Full credit needs the
#              neighbourhood at/near record lows too; collective improvements
#              pass untouched. 0 if observed but no paid record; NA if m or
#              baseline undefined
# Three generations of the credit rule are computed side by side. Only the
# newest is read by anything downstream; the others are the audit trail for
# what was published before, and keeping them means a rule change never
# rewrites a column anyone has already seen.
#
#   credit     (v1, retired) baseline held back a year, 2% margin. Pays the
#              cumulative gap every month until the cell's own low ages in, so
#              totals run ~7x the current rule and a cell kept earning for up
#              to a year after it stopped improving.
#   baseline_v2 / parent_under_v2 / credit_v2
#              (v2, retired) baseline window ends at t-1 instead of t-12, so a
#              cell must undercut its own most recent low. Lifetime credit then
#              telescopes to log(m_first / m_last) — paid once per unit of
#              reduction, at any pace. Margin retuned to 1.2% for the closer
#              comparison; plume ramp left at 2% (see config).
#   credit_v3 / is_record_v3
#              (v3, SHIPPED) v2's parameters with the reference carried
#              forward: measured against the level the cell was last paid at,
#              not the lowest it has been. Steps too small to clear the margin
#              accumulate instead of being discarded, which lifts the
#              telescoping ratio from ~0.77 to ~0.87 and pays ~12% more, to the
#              same set of cells. See carry_credit() below.
#
# Output: data/metrics/shard=<h3res0>/part-0.parquet
# ============================================================================

source("config/config.R")
loadPackages(c("data.table", "arrow", "dplyr", "parallel"))

ensure_dir(DATA_METRICS)

# res-4 parent from the fixed H3 v4 string layout (self-tested against h3jsr
# in scripts/06_viz.R): res nibble = char 2, digit 4 = top 3 bits of char 7
HEXC = strsplit("0123456789abcdef", "")[[1]]
parent_r4 = function(h) {
  d4 = bitwShiftR(strtoi(substr(h, 7, 7), 16L), 1L)
  paste0("84", substr(h, 3, 6), HEXC[bitwOr(bitwShiftL(d4, 1L), 1L) + 1L],
         "ffffffff")
}

# --- credit_v3: carry the unpaid remainder forward ---------------------------
# v2 measures the undercut against the lowest m of the last five years, so a
# descent taken in steps each smaller than the margin is never paid: every step
# is discarded and the next is measured from the new, lower low. v3 measures
# against the level the cell was last *paid* at instead, so those steps
# accumulate until together they clear the margin.
#
# Two properties worth knowing. The reference only ever moves down (a payment
# needs m < P*(1-margin)), so no ground is ever paid for twice. And because the
# reference resets only when credit was actually paid, a month the plume guard
# zeroed leaves its undercut on the books — the guard defers a payment rather
# than cancelling it.
#
# Sequential by construction (the reference depends on the payment history), so
# this is a per-cell scan, not a rolling window. Still strictly causal: it only
# ever looks backwards, so recomputing reproduces it exactly.
carry_credit = function(midx, m, base, elig, w, margin, expiry) {
  n = length(m)
  credit = numeric(n); rec = logical(n)
  P = NA_real_; Pm = NA_integer_          # level and month of the last payment
  for (i in seq_len(n)) {
    if (!isTRUE(elig[i]) || !is.finite(m[i])) next
    # a payment older than the expiry stops binding; fall back to v2's baseline
    R = if (is.na(Pm) || (midx[i] - Pm) > expiry) base[i] else P
    if (!is.finite(R)) next
    u = (R - m[i]) / R
    if (u > margin) {
      rec[i] = TRUE
      credit[i] = u * w[i]
      if (credit[i] > 0) { P = m[i]; Pm = midx[i] }
    }
  }
  list(credit, rec)
}

cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet"),
                                   col_select = "shard"))

months_all = months_in_dataset(DATA_PANEL)
if (length(months_all) == 0) stop("Panel is empty. Run scripts/03_build_panel.R first.")
# Contiguous month axis even if the archive ever has a gap
midx_full = seq(month_index(months_all[1]),
                month_index(months_all[length(months_all)]))
message("Month axis: ", index_to_label(midx_full[1]), " .. ",
        index_to_label(midx_full[length(midx_full)]),
        " (", length(midx_full), " months)")

shards = sort(unique(cells$shard))

# One shard's full history per worker (PSOCK; see script 03 on why not fork).
# The panel dataset handle is created inside each worker.
do_shard = function(s) {
  t0 = Sys.time()

  ce = open_dataset(file.path(DATA_LOOKUP, "cells.parquet")) |>
    filter(shard == s) |> select(cell_id, h3) |> collect() |> as.data.table()
  ce[, p4 := parent_r4(h3)]
  ce[, p4i := chmatch(p4, unique(p4))]

  pnl = open_dataset(DATA_PANEL) |>
    filter(shard == s) |>
    select(cell_id, no2, n_pix, month) |>
    collect() |>
    as.data.table()
  if (nrow(pnl) == 0) return(NULL)
  pnl[, midx := month_index(month)][, month := NULL]

  # Balanced grid: all cells of the shard x all months
  dt = CJ(cell_id = ce$cell_id, midx = midx_full)
  dt = pnl[dt, on = c("cell_id", "midx")]
  setkey(dt, cell_id, midx)

  dt[, obs := !is.na(no2)]
  dt[, `:=`(
    m     = frollmean(no2, WINDOW_MONTHS, na.rm = TRUE),
    n_obs = frollsum(as.numeric(obs), WINDOW_MONTHS)
  ), by = cell_id]
  dt[n_obs < MIN_MONTHS_IN_WINDOW, m := NA_real_]
  dt[, has_m := !is.na(m)]

  dt[, perf_short := m / shift(m, WINDOW_MONTHS) - 1, by = cell_id]

  dt[, `:=`(
    m_first    = m[which(has_m)[1]],
    midx_first = midx[which(has_m)[1]]
  ), by = cell_id]
  dt[, perf_long := fifelse(
    has_m & midx > midx_first,
    (m / m_first)^(12 / (midx - midx_first)) - 1,
    NA_real_
  )]

  # Medium horizon: the same annualised rate over a fixed 60-month window, so
  # it does not keep lengthening the way perf_long's since-first-year span does.
  # NA for the first TREND_WINDOW_MONTHS of a cell's record, by construction.
  dt[, perf_5y := (m / shift(m, TREND_WINDOW_MONTHS))^(12 / TREND_WINDOW_MONTHS) - 1,
     by = cell_id]

  # Expiring-min baseline, parameterised by how far back the window has to
  # stop: v1 holds it back a year, credit_v2 stops at t-1 (see config).
  roll_prev_min = function(v, excl) {
    roll_min_adaptive(shift(v, excl),
                      pmin(seq_len(length(v)), BASELINE_WINDOW_MONTHS - excl + 1L))
  }
  dt[, baseline    := roll_prev_min(m, BASELINE_EXCLUDE_MONTHS),    by = cell_id]
  dt[, baseline_v2 := roll_prev_min(m, CREDIT_V2_EXCLUDE_MONTHS),   by = cell_id]

  # res-4 parent context: same series + baseline construction one level up
  # (a res-4 cell lies entirely within one res-0 shard, so this is complete)
  dt[ce, p4i := i.p4i, on = "cell_id"]
  parp = dt[!is.na(m), .(m_p = mean(m)), by = .(p4i, midx)]
  parp = parp[CJ(p4i = unique(ce$p4i), midx = midx_full),
              on = c("p4i", "midx")]
  setkey(parp, p4i, midx)
  parp[, b_p    := roll_prev_min(m_p, BASELINE_EXCLUDE_MONTHS),  by = p4i]
  parp[, b_p_v2 := roll_prev_min(m_p, CREDIT_V2_EXCLUDE_MONTHS), by = p4i]
  parp[, `:=`(parent_under    = (b_p - m_p) / b_p,
              parent_under_v2 = (b_p_v2 - m_p) / b_p_v2)]
  dt[parp, `:=`(parent_under    = i.parent_under,
                parent_under_v2 = i.parent_under_v2), on = c("p4i", "midx")]

  dt[, undercut := (baseline - m) / baseline]
  dt[, eligible := has_m & m >= NO2_FLOOR]
  dt[, is_record := !is.na(m) & !is.na(baseline) & eligible &
                    undercut > CREDIT_MARGIN]
  # The parent series contains the cell, so parent_under is defined whenever
  # the cell baseline is — the NA fallback to full weight is belt and braces.
  dt[, w_parent := fifelse(
    is.na(parent_under), 1,
    pmin(pmax((parent_under + CREDIT_MARGIN) / (2 * CREDIT_MARGIN), 0), 1)
  )]
  dt[, credit := fifelse(
    is.na(m) | is.na(baseline), NA_real_,
    fifelse(is_record, undercut * w_parent, 0)
  )]

  # credit_v2 (candidate, not shipped): identical shape against the baseline
  # that has not been held back a year, its own margin, and a plume ramp that
  # stays at v1's width rather than following the margin down (see config).
  dt[, undercut_v2 := (baseline_v2 - m) / baseline_v2]
  dt[, w_parent_v2 := fifelse(
    is.na(parent_under_v2), 1,
    pmin(pmax((parent_under_v2 + CREDIT_V2_PARENT_RAMP) /
              (2 * CREDIT_V2_PARENT_RAMP), 0), 1)
  )]
  dt[, credit_v2 := fifelse(
    is.na(m) | is.na(baseline_v2), NA_real_,
    fifelse(eligible & undercut_v2 > CREDIT_V2_MARGIN,
            undercut_v2 * w_parent_v2, 0)
  )]

  # credit_v3 (shipped): v2's parameters, but the reference is the level the
  # cell was last paid at, so sub-margin steps carry forward. Only cells that
  # are eligible at some point can ever earn, so the scan skips the rest.
  dt[, `:=`(credit_v3 = 0, is_record_v3 = FALSE)]
  ever = dt[eligible == TRUE, unique(cell_id)]
  if (length(ever)) {
    dt[cell_id %in% ever,
       c("credit_v3", "is_record_v3") := carry_credit(
         midx, m, baseline_v2, eligible, w_parent_v2,
         CREDIT_V2_MARGIN, BASELINE_WINDOW_MONTHS), by = cell_id]
  }
  dt[is.na(m) | is.na(baseline_v2), `:=`(credit_v3 = NA_real_, is_record_v3 = NA)]

  # Drop the empty lead-in before a cell's first observation
  out = dt[obs | has_m, .(
    cell_id, month = index_to_label(midx), no2, n_pix,
    m, perf_short, perf_long, perf_5y, baseline, parent_under,
    credit, eligible, is_record,
    baseline_v2, parent_under_v2, credit_v2,
    credit_v3, is_record_v3
  )]

  shard_dir = ensure_dir(file.path(DATA_METRICS, paste0("shard=", s)))
  write_parquet(out, file.path(shard_dir, "part-0.parquet"))

  message(sprintf("[%s] %s cells, %s records, credit %.0f / v3 %.0f, %.1fs", s,
                  format(uniqueN(out$cell_id), big.mark = ","),
                  format(sum(out$is_record), big.mark = ","),
                  sum(out$credit, na.rm = TRUE),
                  sum(out$credit_v3, na.rm = TRUE),
                  as.numeric(Sys.time() - t0, units = "secs")))
  s
}

cl = makeCluster(max(1L, min(N_WORKERS, length(shards))), outfile = "")
clusterExport(cl, c("do_shard", "parent_r4", "HEXC", "midx_full",
                    "DATA_PANEL", "DATA_METRICS", "DATA_LOOKUP",
                    "WINDOW_MONTHS", "MIN_MONTHS_IN_WINDOW", "TREND_WINDOW_MONTHS",
                    "BASELINE_WINDOW_MONTHS", "BASELINE_EXCLUDE_MONTHS",
                    "CREDIT_MARGIN", "NO2_FLOOR",
                    "CREDIT_V2_EXCLUDE_MONTHS", "CREDIT_V2_MARGIN",
                    "CREDIT_V2_PARENT_RAMP", "carry_credit",
                    "month_index", "index_to_label", "roll_min_adaptive",
                    "ensure_dir"))
invisible(clusterEvalQ(cl, suppressMessages({
  library(data.table); library(arrow); library(dplyr)
  setDTthreads(2); set_cpu_count(2)
})))
res = parLapplyLB(cl, shards, function(s) try(do_shard(s), silent = TRUE))
stopCluster(cl)
failed = vapply(res, inherits, TRUE, "try-error")
if (any(failed)) {
  stop("Failed shards:\n",
       paste(unlist(lapply(res[failed], as.character)), collapse = "\n"))
}

message("Metrics written to ", DATA_METRICS, " (",
        sum(!vapply(res, is.null, TRUE)), " non-empty shards)")

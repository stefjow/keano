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
#   perf_long  annualized change of m vs the cell's first valid m
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

  baseline_len = BASELINE_WINDOW_MONTHS - BASELINE_EXCLUDE_MONTHS + 1L
  dt[, m_base := shift(m, BASELINE_EXCLUDE_MONTHS), by = cell_id]
  dt[, baseline := roll_min_adaptive(
    m_base, pmin(seq_len(.N), baseline_len)
  ), by = cell_id]

  # res-4 parent context: same series + baseline construction one level up
  # (a res-4 cell lies entirely within one res-0 shard, so this is complete)
  dt[ce, p4i := i.p4i, on = "cell_id"]
  parp = dt[!is.na(m), .(m_p = mean(m)), by = .(p4i, midx)]
  parp = parp[CJ(p4i = unique(ce$p4i), midx = midx_full),
              on = c("p4i", "midx")]
  setkey(parp, p4i, midx)
  parp[, pm_base := shift(m_p, BASELINE_EXCLUDE_MONTHS), by = p4i]
  parp[, b_p := roll_min_adaptive(
    pm_base, pmin(seq_len(.N), baseline_len)
  ), by = p4i]
  parp[, parent_under := (b_p - m_p) / b_p]
  dt[parp, parent_under := i.parent_under, on = c("p4i", "midx")]

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

  # Drop the empty lead-in before a cell's first observation
  out = dt[obs | has_m, .(
    cell_id, month = index_to_label(midx), no2, n_pix,
    m, perf_short, perf_long, baseline, parent_under,
    credit, eligible, is_record
  )]

  shard_dir = ensure_dir(file.path(DATA_METRICS, paste0("shard=", s)))
  write_parquet(out, file.path(shard_dir, "part-0.parquet"))

  message(sprintf("[%s] %s cells, %s records, %.1fs", s,
                  format(uniqueN(out$cell_id), big.mark = ","),
                  format(sum(out$is_record), big.mark = ","),
                  as.numeric(Sys.time() - t0, units = "secs")))
  s
}

cl = makeCluster(max(1L, min(N_WORKERS, length(shards))), outfile = "")
clusterExport(cl, c("do_shard", "parent_r4", "HEXC", "midx_full",
                    "DATA_PANEL", "DATA_METRICS", "DATA_LOOKUP",
                    "WINDOW_MONTHS", "MIN_MONTHS_IN_WINDOW",
                    "BASELINE_WINDOW_MONTHS", "BASELINE_EXCLUDE_MONTHS",
                    "CREDIT_MARGIN", "NO2_FLOOR",
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

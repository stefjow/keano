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
#   credit     relative undercut (baseline - m)/baseline, if the cell is
#              eligible (m >= NO2_FLOOR) and the undercut clears CREDIT_MARGIN;
#              0 if observed but no record; NA if m or baseline undefined
#
# Output: data/metrics/shard=<h3res0>/part-0.parquet
# ============================================================================

source("config/config.R")
loadPackages(c("data.table", "arrow", "dplyr"))

ensure_dir(DATA_METRICS)

panel = open_dataset(DATA_PANEL)
cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet")))

months_all = months_in_dataset(DATA_PANEL)
if (length(months_all) == 0) stop("Panel is empty. Run scripts/03_build_panel.R first.")
# Contiguous month axis even if the archive ever has a gap
midx_full = seq(month_index(months_all[1]),
                month_index(months_all[length(months_all)]))
message("Month axis: ", index_to_label(midx_full[1]), " .. ",
        index_to_label(midx_full[length(midx_full)]),
        " (", length(midx_full), " months)")

shards = sort(unique(cells$shard))

for (s_i in seq_along(shards)) {
  s = shards[s_i]
  t0 = Sys.time()

  pnl = panel |>
    filter(shard == s) |>
    select(cell_id, no2, n_pix, month) |>
    collect() |>
    as.data.table()
  if (nrow(pnl) == 0) next
  pnl[, midx := month_index(month)][, month := NULL]

  # Balanced grid: all cells of the shard x all months
  dt = CJ(cell_id = cells[shard == s, cell_id], midx = midx_full)
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

  dt[, undercut := (baseline - m) / baseline]
  dt[, eligible := has_m & m >= NO2_FLOOR]
  dt[, credit := fifelse(
    is.na(m) | is.na(baseline), NA_real_,
    fifelse(eligible & undercut > CREDIT_MARGIN, undercut, 0)
  )]
  dt[, is_record := !is.na(credit) & credit > 0]

  # Drop the empty lead-in before a cell's first observation
  out = dt[obs | has_m, .(
    cell_id, month = index_to_label(midx), no2, n_pix,
    m, perf_short, perf_long, baseline, credit, eligible, is_record
  )]

  shard_dir = ensure_dir(file.path(DATA_METRICS, paste0("shard=", s)))
  write_parquet(out, file.path(shard_dir, "part-0.parquet"))

  message(sprintf("[%d/%d] %s: %s cells, %s records, %.1fs",
                  s_i, length(shards), s,
                  format(uniqueN(out$cell_id), big.mark = ","),
                  format(sum(out$is_record), big.mark = ","),
                  as.numeric(Sys.time() - t0, units = "secs")))

  rm(pnl, dt, out)
}

message("Metrics written to ", DATA_METRICS)

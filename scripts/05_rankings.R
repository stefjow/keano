# ============================================================================
# Script 05: Derived views — records, top credits, monthly summaries
# ============================================================================
# Everything here is a VIEW over data/metrics: it can be redefined freely
# (different top-N, composites, regional leagues) without touching the
# stored panel or metric history.
#
# Outputs (data/rankings/):
#   monthly_summary.csv      per month: coverage, eligible cells, records,
#                            total credit, mean perf_short among eligible
#   monthly_top_credits.csv  top TOP_N record cells per month, with h3/coords
#   record_cells.csv         every record event (cell x month with credit > 0)
# ============================================================================

source("config/config.R")
loadPackages(c("data.table", "arrow", "dplyr"))

ensure_dir(DATA_RANKINGS)
ensure_dir(TMP_DIR)

metrics = open_dataset(DATA_METRICS)
cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet")))
shards = sort(unique(cells$shard))

sum_list = list()
rec_list = list()

for (s_i in seq_along(shards)) {
  s = shards[s_i]
  mt = metrics |>
    filter(shard == s) |>
    select(cell_id, month, no2, m, perf_short, baseline,
           credit, eligible, is_record) |>
    collect() |>
    as.data.table()
  if (nrow(mt) == 0) next

  sum_list[[s]] = mt[, .(
    n_cells_obs    = sum(!is.na(no2)),
    n_eligible     = sum(eligible, na.rm = TRUE),
    n_records      = sum(is_record),
    total_credit   = sum(credit, na.rm = TRUE),
    sum_perf_short = sum(perf_short[eligible & !is.na(perf_short)]),
    n_perf_short   = sum(eligible & !is.na(perf_short))
  ), by = month]

  rec_list[[s]] = mt[is_record == TRUE,
                     .(cell_id, month, no2, m, baseline, credit)]

  if (s_i %% 20 == 0) message("  scanned ", s_i, "/", length(shards), " shards")
}

# --- Monthly summary ----------------------------------------------------------
monthly = rbindlist(sum_list)[, .(
  n_cells_obs    = sum(n_cells_obs),
  n_eligible     = sum(n_eligible),
  n_records      = sum(n_records),
  total_credit   = sum(total_credit),
  mean_perf_short_eligible = sum(sum_perf_short) / pmax(sum(n_perf_short), 1)
), by = month][order(month)]

fwrite(monthly, file.path(DATA_RANKINGS, "monthly_summary.csv"))

# --- Record events and monthly top credits ------------------------------------
records = rbindlist(rec_list)
setkey(cells, cell_id)
records[cells, `:=`(h3 = i.h3, lng = i.lng, lat = i.lat), on = "cell_id"]
setorder(records, month, -credit)

fwrite(records, file.path(DATA_RANKINGS, "record_cells.csv"))

top_monthly = records[, head(.SD, TOP_N), by = month]
fwrite(top_monthly, file.path(DATA_RANKINGS, "monthly_top_credits.csv"))

# Quick-look copies for browsing
fwrite(monthly, file.path(TMP_DIR, "monthly_summary.csv"))
fwrite(top_monthly[month == max(month)],
       file.path(TMP_DIR, "latest_month_top_credits.csv"))

message("Rankings written to ", DATA_RANKINGS)
message("Months: ", nrow(monthly),
        ", record events: ", format(nrow(records), big.mark = ","))
print(tail(monthly, 12))

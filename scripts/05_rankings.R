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
loadPackages(c("data.table", "arrow", "dplyr", "parallel"))

ensure_dir(DATA_RANKINGS)
ensure_dir(TMP_DIR)

cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet")))
shards = sort(unique(cells$shard))

scan_shard = function(s) {
  mt = open_dataset(DATA_METRICS) |>
    filter(shard == s) |>
    select(cell_id, month, no2, m, perf_short, baseline, parent_under,
           credit, eligible, is_record) |>
    collect() |>
    as.data.table()
  if (nrow(mt) == 0) return(NULL)

  list(
    sum = mt[, .(
      n_cells_obs    = sum(!is.na(no2)),
      n_eligible     = sum(eligible, na.rm = TRUE),
      n_records      = sum(is_record),
      total_credit   = sum(credit, na.rm = TRUE),
      sum_perf_short = sum(perf_short[eligible & !is.na(perf_short)]),
      n_perf_short   = sum(eligible & !is.na(perf_short))
    ), by = month],
    rec = mt[is_record == TRUE,
             .(cell_id, month, no2, m, baseline, parent_under, credit)]
  )
}

# PSOCK, not fork (see script 03): arrow used pre-fork deadlocks in children
cl = makeCluster(max(1L, min(N_WORKERS, length(shards))), outfile = "")
clusterExport(cl, c("scan_shard", "DATA_METRICS"))
invisible(clusterEvalQ(cl, suppressMessages({
  library(data.table); library(arrow); library(dplyr)
  setDTthreads(2); set_cpu_count(2)
})))
scans = parLapplyLB(cl, shards, function(s) try(scan_shard(s), silent = TRUE))
stopCluster(cl)
failed = vapply(scans, inherits, TRUE, "try-error")
if (any(failed)) {
  stop("Failed shards:\n",
       paste(unlist(lapply(scans[failed], as.character)), collapse = "\n"))
}
scans = scans[!vapply(scans, is.null, TRUE)]
sum_list = lapply(scans, `[[`, "sum")
rec_list = lapply(scans, `[[`, "rec")

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

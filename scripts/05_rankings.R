# ============================================================================
# Script 05: Derived views — records, top credits, monthly summaries
# ============================================================================
# Everything here is a VIEW over data/metrics: it can be redefined freely
# (different top-N, composites, regional leagues) without touching the
# stored panel or metric history.
#
# Outputs (data/rankings/):
#   monthly_summary.csv      per month: coverage, eligible cells, records,
#                            total credit, mean perf_short among eligible.
#                            n_records/total_credit are the SHIPPED rule
#                            (credit_v2); *_v1 keep the retired rule for audit
#   monthly_top_credits.csv  top TOP_N record cells per month, with h3/coords
#   record_cells.csv         every record event (cell x month with credit > 0)
#
# Credit here is credit_v2 — the baseline is not held back a year, so a cell
# must undercut its own most recent low. Totals therefore run ~7x below the
# retired v1 rule; that is a change of unit, not of coverage (slightly more
# cells earn). See config/config.R for the reasoning and script 04 for both.
# ============================================================================

source("config/config.R")
loadPackages(c("data.table", "arrow", "dplyr", "parallel"))

ensure_dir(DATA_RANKINGS)
ensure_dir(TMP_DIR)

cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet")))
shards = sort(unique(cells$shard))

# The shipped credit rule is credit_v2 (see config and script 04): the baseline
# is not held back a year, so a cell must undercut its own most recent low.
# `credit`/`baseline`/`parent_under` below therefore carry the v2 values — the
# v1 columns stay in data/metrics as the audit trail and are summarised
# alongside as *_v1, but nothing user-facing reads them.
# is_record_v2 is derived here rather than stored: it is exactly the v2
# undercut clearing the v2 margin while eligible, and needs no extra column.
scan_shard = function(s) {
  mt = open_dataset(DATA_METRICS) |>
    filter(shard == s) |>
    select(cell_id, month, no2, m, perf_short, baseline_v2, parent_under_v2,
           credit_v2, credit, eligible, is_record) |>
    collect() |>
    as.data.table()
  if (nrow(mt) == 0) return(NULL)
  mt[, undercut_v2 := (baseline_v2 - m) / baseline_v2]
  mt[, is_record_v2 := !is.na(m) & !is.na(baseline_v2) & eligible &
                       undercut_v2 > CREDIT_V2_MARGIN]

  list(
    sum = mt[, .(
      n_cells_obs     = sum(!is.na(no2)),
      n_eligible      = sum(eligible, na.rm = TRUE),
      n_records       = sum(is_record_v2),
      total_credit    = sum(credit_v2, na.rm = TRUE),
      n_records_v1    = sum(is_record),
      total_credit_v1 = sum(credit, na.rm = TRUE),
      sum_perf_short  = sum(perf_short[eligible & !is.na(perf_short)]),
      n_perf_short    = sum(eligible & !is.na(perf_short))
    ), by = month],
    rec = mt[is_record_v2 == TRUE,
             .(cell_id, month, no2, m, baseline = baseline_v2,
               parent_under = parent_under_v2, credit = credit_v2)]
  )
}

# PSOCK, not fork (see script 03): arrow used pre-fork deadlocks in children
cl = makeCluster(max(1L, min(N_WORKERS, length(shards))), outfile = "")
clusterExport(cl, c("scan_shard", "DATA_METRICS", "CREDIT_V2_MARGIN"))
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
  n_cells_obs     = sum(n_cells_obs),
  n_eligible      = sum(n_eligible),
  n_records       = sum(n_records),
  total_credit    = sum(total_credit),
  n_records_v1    = sum(n_records_v1),
  total_credit_v1 = sum(total_credit_v1),
  mean_perf_short_eligible = sum(sum_perf_short) / pmax(sum(n_perf_short), 1)
), by = month][order(month)]

# --- Sanity gate --------------------------------------------------------------
# The smoke test proves the map works; nothing proved the numbers in it were
# sane. A month that is the current upstream vintage can still be wrong —
# half the globe missing, a scale error, a corrupted tile — and it would
# render into a perfectly functional map. Checked before anything is written,
# so a rejected month leaves the previous rankings in place; the candidate
# lands in TMP_DIR to be looked at. KEANO_SANITY_ACK=1 accepts and continues.
summary_file = file.path(DATA_RANKINGS, "monthly_summary.csv")
previous = if (file.exists(summary_file))
  fread(summary_file, data.table = FALSE) else NULL

findings = sanity_findings(monthly, previous,
                           coverage_tol = SANITY_COVERAGE_TOL,
                           eligible_tol = SANITY_ELIGIBLE_TOL,
                           perf_abs     = SANITY_PERF_ABS,
                           perf_step    = SANITY_PERF_STEP)

if (length(findings)) {
  candidate = file.path(TMP_DIR, "monthly_summary_rejected.csv")
  fwrite(monthly, candidate)
  bar = strrep("=", 74)
  message("\n", bar)
  message("SANITY GATE — the recomputed summary does not look right:")
  for (f in findings) message("  * ", f)
  message(bar)
  message("Nothing was written to ", DATA_RANKINGS, "; the previous rankings\n",
          "still stand. The rejected summary is at ", candidate, ".\n",
          "KEANO_SANITY_ACK=1 accepts it and continues this run.")
  if (!nzchar(Sys.getenv("KEANO_SANITY_ACK")))
    stop("Sanity gate failed: ", length(findings), " finding(s).")
} else {
  message("Sanity gate: ", nrow(monthly), " months clean (newest ",
          monthly[.N, month], ").")
}

fwrite(monthly, summary_file)

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

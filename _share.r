# ============================================================================
# Shared utility functions for keano
# ============================================================================

#' Load and install packages if needed
#' @param packages Character vector of package names
loadPackages = function(packages) {
  for (pkg in packages) {
    if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
      message("Installing package: ", pkg)
      install.packages(pkg, repos = "https://cloud.r-project.org/")
      library(pkg, character.only = TRUE)
    }
  }
  invisible(NULL)
}

#' Ensure a directory exists
ensure_dir = function(path) {
  if (!dir.exists(path)) dir.create(path, recursive = TRUE)
  invisible(path)
}

#' Month label ("2018-05") from a Date
month_label = function(date) format(as.Date(date), "%Y-%m")

#' Integer month index (months since Jan 2018) from a "YYYY-MM" label.
#' Used so time arithmetic (lags, windows) is plain integer math.
month_index = function(label) {
  y = as.integer(substr(label, 1, 4))
  m = as.integer(substr(label, 6, 7))
  (y - 2018L) * 12L + m
}

#' Month label from an integer month index
index_to_label = function(idx) {
  y = 2018L + (idx - 1L) %/% 12L
  m = (idx - 1L) %% 12L + 1L
  sprintf("%04d-%02d", y, m)
}

#' Rolling minimum over an adaptive trailing window (right-aligned),
#' NA-tolerant. Windows that contain no finite value return NA.
roll_min_adaptive = function(x, n) {
  out = -data.table::frollmax(-x, n = n, adaptive = TRUE, na.rm = TRUE)
  out[!is.finite(out)] = NA_real_
  out
}

#' Copy raw files to a local cache and return the cache paths. DATA_RAW may
#' live on a network share (SMB), which is latency-bound and collapses under
#' many concurrent GDAL readers — compute must read local copies. Sizes are
#' compared so interrupted copies are redone; the cache is safe to delete.
stage_raw = function(files, cache_dir, workers = 4) {
  ensure_dir(cache_dir)
  dest = file.path(cache_dir, basename(files))
  todo = which(!file.exists(dest) | file.size(dest) != file.size(files))
  if (length(todo) > 0) {
    message("Staging ", length(todo), " files to ", cache_dir, " ...")
    ok = unlist(parallel::mclapply(todo, function(i)
      file.copy(files[i], dest[i], overwrite = TRUE),
      mc.cores = min(workers, length(todo))))
    if (!all(ok)) stop("Failed to stage ", sum(!ok), " files")
  }
  dest
}

#' Sanity findings for a freshly computed monthly summary.
#'
#' Returns human-readable problems, empty when the month looks fine. Pure —
#' no I/O — so it can be exercised on synthetic tables.
#'
#' Bounds are set from the observed history rather than guessed: over 98
#' months, coverage stayed within 0.959-1.053 of its own trailing-12-month
#' median and eligible cells within 0.970-1.029 month-over-month, so the
#' defaults sit ~3x outside anything that has happened. Records and credit
#' trend far too hard to bound tightly (both roughly tripled during 2026), so
#' they are only checked for being present at all.
#'
#' The history comparison is the other half: metrics are causal, so a rerun
#' must reproduce closed months exactly. Nothing verified that until now.
#'
#' @param monthly  one row per month, ordered by month, with n_cells_obs,
#'                 n_eligible, n_records, total_credit,
#'                 mean_perf_short_eligible
#' @param previous the same table from the previous run, or NULL
sanity_findings = function(monthly, previous = NULL,
                           coverage_tol = 0.15, eligible_tol = 0.15,
                           perf_abs = 0.25, perf_step = 0.15,
                           history_tol = 1e-9) {
  need = c("month", "n_cells_obs", "n_eligible", "n_records",
           "total_credit", "mean_perf_short_eligible")
  m = as.data.frame(monthly, stringsAsFactors = FALSE)
  miss = setdiff(need, names(m))
  if (length(miss))
    return(sprintf("summary is missing column(s): %s", paste(miss, collapse = ", ")))
  m = m[order(m$month), need]
  n = nrow(m)
  if (n == 0L) return("summary is empty")

  out = character()
  add = function(...) out <<- c(out, sprintf(...))
  last = m[n, ]
  lab = last$month

  nonfinite = need[-1][!vapply(need[-1], function(k) is.finite(last[[k]]), TRUE)]
  if (length(nonfinite))
    add("%s: non-finite %s", lab, paste(nonfinite, collapse = ", "))
  if (isTRUE(last$n_cells_obs <= 0)) add("%s: no observed cells at all", lab)
  if (isTRUE(last$n_eligible  <= 0)) add("%s: no eligible cells at all", lab)
  if (isTRUE(last$n_records   <= 0)) add("%s: no record cells anywhere", lab)

  # Coverage against its own trailing-12-month median: seasonal, so comparing
  # to the previous month alone would flag every spring and autumn.
  if (n >= 13L) {
    ref = stats::median(m$n_cells_obs[(n - 12L):(n - 1L)])
    if (is.finite(ref) && ref > 0 && is.finite(last$n_cells_obs)) {
      r = last$n_cells_obs / ref
      if (abs(r - 1) > coverage_tol)
        add("%s: coverage %s cells is %+.1f%% against the trailing-12-month median %s (limit %.0f%%)",
            lab, format(last$n_cells_obs, big.mark = ","), 100 * (r - 1),
            format(ref, big.mark = ","), 100 * coverage_tol)
    }
  }

  # Eligibility rides a 12-month trailing mean, so it moves very smoothly; a
  # scale error upstream would push cells over NO2_FLOOR en masse.
  if (n >= 2L) {
    ref = m$n_eligible[n - 1L]
    if (is.finite(ref) && ref > 0 && is.finite(last$n_eligible)) {
      r = last$n_eligible / ref
      if (abs(r - 1) > eligible_tol)
        add("%s: %s eligible cells is %+.1f%% against %s (limit %.0f%%)",
            lab, format(last$n_eligible, big.mark = ","), 100 * (r - 1),
            m$month[n - 1L], 100 * eligible_tol)
    }
  }

  p = last$mean_perf_short_eligible
  if (is.finite(p) && abs(p) > perf_abs)
    add("%s: mean perf_short %+.4f is outside +/-%.2f", lab, p, perf_abs)
  if (n >= 2L) {
    d = p - m$mean_perf_short_eligible[n - 1L]
    if (is.finite(d) && abs(d) > perf_step)
      add("%s: mean perf_short moved %+.4f in one month (limit %.2f)", lab, d, perf_step)
  }

  # Closed months must survive a recompute unchanged (README rule 2).
  if (!is.null(previous) && nrow(previous) > 0) {
    pv = as.data.frame(previous, stringsAsFactors = FALSE)
    if (all(need %in% names(pv))) {
      shared = intersect(pv$month, m$month)
      if (length(shared)) {
        ia = match(shared, m$month); ib = match(shared, pv$month)
        for (k in need[-1]) {
          a = as.numeric(m[[k]][ia]); b = as.numeric(pv[[k]][ib])
          moved = abs(a - b) > history_tol * pmax(abs(a), abs(b), 1)
          moved[is.na(moved)] = TRUE
          if (any(moved))
            add("%s changed on recompute for %d closed month(s): %s", k, sum(moved),
                paste(utils::head(shared[moved], 3), collapse = ", "))
        }
      }
      dropped = setdiff(pv$month, m$month)
      if (length(dropped))
        add("%d month(s) present last run are missing now: %s", length(dropped),
            paste(utils::head(dropped, 5), collapse = ", "))
    }
  }
  out
}

#' Months ("YYYY-MM") already present in a hive-partitioned dataset directory
months_in_dataset = function(path) {
  dirs = list.dirs(path, recursive = FALSE, full.names = FALSE)
  sort(sub("^month=", "", dirs[grepl("^month=", dirs)]))
}

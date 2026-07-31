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

#' Months ("YYYY-MM") already present in a hive-partitioned dataset directory
months_in_dataset = function(path) {
  dirs = list.dirs(path, recursive = FALSE, full.names = FALSE)
  sort(sub("^month=", "", dirs[grepl("^month=", dirs)]))
}

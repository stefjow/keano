# ============================================================================
# Script 03: Build the H3 panel, month by month
# ============================================================================
# For every archived month not yet in the panel: read the global raster,
# join pixels to H3 cells via the static lookup, average per cell, and write
# a hive-partitioned parquet slice:
#
#   data/panel/month=YYYY-MM/shard=<h3res0>/part-0.parquet
#     cell_id (int), no2 (µmol/m², weighted mean over pixels),
#     w_sum (total L3 coverage weight), n_pix (coverage QC)
#
# The hex mean is weighted by the L3 gridding weight (NO2_WEIGHT ~ number of
# contributing L2 observations per pixel) — SPATIAL weighting only. Temporal
# aggregation (script 04) stays unweighted by design; see README "Weights".
#
# Incremental and append-only: existing months are skipped, never rewritten.
# ============================================================================

source("config/config.R")
loadPackages(c("terra", "data.table", "arrow", "parallel"))

ensure_dir(DATA_PANEL)

# --- Inputs -------------------------------------------------------------------
lookup_file = file.path(DATA_LOOKUP, "pixel_cell.parquet")
if (!file.exists(lookup_file)) {
  stop("Lookup not found. Run scripts/02_build_lookup.R first.")
}
cell_by_pixel = read_parquet(lookup_file)$cell_id
# Only the cell -> shard map is needed here; skip the H3 address strings
# (they'd cost ~1.5 GB per PSOCK worker to ship).
cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet"),
                                   col_select = c("cell_id", "shard")))
grid_meta = readRDS(file.path(DATA_LOOKUP, "grid_meta.rds"))

tif_files = sort(list.files(DATA_RAW, pattern = "^no2_monthly_.*\\.tif$",
                            full.names = TRUE))
tif_files = tif_files[!grepl("\\.aux\\.xml", tif_files)]
file_months = month_label(as.Date(
  regmatches(basename(tif_files), regexpr("\\d{8}", basename(tif_files))),
  format = "%Y%m%d"
))

done_months = months_in_dataset(DATA_PANEL)
todo = which(!file_months %in% done_months)
message(length(done_months), " months already in panel, ",
        length(todo), " to process")

# --- Stage inputs locally ------------------------------------------------------
# The archive may live on a network share; 32 concurrent GDAL readers over
# SMB are latency-bound and starve. Copy once, read locally (see stage_raw).
no2_remote = tif_files[todo]
w_remote = file.path(dirname(no2_remote),
                     sub("^no2_monthly_", "no2_weight_", basename(no2_remote)))
if (any(!file.exists(w_remote))) {
  stop("Missing weight file(s): ",
       paste(basename(w_remote[!file.exists(w_remote)]), collapse = ", "),
       ". Run scripts/01_download.R to backfill NO2_WEIGHT.")
}
no2_local = stage_raw(no2_remote, DATA_CACHE)
w_local   = stage_raw(w_remote, DATA_CACHE)
todo_months = file_months[todo]

# --- Process new months (parallel; cells/lookup shared copy-on-write) ---------
setkey(cells, cell_id)

process_month = function(k) {
  mlab = todo_months[k]

  r = rast(no2_local[k])
  w = rast(w_local[k])

  # The static lookup is only valid if every file shares the grid geometry.
  for (rr in list(r, w)) {
    if (nrow(rr) != grid_meta$nrow || ncol(rr) != grid_meta$ncol ||
        !all(abs(as.vector(ext(rr)) - grid_meta$extent) < 1e-9)) {
      stop("Grid geometry of ", basename(sources(rr)),
           " differs from the lookup grid. Rebuild the lookup (script 02) ",
           "and investigate — this may indicate a product change.")
    }
  }

  # terra applies scale/offset from file metadata; NoData comes back as NA.
  # Pixels without positive coverage weight carry no valid retrieval.
  dt = data.table(cell_id = cell_by_pixel,
                  no2 = as.vector(values(r)),
                  w   = as.vector(values(w)))
  dt = dt[is.finite(no2) & is.finite(w) & w > 0]
  agg = dt[, .(no2 = sum(w * no2) / sum(w), w_sum = sum(w), n_pix = .N),
           by = cell_id]
  agg[cells, shard := i.shard, on = "cell_id"]

  write_dataset(
    agg,
    path = file.path(DATA_PANEL, paste0("month=", mlab)),
    partitioning = "shard",
    format = "parquet"
  )

  message("Aggregated ", mlab, " (", basename(no2_local[k]), ")")
  mlab
}

# PSOCK, not fork: the parent has used arrow (multithreaded C++) before this
# point, and forked children inherit its locked mutexes and deadlock. Fresh
# worker processes load their own arrow. outfile="" routes worker messages
# into the pipeline log.
if (length(todo) > 0) {
  cl = makeCluster(max(1L, min(N_WORKERS, length(todo))), outfile = "")
  clusterExport(cl, c("process_month", "no2_local", "w_local", "todo_months",
                      "grid_meta", "cell_by_pixel", "cells", "DATA_PANEL"))
  invisible(clusterEvalQ(cl, suppressMessages({
    library(terra); library(data.table); library(arrow)
    setDTthreads(2); set_cpu_count(2)
  })))
  res = parLapplyLB(cl, seq_along(todo),
                    function(k) try(process_month(k), silent = TRUE))
  stopCluster(cl)
  failed = vapply(res, inherits, TRUE, "try-error")
  if (any(failed)) {
    stop("Failed months:\n",
         paste(unlist(lapply(res[failed], as.character)), collapse = "\n"))
  }
}

message("Panel now holds ", length(months_in_dataset(DATA_PANEL)), " months.")

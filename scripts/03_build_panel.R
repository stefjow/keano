# ============================================================================
# Script 03: Build the H3 panel, month by month
# ============================================================================
# For every archived month not yet in the panel: read the global raster,
# join pixels to H3 cells via the static lookup, average per cell, and write
# a hive-partitioned parquet slice:
#
#   data/panel/month=YYYY-MM/shard=<h3res0>/part-0.parquet
#     cell_id (int), no2 (µmol/m², mean over pixels), n_pix (coverage QC)
#
# Incremental and append-only: existing months are skipped, never rewritten.
# ============================================================================

source("config/config.R")
loadPackages(c("terra", "data.table", "arrow"))

ensure_dir(DATA_PANEL)

# --- Inputs -------------------------------------------------------------------
lookup_file = file.path(DATA_LOOKUP, "pixel_cell.parquet")
if (!file.exists(lookup_file)) {
  stop("Lookup not found. Run scripts/02_build_lookup.R first.")
}
cell_by_pixel = read_parquet(lookup_file)$cell_id
cells = as.data.table(read_parquet(file.path(DATA_LOOKUP, "cells.parquet")))
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

# --- Process new months --------------------------------------------------------
setkey(cells, cell_id)

for (i in todo) {
  mlab = file_months[i]
  message("Aggregating ", mlab, " (", basename(tif_files[i]), ")")

  r = rast(tif_files[i])

  # The static lookup is only valid if every file shares the grid geometry.
  if (nrow(r) != grid_meta$nrow || ncol(r) != grid_meta$ncol ||
      !all(abs(as.vector(ext(r)) - grid_meta$extent) < 1e-9)) {
    stop("Grid geometry of ", basename(tif_files[i]),
         " differs from the lookup grid. Rebuild the lookup (script 02) ",
         "and investigate — this may indicate a product change.")
  }

  # terra applies scale/offset from file metadata; NoData comes back as NA
  dt = data.table(cell_id = cell_by_pixel, no2 = as.vector(values(r)))
  dt = dt[!is.na(no2)]
  agg = dt[, .(no2 = mean(no2), n_pix = .N), by = cell_id]
  agg[cells, shard := i.shard, on = "cell_id"]

  write_dataset(
    agg,
    path = file.path(DATA_PANEL, paste0("month=", mlab)),
    partitioning = "shard",
    format = "parquet"
  )

  rm(r, dt, agg)
}

message("Panel now holds ", length(months_in_dataset(DATA_PANEL)), " months.")

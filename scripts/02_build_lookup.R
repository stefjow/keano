# ============================================================================
# Script 02: One-time pixel -> H3 lookup
# ============================================================================
# The global L3 grid geometry never changes, so we index every pixel center
# to its H3 res-6 cell exactly once. After this, aggregating a month is a
# plain integer join + grouped mean — no polygon extraction.
#
# Outputs (data/lookup/):
#   pixel_cell.parquet  one int32 column `cell_id`, row order = pixel order
#   cells.parquet       cell_id, h3, shard (res-0 parent), lng, lat
#   grid_meta.rds       grid dims/extent, used by 03 to validate every file
#
# Memory note: holds ~26M H3 address strings at peak (~a few GB). One-time
# cost; runs in a few minutes.
# ============================================================================

source("config/config.R")
loadPackages(c("terra", "data.table", "h3jsr", "arrow", "sf", "parallel"))

ensure_dir(DATA_LOOKUP)

tif_files = list.files(DATA_RAW, pattern = "^no2_monthly_.*\\.tif$",
                       full.names = TRUE)
if (length(tif_files) == 0) {
  stop("No monthly files in ", DATA_RAW, ". Run scripts/01_download.R first.")
}

r = rast(tif_files[1])
n_pixel = ncell(r)
message("Grid: ", nrow(r), " x ", ncol(r), " = ", n_pixel, " pixels")

grid_meta = list(
  nrow = nrow(r), ncol = ncol(r),
  extent = as.vector(ext(r)),
  h3_resolution = H3_RESOLUTION,
  source_file = basename(tif_files[1]),
  created = Sys.time()
)

# --- Pixel centers -> H3 addresses, chunked & parallel ------------------------
# h3jsr goes through V8, which is single-threaded per process, so the chunks
# run on a PSOCK cluster (each worker owns its own V8 context).
chunk_size = 1e6
n_chunks = ceiling(n_pixel / chunk_size)
bounds = lapply(seq_len(n_chunks), function(k)
  c((k - 1L) * chunk_size + 1L, min(k * chunk_size, n_pixel)))

n_cl = min(N_WORKERS, n_chunks)
message("Indexing pixel centers to H3 res ", H3_RESOLUTION,
        " in ", n_chunks, " chunks on ", n_cl, " workers...")
src_file = tif_files[1]
cl = makeCluster(n_cl)
clusterExport(cl, c("src_file", "H3_RESOLUTION", "SHARD_RESOLUTION"))
invisible(clusterEvalQ(cl, suppressMessages({
  library(terra); library(h3jsr)
})))

h3_chunks = parLapplyLB(cl, bounds, function(b) {
  r = rast(src_file)
  xy = xyFromCell(r, b[1]:b[2])
  point_to_cell(data.frame(lng = xy[, 1], lat = xy[, 2]),
                res = H3_RESOLUTION)
})
h3_by_pixel = unlist(h3_chunks, use.names = FALSE)
rm(h3_chunks)

# --- Cell table with compact integer ids -------------------------------------
h3_unique = sort(unique(h3_by_pixel))
message(length(h3_unique), " unique H3 cells")

cells = data.table(cell_id = seq_along(h3_unique), h3 = h3_unique)
parent_chunks = split(cells$h3, ceiling(seq_len(nrow(cells)) / chunk_size))
cells[, shard := unlist(parLapplyLB(cl, parent_chunks, function(hh)
  get_parent(hh, res = SHARD_RESOLUTION)), use.names = FALSE)]

# Cell-center coordinates (chunked, same V8 route as point_to_cell)
message("Computing cell centers...")
coord_chunks = split(cells$h3, ceiling(seq_len(nrow(cells)) / chunk_size))
coords = do.call(rbind, parLapplyLB(cl, coord_chunks, function(hh) {
  sf::st_coordinates(cell_to_point(hh, simple = TRUE))
}))
cells[, `:=`(lng = coords[, 1], lat = coords[, 2])]
stopCluster(cl)

# --- Write --------------------------------------------------------------------
pixel_cell = data.table(cell_id = cells[chmatch(h3_by_pixel, h3), cell_id])
write_parquet(pixel_cell, file.path(DATA_LOOKUP, "pixel_cell.parquet"))
write_parquet(cells, file.path(DATA_LOOKUP, "cells.parquet"))
saveRDS(grid_meta, file.path(DATA_LOOKUP, "grid_meta.rds"))

message("Lookup written to ", DATA_LOOKUP, ": ",
        n_pixel, " pixels -> ", nrow(cells), " cells in ",
        uniqueN(cells$shard), " shards")

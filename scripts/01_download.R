# ============================================================================
# Script 01: Download monthly global NO2 GeoTIFFs from Terrascope
# ============================================================================
# data/raw is an APPEND-ONLY archive: we only request months newer than the
# newest archived file and never overwrite or delete. This is what keeps the
# scored history consistent over time (see README) — if Terrascope ever
# reprocesses the product, keano keeps scoring from the archived vintage.
# ============================================================================

source("config/config.R")
loadPackages(c("terrascoper", "terra"))

ensure_dir(DATA_RAW)
ensure_dir(file.path(TMP_DIR, "previews"))

# --- Determine the incremental date range -----------------------------------
# NO2 and NO2_WEIGHT each keep their own incremental start, so a weight
# backfill can catch up independently of the NO2 archive.
incremental_start = function(prefix) {
  existing = list.files(DATA_RAW, pattern = paste0("^", prefix, "_\\d{8}.*\\.tif$"))
  if (length(existing) == 0) {
    message(prefix, ": empty archive, starting from ", START_DATE)
    return(as.Date(START_DATE))
  }
  last_date = max(as.Date(regmatches(existing, regexpr("\\d{8}", existing)),
                          format = "%Y%m%d"))
  message("Archive holds ", length(existing), " ", prefix, " months up to ",
          month_label(last_date))
  # First day of the month after the newest archived month
  seq(as.Date(format(last_date, "%Y-%m-01")), length = 2, by = "1 month")[2]
}

for (asset in list(c("NO2", "no2_monthly"), c("NO2_WEIGHT", "no2_weight"))) {
  download_start = incremental_start(asset[2])
  if (download_start > as.Date(END_DATE)) {
    message(asset[2], ": archive is up to date, nothing to download.")
    next
  }
  message(asset[2], ": Requesting ", month_label(download_start), " .. ",
          month_label(END_DATE))
  download_terrascope(
    bbox        = BBOX_GLOBAL,
    start_date  = format(download_start, "%Y-%m-%d"),
    end_date    = END_DATE,
    output_dir  = DATA_RAW,
    collection  = S5P_COLLECTION,
    asset_key   = asset[1],
    file_prefix = asset[2]
  )
}

# --- Preview PNGs for visual QC ----------------------------------------------
# One auto-scaled PNG per raw file so anomalous months stand out. Skips
# existing previews, so repeated runs are cheap.
tif_files = list.files(DATA_RAW, pattern = "^no2_monthly_.*\\.tif$",
                       full.names = TRUE)
tif_files = tif_files[!grepl("\\.aux\\.xml", tif_files)]

for (f in tif_files) {
  png_file = file.path(TMP_DIR, "previews",
                       sub("\\.tif$", ".png", basename(f)))
  if (file.exists(png_file)) next
  message("Preview: ", basename(png_file))
  r = rast(f)
  png(png_file, width = 1600, height = 800)
  plot(r, col = hcl.colors(100, "YlOrRd", rev = TRUE), main = basename(f))
  dev.off()
  rm(r)
}

message("Done. Archive: ", length(tif_files), " monthly files.")

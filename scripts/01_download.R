# ============================================================================
# Script 01: Download monthly global NO2 GeoTIFFs from Terrascope
# ============================================================================
# data/raw is an APPEND-ONLY archive: we only request months newer than the
# newest archived file and never overwrite or delete. This is what keeps the
# scored history consistent over time (see README) — if Terrascope ever
# reprocesses the product, Lichterloh keeps scoring from the archived vintage.
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

# --- Vintage check -----------------------------------------------------------
# Append-only guarantees we never overwrite; it does not tell us when upstream
# revises a month we already hold. Terrascope does revise, in two shapes: one
# campaign moved `updated` and left `created` alone, another deleted and
# recreated the items so both moved. So the fingerprint is processing:version,
# both item timestamps and the asset's declared size — all free metadata, no
# redownload — and vintage.csv sits next to the archive it describes.
#
# Rows are never rewritten. The manifest records the vintage we hold, not what
# upstream says today, so drift stays visible until someone re-vintages on
# purpose. On drift we stop: the archive stays authoritative (never
# redownload), but nothing should publish until a human has looked.
# NO2_VINTAGE_ACK=1 acknowledges and continues.
VINTAGE_FILE = file.path(DATA_RAW, "vintage.csv")

fld = function(x, k) { v = x[[k]]; if (is.null(v)) NA_character_ else as.character(v) }

archive_tifs = list.files(DATA_RAW, pattern = "\\.tif$")
archive_tifs = archive_tifs[!grepl("\\.aux\\.xml$", archive_tifs)]
archive_size = setNames(file.size(file.path(DATA_RAW, archive_tifs)), archive_tifs)

message("\nVintage check: ", S5P_COLLECTION)
items = search_terrascope(bbox = BBOX_GLOBAL, start_date = START_DATE,
                          end_date = END_DATE, collection = S5P_COLLECTION,
                          limit = 500L)

today = format(Sys.Date(), "%Y-%m-%d")
rows = list()
for (f in items$features) {
  p = f$properties
  day = format(as.Date(substr(p$datetime, 1, 10)), "%Y%m%d")
  for (asset in list(c("NO2", "no2_monthly"), c("NO2_WEIGHT", "no2_weight"))) {
    a = f$assets[[asset[1]]]
    if (is.null(a)) next
    hit = archive_tifs[startsWith(archive_tifs, paste0(asset[2], "_", day))]
    if (!length(hit)) next          # not archived (yet) — nothing to compare
    rows[[length(rows) + 1L]] = data.frame(
      file = hit[1], month = substr(p$datetime, 1, 7), asset = asset[1],
      item_id = f$id, proc_version = fld(p, "processing:version"),
      item_created = fld(p, "created"), item_updated = fld(p, "updated"),
      asset_updated = fld(a, "updated"),
      size = as.numeric(fld(a, "file:size")), recorded = today,
      stringsAsFactors = FALSE)
  }
}
upstream = if (length(rows)) do.call(rbind, rows) else NULL

if (is.null(upstream)) {
  message("Vintage: archive is empty, nothing to reconcile.")
} else {
  # colClasses = "character" throughout: read.csv would otherwise type
  # proc_version as integer while the upstream side is character, and every
  # identical() comparison would report a difference that isn't one.
  have = upstream[0, ]
  if (file.exists(VINTAGE_FILE)) {
    have = read.csv(VINTAGE_FILE, colClasses = "character",
                    stringsAsFactors = FALSE)
    have$size = as.numeric(have$size)
  }

  drift = character(); integrity = character(); fresh = upstream[0, ]

  for (i in seq_len(nrow(upstream))) {
    u = upstream[i, ]; disk = unname(archive_size[u$file])
    j = match(u$file, have$file)

    if (is.na(j)) {
      # No record yet. The declared size is checkable, so only adopt the
      # current upstream vintage as ours when the bytes on disk agree.
      if (!is.na(u$size) && !is.na(disk) && disk != u$size)
        drift = c(drift, sprintf(
          "%s %s: %.0f bytes on disk, upstream serves %.0f (no prior record)",
          u$month, u$asset, disk, u$size))
      else fresh = rbind(fresh, u)
      next
    }

    h = have[j, ]
    changed = c(
      if (!identical(h$proc_version,  u$proc_version))
        sprintf("processing:version %s -> %s", h$proc_version, u$proc_version),
      if (!identical(h$item_created,  u$item_created))
        sprintf("created %s -> %s", h$item_created, u$item_created),
      if (!identical(h$item_updated,  u$item_updated))
        sprintf("updated %s -> %s", h$item_updated, u$item_updated),
      if (!identical(h$asset_updated, u$asset_updated))
        sprintf("asset updated %s -> %s", h$asset_updated, u$asset_updated),
      if (!identical(as.numeric(h$size), u$size))
        sprintf("size %.0f -> %.0f", as.numeric(h$size), u$size))
    if (length(changed))
      drift = c(drift, sprintf("%s %s: %s", u$month, u$asset,
                               paste(changed, collapse = "; ")))
    if (!is.na(disk) && !is.na(h$size) && disk != as.numeric(h$size))
      integrity = c(integrity, sprintf(
        "%s %s: %.0f bytes on disk, manifest recorded %.0f",
        u$month, u$asset, disk, as.numeric(h$size)))
  }

  for (fn in setdiff(have$file, upstream$file)) {
    if (!file.exists(file.path(DATA_RAW, fn)))
      integrity = c(integrity, sprintf("%s: in the manifest, missing from the archive", fn))
    else
      drift = c(drift, sprintf("%s: archived and recorded, no longer offered upstream", fn))
  }

  if (nrow(fresh)) {
    out = rbind(have[, names(upstream)], fresh)
    write.csv(out[order(out$file), ], VINTAGE_FILE, row.names = FALSE)
    message("Vintage: recorded ", nrow(fresh), " file(s); manifest now ",
            nrow(out), " rows")
  }

  # Pinned to one collection version, so a successor would not show up as a
  # changed item — it would show up as nothing at all. Informational only.
  stem = sub("-v[0-9]+$", "", S5P_COLLECTION)
  vnum = function(x) as.integer(sub(".*-v([0-9]+)$", "\\1", x))
  ids = tryCatch({
    cs = list_collections()
    if (is.data.frame(cs)) cs$id else vapply(cs, function(x) x$id, "")
  }, error = function(e) character())
  newer = grep(sprintf("^%s-v[0-9]+$", stem), ids, value = TRUE)
  newer = newer[vnum(newer) > vnum(S5P_COLLECTION)]
  if (length(newer))
    message("NOTE: newer collection upstream (", paste(newer, collapse = ", "),
            "); the pipeline is pinned to ", S5P_COLLECTION, " and will not see it.")

  if (length(drift) || length(integrity)) {
    # A campaign-wide reprocessing hits every month at once, so cap the list —
    # this lands in a notification, and 200 identical lines help nobody.
    report = function(title, xs, cap = 15L) {
      message(title)
      for (d in utils::head(xs, cap)) message("  * ", d)
      if (length(xs) > cap) message("  ... and ", length(xs) - cap, " more")
    }
    bar = strrep("=", 74)
    message("\n", bar)
    if (length(drift))
      report("VINTAGE DRIFT — upstream no longer matches the archived vintage:", drift)
    if (length(integrity))
      report("ARCHIVE INTEGRITY — files on disk no longer match the manifest:", integrity)
    message(bar)
    message("The archived vintage stays authoritative — do NOT redownload.\n",
            "Decide whether to keep scoring it or re-vintage the history on\n",
            "purpose, then edit ", VINTAGE_FILE, " to match that decision.\n",
            "NO2_VINTAGE_ACK=1 acknowledges and continues this run.")
    if (!nzchar(Sys.getenv("NO2_VINTAGE_ACK")))
      stop("Vintage check failed: ", length(drift), " drift, ",
           length(integrity), " integrity.")
  } else {
    message("Vintage: ", nrow(upstream), " archived files match upstream.")
  }
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

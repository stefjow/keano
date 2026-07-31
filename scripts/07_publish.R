# ============================================================================
# Step 7: Publish derived views to the share
# ============================================================================
# Copies everything a viewer needs to PUBLISH_DIR (network share): the
# self-contained HTML map, the rankings CSVs, and the README. Pure copies of
# derived views — rerunning after a new month simply refreshes them; the
# panel/metric history never lives on the share (only its raw inputs do).
# ============================================================================

source("config/config.R")

ensure_dir(PUBLISH_DIR)

publish = c(
  file.path(DATA_VIZ, "index.html"),
  file.path(DATA_RANKINGS, "monthly_summary.csv"),
  file.path(DATA_RANKINGS, "monthly_top_credits.csv"),
  file.path(DATA_RANKINGS, "record_cells.csv"),
  "README.md"
)

missing = publish[!file.exists(publish)]
if (length(missing) > 0) {
  stop("Nothing published — missing: ", paste(missing, collapse = ", "),
       ". Run the pipeline (scripts 05/06) first.")
}

for (f in publish) {
  ok = file.copy(f, file.path(PUBLISH_DIR, basename(f)), overwrite = TRUE,
                 copy.date = TRUE)
  if (!ok) stop("Copy failed: ", f)
  message("  ", basename(f), " (",
          format(round(file.size(f) / 2^20, 1), nsmall = 1), " MB)")
}

message("Published ", length(publish), " files to ", PUBLISH_DIR)

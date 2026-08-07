# ============================================================================
# Step 6: Interactive H3 hexagon map (MapLibre), res 3 -> 6
# ============================================================================
# Renders data/viz/index.html — a single self-contained HTML file (MapLibre GL
# + h3-js from CDN, dark basemap tiles; all hexagon data embedded):
#
#   * res-3 hexagons globally (~41k): current metrics + the full monthly
#     m series per hexagon, shown as a small trend chart on mouse-over
#   * full-coverage res-4 / res-5 / res-6 tiers when zoomed in (~0.3M / 1.8M /
#     12.4M cells): no ids, coordinates or polygon geometry are shipped —
#     each tier is a per-res-3-parent occupancy bitmap plus quantized metric
#     planes, and the browser reconstructs H3 ids and hexagon outlines for
#     the cells in the current viewport only
#
# Encoding: metric values are quantized to u8 levels (0 = NA; res-3 series:
# u16) against the scales stored in the payload, delta-encoded, concatenated
# into one binary container, zlib-compressed and base64-embedded; the browser
# inflates it with DecompressionStream. A derived view: regenerating it never
# touches panel or metric history.
# ============================================================================

source("config/config.R")
loadPackages(c("data.table", "arrow", "dplyr", "parallel", "h3jsr", "jsonlite"))

ensure_dir(DATA_VIZ)

months_all = months_in_dataset(DATA_PANEL)
latest = max(months_all)
nm = length(months_all)
message("Rendering hexagon map for ", latest, " (", nm, " months of history)")

# --- H3 id arithmetic on the 15-char hex strings ------------------------------
# The H3 v4 index layout is fixed: char 2 is the resolution nibble, chars 3-6
# hold base cell + digits 1-3 (bits 51-36), digits 4-6 are bits 35-27. So the
# res-3 parent and the 9-bit digit path (digits 4-6) addressing a res-6 cell
# inside it are pure string/bit operations — no h3 library calls per cell.
parent_r3 = function(h) paste0("83", substr(h, 3, 6), "fffffffff")
path_r6   = function(h) bitwShiftR(strtoi(substr(h, 7, 9), 16L), 3L)

# Inverse (parent + path -> child id), mirrored 1:1 by the client-side
# JavaScript; used below to self-test the encoding against h3jsr.
HEXC = strsplit("0123456789abcdef", "")[[1]]
child_id = function(p, res, k) {
  b = substr(p, 3, 6)
  switch(as.character(res),
    "4" = paste0("84", b, HEXC[bitwOr(bitwShiftL(k, 1L), 1L) + 1L],
                 "ffffffff"),
    "5" = paste0("85", b, HEXC[bitwShiftR(k, 2L) + 1L],
                 HEXC[bitwOr(bitwShiftL(bitwAnd(k, 3L), 2L), 3L) + 1L],
                 "fffffff"),
    "6" = paste0("86", b, HEXC[bitwShiftR(k, 5L) + 1L],
                 HEXC[bitwAnd(bitwShiftR(k, 1L), 15L) + 1L],
                 HEXC[bitwOr(bitwShiftL(bitwAnd(k, 1L), 3L), 7L) + 1L],
                 "ffffff"))
}

# res-1 parent of a res-3 id (digits 2-3 -> 7, res nibble -> 1); groups the
# res-6 planes into the web bundle's spatial chunks
r1_of_r3 = function(h) paste0("81", substr(h, 3, 4),
  HEXC[bitwOr(bitwAnd(strtoi(substr(h, 5, 5), 16L), 12L), 3L) + 1L],
  "ffffffffff")

smp = open_dataset(file.path(DATA_LOOKUP, "cells.parquet")) |>
  head(200000) |> select(h3) |> collect()
smp = sample(smp$h3, 1000)
pth = path_r6(smp)
stopifnot(identical(parent_r3(smp), get_parent(smp, 3)),
          identical(child_id(parent_r3(smp), 6, pth), smp),
          identical(child_id(parent_r3(smp), 5, pth %/% 8L), get_parent(smp, 5)),
          identical(child_id(parent_r3(smp), 4, pth %/% 64L), get_parent(smp, 4)),
          identical(r1_of_r3(parent_r3(smp)), get_parent(smp, 1)))
rm(smp, pth)

shards = sort(sub("^shard=", "",
                  grep("^shard=", list.dirs(DATA_METRICS, recursive = FALSE,
                                            full.names = FALSE), value = TRUE)))

# --- Per shard: res-3 series + res-3 latest metrics + all res-6 cells ---------
# A res-3 cell lies entirely within one res-0 shard (H3 truncation is
# hierarchical), so per-shard aggregates are already complete.
do_shard = function(s) {
  ce = open_dataset(file.path(DATA_LOOKUP, "cells.parquet")) |>
    filter(shard == s) |> select(cell_id, h3) |> collect() |> as.data.table()
  ce[, `:=`(r3 = parent_r3(h3), path = path_r6(h3), h3 = NULL)]

  hist = open_dataset(DATA_METRICS) |>
    filter(shard == s) |> select(cell_id, month, m) |> collect() |>
    as.data.table()
  if (nrow(hist) == 0) return(NULL)
  hist[ce, r3 := i.r3, on = "cell_id"]
  ser = hist[is.finite(m), .(sum_m = sum(m), n_m = .N), by = .(r3, month)]
  rm(hist)

  last = open_dataset(DATA_METRICS) |>
    filter(shard == s, month == latest) |>
    select(cell_id, m, perf_short, perf_long, credit, eligible) |>
    collect() |> as.data.table()
  last[ce, `:=`(r3 = i.r3, path = i.path), on = "cell_id"]
  last[, elig := !is.na(eligible) & eligible]

  # YoY/trend aggregate over ALL cells with finite values so the layers have
  # full coverage at every tier (res 6 shows raw per-cell values); credit
  # stays gated on eligibility — that is inherent to credit.
  r3last = last[, .(
    sum_m = sum(m[is.finite(m)]),          n_m = sum(is.finite(m)),
    sum_y = sum(perf_short[is.finite(perf_short)]),
    n_y   = sum(is.finite(perf_short)),
    sum_t = sum(perf_long[is.finite(perf_long)]),
    n_t   = sum(is.finite(perf_long)),
    credit = sum(credit, na.rm = TRUE),    n_el = sum(elig),
    n_cr  = sum(!is.na(credit) & credit > 0)
  ), by = r3]

  fine = last[is.finite(m),
              .(r3, path, m, perf_short, perf_long, credit, elig)]
  list(ser = ser, r3last = r3last, fine = fine)
}

# PSOCK, not fork (see script 03): arrow used pre-fork deadlocks in children
cl = makeCluster(max(1L, min(N_WORKERS, length(shards))), outfile = "")
clusterExport(cl, c("do_shard", "latest", "parent_r3", "path_r6",
                    "DATA_METRICS", "DATA_LOOKUP"))
invisible(clusterEvalQ(cl, suppressMessages({
  library(data.table); library(arrow); library(dplyr)
  setDTthreads(2); set_cpu_count(2)
})))
res = parLapplyLB(cl, shards, function(s) try(do_shard(s), silent = TRUE))
stopCluster(cl)
failed = vapply(res, inherits, TRUE, "try-error")
if (any(failed)) {
  stop("Failed shards:\n",
       paste(unlist(lapply(res[failed], as.character)), collapse = "\n"))
}
res = res[!vapply(res, is.null, TRUE)]
ser    = rbindlist(lapply(res, `[[`, "ser"))
r3last = rbindlist(lapply(res, `[[`, "r3last"))
fine   = rbindlist(lapply(res, `[[`, "fine"))
rm(res)

# --- res-3 alignment + res-4/5 aggregates -------------------------------------
# The series can contain res-3 cells with history but no latest-month row;
# align r3last to the union (missing metrics become NA -> level 0).
r3_ids = sort(unique(c(r3last$r3, ser$r3)))
nP = length(r3_ids)
r3last = r3last[data.table(r3 = r3_ids), on = "r3"]

fine[, r3i := chmatch(r3, r3_ids)]
stopifnot(!anyNA(fine$r3i))
setorder(fine, r3i, path)      # bitmap enumeration order (parent, then path)
fine[, `:=`(p4 = path %/% 64L, p5 = path %/% 8L)]   # digit 4 / digits 4-5

agg_tier = function(key) {
  fine[, .(
    m = mean(m),
    y = mean(perf_short[is.finite(perf_short)]),   # NaN if none
    t = mean(perf_long[is.finite(perf_long)]),
    credit = sum(credit, na.rm = TRUE),
    n_el = sum(elig)
  ), keyby = c("r3i", key)]
}
t4 = agg_tier("p4")
t5 = agg_tier("p5")
message(format(nP, big.mark = ","), " res-3 / ",
        format(nrow(t4), big.mark = ","), " res-4 / ",
        format(nrow(t5), big.mark = ","), " res-5 / ",
        format(nrow(fine), big.mark = ","), " res-6 hexagons")

# --- Scales -----------------------------------------------------------------
clamp01 = function(t) pmin(pmax(t, 0), 1)
r3last[, `:=`(
  m3 = ifelse(n_m > 0, sum_m / n_m, NA_real_),
  y3 = ifelse(n_y > 0, sum_y / n_y, NA_real_),
  t3 = ifelse(n_t > 0, sum_t / n_t, NA_real_)
)]

m_pool = c(r3last$m3, fine$m)
lmin = log10(max(1, as.numeric(quantile(m_pool, 0.005, na.rm = TRUE))))
lmax = log10(as.numeric(quantile(m_pool, 0.999, na.rm = TRUE)))
# YoY/trend scales from the eligible pool: low-NO2 cells swing wildly in
# relative terms and would wash out the meaningful signal (they just clamp).
sym_y = signif(as.numeric(quantile(abs(c(r3last$y3, fine[elig == TRUE, perf_short])),
                                   0.98, na.rm = TRUE)), 2)
sym_t = signif(as.numeric(quantile(abs(c(r3last$t3, fine[elig == TRUE, perf_long])),
                                   0.98, na.rm = TRUE)), 2)
# true max, not a quantile: the sqrt scale keeps low-end resolution anyway,
# and clamping would truncate exactly the cells the top list showcases
cr_max = function(v) {
  hi = suppressWarnings(max(v[v > 0], na.rm = TRUE))
  if (!is.finite(hi) || hi <= 0) 1 else hi
}
cr3_max = cr_max(r3last$credit)
cr4_max = cr_max(t4$credit)
cr5_max = cr_max(t5$credit)
cr6_max = cr_max(fine$credit)

t_m   = function(v) clamp01((log10(pmax(v, 1e-6)) - lmin) / (lmax - lmin))
t_sym = function(v, s) clamp01((v / s + 1) / 2)
t_cr  = function(v, hi) sqrt(clamp01(v / hi))

# --- Binary container ---------------------------------------------------------
# Sections are quantized levels (0 = NA), delta-encoded so that the smooth
# spatial fields compress well, concatenated, zlib-compressed, base64-embedded.
lev_u8  = function(t) fifelse(is.finite(t), 1L + as.integer(round(t * 254)), 0L)
lev_u16 = function(t) fifelse(is.finite(t), 1L + as.integer(round(t * 65533)), 0L)
delta_u8 = function(lev) as.raw((lev - c(0L, lev[-length(lev)])) %% 256L)
delta_u16_raw = function(lev) {
  d = (lev - c(0L, lev[-length(lev)])) %% 65536L
  d = ifelse(d > 32767L, d - 65536L, d)   # signed trick for writeBin size=2
  con = rawConnection(raw(0), "wb")
  writeBin(d, con, size = 2L, endian = "little")
  x = rawConnectionValue(con); close(con)
  x
}
raw_bin = function(v, size) {
  con = rawConnection(raw(0), "wb")
  writeBin(v, con, size = size, endian = "little")
  x = rawConnectionValue(con); close(con)
  x
}
bitmap_raw = function(r3i, key, B) {   # LSB-first occupancy bitmap per parent
  dt = data.table(byte = (r3i - 1L) * B + key %/% 8L,
                  v = bitwShiftL(1L, key %% 8L))
  dt = dt[, .(v = sum(v)), by = byte]  # keys unique per parent -> sum == OR
  out = raw(nP * B)
  out[dt$byte + 1L] = as.raw(dt$v)
  out
}

sections = list()
manifest = list()
bin_off = 0
add_sec = function(name, r) {
  sections[[name]] <<- r
  manifest[[length(manifest) + 1L]] <<- list(name, bin_off, length(r))
  bin_off <<- bin_off + length(r)
}

ser[, i := chmatch(r3, r3_ids)]
ser[, j := chmatch(month, months_all)]
t_ser = rep(NA_real_, nP * nm)
t_ser[(ser$i - 1L) * nm + ser$j] = t_m(ser$sum_m / ser$n_m)

add_sec("r3ids", charToRaw(paste(r3_ids, collapse = "")))
add_sec("tm3", delta_u8(lev_u8(t_m(r3last$m3))))
add_sec("ty3", delta_u8(lev_u8(t_sym(r3last$y3, sym_y))))
add_sec("tt3", delta_u8(lev_u8(t_sym(r3last$t3, sym_t))))
add_sec("tc3", delta_u8(lev_u8(fifelse(!is.na(r3last$n_el) & r3last$n_el > 0,
                                       t_cr(r3last$credit, cr3_max), NA_real_))))
add_sec("r3series", delta_u16_raw(lev_u16(t_ser)))
# exact regional credit for the viewport-aware "top regions" table
add_sec("cr3f", raw_bin(as.numeric(fifelse(is.na(r3last$credit), 0,
                                           r3last$credit)), 4L))
add_sec("nc3", raw_bin(fifelse(is.na(r3last$n_cr), 0L, r3last$n_cr), 2L))

tier_sec = function(r, tt, key, B, crmax) {
  add_sec(paste0("bm", r), bitmap_raw(tt$r3i, key, B))
  add_sec(paste0("tm", r), delta_u8(lev_u8(t_m(tt$m))))
  add_sec(paste0("ty", r), delta_u8(lev_u8(t_sym(tt$y, sym_y))))
  add_sec(paste0("tt", r), delta_u8(lev_u8(t_sym(tt$t, sym_t))))
  add_sec(paste0("tc", r), delta_u8(lev_u8(fifelse(tt$n_el > 0,
                                                   t_cr(tt$credit, crmax),
                                                   NA_real_))))
}
tier_sec(4, t4, t4$p4, 1L, cr4_max)
tier_sec(5, t5, t5$p5, 8L, cr5_max)
# res 6: raw per-cell values; credit is the cell's own relative undercut,
# defined (>= 0) for eligible cells and NA (transparent) otherwise.
# Levels kept un-delta'd too: the web bundle re-deltas them per chunk.
lev6 = list(
  tm = lev_u8(t_m(fine$m)),
  ty = lev_u8(t_sym(fine$perf_short, sym_y)),
  tt = lev_u8(t_sym(fine$perf_long, sym_t)),
  tc = lev_u8(fifelse(fine$elig,
                      t_cr(fifelse(is.na(fine$credit), 0, fine$credit),
                           cr6_max),
                      NA_real_))
)
add_sec("bm6", bitmap_raw(fine$r3i, fine$path, 64L))
for (pl in names(lev6)) add_sec(paste0(pl, 6), delta_u8(lev6[[pl]]))

bin = do.call(c, unname(sections))
comp = memCompress(bin, type = "gzip")   # zlib stream; browser sniffs format
b64 = gsub("\n", "", base64_enc(comp), fixed = TRUE)
message("Container: ", round(length(bin) / 2^20, 1), " MB raw -> ",
        round(length(comp) / 2^20, 1), " MB compressed")

# --- Global series, top list, stats ------------------------------------------------
monthly = fread(file.path(DATA_RANKINGS, "monthly_summary.csv"))
series_global = monthly[, .(month, credit = round(total_credit, 1),
                            perf = round(mean_perf_short_eligible, 5))]
stats = as.list(monthly[month == latest,
                        .(n_cells_obs, n_eligible, n_records,
                          total_credit = round(total_credit))])

# --- Assemble --------------------------------------------------------------------
meta = list(
  month = latest,
  generated = format(Sys.time(), "%Y-%m-%d %H:%M"),
  months = months_all,
  scales = list(m = list(lmin = lmin, lmax = lmax),
                yoy = list(sym = sym_y), trend = list(sym = sym_t),
                credit3 = list(max = cr3_max), credit4 = list(max = cr4_max),
                credit5 = list(max = cr5_max), credit6 = list(max = cr6_max)),
  nP = nP,
  n = list(`4` = nrow(t4), `5` = nrow(t5), `6` = nrow(fine)),
  series_global = series_global,
  stats = stats
)

# Splice instead of sub(): the replacement strings are huge and sub() would
# interpret backslashes/backreferences in them.
html = paste(readLines("viz/template.html", encoding = "UTF-8"), collapse = "\n")
splice = function(meta_list, bin_b64, out_file) {
  a = strsplit(html, "__KEANO_META__", fixed = TRUE)[[1]]
  stopifnot(length(a) == 2)
  b = strsplit(a[2], "__KEANO_BIN__", fixed = TRUE)[[1]]
  stopifnot(length(b) == 2)
  json = toJSON(meta_list, auto_unbox = TRUE, digits = NA)
  writeLines(paste0(a[1], json, b[1], bin_b64, b[2]), out_file, useBytes = TRUE)
}

# --- Single-file build (network share: no HTTP, everything embedded) ----------
meta_single = meta
meta_single$bin_len = length(bin)
meta_single$manifest = manifest
out_file = file.path(DATA_VIZ, "index.html")
splice(meta_single, b64, out_file)
message("Single-file map: ", out_file, " (",
        round(file.size(out_file) / 2^20, 1), " MB)")

# --- Web bundle (public hosting: shell + binaries fetched on demand) ----------
# data/<month>/ is immutable — serve with long-lived cache headers, and
# index.html with no-cache; every .bin gets a precompressed .gz sibling for
# nginx gzip_static.
WEB_DIR = file.path(DATA_VIZ, "web")
wdata = ensure_dir(file.path(WEB_DIR, "data", latest))
write_bin_gz = function(r, path) {
  writeBin(r, path)
  con = gzfile(paste0(path, ".gz"), "wb", compression = 9L)
  writeBin(r, con); close(con)
  invisible(length(r))
}
concat_file = function(names) {
  man = list(); off = 0
  for (nm in names) {
    man[[length(man) + 1L]] = list(nm, off, length(sections[[nm]]))
    off = off + length(sections[[nm]])
  }
  list(bin = do.call(c, unname(sections[names])), manifest = man)
}
core = concat_file(c("r3ids", "tm3", "ty3", "tt3", "tc3", "cr3f", "nc3"))
t4f  = concat_file(c("bm4", "tm4", "ty4", "tt4", "tc4"))
t5f  = concat_file(c("bm5", "tm5", "ty5", "tt5", "tc5"))
write_bin_gz(core$bin, file.path(wdata, "core.bin"))
write_bin_gz(sections$r3series, file.path(wdata, "series.bin"))
write_bin_gz(t4f$bin, file.path(wdata, "t4.bin"))
write_bin_gz(t5f$bin, file.path(wdata, "t5.bin"))

# res-6 planes chunked by res-1 parent. Sorted res-3 ids are contiguous
# within a res-1 parent (lexicographic = prefix order), so every chunk is an
# index range: [first, first + nR3) parents, their cells re-delta'd locally.
r1 = r1_of_r3(r3_ids)
rl = rle(r1)
stopifnot(!anyDuplicated(rl$values))
first = cumsum(c(1L, head(rl$lengths, -1L)))
off6 = c(0L, cumsum(tabulate(fine$r3i, nbins = nP)))
chunks_meta = vector("list", length(rl$lengths))
for (k in seq_along(rl$lengths)) {
  a = first[k]; nr = rl$lengths[k]
  cells = if (off6[a + nr] > off6[a]) (off6[a] + 1L):off6[a + nr] else integer(0)
  raw_k = c(sections$bm6[((a - 1L) * 64L + 1L):((a + nr - 1L) * 64L)],
            unlist(lapply(lev6, function(v) delta_u8(v[cells])),
                   use.names = FALSE))
  write_bin_gz(as.raw(raw_k), file.path(wdata, sprintf("r6-%04d.bin", k - 1L)))
  chunks_meta[[k]] = c(a - 1L, nr, length(cells))
}
# --- Per-hex monthly series (web only; fetched per cell via HTTP ranges) -----
# s<r>.bin holds one row per tier-r hex in plane order (r3, then digit path),
# NM u16 levels delta-encoded per row. A hex's row sits at featureId*NM*2, so
# the client range-fetches exactly 2*NM bytes on hover. Too big to embed
# (res-6: ~2.4 GB), cheap to store, never downloaded in bulk.
do_series_shard = function(s) {
  clamp01 = function(t) pmin(pmax(t, 0), 1)
  lev16 = function(m) {
    t = clamp01((log10(pmax(m, 1e-6)) - lmin) / (lmax - lmin))
    fifelse(is.finite(t), 1L + as.integer(round(t * 65533)), 0L)
  }
  write_rows = function(v, nrows, path) {
    d = (v - c(0L, v[-length(v)])) %% 65536L
    starts = (seq_len(nrows) - 1L) * nm + 1L
    d[starts] = v[starts]
    d = ifelse(d > 32767L, d - 65536L, d)
    con = file(path, "wb")
    writeBin(d, con, size = 2L, endian = "little")
    close(con)
  }

  ce = open_dataset(file.path(DATA_LOOKUP, "cells.parquet")) |>
    filter(shard == s) |> select(cell_id, h3) |> collect() |> as.data.table()
  ce[, `:=`(r3 = parent_r3(h3), path = path_r6(h3), h3 = NULL)]
  hist = open_dataset(DATA_METRICS) |>
    filter(shard == s) |> select(cell_id, month, m) |> collect() |>
    as.data.table()
  hist = hist[is.finite(m)]
  if (nrow(hist) == 0) return(NULL)
  hist[ce, `:=`(r3 = i.r3, path = i.path), on = "cell_id"]
  hist[, j := chmatch(month, months_all)]

  counts = integer(3)
  # res 6: cells with finite m in the latest month, ordered like the planes.
  # A shard can have history but no current cells (Antarctic winter): it then
  # contributes no rows to any tier — same exclusion as the metric planes.
  rows = ce[cell_id %in% hist[month == latest, cell_id]]
  if (nrow(rows) == 0) return(NULL)
  setorder(rows, r3, path)
  rows[, i := .I]
  hist[rows, i6 := i.i, on = "cell_id"]
  v = integer(nrow(rows) * nm)
  sub = hist[!is.na(i6)]
  v[(sub$i6 - 1L) * nm + sub$j] = lev16(sub$m)
  # self-check: one random row re-derived straight from the metric history
  k = sample(nrow(rows), 1)
  chk = integer(nm)
  smp = hist[i6 == k]
  chk[smp$j] = lev16(smp$m)
  stopifnot(identical(chk, v[(k - 1L) * nm + seq_len(nm)]))
  write_rows(v, nrow(rows), file.path(wdata, sprintf(".s6-%s.tmp", s)))
  counts[3] = nrow(rows)
  bounds = c(rows$r3[1], rows$r3[nrow(rows)])
  rm(v, sub)

  # res 4/5: mean of children m per month, rows = groups present at latest
  for (spec in list(list(r = 4L, div = 64L), list(r = 5L, div = 8L))) {
    g = hist[, .(lev = lev16(mean(m))), by = .(r3, p = path %/% spec$div, j)]
    rws = unique(rows[, .(r3, p = path %/% spec$div)])
    setkey(rws, r3, p)
    rws[, i := .I]
    g[rws, ig := i.i, on = c("r3", "p")]
    g = g[!is.na(ig)]
    v = integer(nrow(rws) * nm)
    v[(g$ig - 1L) * nm + g$j] = g$lev
    write_rows(v, nrow(rws), file.path(wdata, sprintf(".s%d-%s.tmp", spec$r, s)))
    counts[spec$r - 3L] = nrow(rws)
    rm(v, g)
  }
  list(shard = s, n = counts, r3_first = bounds[1], r3_last = bounds[2])
}

cl = makeCluster(max(1L, min(N_WORKERS, length(shards))), outfile = "")
clusterExport(cl, c("do_series_shard", "parent_r3", "path_r6", "months_all",
                    "latest", "nm", "lmin", "lmax", "wdata",
                    "DATA_METRICS", "DATA_LOOKUP"))
invisible(clusterEvalQ(cl, suppressMessages({
  library(data.table); library(arrow); library(dplyr)
  setDTthreads(2); set_cpu_count(2)
})))
res = parLapplyLB(cl, shards, function(s) try(do_series_shard(s), silent = TRUE))
stopCluster(cl)
failed = vapply(res, inherits, TRUE, "try-error")
if (any(failed)) {
  stop("Failed series shards:\n",
       paste(unlist(lapply(res[failed], as.character)), collapse = "\n"))
}
res = res[!vapply(res, is.null, TRUE)]
# rows concatenated in sorted-shard order must tile the global plane order:
# counts match, and per-shard res-3 ranges are strictly increasing
stopifnot(
  sum(vapply(res, function(x) x$n[3], 1L)) == nrow(fine),
  sum(vapply(res, function(x) x$n[2], 1L)) == nrow(t5),
  sum(vapply(res, function(x) x$n[1], 1L)) == nrow(t4),
  !is.unsorted(unlist(lapply(res, function(x) c(x$r3_first, x$r3_last)))))
for (r in 4:6) {
  target = file.path(wdata, sprintf("s%d.bin", r))
  unlink(target)
  parts = file.path(wdata, sprintf(".s%d-%s.tmp", r,
                                   vapply(res, `[[`, "", "shard")))
  file.create(target)
  stopifnot(file.append(target, parts))
  unlink(parts)
}
stopifnot(file.size(file.path(wdata, "s6.bin")) == nrow(fine) * nm * 2)
message("Per-hex series: ",
        paste(sprintf("s%d.bin %.0f MB", 4:6,
                      file.size(file.path(wdata, sprintf("s%d.bin", 4:6))) / 2^20),
              collapse = ", "))

meta_web = meta
meta_web$web = list(
  base = paste0("data/", latest),
  files = list(core = list(name = "core.bin", manifest = core$manifest),
               series = list(name = "series.bin"),
               t4 = list(name = "t4.bin", manifest = t4f$manifest),
               t5 = list(name = "t5.bin", manifest = t5f$manifest)),
  series2 = list(`4` = "s4.bin", `5` = "s5.bin", `6` = "s6.bin"),
  r6 = chunks_meta
)
splice(meta_web, "", file.path(WEB_DIR, "index.html"))
web_files = list.files(wdata, full.names = TRUE)
message("Web bundle: ", WEB_DIR, " (", length(web_files) + 1L, " files; ",
        round(sum(file.size(web_files[!grepl("\\.gz$", web_files)])) / 2^20, 1),
        " MB raw, ",
        round(sum(file.size(web_files[grepl("\\.gz$", web_files)])) / 2^20, 1),
        " MB gzipped)")

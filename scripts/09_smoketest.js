#!/usr/bin/env node
// GENERATED — built from lufterl-map v1.4.1 (2026-09-05). This file is a build artifact; edit the lufterl-map repo instead, then re-vendor.
/* ============================================================================
 * Smoke test of the built web bundle (lufterl-map)
 * ============================================================================
 * Serves a web bundle locally and drives it in headless Chrome. Guards the
 * regressions we actually shipped fixes for: page-level JS crashes (ECharts),
 * deep links arriving at a zoom where the hex renders, and the region panel
 * resizing when the pin chip disappears.
 *
 * Three runs from one suite:
 *   desktop     — Chrome forced to report a hover-capable mouse pointer
 *                 (headless defaults to hover:none): hover previews, click
 *                 pins, the ⌖ chip releases without hiding or resizing the
 *                 panel, hex and viewport deep links;
 *   layer control — the three primary layers, the horizons under Change and
 *                 Credit, their scales and hash round-trip;
 *   top regions — the three credit-window scopes, → flying to a hex in every
 *                 tier the map draws without leaving that tier, and the
 *                 ten-row default with its “show top n” toggle;
 *   touch       — default headless (hover:none): tap pins, × dismisses.
 *
 * Needs: npm install (puppeteer-core) and a Chrome under ~/.cache/puppeteer
 * (or PUPPETEER_EXECUTABLE_PATH). The map libraries are bundled into the app,
 * so no internet is required beyond the basemap tiles (whose absence the app
 * tolerates). Bundle dir: NO2_WEB_DIR, else .stage/ (repo: `npm run stage`),
 * else ../data/viz/web relative to this file (pipeline layout, where the
 * deploy script runs it as a gate — SKIP_SMOKE=1 to bypass). Exit 0 = green.
 * ==========================================================================*/
"use strict";

const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const puppeteer = require("puppeteer-core");

const WEB_DIR = process.env.NO2_WEB_DIR ||
  [path.resolve(".stage"),                              // repo: staged current build
   path.join(__dirname, "..", "data", "viz", "web")]    // pipeline: the real bundle
    .find(d => fs.existsSync(path.join(d, "index.html"))) ||
  path.resolve(".stage");
const HOVER_FLAG = "--blink-settings=primaryHoverType=2,availableHoverTypes=2," +
                   "primaryPointerType=4,availablePointerTypes=4";
/* NO2_OFFLINE=1: refuse all DNS except localhost, proving the page needs no
   network beyond its own host — basemap tiles fail, everything else must pass. */
const OFFLINE_ARGS = process.env.NO2_OFFLINE
  ? ["--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"] : [];

/* --- Chrome from the puppeteer cache (puppeteer-core doesn't resolve it) --- */
function findChrome() {
  if (process.env.PUPPETEER_EXECUTABLE_PATH) return process.env.PUPPETEER_EXECUTABLE_PATH;
  const base = path.join(os.homedir(), ".cache", "puppeteer", "chrome");
  const vnum = d => d.split("-").pop().split(".").map(Number);
  const versions = fs.existsSync(base)
    ? fs.readdirSync(base).sort((a, b) => {
        const va = vnum(a), vb = vnum(b);
        for (let i = 0; i < va.length; i++) if (va[i] !== vb[i]) return va[i] - vb[i];
        return 0;
      })
    : [];
  for (const v of versions.reverse()) {
    const dir = path.join(base, v);
    for (const sub of fs.readdirSync(dir)) {
      const bin = path.join(dir, sub, sub.startsWith("chrome-headless") ? "chrome-headless-shell" : "chrome");
      if (sub.startsWith("chrome-") && !sub.startsWith("chrome-headless") && fs.existsSync(bin))
        return bin;
    }
  }
  throw new Error("no Chrome found — set PUPPETEER_EXECUTABLE_PATH or npx puppeteer browsers install chrome");
}

/* --- Static server with Range support (per-hex series use range requests) --- */
const MIME = { ".html": "text/html; charset=utf-8", ".bin": "application/octet-stream",
               ".csv": "text/csv", ".png": "image/png" };
function serve(root) {
  return new Promise(resolve => {
    const srv = http.createServer((req, res) => {
      const rel = decodeURIComponent(new URL(req.url, "http://x").pathname);
      const file = path.join(root, rel === "/" ? "index.html" : rel);
      if (!file.startsWith(root) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
        res.writeHead(404); res.end(); return;
      }
      const size = fs.statSync(file).size;
      const type = MIME[path.extname(file)] || "application/octet-stream";
      const m = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range || "");
      if (m) {
        const a = +m[1], b = Math.min(+m[2], size - 1);
        res.writeHead(206, { "Content-Type": type, "Content-Length": b - a + 1,
                             "Content-Range": `bytes ${a}-${b}/${size}` });
        fs.createReadStream(file, { start: a, end: b }).pipe(res);
      } else {
        res.writeHead(200, { "Content-Type": type, "Content-Length": size,
                             "Accept-Ranges": "bytes" });
        fs.createReadStream(file).pipe(res);
      }
    });
    srv.listen(0, "127.0.0.1", () => resolve(srv));
  });
}

/* --- Tiny harness ----------------------------------------------------------- */
let failures = 0;
function ok(cond, label) {
  console.log((cond ? "  ok    " : "  FAIL  ") + label);
  if (!cond) failures++;
}

async function newPage(browser, url) {
  const page = await browser.newPage();
  const errors = [];
  const dataReqs = [];
  page.on("pageerror", e => errors.push(String(e)));
  page.on("response", r => {
    const u = new URL(r.url());
    if (u.hostname === "127.0.0.1" && r.status() >= 400) errors.push(r.status() + " " + u.pathname);
    if (u.pathname.endsWith(".bin")) dataReqs.push(u.pathname + u.search);
  });
  await page.goto(url, { waitUntil: "domcontentloaded" });
  // loading overlay removes itself once data + map are up; then wait for idle
  await page.waitForFunction("!document.getElementById('loading')", { timeout: 60000 });
  await page.evaluate(() => new Promise(r => {
    const m = window._appMap;
    m.loaded() && !m.isMoving() ? r() : m.once("idle", r);
  }));
  return { page, errors, dataReqs };
}

/* Pick a rendered res-3 hex whose center projects well inside the map and
   clear of the UI (left rail on desktop, layer card / bottom sheet on touch),
   and return its id + page pixel coordinates. */
function pickHex(page) {
  return page.evaluate(() => {
    const map = window._appMap;
    const rect = map.getContainer().getBoundingClientRect();
    const cx = rect.width * 0.6, cy = rect.height * 0.4;
    let best = null;
    const seen = new Set();
    /* sample point queries across the clear zone: on the globe projection,
       geometry-less / whole-viewport queries come back empty whenever a
       screen corner misses the planet, but point queries always work */
    for (let gx = 0.32; gx <= 0.93; gx += 0.03) {
      for (let gy = 0.2; gy <= 0.68; gy += 0.04) {
        const f = map.queryRenderedFeatures([rect.width * gx, rect.height * gy],
                                            { layers: ["r3-fill"] })[0];
        if (!f || seen.has(f.properties.id)) continue;
        seen.add(f.properties.id);
        const [la, lo] = window._app.h3.cellToLatLng(f.properties.id);
        const p = map.project([lo, la]);
        if (p.x < 400 || p.y < 130 || p.x > rect.width - 80 || p.y > rect.height - 220) continue;
        const d = (p.x - cx) ** 2 + (p.y - cy) ** 2;
        if (!best || d < best.d) best = { id: f.properties.id,
                                          x: rect.left + p.x, y: rect.top + p.y, d };
      }
    }
    return best;
  });
}

const $text = (page, sel) => page.$eval(sel, el => el.textContent);
const $display = (page, sel) => page.$eval(sel, el => getComputedStyle(el).display);
/* Which hex the region panel is showing. The copy-link button carries it in
   data-h3; the panel prints coordinates, not the fifteen-character index. */
const $hex = page => page.$eval("#rp-h3", el => el.dataset.h3 || "");
const panelState = page => page.$eval("#region-panel", el =>
  ({ hidden: el.hidden, pinned: el.classList.contains("pinned"), height: el.offsetHeight }));

/* --- Desktop run (hover-capable pointer) ------------------------------------ */
async function desktopRun(browser, base) {
  console.log("desktop (hover pointer):");
  const { page, errors } = await newPage(browser, base);

  const hex = await pickHex(page);
  ok(hex, "a res-3 hex renders clear of the UI");
  if (!hex) return;

  // hover previews
  await page.mouse.move(hex.x, hex.y);
  await page.waitForFunction("!document.getElementById('region-panel').hidden", { timeout: 5000 });
  let st = await panelState(page);
  ok(!st.hidden && !st.pinned, "hover shows the region panel unpinned");
  ok((await $hex(page)) === hex.id, "panel shows the hovered hex " + hex.id);
  ok((await page.$eval("#rp-h3", el => el.title)).includes(hex.id),
     "and the copy button still names it for anyone who wants to read it");

  // both charts alive (rp-chart exists only once the panel drew)
  ok(await page.evaluate(() =>
    ["chart-global", "rp-chart"].every(id =>
      !!window._app.echarts.getInstanceByDom(document.getElementById(id)))),
    "two live ECharts instances");

  /* The credit line waits on series.bin / a range request, and it changes the
     panel's height when it lands. Settle it before measuring heights below,
     or the release assertion races the fetch. */
  await page.waitForFunction("document.getElementById('rp-cred').textContent !== ''",
                             { timeout: 30000 });
  ok(/^[⬢⬡] (paid \d+\/\d+ mo · peak |never paid in \d+ mo)/u
       .test(await $text(page, "#rp-cred")),
     "credit history line reads “" + (await $text(page, "#rp-cred")) + "”");

  // click pins; ⌖ chip visible, × hidden on hover devices
  await page.mouse.click(hex.x, hex.y);
  st = await panelState(page);
  ok(st.pinned, "click pins the panel");
  ok(await $display(page, "#rp-pin") !== "none", "⌖ unpin chip is visible");
  ok(await $display(page, "#rp-close") === "none", "× stays touch-only");

  /* The unpin chip is anchored to the pinned cell itself rather than to the
     rail — the whole point of it. So it has to hang above the cell's centre,
     travel with the cell when the map moves, and leave with the pin. */
  const chipAt = () => page.evaluate(id => {
    const b = document.getElementById("unpin");
    if (!b) return null;
    const r = b.getBoundingClientRect();
    const [la, lo] = window._app.h3.cellToLatLng(id);
    const c = window._appMap.project([lo, la]);
    return { dx: r.left + r.width / 2 - c.x, dy: r.bottom - c.y };
  }, hex.id);
  let chip = await chipAt();
  ok(chip && Math.abs(chip.dx) < 30 && chip.dy < 0,
     "the unpin chip hangs above the pinned cell" + (chip
       ? " (dx " + Math.round(chip.dx) + ", dy " + Math.round(chip.dy) + ")"
       : " — absent"));

  // chip releases without hiding or resizing the panel
  const before = st.height;
  await page.click("#rp-pin");
  st = await panelState(page);
  ok(!st.pinned && !st.hidden, "chip releases the pin without hiding the panel");
  ok(st.height === before, "panel height unchanged on release (" + before + "px)");
  ok(await page.$("#unpin") === null, "releasing takes the map chip with it");

  /* Re-pin, then move the map: a geographic anchor has to follow the cell, and
     the outline has to survive the source rebuild that the pan triggers. */
  await page.mouse.click(hex.x, hex.y);
  await page.evaluate(() => new Promise(r => {
    window._appMap.once("moveend", r);
    window._appMap.panBy([-70, 30], { duration: 0 });
  }));
  chip = await chipAt();
  ok(chip && Math.abs(chip.dx) < 30 && chip.dy < 0,
     "the chip follows the cell across a pan");
  ok(await page.waitForFunction(() => window._appMap.querySourceFeatures("pin").length > 0,
                                { timeout: 5000 }).then(() => true).catch(() => false),
     "the pinned cell keeps its own outline across the pan");
  await page.click("#unpin");
  st = await panelState(page);
  ok(!st.pinned && !st.hidden && (await $hex(page)) === hex.id,
     "the chip releases the pin without re-pinning the cell under it");

  // zoomed in, the region chart must gain the hovered hex's own series line
  // (fetched per hex via HTTP range requests) next to the res-3 region line
  const fine = await page.evaluate(id => new Promise(res => {
    const map = window._appMap;
    const [la, lo] = window._app.h3.cellToLatLng(id);
    map.jumpTo({ center: [lo, la], zoom: 9.4 });
    const t0 = Date.now();
    (function poll() {   // fine chunks stream in after idle; retry briefly
      const rect = map.getContainer().getBoundingClientRect();
      let best = null;
      const vp = [[0, 0], [rect.width, rect.height]];
      for (const f of map.queryRenderedFeatures(vp, { layers: ["fine-fill"] })) {
        const [fla, flo] = window._app.h3.cellToLatLng(f.properties.id);
        const p = map.project([flo, fla]);
        if (p.x < 400 || p.y < 130 || p.x > rect.width - 80 || p.y > rect.height - 220) continue;
        const d = (p.x - rect.width * 0.6) ** 2 + (p.y - rect.height * 0.4) ** 2;
        if (!best || d < best.d) best = { id: f.properties.id,
                                          x: rect.left + p.x, y: rect.top + p.y, d };
      }
      if (best || Date.now() - t0 > 10000) return res(best);
      setTimeout(poll, 250);
    })();
  }), hex.id);
  ok(fine, "a fine-tier hex renders clear of the UI after zooming in");
  if (fine) {
    // the chart follows the layer group; the two-line view is NO₂'s
    await pickGroup(page, "NO₂");
    await page.mouse.move(fine.x, fine.y);
    const twoLines = await page.waitForFunction(id => {
      const ch = window._app && window._app.echarts.getInstanceByDom(document.getElementById("rp-chart"));
      if (!ch || document.getElementById("rp-h3").dataset.h3 !== id) return false;
      const s = ch.getOption().series;
      return s.length === 2 && s[1].name === "this hex" && s[1].data.some(v => v != null);
    }, { timeout: 8000 }, fine.id).then(() => true).catch(() => false);
    ok(twoLines, "hovering " + fine.id + " draws its own line next to the region line");
  }

  /* Satellite mode. Past the switch the Esri imagery is in and the NO2 fills are
     out — but they go out by opacity, not by visibility, precisely so the cells
     stay pickable up there: the panel and the pin have to keep working over the
     ground. The labels switch to Carto's light variant — dark text on a pale
     halo — whatever the theme says, that being the readable one on imagery. */
  const atZoom = z => page.evaluate(zz => new Promise(r => {
    window._appMap.once("moveend", r);
    window._appMap.setZoom(zz);
  }), z);
  const waitFor = (fn, ms) => page.waitForFunction(fn, { timeout: ms })
    .then(() => true).catch(() => false);
  ok(await page.evaluate(() => window._appMap.getMaxZoom()) === 16,
     "the camera reaches zoom 16, deep enough for imagery to be worth it");
  await atZoom(8);
  const lowAttrib = await page.$eval(".maplibregl-ctrl-attrib-inner", e => e.textContent);
  ok(lowAttrib.includes("CARTO") && !lowAttrib.includes("Esri"),
     "below the switch the imagery is not credited (" + lowAttrib + ")");
  await atZoom(12);
  ok(await waitFor(() => document.querySelector(".maplibregl-ctrl-attrib-inner")
                           .textContent.includes("Esri"), 15000),
     "above it Esri is credited, so its imagery is on screen");
  const live = await page.evaluate(() => {
    const m = window._appMap, r = m.getContainer().getBoundingClientRect();
    const p = m.project(m.getCenter());   // padded centre: clear of the rail
    return { hits: m.queryRenderedFeatures([p.x, p.y], { layers: ["fine-fill"] }).length,
             x: r.left + p.x, y: r.top + p.y };
  });
  ok(live.hits > 0, "the faded-out cells are still pickable over the imagery");
  if (live.hits > 0) {
    await page.mouse.click(live.x, live.y);
    const sat = await panelState(page);
    ok(sat.pinned && !sat.hidden, "so a cell can still be pinned there");
  }
  const labelsOn = () => page.evaluate(() => ["dark", "light"].find(v =>
    window._appMap.getLayoutProperty("labels-" + v, "visibility") !== "none"));
  ok(await waitFor(() => window._appMap
       .getLayoutProperty("labels-light", "visibility") !== "none", 5000),
     "the dark theme takes Carto's light labels over the imagery");
  await atZoom(8);
  ok(await waitFor(() => window._appMap
       .getLayoutProperty("labels-dark", "visibility") !== "none", 5000),
     "and hands them back to the theme on the way out (" + await labelsOn() + ")");

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();

  // hex deep link: fresh page, must arrive *pinned on exactly that hex*
  const dl = await newPage(browser, base + "#trend/" + hex.id);
  await dl.page.waitForFunction(id =>
    document.getElementById("region-panel").classList.contains("pinned") &&
    document.getElementById("rp-h3").dataset.h3 === id,
    { timeout: 20000 }, hex.id).catch(() => {});
  const dst = await panelState(dl.page);
  ok(dst.pinned && (await $hex(dl.page)) === hex.id,
     "deep link #trend/" + hex.id + " arrives pinned on that hex");
  ok(dl.errors.length === 0, "deep link page clean" +
     (dl.errors.length ? " — " + dl.errors.join("; ") : ""));
  await dl.page.close();

  // viewport deep link: #layer/@lat,lng,z restores the view; panning writes it back
  const vw = await newPage(browser, base + "#yoy/@40.400,-3.700,6.50");
  const got = await vw.page.evaluate(() => {
    const c = window._appMap.getCenter();
    return { lat: c.lat, lng: c.lng, zoom: window._appMap.getZoom(),
             /* the deep link carries the horizon, so both rows must reflect it */
             layer: window._app.activeLayer,
             group: [...document.querySelectorAll("#layer-buttons button")]
                      .find(b => b.getAttribute("aria-pressed") === "true")?.textContent,
             sub: [...document.querySelectorAll("#sub-buttons button")]
                    .find(b => b.getAttribute("aria-pressed") === "true")?.textContent };
  });
  ok(Math.abs(got.lat - 40.4) < 0.05 && Math.abs(got.lng + 3.7) < 0.05 &&
     Math.abs(got.zoom - 6.5) < 0.05 &&
     got.layer === "yoy" && got.group === "Change" && got.sub === "last year",
     "viewport deep link restores layer + view (" + got.group + "/" + got.sub + ")");
  await vw.page.evaluate(() => new Promise(r => {
    window._appMap.once("moveend", r);
    window._appMap.panBy([120, 0], { duration: 0 });
  }));
  const hash = await vw.page.evaluate(() => location.hash);
  ok(/^#yoy\/@-?\d+\.\d+,-?\d+\.\d+,\d+\.\d+$/.test(hash),
     "panning writes the view into the hash (" + hash + ")");
  ok(vw.errors.length === 0, "viewport page clean" +
     (vw.errors.length ? " — " + vw.errors.join("; ") : ""));
  await vw.page.close();
}

/* --- Top-regions run: the scope toggle, and → keeping you in your tier ------- */
/* Two things this guards. The trailing-12/all-time scope had no assertion at
   all. And the list used to fall back to res-3 rows whenever the map drew
   res-4 or res-5, so → flew the reader clean out of the tier they were reading
   (always zoom 4.8) instead of to the hex they had clicked on. */
const TIER_ZOOM = [[4, 5.6], [5, 6.8], [6, 9.2]];
const TIER_TITLE = { 4: "Top areas in view — this month",
                     5: "Top areas in view — this month",
                     6: "Top cells in view — this month" };

/* the layer control is two rows: primary groups, then that group's horizons */
const pickGroup = (page, label) => page.evaluate(g => {
  const b = [...document.querySelectorAll("#layer-buttons button")]
              .find(x => x.textContent === g);
  if (b) b.click();
  return !!b;
}, label);
const subLabels = page => page.$$eval("#sub-buttons button", bs =>
  bs.map(b => b.textContent));
const pickSub = (page, i) =>
  page.evaluate(n => document.querySelectorAll("#sub-buttons button")[n].click(), i);
const cardState = page => page.evaluate(() => ({
  labels: [...document.querySelectorAll("#rp-metrics .k")].map(e => e.textContent),
  values: [...document.querySelectorAll("#rp-metrics .v")].map(e => e.textContent),
  accented: [...document.querySelectorAll("#rp-metrics button")]
              .map((e, i) => e.getAttribute("aria-pressed") === "true" ? i : -1)
              .filter(i => i >= 0)
}));
/* The cards are built from GROUPS, so their order is an editorial choice that
   has changed before (NO₂ moved to the front when it became the default layer).
   Address them by group label so a reorder cannot silently retarget an
   assertion at the wrong card. */
const cardIx = (cards, group) => cards.labels.findIndex(l => l.startsWith(group));
const layerState = page => page.evaluate(() => ({
  active: window._app.activeLayer,
  group: [...document.querySelectorAll("#layer-buttons button")]
           .find(b => b.getAttribute("aria-pressed") === "true")?.textContent,
  sub: [...document.querySelectorAll("#sub-buttons button")]
         .find(b => b.getAttribute("aria-pressed") === "true")?.textContent,
  subHidden: document.getElementById("sub-buttons").hidden,
  legend: document.getElementById("legend-min").textContent + " … " +
          document.getElementById("legend-max").textContent
}));

const topState = page => page.evaluate(() => {
  const m = /[0-9a-f]{15}/.exec(document.getElementById("rp-h3").dataset.h3 || "");
  const ec = window._app && window._app.echarts.getInstanceByDom(document.getElementById("rp-chart"));
  const ser = ec ? (ec.getOption().series || []) : [];
  const paid = ser.find(s => s.name === "credit paid");
  return {
    res: window._app.displayRes(), zoom: window._appMap.getZoom(),
    title: document.getElementById("top-title").textContent,
    titleTip: document.getElementById("top-title").title,
    rows: document.querySelectorAll("#top-table button.loc").length,
    heads: [...document.querySelectorAll("#top-table th")].map(th => th.textContent),
    more: document.getElementById("top-more").hidden ? null
            : document.getElementById("top-more").textContent,
    ranks: [...document.querySelectorAll("#top-table td.rk")].map(td => td.textContent),
    /* the header row carries th, not td: keep the body rows only, so index 0
       is still rank 1 */
    rowVals: [...document.querySelectorAll("#top-table tr")]
               .filter(tr => tr.querySelector("td"))
               .map(tr => tr.querySelector("td.cr")?.textContent),
    rowCells: [...document.querySelectorAll("#top-table tr")]
                .filter(tr => tr.querySelector("td"))
                .map(tr => [...tr.querySelectorAll("td")].map(td => td.textContent)),
    pinned: document.getElementById("region-panel").classList.contains("pinned"),
    pinnedRes: m ? window._app.h3.getResolution(m[0]) : null,
    cred: document.getElementById("rp-cred").textContent,
    credBars: paid ? paid.data.filter(v => v != null).length : 0,
    scope: [...document.querySelectorAll("#sub-buttons button")]
             .find(b => b.getAttribute("aria-pressed") === "true")?.textContent
  };
});

/* The top-ranked hex of a tier earned credit by construction, and this run
   walks it on the Credit layer, so the chart is the bar view: every paid
   month in the summary line gets a bar, no more, no fewer. */
function okCreditMarkers(st, label) {
  const m = /^⬢ paid (\d+)\/(\d+) mo · peak /u.exec(st.cred);
  ok(!!m, label + " credit summary reads “" + st.cred + "”");
  if (!m) return;
  ok(st.credBars === +m[1],
     label + " draws " + st.credBars + " bar(s) for " + m[1] + " paid month(s)");
}

/* Wait out the debounced refresh: a zoom into a new tier fetches t4/t5 or res-6
   chunks, and the table only fills once they land (scheduleFineRefresh). */
const settleTop = page =>
  page.waitForFunction(() => document.querySelector("#top-table button.loc"),
                       { timeout: 30000 }).catch(() => {});

async function zoomTo(page, zoom) {
  await page.evaluate(z => new Promise(r => {
    window._appMap.once("moveend", r);
    window._appMap.setZoom(z);
  }), zoom);
  await settleTop(page);
}

/* Click → on row 1 and report where it put us. Releases any existing pin first
   so "pinned" is unambiguously the arrival of *this* flight. */
async function flyFirstRow(page) {
  await page.keyboard.press("Escape");
  await page.waitForFunction(
    () => !document.getElementById("region-panel").classList.contains("pinned"),
    { timeout: 5000 }).catch(() => {});
  await page.evaluate(() => document.querySelector("#top-table button.loc").click());
  await page.waitForFunction(
    () => !window._appMap.isMoving() &&
          document.getElementById("region-panel").classList.contains("pinned") &&
          document.getElementById("rp-cred").textContent !== "",
    { timeout: 20000 }).catch(() => {});
  await settleTop(page);
  return topState(page);
}

async function topRegionsRun(browser, base) {
  console.log("top regions (credit scopes + fly-to per tier):");
  const { page, errors } = await newPage(browser, base);

  ok(await pickGroup(page, "Credit"), "a Credit layer button exists");
  const scopes = await subLabels(page);
  ok(scopes.length === 3, "three credit windows offered (" + scopes.join(" / ") + ")");

  /* Every window fills the table, labels itself, marks its own button, and
     names the window it is showing in the heading. */
  const WIN_WORD = ["this month", "last 12 months", "all time"];
  for (let i = scopes.length - 1; i >= 0; i--) {
    await pickSub(page, i);
    await settleTop(page);
    const st = await topState(page);
    ok(st.scope === scopes[i], "scope “" + scopes[i] + "” is the pressed button");
    ok(st.rows > 0, "scope “" + scopes[i] + "” lists " + st.rows + " row(s), each with a →");
    ok(st.title.includes(WIN_WORD[i]),
       "scope “" + scopes[i] + "” names its window in the heading (" + WIN_WORD[i] + ")");
  }

  await pickSub(page, 0);   // back to last-month for the per-tier walk
  await settleTop(page);

  /* Park on the highest-credit region on the planet, then walk down the tiers.
     Descending via → keeps the viewport centred on credited ground, so each
     tier has something to list. */
  let st = await flyFirstRow(page);
  ok(st.res === 3 && st.pinnedRes === 3,
     "→ on a res-3 region arrives in the res-3 tier on a res-3 hex");
  okCreditMarkers(st, "res-3");
  ok(!st.cred.includes("(region)"),
     "res-3 credit is the region's own, not borrowed");

  for (const [res, zoom] of TIER_ZOOM) {
    await zoomTo(page, zoom);
    st = await topState(page);
    ok(st.res === res, "zoom " + zoom + " draws the res-" + res + " tier");
    ok(st.title === TIER_TITLE[res],
       "res-" + res + " list titles itself “" + st.title + "”");
    /* the heading's tooltip says how much ground one row covers, and has to
       distinguish the tiers: res-3 reads "km² region", not "km² area" */
    ok(st.titleTip.includes(res === 6 ? "36 km²" : "km² area"),
       "res-" + res + " heading tip explains " +
       (res === 6 ? "a single cell" : "a sum over children"));
    /* the column headers replaced the paragraph of prose that named the glyphs */
    ok(st.heads.includes("credit") && (res === 6) !== st.heads.includes("cells"),
       "res-" + res + " heads its columns (" + st.heads.filter(Boolean).join("|") + ")");
    ok(st.rows > 0, "res-" + res + " lists " + st.rows + " credited hex(es) in view");
    if (!st.rows) continue;
    /* res-4/5 rows carry the count of credited res-6 children, like res-3 does;
       res-6 is a single cell so it has no such column. A res-4 hex has 49
       children and a res-5 hex 7, so the count must not exceed that. */
    const cells = st.rowCells[0] || [];
    const cnt = cells.find(t => /^\d+c$/.test(t));
    if (res === 6) {
      ok(!cnt, "res-6 rows have no credited-children column (" + cells.join("|") + ")");
    } else {
      const lim = res === 4 ? 49 : 7;
      ok(cnt && +cnt.slice(0, -1) >= 1 && +cnt.slice(0, -1) <= lim,
         "res-" + res + " rows show credited children " + cnt + " (max " + lim + ")");
    }

    const flown = await flyFirstRow(page);
    ok(flown.res === res,
       "→ on a res-" + res + " row stays in the res-" + res + " tier (zoom " +
       flown.zoom.toFixed(2) + ")");
    ok(flown.pinned && flown.pinnedRes === res,
       "→ pins the res-" + res + " hex it flew to" +
       (flown.pinnedRes ? "" : " (nothing pinned)"));
    okCreditMarkers(flown, "res-" + res);
    ok(!flown.cred.includes("(region)"),
       "res-" + res + " credit is the hex's own, not its region's");
  }

  /* Regression: the windowed credit scopes used to have no fine-tier planes, so
     the list fell back to res-3 regions and → flew the reader out to zoom 4.8
     however far they had zoomed in. They have planes now, so a window must
     behave exactly like the month scope at a fine tier. */
  for (const win of [1, 2]) {
    await pickSub(page, win);
    await zoomTo(page, 9.2);
    const w = await topState(page);
    ok(w.res === 6, "window “" + scopes[win] + "”: still at res-6 (" + w.res + ")");
    ok(w.title === "Top cells in view — " + WIN_WORD[win],
       "window “" + scopes[win] + "” lists cells, not regions (" + w.title + ")");
    ok(w.rows > 0, "window “" + scopes[win] + "” lists " + w.rows + " cell(s) in view");
    if (w.rows) {
      const rowVal = w.rowVals[0];
      const f = await flyFirstRow(page);
      ok(f.res === 6, "window “" + scopes[win] + "”: → stays at res-6 (zoom " +
         f.zoom.toFixed(2) + ")");
      ok(f.pinnedRes === 6, "window “" + scopes[win] + "”: → pins a res-6 cell");
      /* The row and the credit card read the same plane for the same hex, so
         they must print the same string. They did not when the list ranked by
         one window while the map painted another. */
      const cards = await cardState(page);
      const cv = cards.values[cardIx(cards, "Credit")];
      ok(cv === rowVal,
         "window “" + scopes[win] + "”: list row and panel card agree (" +
         rowVal + " vs " + cv + ")");
    }
  }

  /* Ten rows by default, the tail one click away. The whole world has hundreds
     of credited regions, so the block has to open at a fixed height, and the
     ranks have to stay absolute from 1 either way — → flies to a rank the
     reader can name. */
  await pickSub(page, 0);
  await zoomTo(page, 1.4);   // whole world: the longest list there is
  let p = await topState(page);
  ok(p.rows === 10, "the world view opens on ten rows (" + p.rows + ")");
  ok(p.ranks.join() === "1,2,3,4,5,6,7,8,9,10", "the rows rank 1..10");
  ok(p.more && /^show top (\d+)$/.test(p.more) && +p.more.split(" ")[2] > 10,
     "a longer ranking offers its tail (“" + p.more + "”)");
  const tail = +p.more.split(" ")[2];
  ok(tail <= 100, "never offers more than a hundred rows (" + tail + ")");

  await page.evaluate(() => document.getElementById("top-more").click());
  p = await topState(page);
  ok(p.rows === tail, "the toggle shows all " + tail + " of them (" + p.rows + ")");
  ok(p.ranks[0] === "1" && p.ranks[tail - 1] === String(tail),
     "the expanded rows still rank 1.." + tail);
  ok(p.more === "show top 10", "and offers the way back (“" + p.more + "”)");

  /* Expanded is a property of the reader, not of the ranking: a different
     credit window re-ranks the rows but must not fold the list back up. */
  await pickSub(page, 1);
  await settleTop(page);
  ok((await topState(page)).rows > 10, "a new credit window stays expanded");
  await page.evaluate(() => document.getElementById("top-more").click());
  ok((await topState(page)).rows === 10, "the toggle folds it back to ten");

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();
}

/* --- Layer control: three groups, and the horizons under two of them --------- */
/* Guards the shape of the control and that each horizon actually paints its own
   plane: a wrong prop or a missing scale shows up as an unchanged legend or a
   blank map, neither of which the other runs would catch. */
async function layerRun(browser, base) {
  console.log("layer control (groups + horizons):");
  const { page, errors, dataReqs } = await newPage(browser, base);

  /* A hash-less visit opens on the measurement, not on a derived metric. The
     rail order and the default have to move together: the first group being
     NO₂ while the map painted trend would leave the pressed button out of sync
     with the paint on first load. Read before anything below clicks. */
  const first = await page.evaluate(() => ({
    active: window._app.activeLayer,
    pressed: [...document.querySelectorAll("#layer-buttons button")]
               .findIndex(b => b.getAttribute("aria-pressed") === "true")
  }));
  ok(first.active === "m" && first.pressed === 0,
     "a hash-less visit opens on NO₂ (activeLayer=" + first.active +
     ", pressed=" + first.pressed + ")");

  /* data/<month>/ is served immutable but named by month, so a rebuild of an
     already-shipped month must not reuse the old URL — every .bin fetch has to
     carry the build id or returning visitors read the previous layout. */
  const unversioned = dataReqs.filter(u => !/[?&]v=\d+/.test(u));
  ok(dataReqs.length > 0 && unversioned.length === 0,
     dataReqs.length + " data requests all carry the build id" +
     (unversioned.length ? " — MISSING on " + unversioned.slice(0, 3).join(", ") : ""));

  /* Every scale the client can ask for must exist in META.scales. A missing one
     surfaces as NaN in a tooltip or legend rather than an error, which is easy
     to ship unnoticed: the layers, the four credit windows per resolution and
     the credit-history scales are all keyed by string. */
  const scales = await page.evaluate(() => {
    const { S, LAYERS, scaleKey, dec, fmt } = window._app;
    const need = ["m", "yoy", "trend", "trend5"];
    for (const r of [3, 4, 5, 6]) {
      for (const sfx of ["", "y", "a", "h"]) need.push("credit" + r + sfx);
    }
    const missing = need.filter(k => !S[k] ||
      !(Number.isFinite(S[k].max) || Number.isFinite(S[k].sym) ||
        Number.isFinite(S[k].lmin)));
    // and every decoder/formatter the layers resolve to must be a function
    const bad = [];
    for (const l of LAYERS) for (const r of [3, 4, 5, 6]) {
      const k = scaleKey(l.key, r);
      if (typeof dec[k] !== "function" || typeof fmt[k] !== "function") bad.push(k);
      else if (!Number.isFinite(dec[k](0.5))) bad.push(k + " (NaN)");
    }
    return { missing, bad, n: need.length };
  });
  ok(scales.missing.length === 0,
     scales.n + " scales present in META" +
     (scales.missing.length ? " — MISSING " + scales.missing.join(", ") : ""));
  ok(scales.bad.length === 0,
     "every layer resolves to a finite decoder + formatter" +
     (scales.bad.length ? " — BAD " + scales.bad.join(", ") : ""));

  /* fmt >= 2: the u16 series planes carry their own ceiling, which has to cover
     the whole record and so can never sit below the map planes' trimmed one.
     A producer that dropped `mser` would silently decode every series value
     against the wrong scale — the exact bug v2 exists to fix — and the app
     cannot tell from the bytes, so assert the contract here. */
  const mser = await page.evaluate(() => {
    const { META, S, dec } = window._app;
    return { fmt: META.fmt == null ? 1 : META.fmt, has: !!S.mser,
             mLmax: S.m.lmax, sLmax: S.mser && S.mser.lmax,
             top: dec.mser(1) };
  });
  if (mser.fmt >= 2) {
    ok(mser.has && mser.sLmax >= mser.mLmax && Number.isFinite(mser.top),
       "series scale covers the record (mser ceiling " + mser.top.toFixed(0) +
       " >= map ceiling " + Math.pow(10, mser.mLmax).toFixed(0) + " µmol/m²)");
  } else {
    ok(!mser.has && Number.isFinite(mser.top),
       "fmt 1 bundle: series decode falls back to the map scale");
  }

  /* An open NO₂ box. The u8 map plane stops at the ramp's trimmed ceiling, so
     a cell above it used to read “115+” in the panel while the chart right
     under it drew the real figure off `mser`. The box now closes itself from
     that same series, so the two have to agree at the last month. Only a v2
     bundle clamps anything, and only where something sits above the ceiling. */
  if (mser.fmt >= 2) {
    const home = await page.evaluate(() => {
      const map = window._appMap, c = map.getCenter();
      const back = { center: [c.lng, c.lat], zoom: map.getZoom() };   // before the jump
      const f = map.querySourceFeatures("r3").find(x => x.properties.tm >= 1);
      if (!f) return null;
      const [la, lo] = window._app.h3.cellToLatLng(f.properties.id);
      map.jumpTo({ center: [lo, la], zoom: 4.8 });
      const p = map.project([lo, la]), r = map.getContainer().getBoundingClientRect();
      return { id: f.properties.id, x: r.left + p.x, y: r.top + p.y, back };
    });
    if (!home) {
      console.log("  skip  nothing above the map ceiling in this bundle");
    } else {
      await pickGroup(page, "NO₂");   // the chart draws m itself on this group
      await page.mouse.click(home.x, home.y);
      const box = await page.waitForFunction(id => {
        if (document.getElementById("rp-h3").dataset.h3 !== id) return false;
        const b = [...document.querySelectorAll("#rp-metrics button")]
                    .find(x => x.querySelector(".k").textContent.trim() === "NO₂");
        if (!b || b.querySelector(".v").textContent.includes("+")) return false;
        const ec = window._app.echarts.getInstanceByDom(document.getElementById("rp-chart"));
        const d = ec && (ec.getOption().series[0].data || []).filter(v => v != null);
        if (!d || !d.length) return false;
        return { card: b.querySelector(".v").textContent,
                 want: window._app.fmt.m(d[d.length - 1]) };
      }, { timeout: 30000 }, home.id).then(h => h.jsonValue()).catch(() => null);
      ok(box, "the NO₂ box on " + home.id + " closes above the map ceiling");
      if (box) {
        ok(box.card.startsWith(box.want),
           "and reads what the chart draws (" + box.card + " vs " + box.want + ")");
      }
      await page.keyboard.press("Escape");
      await page.evaluate(v => window._appMap.jumpTo(v), home.back);
    }
  }

  const groups = await page.$$eval("#layer-buttons button", bs => bs.map(b => b.textContent));
  /* NO₂ leads: it is the layer the map opens on, so the rail reads in the same
     order as the default view rather than starting on a derived metric. */
  ok(groups.length === 3 && groups.join("/") === "NO₂/Change/Credit",
     "three primary layers (" + groups.join(" / ") + ")");

  const seen = new Map();
  for (const [g, want] of [["Change", ["overall", "5 years", "last year"]],
                           ["Credit", ["last month", "12 months", "all time"]]]) {
    await pickGroup(page, g);
    const subs = await subLabels(page);
    ok(subs.join("/") === want.join("/"),
       g + " offers " + want.length + " horizons (" + subs.join(" / ") + ")");
    for (let i = 0; i < subs.length; i++) {
      await pickSub(page, i);
      const st = await layerState(page);
      ok(st.group === g && st.sub === subs[i],
         g + " → “" + subs[i] + "” is pressed (activeLayer=" + st.active + ")");
      ok(/\d/.test(st.legend), g + " → “" + subs[i] + "” has a numeric legend (" + st.legend + ")");
      seen.set(st.active, st.legend);
      // the hash must round-trip the horizon, not just the group
      const h = await page.evaluate(() => location.hash);
      ok(h.startsWith("#" + st.active),
         g + " → “" + subs[i] + "” writes #" + st.active + " (" + h + ")");
    }
  }
  ok(seen.size === 6, "six distinct horizons visited (" + [...seen.keys()].join(", ") + ")");
  // each horizon must have its own scale: identical legends would mean a shared plane
  ok(new Set([...seen.values()]).size >= 4,
     "horizons have distinct scales (" + new Set([...seen.values()]).size + " of 6 legends differ)");

  await pickGroup(page, "NO₂");
  const st = await layerState(page);
  ok(st.subHidden, "NO₂ has no horizon row");
  ok(st.active === "m", "NO₂ selects the m layer");

  // returning to a group restores the horizon that was last used there
  await pickGroup(page, "Change");
  await pickSub(page, 1);
  await pickGroup(page, "Credit");
  await pickGroup(page, "Change");
  ok((await layerState(page)).active === "trend5",
     "switching away and back restores the last horizon");

  /* The panel carries one card per primary layer, each naming its horizon, and
     a pinned panel must follow a horizon switch rather than going stale. */
  const hex = await pickHex(page);
  ok(hex, "a res-3 hex renders clear of the UI");
  if (hex) {
    await page.mouse.click(hex.x, hex.y);
    await page.waitForFunction(
      "document.getElementById('region-panel').classList.contains('pinned')",
      { timeout: 5000 }).catch(() => {});
    await pickGroup(page, "Change");
    await pickSub(page, 0);                       // overall
    const a = await cardState(page);
    ok(a.labels.length === 3, "the panel shows one card per primary layer (" +
       a.labels.join(" / ") + ")");
    const chg = cardIx(a, "Change");
    ok(a.accented.length === 1 && a.accented[0] === chg,
       "the card the map is painted by is the accented one");
    await pickSub(page, 1);                       // 5 years
    const b = await cardState(page);
    ok(b.labels[chg] !== a.labels[chg],
       "switching horizon relabels the card (" + a.labels[chg] + " → " + b.labels[chg] + ")");
    ok(b.values[chg] !== a.values[chg] || a.values[chg] === "–",
       "and re-reads its value for the pinned hex (" + a.values[chg] + " → " + b.values[chg] + ")");
    await pickGroup(page, "Credit");
    const c = await cardState(page);
    ok(c.accented.length === 1 && c.accented[0] === cardIx(c, "Credit"),
       "selecting Credit moves the accent to the credit card");

    /* The cards are controls, not readouts: pressing one paints the map by that
       layer at the horizon the card names, and the accent follows. */
    await page.evaluate(i => document.querySelectorAll("#rp-metrics button")[i].click(),
                        cardIx(c, "Change"));
    const d = await cardState(page), ls = await layerState(page);
    ok(ls.active === "trend5" && ls.group === "Change" && ls.sub === "5 years",
       "pressing the Change card selects the horizon it names (" + ls.active + ")");
    ok(d.accented.length === 1 && d.accented[0] === cardIx(d, "Change"),
       "and the accent follows to the pressed card");
  }

  /* The list must follow the drawn tier even when the active layer is not a
     credit layer at all: switching Change horizons leaves the credit window
     alone, and the list used to fall back to res-3 whenever that window was not
     "last month" — so a reader on 5-year change at res-6 got res-3 rows and an
     arrow that zoomed them out. */
  for (const [win, wname, wlab] of [[0, "last month", "this month"],
                                    [2, "all time", "all time"]]) {
    await pickGroup(page, "Credit");
    await pickSub(page, win);
    await pickGroup(page, "Change");
    await pickSub(page, 1);                 // 5 years
    await zoomTo(page, 9.2);
    const st = await topState(page);
    ok(st.res === 6 && st.title === "Top cells in view — " + wlab,
       "Change/5y with the “" + wname + "” window still lists res-6 (" +
       st.title + ")");
    if (st.rows) {
      const f = await flyFirstRow(page);
      ok(f.res === 6, "Change/5y + “" + wname + "”: → stays at res-6 (zoom " +
         f.zoom.toFixed(2) + ")");
    }
  }

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();

  /* A deep link to a credit window must also put the TOP LIST on that window.
     topScope used to be hardcoded to "month" and only moved on a click, so
     #creditAll painted all-time credit while the list still ranked last month —
     the map and the table disagreed until you touched the control. */
  for (const [key, want] of [["credit", "this month"],
                             ["credit12", "last 12 months"],
                             ["creditAll", "all time"]]) {
    const dl = await newPage(browser, base + "#" + key);
    const title = await $text(dl.page, "#top-title");
    ok(title.includes(want),
       "#" + key + " starts the top list on its own window (" + want + ")");
    await dl.page.close();
  }

  /* Cold load of a horizon deep link: the group row, the horizon row and the
     paint all have to come back from the hash alone, not just after a click. */
  for (const [key, group, sub] of [["trend5", "Change", "5 years"],
                                   ["credit12", "Credit", "12 months"],
                                   ["m", "NO₂", undefined]]) {
    const dl = await newPage(browser, base + "#" + key);
    const st = await layerState(dl.page);
    ok(st.active === key && st.group === group && st.sub === sub,
       "#" + key + " loads as " + group + (sub ? " / " + sub : " (no horizon row)") +
       " — got " + st.group + "/" + st.sub);
    ok(dl.errors.length === 0, "#" + key + " page clean" +
       (dl.errors.length ? " — " + dl.errors.join("; ") : ""));
    await dl.page.close();
  }
}

/* --- Touch run (default headless: hover:none) -------------------------------- */
async function touchRun(browser, base) {
  console.log("touch (hover: none):");
  const { page, errors } = await newPage(browser, base);

  const hex = await pickHex(page);
  ok(hex, "a res-3 hex renders clear of the UI");
  if (!hex) return;

  await page.mouse.click(hex.x, hex.y);
  await page.waitForFunction("document.getElementById('region-panel').classList.contains('pinned')",
                             { timeout: 5000 });
  const st = await panelState(page);
  ok(st.pinned && !st.hidden, "tap pins the panel");
  ok(await $display(page, "#rp-close") !== "none", "× is visible");
  ok(await $display(page, "#rp-pin") === "none", "⌖ chip is hover-only");
  ok(await page.$("#unpin") === null, "so is the chip on the map");

  /* On a phone the cards are the layer control within thumb reach — the rail's
     own is pinned to the far top-left corner. (Clicked, not tapped: this run
     emulates the hover:none pointer, not a touchscreen.) */
  const was = await page.evaluate(() => window._app.activeLayer);
  const cards = await page.$$("#rp-metrics button");
  ok(cards.length === 3, "the panel shows one pressable card per primary layer");
  if (cards.length === 3) {
    const ci = cardIx(await cardState(page), "Credit");
    await cards[ci].click();
    const got = await page.evaluate(() => ({
      active: window._app.activeLayer,
      pressed: [...document.querySelectorAll("#rp-metrics button")]
                 .findIndex(b => b.getAttribute("aria-pressed") === "true")
    }));
    ok(got.active !== was && got.pressed === ci,
       "tapping the credit card paints the map by it (" + was + " → " + got.active + ")");
  }

  /* Phone width, which no other run exercises: every run launches at 1400x900,
     so the mobile media query has always been checked at a width where it has
     room to spare. The brand row is the tight one — it overflowed the card and
     pushed the about link out of it, in September but not in May, because the
     month name is variable-width. Assert the link stays inside the card at the
     narrowest width worth supporting, with the longest month forced in. */
  await page.setViewport({ width: 320, height: 720 });
  const brand = await page.evaluate(() => {
    const chip = document.getElementById("month-chip");
    const before = chip.textContent;
    chip.textContent = "September 2026";           // the widest the chip ever gets
    const card = document.getElementById("layer-card").getBoundingClientRect();
    const link = document.getElementById("about-link").getBoundingClientRect();
    const word = document.querySelector(".wordmark").getBoundingClientRect();
    const out = {
      cardRight: +card.right.toFixed(1), linkRight: +link.right.toFixed(1),
      linkLeft: +link.left.toFixed(1), wordRight: +word.right.toFixed(1),
      chipShown: getComputedStyle(chip).display !== "none"
    };
    chip.textContent = before;
    return out;
  });
  ok(brand.linkRight <= brand.cardRight,
     "at 320px the about link stays inside the layer card (link " +
     brand.linkRight + " vs card " + brand.cardRight + ")");
  ok(brand.linkLeft >= brand.wordRight,
     "and clear of the wordmark, which keeps its size (" +
     brand.wordRight + " -> " + brand.linkLeft + ")");
  ok(!brand.chipShown,
     "the month chip yields the row on mobile — it leads the About colophon instead");
  await page.setViewport({ width: 1400, height: 900 });

  await page.click("#rp-close");
  ok((await panelState(page)).hidden, "× dismisses the panel");

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();
}

/* --- Main --------------------------------------------------------------------- */
(async () => {
  if (!fs.existsSync(path.join(WEB_DIR, "index.html"))) {
    console.error("No web bundle at " + WEB_DIR + " — pipeline: run scripts/06_viz.R; " +
                  "repo: npm run build && npm run stage (or set NO2_WEB_DIR).");
    process.exit(1);
  }
  const chrome = findChrome();
  const srv = await serve(WEB_DIR);
  const base = "http://127.0.0.1:" + srv.address().port + "/index.html";

  for (const [label, args, run] of [["desktop", [HOVER_FLAG], desktopRun],
                                    ["layer control", [HOVER_FLAG], layerRun],
                                    ["top regions", [HOVER_FLAG], topRegionsRun],
                                    ["touch", [], touchRun]]) {
    /* defaultViewport:null — Puppeteer's viewport emulation (CDP
       setDeviceMetricsOverride) silently resets the pointer/hover media back
       to hover:none, undoing the blink-settings flag; size via --window-size */
    const browser = await puppeteer.launch({
      executablePath: chrome, headless: true, defaultViewport: null,
      args: ["--window-size=1400,900", ...OFFLINE_ARGS, ...args]
    });
    try {
      await run(browser, base);
    } catch (e) {
      failures++;
      console.log("  FAIL  " + label + " run crashed: " + (e.stack || e));
    } finally {
      await browser.close();
    }
  }
  srv.close();
  console.log(failures ? "SMOKE TEST RED — " + failures + " failure(s)" : "smoke test green");
  process.exit(failures ? 1 : 0);
})();

#!/usr/bin/env node
/* ============================================================================
 * Step 9 (gate): Smoke test of the built web bundle
 * ============================================================================
 * Serves data/viz/web/ locally and drives it in headless Chrome. Guards the
 * regressions we actually shipped fixes for: page-level JS crashes (ECharts),
 * deep links arriving at a zoom where the hex renders, and the region panel
 * resizing when the pin chip disappears.
 *
 * Three runs from one suite:
 *   desktop     — Chrome forced to report a hover-capable mouse pointer
 *                 (headless defaults to hover:none): hover previews, click
 *                 pins, the ⌖ chip releases without hiding or resizing the
 *                 panel, hex and viewport deep links;
 *   top regions — the three credit-window scopes, and → flying to a hex in
 *                 every tier the map draws without leaving that tier;
 *   touch       — default headless (hover:none): tap pins, × dismisses.
 *
 * Needs: npm install (puppeteer-core), a Chrome under ~/.cache/puppeteer
 * (or PUPPETEER_EXECUTABLE_PATH), and internet for the CDN map libraries.
 * Run it after 06_viz.R; 08_deploy.sh runs it as a deploy gate (SKIP_SMOKE=1
 * to bypass). Exit code 0 = green.
 * ==========================================================================*/
"use strict";

const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const puppeteer = require("puppeteer-core");

const WEB_DIR = path.join(__dirname, "..", "data", "viz", "web");
const HOVER_FLAG = "--blink-settings=primaryHoverType=2,availableHoverTypes=2," +
                   "primaryPointerType=4,availablePointerTypes=4";

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
  page.on("pageerror", e => errors.push(String(e)));
  page.on("response", r => {
    const u = new URL(r.url());
    if (u.hostname === "127.0.0.1" && r.status() >= 400) errors.push(r.status() + " " + u.pathname);
  });
  await page.goto(url, { waitUntil: "domcontentloaded" });
  // loading overlay removes itself once data + map are up; then wait for idle
  await page.waitForFunction("!document.getElementById('loading')", { timeout: 60000 });
  await page.evaluate(() => new Promise(r => {
    const m = window._keanoMap;
    m.loaded() && !m.isMoving() ? r() : m.once("idle", r);
  }));
  return { page, errors };
}

/* Pick a rendered res-3 hex whose center projects well inside the map and
   clear of the UI (left rail on desktop, layer card / bottom sheet on touch),
   and return its id + page pixel coordinates. */
function pickHex(page) {
  return page.evaluate(() => {
    const map = window._keanoMap;
    const rect = map.getContainer().getBoundingClientRect();
    const cx = rect.width * 0.6, cy = rect.height * 0.4;
    let best = null;
    for (const f of map.queryRenderedFeatures({ layers: ["r3-fill"] })) {
      const [la, lo] = h3.cellToLatLng(f.properties.id);
      const p = map.project([lo, la]);
      if (p.x < 400 || p.y < 130 || p.x > rect.width - 80 || p.y > rect.height - 220) continue;
      const d = (p.x - cx) ** 2 + (p.y - cy) ** 2;
      if (!best || d < best.d) best = { id: f.properties.id,
                                        x: rect.left + p.x, y: rect.top + p.y, d };
    }
    return best;
  });
}

const $text = (page, sel) => page.$eval(sel, el => el.textContent);
const $display = (page, sel) => page.$eval(sel, el => getComputedStyle(el).display);
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
  ok((await $text(page, "#rp-h3")).includes(hex.id), "panel shows the hovered hex " + hex.id);

  // all three charts alive (rp-chart exists only once the panel drew)
  ok(await page.evaluate(() =>
    ["chart-perf", "chart-credit", "rp-chart"].every(id =>
      !!echarts.getInstanceByDom(document.getElementById(id)))),
    "three live ECharts instances");

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
  ok(await $display(page, "#rp-pin") !== "none", "⌖ pinned chip is visible");
  ok(await $display(page, "#rp-close") === "none", "× stays touch-only");

  // chip releases without hiding or resizing the panel
  const before = st.height;
  await page.click("#rp-pin");
  st = await panelState(page);
  ok(!st.pinned && !st.hidden, "chip releases the pin without hiding the panel");
  ok(st.height === before, "panel height unchanged on release (" + before + "px)");

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();

  // hex deep link: fresh page, must arrive *pinned on exactly that hex*
  const dl = await newPage(browser, base + "#trend/" + hex.id);
  await dl.page.waitForFunction(id =>
    document.getElementById("region-panel").classList.contains("pinned") &&
    document.getElementById("rp-h3").textContent.includes(id),
    { timeout: 20000 }, hex.id).catch(() => {});
  const dst = await panelState(dl.page);
  ok(dst.pinned && (await $text(dl.page, "#rp-h3")).includes(hex.id),
     "deep link #trend/" + hex.id + " arrives pinned on that hex");
  ok(dl.errors.length === 0, "deep link page clean" +
     (dl.errors.length ? " — " + dl.errors.join("; ") : ""));
  await dl.page.close();

  // viewport deep link: #layer/@lat,lng,z restores the view; panning writes it back
  const vw = await newPage(browser, base + "#yoy/@40.400,-3.700,6.50");
  const got = await vw.page.evaluate(() => {
    const c = window._keanoMap.getCenter();
    return { lat: c.lat, lng: c.lng, zoom: window._keanoMap.getZoom(),
             yoy: [...document.querySelectorAll(".layers button")]
                    .some(b => b.textContent === "YoY" && b.getAttribute("aria-pressed") === "true") };
  });
  ok(Math.abs(got.lat - 40.4) < 0.05 && Math.abs(got.lng + 3.7) < 0.05 &&
     Math.abs(got.zoom - 6.5) < 0.05 && got.yoy,
     "viewport deep link restores layer + view");
  await vw.page.evaluate(() => new Promise(r => {
    window._keanoMap.once("moveend", r);
    window._keanoMap.panBy([120, 0], { duration: 0 });
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
const TIER_TITLE = { 4: "Top areas — in view", 5: "Top areas — in view",
                     6: "Top cells — in view" };

const topState = page => page.evaluate(() => {
  const m = /[0-9a-f]{15}/.exec(document.getElementById("rp-h3").textContent);
  const ec = window.echarts && echarts.getInstanceByDom(document.getElementById("rp-chart"));
  const ser = ec ? (ec.getOption().series || []) : [];
  const paid = ser.find(s => s.name === "credit paid");
  return {
    res: displayRes(), zoom: window._keanoMap.getZoom(),
    title: document.getElementById("top-title").textContent,
    note: document.getElementById("top-note").textContent,
    rows: document.querySelectorAll("#top-table button.loc").length,
    pinned: document.getElementById("region-panel").classList.contains("pinned"),
    pinnedRes: m ? h3.getResolution(m[0]) : null,
    cred: document.getElementById("rp-cred").textContent,
    credDots: paid ? paid.data.length : 0,
    scope: [...document.querySelectorAll("#scope-buttons button")]
             .find(b => b.getAttribute("aria-pressed") === "true")?.textContent
  };
});

/* The top-ranked hex of a tier earned credit by construction, so its chart
   must carry markers, and the count in the summary line must be consistent
   with the number of dots drawn (a credited month with no m value on the line
   has nowhere to sit, so dots ≤ paid months). */
function okCreditMarkers(st, label) {
  const m = /^⬢ paid (\d+)\/(\d+) mo · peak /u.exec(st.cred);
  ok(!!m, label + " credit summary reads “" + st.cred + "”");
  if (!m) return;
  ok(st.credDots > 0 && st.credDots <= +m[1],
     label + " draws " + st.credDots + " marker(s) for " + m[1] + " paid month(s)");
}

/* Wait out the debounced refresh: a zoom into a new tier fetches t4/t5 or res-6
   chunks, and the table only fills once they land (scheduleFineRefresh). */
const settleTop = page =>
  page.waitForFunction(() => document.querySelector("#top-table button.loc"),
                       { timeout: 30000 }).catch(() => {});

async function zoomTo(page, zoom) {
  await page.evaluate(z => new Promise(r => {
    window._keanoMap.once("moveend", r);
    window._keanoMap.setZoom(z);
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
    () => !window._keanoMap.isMoving() &&
          document.getElementById("region-panel").classList.contains("pinned") &&
          document.getElementById("rp-cred").textContent !== "",
    { timeout: 20000 }).catch(() => {});
  await settleTop(page);
  return topState(page);
}

async function topRegionsRun(browser, base) {
  console.log("top regions (credit scopes + fly-to per tier):");
  const { page, errors } = await newPage(browser, base);

  const scopes = await page.$$eval("#scope-buttons button", bs => bs.map(b => b.textContent));
  ok(scopes.length === 3, "three credit windows offered (" + scopes.join(" / ") + ")");

  /* Every scope fills the table, labels itself, and marks its own button. The
     windowed scopes stay res-3 by design — per-cell credit history isn't
     shipped — so they must say "Top regions" at any zoom. */
  for (let i = scopes.length - 1; i >= 0; i--) {
    await page.evaluate(n => document.querySelectorAll("#scope-buttons button")[n].click(), i);
    await settleTop(page);
    const st = await topState(page);
    ok(st.scope === scopes[i], "scope “" + scopes[i] + "” is the pressed button");
    ok(st.rows > 0, "scope “" + scopes[i] + "” lists " + st.rows + " row(s), each with a →");
    if (i > 0) ok(st.title.startsWith("Top regions"),
                  "windowed scope “" + scopes[i] + "” stays regional (" + st.title + ")");
  }

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
    /* wording has to distinguish the tiers, not just be present: the res-3
       note also carries a Σ and a km² figure ("region", not "area") */
    ok(st.note.includes(res === 6 ? "past 5 years" : "km² area"),
       "res-" + res + " note explains " + (res === 6 ? "a per-cell %" : "a Σ over children"));
    ok(st.rows > 0, "res-" + res + " lists " + st.rows + " credited hex(es) in view");
    if (!st.rows) continue;

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

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();
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

  await page.click("#rp-close");
  ok((await panelState(page)).hidden, "× dismisses the panel");

  ok(errors.length === 0, "no page errors / failed local requests" +
     (errors.length ? " — " + errors.join("; ") : ""));
  await page.close();
}

/* --- Main --------------------------------------------------------------------- */
(async () => {
  if (!fs.existsSync(path.join(WEB_DIR, "index.html"))) {
    console.error("No web bundle at " + WEB_DIR + " — run scripts/06_viz.R first.");
    process.exit(1);
  }
  const chrome = findChrome();
  const srv = await serve(WEB_DIR);
  const base = "http://127.0.0.1:" + srv.address().port + "/index.html";

  for (const [label, args, run] of [["desktop", [HOVER_FLAG], desktopRun],
                                    ["top regions", [HOVER_FLAG], topRegionsRun],
                                    ["touch", [], touchRun]]) {
    /* defaultViewport:null — Puppeteer's viewport emulation (CDP
       setDeviceMetricsOverride) silently resets the pointer/hover media back
       to hover:none, undoing the blink-settings flag; size via --window-size */
    const browser = await puppeteer.launch({
      executablePath: chrome, headless: true, defaultViewport: null,
      args: ["--window-size=1400,900", ...args]
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

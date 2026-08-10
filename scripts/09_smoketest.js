#!/usr/bin/env node
/* ============================================================================
 * Step 9 (gate): Smoke test of the built web bundle
 * ============================================================================
 * Serves data/viz/web/ locally and drives it in headless Chrome. Guards the
 * regressions we actually shipped fixes for: page-level JS crashes (ECharts),
 * deep links arriving at a zoom where the hex renders, and the region panel
 * resizing when the pin chip disappears.
 *
 * Two runs from one suite:
 *   desktop — Chrome forced to report a hover-capable mouse pointer
 *             (headless defaults to hover:none): hover previews, click pins,
 *             the ⌖ chip releases without hiding or resizing the panel;
 *   touch   — default headless (hover:none): tap pins, × dismisses.
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

const WEB_DIR = process.env.KEANO_WEB_DIR ||
                path.join(__dirname, "..", "data", "viz", "web");
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
        const [la, lo] = h3.cellToLatLng(f.properties.id);
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

  // zoomed in, the region chart must gain the hovered hex's own series line
  // (fetched per hex via HTTP range requests) next to the res-3 region line
  const fine = await page.evaluate(id => new Promise(res => {
    const map = window._keanoMap;
    const [la, lo] = h3.cellToLatLng(id);
    map.jumpTo({ center: [lo, la], zoom: 9.4 });
    const t0 = Date.now();
    (function poll() {   // fine chunks stream in after idle; retry briefly
      const rect = map.getContainer().getBoundingClientRect();
      let best = null;
      const vp = [[0, 0], [rect.width, rect.height]];
      for (const f of map.queryRenderedFeatures(vp, { layers: ["fine-fill"] })) {
        const [fla, flo] = h3.cellToLatLng(f.properties.id);
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
    await page.mouse.move(fine.x, fine.y);
    const twoLines = await page.waitForFunction(id => {
      const ch = window.echarts && echarts.getInstanceByDom(document.getElementById("rp-chart"));
      if (!ch || !document.getElementById("rp-h3").textContent.includes(id)) return false;
      const s = ch.getOption().series;
      return s.length === 2 && s[1].name === "this hex" && s[1].data.some(v => v != null);
    }, { timeout: 8000 }, fine.id).then(() => true).catch(() => false);
    ok(twoLines, "hovering " + fine.id + " draws its own line next to the region line");
  }

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

// Does the browser editor actually draw the real ground, and does a sculpt
// still show through it?
//
//     node tools/web_map_check.mjs [out.png]
//
// WHY A BROWSER AND NOT AN EYE. The background is now four layers blended in
// canvas — a palette ramp, a baked photograph of the floor, an overlay and a
// multiply — and every one of those can go wrong in a way that still produces
// a picture. The bake can fail to load and leave the old height ramp. The
// multiply can swallow the bake. The alpha punch can eat the whole image. All
// three look like "a map" in a screenshot.
//
// So this asserts the things a screenshot cannot: that the composite is not
// the palette ramp, that it IS mix(palette, bake, baked_colour) * relief to
// within a couple of levels, that its brightness is in the same band the
// biodome renders in, and that stamping a plateau still moves pixels.

import {chromium} from "/tmp/claude-0/-home-user-Game/baa78a34-f208-5516-ab7a-2e864c2d762e/scratchpad/node_modules/playwright/index.mjs";
import {pathToFileURL} from "node:url";
import path from "node:path";

const PAGE = path.resolve("tools/web_map_editor.html");
const SHOT = process.argv[2] || "build/web/editor_check.png";
let bad = 0;
const ok = (pass, what, detail) => {
  console.log(`  ${pass ? "ok  " : "FAIL"}  ${what}${detail ? "   " + detail : ""}`);
  if (!pass) bad++;
};

const browser = await chromium.launch({executablePath: process.env.CHROMIUM
    || "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"});
const page = await browser.newPage({viewport: {width: 1280, height: 860}});
// SCRIPT errors only. The page pulls its fonts off Google, which this
// container cannot reach, and a failed stylesheet is not a broken editor.
const errs = [];
const netErrs = [];
page.on("pageerror", e => errs.push(String(e)));
page.on("console", m => { if (m.type() === "error") netErrs.push(m.text()); });
await page.goto(pathToFileURL(PAGE).href);
// The page boots on two image decodes; `base` is the last thing boot() fills.
await page.waitForFunction("typeof base !== 'undefined' && base && base.length > 0",
  null, {timeout: 20000});

console.log("SENTINEL — the browser map editor, measured\n");
ok(errs.length === 0, "no script errors", errs.slice(0, 2).join(" | "));
if (netErrs.length) console.log(`        (${netErrs.length} resource load(s) failed — fonts, offline)`);

const r = await page.evaluate(() => {
  const s = (cv) => {
    const c = document.createElement("canvas");
    c.width = cv.width; c.height = cv.height;
    c.getContext("2d").drawImage(cv, 0, 0);
    return c.getContext("2d").getImageData(0, 0, cv.width, cv.height).data;
  };
  // OVER THE OPEN FLOOR, always — the bake's footprint intersected with the
  // ground the terrain actually calls passable. The first version of this skipped
  // dark pixels instead, which quietly compared the bake (whose off-map void
  // is pure black and got skipped) against the composite (whose void is the
  // chasm colour and did not) and reported a 24-level gap that was entirely
  // the two means being taken over different pixels. The second version fixed
  // that and still read 9% low, because the bake's silhouette is the MESH
  // edge and impassable_below is a gameplay line above it: a tenth of what
  // the bake covers is ground the editor correctly paints as chasm, and
  // averaging the editor's near-black over it is not a veil.
  const lum = (d, mask) => {
    let n = 0, sum = 0, lo = 255, hi = 0;
    for (let i = 0; i < d.length; i += 4) {
      if (mask && !mask[i >> 2]) continue;
      const l = (d[i] * 0.299 + d[i + 1] * 0.587 + d[i + 2] * 0.114);
      sum += l; n++; lo = Math.min(lo, l); hi = Math.max(hi, l);
    }
    return {mean: n ? sum / n : 0, lo, hi, n};
  };
  const bgd = s(bg), tiled = s(tile);
  const acv0 = albedoCv ? s(albedoCv) : null;
  // Sample the composite against the layers it claims to be made of.
  const bw = bg.width, bh = bg.height;
  const open = new Uint8Array(bw * bh);
  let covered = 0, chasmUnderBake = 0;
  for (let py = 0; py < bh; py++) for (let px = 0; px < bw; px++) {
    const k = py * bw + px;
    if (!acv0 || acv0[k * 4 + 3] < 255) continue;
    covered++;
    const mi = Math.min(H - 1, Math.floor(py / bh * H)) * W
      + Math.min(W - 1, Math.floor(px / bw * W));
    if (work[mi] < M.impassable_below || walled[mi]) { chasmUnderBake++; continue; }
    open[k] = 1;
  }
  const acv = acv0;
  const rel = s(relief);
  // WHERE THE 150x112 LAYERS CAN BE READ EXACTLY. They are blitted up to
  // 1400 px, so at any bg pixel the browser is showing a FILTERED blend of
  // neighbouring cells, not one cell. Comparing against the nearest cell
  // measures the upscale filter, not the composite — the first version of
  // this did exactly that and reported 47/255.
  //
  // So sample only where the 3x3 neighbourhood of every small layer is
  // uniform, because there a filter of any kind is the identity and the
  // arithmetic is the only thing left that can be wrong.
  const flat = (d, mx, mz) => {
    const at = (x, z) => d[((z * W) + x) * 4];
    const c0 = at(mx, mz), c1 = d[((mz * W) + mx) * 4 + 1], c2 = d[((mz * W) + mx) * 4 + 2];
    for (let dz = -1; dz <= 1; dz++) for (let dx = -1; dx <= 1; dx++) {
      const o = (((mz + dz) * W) + mx + dx) * 4;
      if (Math.abs(d[o] - c0) > 1 || Math.abs(d[o + 1] - c1) > 1
        || Math.abs(d[o + 2] - c2) > 1) return false;
    }
    return true;
  };
  let worst = 0, checked = 0;
  if (acv) {
    for (let mz = 2; mz < H - 2; mz++) for (let mx = 2; mx < W - 2; mx++) {
      const mi = mz * W + mx;
      if (work[mi] < M.impassable_below || walled[mi]) continue;
      if (!flat(tiled, mx, mz) || !flat(rel, mx, mz)) continue;
      // The centre of that cell, in bg pixels.
      const px = Math.round((mx + 0.5) * bw / W), py = Math.round((mz + 0.5) * bh / H);
      const ai = (py * bw + px) * 4;
      if (acv[ai + 3] < 255) continue;               // punched or feathered
      const ti = mi * 4;
      const kk = rel[ti] / 255;
      for (let ch = 0; ch < 3; ch++) {
              const want = (tiled[ti + ch] * (1 - BAKED) + acv[ai + ch] * BAKED) * kk;
        worst = Math.max(worst, Math.abs(want - bgd[ai + ch]));
      }
      checked++;
    }
  }
  // LOCAL CONTRAST, not global spread: the question is whether you can still
  // see the vines, and a veil kills the difference between neighbouring
  // pixels while leaving the overall range alone. Mean |dx| across the floor,
  // on the bake and on the composite, over the same pixels.
  const detail = (d) => {
    let sum = 0, n = 0;
    for (let py = 2; py < bh - 2; py += 2) for (let px = 2; px < bw - 3; px += 2) {
      const a = (py * bw + px) * 4;
      const k = py * bw + px;
      if (!open[k] || !open[k + 1]) continue;
      sum += Math.abs(d[a] - d[a + 4]) + Math.abs(d[a + 1] - d[a + 5])
        + Math.abs(d[a + 2] - d[a + 6]);
      n++;
    }
    return n ? sum / n / 3 : 0;
  };
  const bakeDetail = acv ? detail(acv) : 0, bgDetail = detail(bgd);
  // The ramp alone, blitted to the same size — what the background used to be.
  const up = document.createElement("canvas");
  up.width = bw; up.height = bh;
  const uctx = up.getContext("2d", {willReadFrequently: true});
  uctx.imageSmoothingEnabled = true;
  uctx.drawImage(tile, 0, 0, bw, bh);
  const tiledUp = uctx.getImageData(0, 0, bw, bh).data;
  const bakeLum = acv ? lum(acv, open) : {mean: 0};
  // The relief's own mean over that same footprint. The composite is darker
  // than the bake BY DESIGN — relief is a multiply — so a brightness check
  // that ignores it just measures the shading and calls it a veil.
  let rSum = 0, rN = 0;
  for (let mz = 0; mz < H; mz++) for (let mx = 0; mx < W; mx++) {
    if (!acv) break;
    const px = Math.min(bw - 1, Math.round((mx + 0.5) * bw / W));
    const py = Math.min(bh - 1, Math.round((mz + 0.5) * bh / H));
    if (!open[py * bw + px]) continue;
    rSum += rel[(mz * W + mx) * 4] / 255; rN++;
  }
  const reliefMean = rN ? rSum / rN : 1;
  return {
    albedo: !!albedoCv, baked: BAKED, gameBaked: M.baked_colour,
    gain: GAIN.map(g => +g.toFixed(2)), rampDetail: detail(tiledUp),
    bakeLum, bakeDetail, bgDetail, reliefMean,
    covered, chasmUnderBake,
    bgSize: [bw, bh], tileSize: [tile.width, tile.height],
    bgLum: lum(bgd, open), tileLum: lum(tiled),
    worst, checked,
  };
});

ok(r.albedo, "the baked ground texture loaded");
console.log(`        (${(100 * r.chasmUnderBake / r.covered).toFixed(1)}% of what`
  + ` the bake covers is below impassable_below — the mesh edge sits under the`
  + ` gameplay line, and the editor paints that as chasm)`);
ok(r.baked > 0, "the page mixes the bake in",
  `page ${r.baked}, game baked_colour ${r.gameBaked}`);
ok(r.bgSize[0] >= 1000, "composite is at the bake's resolution",
  `${r.bgSize.join("x")} from a ${r.tileSize.join("x")} tile`);
ok(r.checked > 200, "enough open floor sampled", `${r.checked} points`);
// The whole claim of this change, as a number: the composite is the shader's
// mix, not a background with a texture thrown over it.
ok(r.worst <= 3, "composite == mix(palette, bake, baked_colour) * relief",
  `worst channel off by ${r.worst.toFixed(1)}/255`);
// And it is NOT the old height ramp with a wash over it. The ramp is a smooth
// four-colour gradient blitted up 9x; it has almost no pixel-to-pixel detail
// of its own, so anything the background has came from the bake.
ok(r.bgDetail > 6 * r.rampDetail, "the background is the bake, not the ramp",
  `${r.bgDetail.toFixed(2)} vs ramp-only ${r.rampDetail.toFixed(2)} levels per pixel`);
// The failure this page has already had once: a pale grey survey of somewhere
// else. The biodome floor is dark, and the bake is the authority on how dark.
const wantLum = r.bakeLum.mean * r.reliefMean;
ok(Math.abs(r.bgLum.mean - wantLum) < 0.08 * wantLum,
  "floor brightness is the bake's, shaded",
  `composite ${r.bgLum.mean.toFixed(1)} vs bake ${r.bakeLum.mean.toFixed(1)}`
  + ` x relief ${r.reliefMean.toFixed(2)} = ${wantLum.toFixed(1)}; ramp gain ${r.gain.join("/")}`);
// THE ANTI-VEIL ASSERTION. Mixing a 45% flat layer in costs contrast no
// matter what, but if the vines have gone soft the whole change was pointless.
ok(r.bgDetail > 0.55 * r.bakeDetail, "the bake's detail survives the mix",
  `${r.bgDetail.toFixed(2)} vs ${r.bakeDetail.toFixed(2)} levels per pixel `
  + `(${(100 * r.bgDetail / r.bakeDetail).toFixed(0)}%)`);

// A sculpt has to survive a background that cannot move.
const moved = await page.evaluate(() => {
  const before = bg.getContext("2d").getImageData(0, 0, bg.width, bg.height).data;
  stamp({op: "plateau", x: 74, z: 56, r: 18, level: 0.92, strength: 1});
  const after = bg.getContext("2d").getImageData(0, 0, bg.width, bg.height).data;
  let n = 0;
  for (let i = 0; i < before.length; i += 4) if (Math.abs(before[i] - after[i]) > 4) n++;
  return n / (before.length / 4);
});
ok(moved > 0.01, "a stamped plateau still shows through the bake",
  `${(moved * 100).toFixed(1)}% of the background moved`);
await page.evaluate(() => { document.getElementById("bUndo").click(); });

// WHAT A SCULPT STROKE COSTS NOW. paint() runs once per pointer move while
// dragging a brush, and it went from writing one 150x112 buffer to writing
// three and compositing four layers at 1400 px. A phone is not a desktop and
// this container is not a phone, so this is a floor, not a verdict — but a
// floor in the hundreds of milliseconds would settle the question on its own.
const ms = await page.evaluate(() => {
  paint();                                   // warm the blit path
  const t0 = performance.now();
  for (let i = 0; i < 20; i++) paint();
  return (performance.now() - t0) / 20;
});
ok(ms < 33, "a sculpt step stays inside a frame",
  `${ms.toFixed(1)} ms per paint() — DESKTOP, the A54 is the only thing that can price it`);

await page.screenshot({path: SHOT});
console.log(`\n  ${SHOT}`);
console.log(bad === 0 ? "\nALL CHECKS PASS" : `\n${bad} CHECK(S) FAILED`);
await browser.close();
process.exit(bad === 0 ? 0 : 1);

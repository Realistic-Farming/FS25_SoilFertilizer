// bigbag-labels-check.mjs - MAINTENANCE row 212 (issue #1087): each big bag loads its own label.
//
// Built on Bob's intake (Desk Office/Drafts/BOB-INTAKE-SOIL-1087-BIGBAG-LABELS-2026-10-03.md). The bar starts where
// the game starts: modDesc.xml's storeItems and fillTypes.xml's pallet entries under objects/bigBag, never a hand
// list. Each is walked to its vehicle XML (a multi-purchase item through its multipleItemPurchase filename), then to
// that XML's <base><filename> i3d, then to the i3d's own files: the label (every File the i3d loads from its own
// folder, not from $data) and its externalShapesFile, both resolved beside the i3d as the engine resolves them.
//
// Rows:
//   W1  the walk reaches every big bag: each fill type with a big-bag pallet, and each storeItem under objects/bigBag
//   F   every file the walk names exists (vehicle XMLs, i3ds, labels, shapes, store images)
//   B   NAMED: no two products (fill types) resolve to one label blob
//   D   NAMED: DAP, Polifoska and AN resolve to their own prints
//   P   the Polifoska i3d is its own, well-formed, and differs from DAP's in its label and shapes file only, with the
//       DAP i3d's bytes otherwise (UTF-8 BOM and iso-8859-1 declaration kept)
//   O   no label print in objects/bigBag is left unreferenced (a stale copy would hide the next mix-up)
//
// Usage:  node tools/test/bigbag-labels-check.mjs        Exit: 0 clean, 1 any failure.
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname, posix } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const BAG = "objects/bigBag/";
const failures = [];
let rows = 0;
const ok = (name, cond, detail) => { rows++; if (!cond) failures.push(`${name}${detail !== undefined ? " :: " + detail : ""}`); };
const eq = (name, got, want) => ok(name, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
const read = (rel) => readFileSync(join(ROOT, rel));
const text = (rel) => read(rel).toString("latin1");
const exists = (rel) => existsSync(join(ROOT, rel));
const sha = (rel) => createHash("sha256").update(read(rel)).digest("hex");
const attrs = (s) => { const o = {}; for (const m of s.matchAll(/([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"/g)) o[m[1]] = m[2]; return o; };

// ---- the walk, from the game's own lists
const modDesc = text("modDesc.xml");
const storeItems = [...modDesc.matchAll(/<storeItem\s+xmlFilename="([^"]+)"/g)].map((m) => m[1]).filter((p) => p.startsWith(BAG));
const fillTypes = text("fillTypes.xml");
const pallets = [];
for (const m of fillTypes.matchAll(/<fillType\s([^>]*)>([\s\S]*?)<\/fillType>/g)) {
  const name = attrs(m[1]).name;
  for (const p of m[2].matchAll(/<pallet\s+filename="([^"]+)"/g)) if (p[1].startsWith(BAG)) pallets.push({ fillType: name, xml: p[1] });
}
const missing = [];
const need = (rel, why) => { if (!exists(rel)) missing.push(`${rel} (${why})`); return exists(rel); };
const modPath = (p) => p.replace(/^\$moddir\$\/?/, "");

// vehicle XMLs reached: from pallets directly, from storeItems directly or through a multi-purchase item
const vehicles = new Map();          // vehicle xml -> { from: [...] }
const addVehicle = (rel, from) => { if (!vehicles.has(rel)) vehicles.set(rel, { from: [] }); vehicles.get(rel).from.push(from); };
for (const p of pallets) if (need(p.xml, `pallet of ${p.fillType}`)) addVehicle(p.xml, `fillTypes ${p.fillType}`);
for (const s of storeItems) {
  if (!need(s, "storeItem")) continue;
  const x = text(s);
  const image = (x.match(/<image>([^<]+)<\/image>/) || [])[1];
  if (image) need(modPath(image), `store image of ${s}`);
  const multi = x.match(/<multipleItemPurchase\s+filename="([^"]+)"/);
  if (multi) { if (need(multi[1], `multi-purchase item of ${s}`)) addVehicle(multi[1], `storeItem ${s}`); }
  else addVehicle(s, `storeItem ${s}`);
}

// each vehicle: its fill type, its i3d, the i3d's label(s) and shapes file
const products = [];
for (const [rel] of vehicles) {
  if (!exists(rel)) continue;
  const x = text(rel);
  const fillType = (x.match(/<fillUnit\s[^>]*fillTypes="([^"]+)"/) || [])[1] || "?";
  const i3d = (x.match(/<base>[\s\S]*?<filename>([^<]+)<\/filename>/) || [])[1];
  if (!i3d) { missing.push(`${rel}: no <base><filename>`); continue; }
  if (!need(i3d, `i3d of ${rel}`)) continue;
  const it = text(i3d), dir = posix.dirname(i3d);
  const labels = [...it.matchAll(/<File\s([^>]*)\/?>/g)].map((m) => attrs(m[1]).filename).filter((f) => f && !f.startsWith("$")).map((f) => posix.join(dir, f));
  const shapes = (it.match(/externalShapesFile="([^"]+)"/) || [])[1];
  for (const l of labels) need(l, `label of ${i3d}`);
  if (shapes) need(posix.join(dir, shapes), `shapes of ${i3d}`); else missing.push(`${i3d}: no externalShapesFile`);
  const image = (x.match(/<image>([^<]+)<\/image>/) || [])[1];
  if (image) need(modPath(image), `store image of ${rel}`);
  products.push({ xml: rel, fillType, i3d, labels });
}

// ---- W
const bagFillTypes = [...new Set(pallets.map((p) => p.fillType))].sort();
const walkedFillTypes = [...new Set(products.map((p) => p.fillType))].sort();
eq("W1 [reached] the walk reaches every fill type with a big-bag pallet", walkedFillTypes, bagFillTypes);
ok("W2 [reached] and every big-bag storeItem (multi-purchase items through their vehicle XML)", storeItems.length >= 22 && products.length >= 15,
   `${storeItems.length} storeItems, ${products.length} vehicle XMLs`);

// ---- F
eq("F1 NAMED: every file the walk names exists", missing, []);

// ---- B: no two products on one label blob
const blobOwners = new Map();
for (const p of products) for (const l of p.labels) {
  if (!exists(l)) continue;
  const h = sha(l);
  if (!blobOwners.has(h)) blobOwners.set(h, new Set());
  blobOwners.get(h).add(p.fillType);
}
const shared = [...blobOwners.values()].filter((s) => s.size > 1).map((s) => [...s].sort().join("+")).sort();
eq("B1 NAMED: no two products resolve to one label blob", shared, []);
const oneLabel = products.filter((p) => p.labels.length !== 1).map((p) => `${p.xml}: ${p.labels.length}`);
eq("B2 every big bag's i3d loads exactly one label of its own", oneLabel, []);

// ---- D: the three named bags
const labelOf = (ft) => [...new Set(products.filter((p) => p.fillType === ft).flatMap((p) => p.labels))];
const i3dOf = (ft) => [...new Set(products.filter((p) => p.fillType === ft).map((p) => p.i3d))];
eq("D1 NAMED: DAP wears its own print", labelOf("DAP"), [BAG + "dap/bigBag_dap_diffuse.png"]);
eq("D2 NAMED: Polifoska loads its own i3d", i3dOf("POLIFOSKA"), [BAG + "polifoska/bigBag_polifoska.i3d"]);
eq("D3 NAMED: and wears its own print", labelOf("POLIFOSKA"), [BAG + "polifoska/bigBag_polifoska_diffuse.dds"]);
eq("D4 NAMED: AN wears its own print", labelOf("AN"), [BAG + "an/bigBag_an_diffuse.dds"]);
eq("D5 urea keeps its print", labelOf("UREA"), [BAG + "urea/bigBag_urea_diffuse.png"]);

// ---- P: the Polifoska i3d
{
  const pRel = BAG + "polifoska/bigBag_polifoska.i3d", dRel = BAG + "dap/bigBag_dap.i3d";
  const has = exists(pRel) && exists(dRel);
  ok("P1 [reached] the Polifoska i3d exists", has);
  if (has) {
    const pb = read(pRel), db = read(dRel);
    ok("P2 it keeps the DAP i3d's UTF-8 BOM and iso-8859-1 declaration (never re-encoded)",
       pb.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf])) && /^<\?xml version="1\.0" encoding="iso-8859-1"\?>/.test(pb.subarray(3).toString("latin1")));
    // well-formed: every tag closes in order
    const s = pb.toString("latin1").replace(/<!--[\s\S]*?-->/g, "").replace(/<\?[\s\S]*?\?>/g, "");
    const stack = []; let bad = null;
    for (const m of s.matchAll(/<(\/?)([A-Za-z_][\w:.-]*)((?:\s+[^\s=>/]+\s*=\s*"[^"]*")*)\s*(\/?)>/g)) {
      if (m[1]) { if (stack.pop() !== m[2]) { bad = `</${m[2]}> out of order`; break; } }
      else if (!m[4]) stack.push(m[2]);
    }
    const tagCount = (s.match(/</g) || []).length, matched = [...s.matchAll(/<(\/?)([A-Za-z_][\w:.-]*)((?:\s+[^\s=>/]+\s*=\s*"[^"]*")*)\s*(\/?)>/g)].length;
    ok("P3 it is well-formed XML (every tag closes in order, every tag parsed)", bad === null && stack.length === 0 && tagCount === matched,
       bad || `${stack.length} unclosed, ${tagCount - matched} unparsed`);
    const pl = pb.toString("latin1").split("\n"), dl = db.toString("latin1").split("\n");
    const diffs = [];
    for (let i = 0; i < Math.max(pl.length, dl.length); i++) if (pl[i] !== dl[i]) diffs.push([i + 1, (dl[i] || "").trim(), (pl[i] || "").trim()]);
    eq("P4 NAMED: it differs from the DAP i3d in its label and its shapes file only",
       diffs.map((d) => d[2]), ['<File fileId="20" filename="bigBag_polifoska_diffuse.dds" />', '<Shapes externalShapesFile="bigBag_polifoska.i3d.shapes">']);
    ok("P5 its shapes file is a byte copy of DAP's", exists(BAG + "polifoska/bigBag_polifoska.i3d.shapes")
       && sha(BAG + "polifoska/bigBag_polifoska.i3d.shapes") === sha(BAG + "dap/bigBag_dap.i3d.shapes"));
  }
}

// ---- O: no stale print
{
  const referenced = new Set(products.flatMap((p) => p.labels));
  const prints = [];
  for (const d of readdirSync(join(ROOT, BAG))) {
    const full = join(ROOT, BAG, d);
    if (!statSync(full).isDirectory()) continue;
    for (const f of readdirSync(full)) if (/_diffuse\.(png|dds)$/i.test(f)) prints.push(BAG + d + "/" + f);
  }
  eq("O1 NAMED: no label print in objects/bigBag is left unreferenced", prints.filter((p) => !referenced.has(p)).sort(), []);
}

if (failures.length) {
  for (const f of failures) console.log("  FAIL " + f);
  console.log(`bigbag-labels: ${failures.length} failure(s) over ${rows} rows`);
  process.exit(1);
}
console.log(`bigbag-labels: PASS - ${rows} rows; ${storeItems.length} storeItems and ${pallets.length} pallets walked to ${products.length} vehicle XMLs`);

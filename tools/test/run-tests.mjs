// run-tests.mjs - offline logic tests for FS25_SoilFertilizer.
//
// For each tools/test/lua/*_test.lua, builds a single Lua program of:
//   prelude.lua  +  the src modules it declares  +  the test file  +  T.summary()
// runs it in a fresh fengari (Lua) state, captures stdout, and parses the
// ##TEST_PASS / ##TEST_FAIL / ##TEST_SUMMARY markers the framework emits.
//
// A test declares which real src files to load with a header line:
//   --!load: src/config/Constants.lua, src/SoilFertilitySystem.lua
//
// A test may ask for the MOD'S OWN ENVIRONMENT with a second header line:
//   --!env: modenv
// The engine loads every mod chunk in its own environment (mods.lua:436-442): a
// table whose __index is the real global table and whose _G is ITSELF. An engine
// global therefore reaches a mod only through __index; rawget(_G, name) from a mod
// never sees one. With this header the prelude and the tools/test/lua/ models (the
// engine side) load in the real global table, and every src/ file and the test
// itself load under `local _ENV` shaped exactly like modEnv, so a source that reads
// an engine global the wrong way fails on the bench the way it fails in a game.
//
// Usage:  node run-tests.mjs [--loads <repo path> ...]
//         (--loads runs only the tests that can reach that file; see Selection below)
// Exit:   0 = all assertions passed, 1 = any failure, Lua load error, or bad selection.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";
import luaparse from "luaparse";
import { REPO_ROOT, findLuaFiles, rel, c } from "./lib.mjs";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const LUA_DIR = fileURLToPath(new URL("./lua", import.meta.url));
const prelude = readFileSync(join(LUA_DIR, "prelude.lua"), "utf8");

function parseDeps(src) {
  const m = src.match(/--!load:\s*(.+)/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim()).filter(Boolean);
}

function wantsModEnv(src) {
  return /--!env:\s*modenv\b/.test(src);
}

// The mod's own environment, as mods.lua:436-442 builds it. `_G` on the right-hand
// side is evaluated before the local takes effect, so it is the real global table.
const MOD_ENV_SWITCH = [
  "-- <<< modEnv: the mod's own environment (mods.lua:436-442) >>>",
  "local _ENV = setmetatable({}, { __index = _G })",
  "_ENV._G = _ENV",
  "",
].join("\n");

// `--!text: path, path` hands a bar the TEXT of a repo file as
// SOURCE_TEXT["path"], for source-witness rows that pin a call site's shape
// (fengari has no io.open). The file is not executed, only quoted; a long
// bracket level absent from the text is chosen so nothing can close it early.
function parseTexts(src) {
  const m = src.match(/--!text:\s*(.+)/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim()).filter(Boolean);
}
// MAINTENANCE row 113 (row 87's defect, FertilizerDepot #80's line): the level is chosen
// from the text WITH the closer's "]" appended, so a file whose last characters meet the
// closing bracket (ending in "]" at level 0, or "]=" at level 1) cannot close the string
// early. The bar is MAINT-113-long_string_boundary_test.lua.
function luaLongString(text) {
  let level = 0;
  while ((text + "]").includes("]" + "=".repeat(level) + "]")) level += 1;
  const eq = "=".repeat(level);
  return `[${eq}[\n${text}]${eq}]`;
}

// Run one Lua program string, return { rc, out } with stdout captured.
function runLua(program) {
  let out = "";
  const orig = process.stdout.write.bind(process.stdout);
  process.stdout.write = (s) => { out += s; return true; };
  let rc, errMsg = "";
  try {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    rc = lauxlib.luaL_dostring(L, to_luastring(program));
    if (rc !== lua.LUA_OK) {
      errMsg = lua.lua_tojsstring(L, -1);
    }
  } finally {
    process.stdout.write = orig;
  }
  return { rc, out, errMsg };
}

const allTestFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();
if (allTestFiles.length === 0) {
  console.log(c.yellow("No *_test.lua files found in tools/test/lua/."));
  process.exit(0);
}

// Selection (Tyson's battery ruling, 2026-09-30): a mutation battery runs each
// mutant only against the test files that can see the file it mutates.
//   node run-tests.mjs                          every *_test.lua, as before
//   node run-tests.mjs --loads src/X.lua [...]  only the tests that can reach it
// Each test file runs in its own fresh Lua state (runLua above), so a repo file
// reaches a test only through that test's own text: its --!load list, its
// --!text list, or a path it loads by hand (RSF-F202 loadfiles
// src/utils/Logger.lua). So a test is selected when its text names the path.
// src/main.lua sources every module, so a test that --!loads it is always
// selected. Selecting by text can take in too many files, never too few, on two
// conditions this block enforces (MAINTENANCE row 182, Bob's MINORs on #1055):
//   - The path is matched the way the tests spell it: resolved against the repo
//     root, made repo-relative with forward slashes, and on Windows, where the
//     file system ignores case, matched without case. So ./src/X.lua, an
//     absolute path and a different letter case select what src/X.lua selects.
//     A path outside the repo is refused.
//   - No src/ file other than src/main.lua loads another. If one did, a test
//     could reach a file its text never names. srcLoaderRefs checks it on every
//     --loads run, and a hit is an error.
// A path that is not a repo file, or a selection that finds no test, is an
// error: a battery must never read a run over zero files as a pass.
const LOADERS = new Set(["source", "loadfile", "dofile", "loadstring", "require"]);
const LOADER_WORD = /\b(source|loadfile|dofile|loadstring|require)\b/;

// The text of a Lua string literal (luaparse leaves .value null by default).
function luaStringText(raw) {
  const m = raw.match(/^"(.*)"$|^'(.*)'$|^\[(=*)\[([\s\S]*)\]\3\]$/s);
  return m ? (m[1] ?? m[2] ?? m[4]) : null;
}

const isGlobal = (n, name) => n?.type === "Identifier" && n.name === name && !n.isLocal;

// An expression that yields the environment, spelled the ways src/ spells it: `_G`,
// any getfenv(...) call (a mod's getfenv returns modEnv, which carries source:
// mods.lua:497-505 and :512 at game 1.24.0.0), `a and getfenv(0) or b`, or a local
// of the file assigned from one of those (`local env = getfenv(0)`). Locals are
// tracked by name within the file, so an unrelated local of the same name counts
// too; that can only add a hit, never hide one.
function isEnv(n, envLocals) {
  if (!n) return false;
  if (isGlobal(n, "_G")) return true;
  if (n.type === "CallExpression" && isGlobal(n.base, "getfenv")) return true;
  if (n.type === "LogicalExpression") return isEnv(n.left, envLocals) || isEnv(n.right, envLocals);
  return n.type === "Identifier" && n.isLocal === true && envLocals.has(n.name);
}

// Walk an AST, depth first in source order. `globals` is skipped: with scope on,
// luaparse lists each global's first Identifier there too (luaparse.js:1496-1497,
// :2732), and walking it would report every hit twice.
function walkAst(node, visit, parent = null, key = null) {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const child of node) walkAst(child, visit, parent, key);
    return;
  }
  visit(node, parent, key);
  for (const k of Object.keys(node)) {
    if (k !== "loc" && k !== "range" && k !== "globals") walkAst(node[k], visit, node, k);
  }
}

// Every reference to a loader in src/ outside src/main.lua, as "file:line name".
// Only global references count, so the many locals, parameters and table keys
// named `source` in src/ are not hits. An alias (`local f = loadfile`) is a hit,
// and so are `env.name`, `env["name"]` and `rawget(env, "name")` for any env above.
// A name built at run time (`_G["sour" .. "ce"]`), or an environment that reaches
// a file another way (a parameter, a table field), is beyond a static check. A
// file that does not parse cannot be checked, so it is reported as a hit.
function srcLoaderRefs() {
  const hits = [];
  for (const file of findLuaFiles()) {
    const where = rel(file);
    if (where === "src/main.lua") continue;
    const text = readFileSync(file, "utf8");
    if (!LOADER_WORD.test(text)) continue;
    let ast;
    try {
      ast = luaparse.parse(text, { comments: false, scope: true, locations: true, luaVersion: "5.1" });
    } catch (e) {
      hits.push(`${where}: does not parse as Lua 5.1 (${e.message}), so it cannot be checked`);
      continue;
    }
    const envLocals = new Set();
    walkAst(ast, (node) => {
      if (node.type !== "LocalStatement" && node.type !== "AssignmentStatement") return;
      node.variables.forEach((v, i) => {
        if (v.type === "Identifier" && v.isLocal === true && isEnv(node.init[i], envLocals)) envLocals.add(v.name);
      });
    });
    walkAst(ast, (node, parent, key) => {
      let name = null;
      if (node.type === "Identifier" && !node.isLocal
          && !(parent?.type === "MemberExpression" && key === "identifier")
          && !(parent?.type === "TableKeyString" && key === "key")) {
        name = node.name;
      } else if (node.type === "MemberExpression" && isEnv(node.base, envLocals)) {
        name = node.identifier.name;
      } else if (node.type === "IndexExpression" && isEnv(node.base, envLocals) && node.index.type === "StringLiteral") {
        name = luaStringText(node.index.raw);
      } else if (node.type === "CallExpression" && isGlobal(node.base, "rawget")
          && isEnv(node.arguments[0], envLocals) && node.arguments[1]?.type === "StringLiteral") {
        name = luaStringText(node.arguments[1].raw);
      }
      if (name !== null && LOADERS.has(name)) hits.push(`${where}:${node.loc.start.line} ${name}`);
    });
  }
  return hits;
}

const loadsArgs = [];
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === "--loads" && i + 1 < process.argv.length) {
    loadsArgs.push(process.argv[++i]);
    continue;
  }
  console.log(c.red(`Unknown argument '${process.argv[i]}'. Usage: node run-tests.mjs [--loads <repo path> ...]`));
  process.exit(1);
}
const fold = process.platform === "win32" ? (s) => s.toLowerCase() : (s) => s;
const loadsPaths = [];
for (const arg of loadsArgs) {
  const abs = resolve(REPO_ROOT, arg.replace(/\\/g, "/"));
  const inRepo = relative(REPO_ROOT, abs);
  if (inRepo === ".." || inRepo.startsWith(".." + sep) || isAbsolute(inRepo)) {
    console.log(c.red(`--loads ${arg}: outside the repo. Give a path in the repo, relative to its root (src/X.lua).`));
    process.exit(1);
  }
  if (!existsSync(abs) || !statSync(abs).isFile()) {
    console.log(c.red(`--loads ${arg}: no such file in the repo.`));
    process.exit(1);
  }
  loadsPaths.push(inRepo.split(sep).join("/"));
}
let testFiles = allTestFiles;
if (loadsPaths.length) {
  const loaderRefs = srcLoaderRefs();
  if (loaderRefs.length) {
    console.log(c.red("--loads cannot select safely: a src/ file other than src/main.lua loads another."));
    for (const h of loaderRefs) console.log(c.red(`  ${h}`));
    console.log(c.red("Selection matches test text, so a test could reach a file its text never names. Run the whole suite without --loads."));
    process.exit(1);
  }
  testFiles = allTestFiles.filter((tf) => {
    const text = fold(readFileSync(join(LUA_DIR, tf), "utf8"));
    return parseDeps(text).includes("src/main.lua") || loadsPaths.some((p) => text.includes(fold(p)));
  });
  if (testFiles.length === 0) {
    console.log(c.red(`--loads ${loadsPaths.join(", ")}: no test file reaches it.`));
    process.exit(1);
  }
  console.log(c.dim(`Selected ${testFiles.length} of ${allTestFiles.length} test files that reach ${loadsPaths.join(", ")}.`));
}

let totalPass = 0, totalFail = 0, hadError = false;

for (const tf of testFiles) {
  const testPath = join(LUA_DIR, tf);
  const testSrc = readFileSync(testPath, "utf8");
  const deps = parseDeps(testSrc);
  const texts = parseTexts(testSrc);
  const modEnv = wantsModEnv(testSrc);

  const parts = [prelude];
  let switched = false;
  for (const d of deps) {
    if (modEnv && !switched && !d.startsWith("tools/")) {
      parts.push(MOD_ENV_SWITCH);
      switched = true;
    }
    try {
      parts.push(`-- <<< ${d} >>>\n` + readFileSync(join(REPO_ROOT, d), "utf8"));
    } catch {
      console.log(c.red(`✗ ${tf}: cannot read declared dependency '${d}'`));
      hadError = true;
    }
  }
  if (modEnv && !switched) {
    parts.push(MOD_ENV_SWITCH);
    switched = true;
  }
  for (const t of texts) {
    try {
      const text = readFileSync(join(REPO_ROOT, t), "utf8");
      parts.push(`-- <<< text: ${t} >>>\nSOURCE_TEXT = SOURCE_TEXT or {}\nSOURCE_TEXT[${JSON.stringify(t)}] = ${luaLongString(text)}\n`);
    } catch {
      console.log(c.red(`✗ ${tf}: cannot read declared text '${t}'`));
      hadError = true;
    }
  }
  parts.push(`-- <<< test: ${tf} >>>\n` + testSrc);
  parts.push("\nT.summary()\n");

  const { rc, out, errMsg } = runLua(parts.join("\n"));

  if (rc !== 0) {
    hadError = true;
    // Report what the file DID produce before it died, then the error.
    //
    // This branch used to `continue` immediately, discarding every ##TEST_PASS and
    // ##TEST_FAIL the file had already emitted. A test that failed an assertion and
    // then crashed reported only "Lua error", so the diagnosis it had already
    // printed was thrown away by the reporter rather than never existing. That is
    // the worst case to lose evidence in: a crash is exactly when you need to know
    // which assertion went red first.
    const crashPasses = [...out.matchAll(/^##TEST_PASS (.+)$/gm)].map((m) => m[1]);
    const crashFails = [...out.matchAll(/^##TEST_FAIL (.+)$/gm)].map((m) => m[1]);
    totalPass += crashPasses.length;
    totalFail += crashFails.length;
    console.log(c.red(`✗ ${c.bold(tf)} - Lua error while loading/running`) +
      c.dim(` (${crashPasses.length} passed, ${crashFails.length} failed before the error)`));
    for (const f of crashFails) console.log(`    ${c.red("FAIL")} ${f}`);
    console.log(`  ${c.red(errMsg || "(no message)")}`);
    continue;
  }

  const passes = [...out.matchAll(/^##TEST_PASS (.+)$/gm)].map((m) => m[1]);
  const fails = [...out.matchAll(/^##TEST_FAIL (.+)$/gm)].map((m) => m[1]);
  totalPass += passes.length;
  totalFail += fails.length;

  const status = fails.length === 0 ? c.green("✓") : c.red("✗");
  console.log(`${status} ${c.bold(tf)} ${c.dim(`(${passes.length} passed, ${fails.length} failed)`)}`);
  for (const f of fails) console.log(`    ${c.red("FAIL")} ${f}`);
}

console.log(
  "\n" +
    (totalFail === 0 && !hadError ? c.green("PASS") : c.red("FAIL")) +
    ` - ${totalPass} assertion${totalPass === 1 ? "" : "s"} passed, ${totalFail} failed across ${testFiles.length} file${testFiles.length === 1 ? "" : "s"}` +
    (loadsPaths.length ? ` (selected by --loads, of ${allTestFiles.length}).` : ".")
);
process.exit(totalFail === 0 && !hadError ? 0 : 1);

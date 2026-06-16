// run-tests.mjs — offline logic tests for FS25_SoilFertilizer.
//
// For each tools/test/lua/*_test.lua, builds a single Lua program of:
//   prelude.lua  +  the src modules it declares  +  the test file  +  T.summary()
// runs it in a fresh fengari (Lua) state, captures stdout, and parses the
// ##TEST_PASS / ##TEST_FAIL / ##TEST_SUMMARY markers the framework emits.
//
// A test declares which real src files to load with a header line:
//   --!load: src/config/Constants.lua, src/SoilFertilitySystem.lua
//
// Usage:  node run-tests.mjs
// Exit:   0 = all assertions passed, 1 = any failure or Lua load error.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";
import { REPO_ROOT, rel, c } from "./lib.mjs";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const LUA_DIR = fileURLToPath(new URL("./lua", import.meta.url));
const prelude = readFileSync(join(LUA_DIR, "prelude.lua"), "utf8");

function parseDeps(src) {
  const m = src.match(/--!load:\s*(.+)/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim()).filter(Boolean);
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

const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();
if (testFiles.length === 0) {
  console.log(c.yellow("No *_test.lua files found in tools/test/lua/."));
  process.exit(0);
}

let totalPass = 0, totalFail = 0, hadError = false;

for (const tf of testFiles) {
  const testPath = join(LUA_DIR, tf);
  const testSrc = readFileSync(testPath, "utf8");
  const deps = parseDeps(testSrc);

  const parts = [prelude];
  for (const d of deps) {
    try {
      parts.push(`-- <<< ${d} >>>\n` + readFileSync(join(REPO_ROOT, d), "utf8"));
    } catch {
      console.log(c.red(`✗ ${tf}: cannot read declared dependency '${d}'`));
      hadError = true;
    }
  }
  parts.push(`-- <<< test: ${tf} >>>\n` + testSrc);
  parts.push("\nT.summary()\n");

  const { rc, out, errMsg } = runLua(parts.join("\n"));

  if (rc !== 0) {
    hadError = true;
    console.log(c.red(`✗ ${c.bold(tf)} — Lua error while loading/running:`));
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
    ` — ${totalPass} assertion${totalPass === 1 ? "" : "s"} passed, ${totalFail} failed across ${testFiles.length} file${testFiles.length === 1 ? "" : "s"}.`
);
process.exit(totalFail === 0 && !hadError ? 0 : 1);

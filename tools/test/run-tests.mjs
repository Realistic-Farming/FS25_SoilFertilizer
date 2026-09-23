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

// `--!text: path, path` hands a bar the TEXT of a repo file as
// SOURCE_TEXT["path"], for source-witness rows that pin a call site's shape
// (fengari has no io.open). The file is not executed, only quoted; a long
// bracket level absent from the text is chosen so nothing can close it early.
function parseTexts(src) {
  const m = src.match(/--!text:\s*(.+)/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim()).filter(Boolean);
}
function luaLongString(text) {
  let level = 0;
  while (text.includes("]" + "=".repeat(level) + "]")) level += 1;
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
  const texts = parseTexts(testSrc);

  const parts = [prelude];
  for (const d of deps) {
    try {
      parts.push(`-- <<< ${d} >>>\n` + readFileSync(join(REPO_ROOT, d), "utf8"));
    } catch {
      console.log(c.red(`✗ ${tf}: cannot read declared dependency '${d}'`));
      hadError = true;
    }
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
    ` - ${totalPass} assertion${totalPass === 1 ? "" : "s"} passed, ${totalFail} failed across ${testFiles.length} file${testFiles.length === 1 ? "" : "s"}.`
);
process.exit(totalFail === 0 && !hadError ? 0 : 1);

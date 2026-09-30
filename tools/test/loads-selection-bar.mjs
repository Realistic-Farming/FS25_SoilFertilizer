// loads-selection-bar.mjs - the bar for `run-tests.mjs --loads` (MAINTENANCE row 182).
//
// Usage:  node loads-selection-bar.mjs      (from tools/test)
// Exit:   0 = every row passed, 1 = any row failed.
//
// Part A drives the REAL runner over the REAL tree: tools/test/lua and src/ as they
// are, nothing planted. Every spelling of one repo file must select exactly what the
// bare spelling selects, and a path outside the repo must be refused. It also runs
// the loader check over the real src/, which must pass.
//
// Part B needs a src/ file that loads another, which the real repo must never carry.
// It builds a throwaway repo under tools/test/.loadsbar_<pid>_temp/ (the root
// .gitignore ignores *_temp/), copies the real run-tests.mjs, lib.mjs and prelude.lua
// into it byte for byte, and runs the copy. REPO_ROOT follows lib.mjs, so the copy
// sees the throwaway repo, and node still finds fengari and luaparse by walking up
// to tools/test/node_modules.
//
// A selection row stops the runner as soon as it prints "Selected N of M", so a
// path that selects most of the suite costs no more than one that selects a file.
import { spawn } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { REPO_ROOT } from "./lib.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const RUNNER = join(HERE, "run-tests.mjs");

// Run a runner with arguments. Resolves { code, out, selected, total } when the
// process exits, or as soon as a "Selected N of M" line appears (then it is killed
// and code is null).
function runRunner(runner, args, cwd) {
  return new Promise((done) => {
    const child = spawn(process.execPath, [runner, ...args], { cwd });
    let out = "";
    let finished = false;
    const finish = (code) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      const m = out.match(/Selected (\d+) of (\d+) test files/);
      done({ code, out, selected: m ? Number(m[1]) : null, total: m ? Number(m[2]) : null });
    };
    const timer = setTimeout(() => { child.kill(); finish("timeout"); }, 180000);
    const take = (chunk) => {
      out += chunk;
      if (/Selected \d+ of \d+ test files/.test(out)) { child.kill(); finish(null); }
    };
    child.stdout.on("data", take);
    child.stderr.on("data", take);
    child.on("close", (code) => finish(code));
  });
}

let pass = 0, fail = 0;
function row(name, ok, detail) {
  if (ok) { pass += 1; console.log(`  PASS ${name}`); }
  else { fail += 1; console.log(`  FAIL ${name}\n       ${detail.trim().split("\n").join("\n       ")}`); }
}
const shown = (r) => `code ${r.code}, selected ${r.selected}\n${r.out.slice(-600)}`;

// ---------------------------------------------------------------------------
// Part A: the real runner over the real tree.
// ---------------------------------------------------------------------------
console.log("Part A: the real runner, the real tools/test/lua and src/");
const TARGET = "src/utils/Logger.lua";
const bare = await runRunner(RUNNER, ["--loads", TARGET], HERE);
row(`A1 bare ${TARGET} selects tests and passes the loader check`,
  bare.selected !== null && bare.selected >= 2 && !/cannot select safely/.test(bare.out), shown(bare));

const spellings = [
  ["A2 ./ prefix", `./${TARGET}`],
  ["A3 backslashes", TARGET.split("/").join("\\")],
  ["A4 absolute path in the repo", join(REPO_ROOT, TARGET)],
  ["A5 a .. segment inside the repo", `src/../${TARGET}`],
];
if (process.platform === "win32") spellings.push(["A6 different letter case (Windows)", "SRC/Utils/logger.LUA"]);
for (const [name, arg] of spellings) {
  const r = await runRunner(RUNNER, ["--loads", arg], HERE);
  row(`${name} (${arg}) selects what the bare path selects (${bare.selected})`,
    bare.selected !== null && r.selected === bare.selected, shown(r));
}
if (process.platform !== "win32") {
  const r = await runRunner(RUNNER, ["--loads", "SRC/Utils/logger.LUA"], HERE);
  row("A6 different letter case is not a file here (case-sensitive file system)",
    r.code === 1 && /no such file in the repo/.test(r.out), shown(r));
}

// An existing file outside the repo, by absolute and by relative path.
const outsideDir = mkdtempSync(join(tmpdir(), "loadsbar-"));
try {
  const outside = join(outsideDir, "Logger.lua");
  writeFileSync(outside, "-- " + TARGET + "\n");
  for (const [name, arg] of [["A7 absolute", outside], ["A8 relative", relative(REPO_ROOT, outside)]]) {
    const r = await runRunner(RUNNER, ["--loads", arg], HERE);
    row(`${name} path to a real file outside the repo is refused as outside`,
      r.code === 1 && /outside the repo/.test(r.out), shown(r));
  }
} finally {
  rmSync(outsideDir, { recursive: true, force: true });
}

{
  const r = await runRunner(RUNNER, ["--loads", "src"], HERE);
  row("A9 a directory is not a repo file", r.code === 1 && /no such file in the repo/.test(r.out), shown(r));
}

// ---------------------------------------------------------------------------
// Part B: a copy of the real runner over a throwaway repo with planted loaders.
// ---------------------------------------------------------------------------
console.log("Part B: a byte copy of the real runner over a throwaway repo");
const FIX = join(HERE, `.loadsbar_${process.pid}_temp`);
const FIX_TEST = join(FIX, "tools", "test");
const put = (path, text) => {
  mkdirSync(dirname(join(FIX, path)), { recursive: true });
  writeFileSync(join(FIX, path), text);
};

// Locals, parameters, table keys, members, comments and strings named after a
// loader. None of them loads anything, and src/ is full of them.
const DECOYS = [
  "A = { value = 1 }",
  "local source = \"rain\"",
  "local t = { source = 1, require = 2 }",
  "function A.dofile() return t.source end",
  "A.loadfile = nil",
  "local function pick(require) return require end",
  "local S = {}; S.source = function() return source end",
  "-- source(g_currentModDirectory .. \"src/B.lua\")",
  "local note = \"loadstring and require\"",
  "local env = getfenv(0)",
  "local mission = env.g_currentMission",
  "local i18n = getfenv(0)[\"g_i18n\"]",
  "local box = {}; box.source = 1",
  "",
].join("\n");

// The environment as src/ reaches it (getfenv(0), directly or through a local),
// one form per row, run after B12.
const ENV_PLANTS = [
  ["B13 getfenv(0).source", "getfenv(0).source(\"src/A.lua\")", "source"],
  ["B14 getfenv(0)[\"dofile\"]", "getfenv(0)[\"dofile\"](\"src/A.lua\")", "dofile"],
  ["B15 a local holding getfenv(0)", "local env = getfenv(0); env.require(\"A\")", "require"],
  ["B16 rawget(getfenv(0), \"loadfile\")", "local f = rawget(getfenv(0), \"loadfile\")", "loadfile"],
  ["B17 getfenv and getfenv(0) or nil", "local env = getfenv and getfenv(0) or nil; env.source(\"src/A.lua\")", "source"],
];

// A hit is reported once: the line must appear exactly once in the output.
const count = (out, s) => out.split(s).length - 1;

const PLANTS = [
  ["B2 source(...)", "source(g_currentModDirectory .. \"src/A.lua\")", "source"],
  ["B3 loadfile(...)", "local f = loadfile(\"src/A.lua\")", "loadfile"],
  ["B4 dofile(...)", "dofile(\"src/A.lua\")", "dofile"],
  ["B5 loadstring(...)", "local f = loadstring(\"return 1\")", "loadstring"],
  ["B6 require(...)", "require(\"A\")", "require"],
  ["B7 an alias of a loader", "local ld = loadfile", "loadfile"],
  ["B8 _G.source", "_G.source(\"src/A.lua\")", "source"],
  ["B9 _G[\"dofile\"]", "_G[\"dofile\"](\"src/A.lua\")", "dofile"],
  ["B10 rawget(_G, \"require\")", "rawget(_G, \"require\")(\"A\")", "require"],
];

try {
  mkdirSync(join(FIX_TEST, "lua"), { recursive: true });
  for (const f of ["run-tests.mjs", "lib.mjs"]) copyFileSync(join(HERE, f), join(FIX_TEST, f));
  copyFileSync(join(HERE, "lua", "prelude.lua"), join(FIX_TEST, "lua", "prelude.lua"));
  put("src/main.lua", "source(g_currentModDirectory .. \"src/A.lua\")\n");
  put("src/A.lua", DECOYS);
  put("tools/test/lua/a_test.lua", "--!load: src/A.lua\nT.eq(\"A loads\", A.value, 1)\n");
  const runner = join(FIX_TEST, "run-tests.mjs");

  const clean = await runRunner(runner, ["--loads", "src/A.lua"], FIX_TEST);
  row("B1 decoys and src/main.lua's own source() are not loader hits",
    clean.selected === 1 && !/cannot select safely/.test(clean.out), shown(clean));

  const plantLine = 3;
  for (const [name, code, loader] of PLANTS) {
    put("src/B.lua", "-- planted\nlocal x = 1\n" + code + "\n");
    const r = await runRunner(runner, ["--loads", "src/A.lua"], FIX_TEST);
    row(`${name} in another src/ file fails --loads and names it once`,
      r.code === 1 && count(r.out, `src/B.lua:${plantLine} ${loader}`) === 1, shown(r));
  }

  put("src/B.lua", "-- source\nlocal = 1\n");
  const broken = await runRunner(runner, ["--loads", "src/A.lua"], FIX_TEST);
  row("B11 a src/ file that does not parse fails --loads (it cannot be checked)",
    broken.code === 1 && /src\/B\.lua: does not parse/.test(broken.out), shown(broken));

  put("src/B.lua", "-- planted\nlocal x = 1\nsource(g_currentModDirectory .. \"src/A.lua\")\n");
  const plain = await runRunner(runner, [], FIX_TEST);
  row("B12 without --loads the check does not run (a plain run is as before)",
    plain.code === 0 && /PASS - 1 assertion passed, 0 failed across 1 file\./.test(plain.out), shown(plain));

  for (const [name, code, loader] of ENV_PLANTS) {
    put("src/B.lua", "-- planted\nlocal x = 1\n" + code + "\n");
    const r = await runRunner(runner, ["--loads", "src/A.lua"], FIX_TEST);
    row(`${name} in another src/ file fails --loads and names it once`,
      r.code === 1 && count(r.out, `src/B.lua:${plantLine} ${loader}`) === 1, shown(r));
  }
} finally {
  rmSync(FIX, { recursive: true, force: true });
}

console.log(`\n${fail === 0 ? "PASS" : "FAIL"} - ${pass} of ${pass + fail} rows passed.`);
process.exit(fail === 0 ? 0 : 1);

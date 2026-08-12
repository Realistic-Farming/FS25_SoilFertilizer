// Parse the exact files git is about to commit, with luaparse pinned to Lua 5.1.
//
// WHY NOT REUSE tools/test/syntax-check.mjs: its findLuaFiles() defaults to SRC_DIR,
// so it never sees main.lua at the repo root - the entry point of several mods in this
// suite. A gate that misses the entry file is worse than no gate, because it grants
// false confidence. This checks the STAGED set instead, which is by definition exactly
// what is shipping, wherever it lives in the tree.
//
// Lives in tools/test/ (not tools/git-hooks/) because node resolves bare imports from
// the SCRIPT's directory upward - from tools/git-hooks it never sees tools/test/node_modules.
// Usage: node check-staged.mjs <abs-path>...
import { readFileSync } from "node:fs";
import luaparse from "luaparse";

const files = process.argv.slice(2);
let bad = 0;
for (const f of files) {
  let code;
  try {
    code = readFileSync(f, "utf8");
  } catch {
    continue; // deleted or moved between staging and now; nothing to parse
  }

  // A UTF-8 BOM is caught by the parse below, but only as
  // "Cannot read properties of undefined (reading 'range')", which tells you
  // nothing. Name it explicitly instead. Lua does not skip a byte order mark
  // the way it skips a shebang, so U+FEFF is read as part of the first token.
  // Seven files across four repos hit this on 2026-08-05, all from an editor
  // saving as "UTF-8 with BOM".
  if (code.charCodeAt(0) === 0xfeff) {
    bad++;
    console.error(`  \u2717 ${f}`);
    console.error("      Starts with a UTF-8 BOM (EF BB BF). Lua 5.1 cannot parse it.");
    console.error("      Fix: re-save as UTF-8 WITHOUT BOM, or strip the 3 leading bytes.");
    continue;
  }

  try {
    luaparse.parse(code, { luaVersion: "5.1", comments: false, locations: true });
  } catch (e) {
    bad++;
    console.error(`  \u2717 ${f}\n      ${e.message}`);
  }
}
if (bad > 0) {
  console.error(`\n  ${bad} staged Lua file(s) will NOT compile in FS25. Commit blocked.`);
  console.error("  FS25 drops the whole file at load with no useful message, so this");
  console.error("  would ship as a silently missing feature. Fix, or --no-verify.");
  process.exit(1);
}
console.log(`  \u2713 Lua 5.1 syntax OK - ${files.length} staged file(s)`);

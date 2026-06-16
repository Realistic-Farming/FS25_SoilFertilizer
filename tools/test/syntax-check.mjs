// Lua 5.1 syntax checker for FS25_SoilFertilizer.
//
// FS25 runs Lua 5.1. A parse error (or a 5.2+-only construct like `goto`/`::label::`)
// makes the whole mod fail to load in-game with no useful message. This parses every
// src/**/*.lua with luaparse pinned to luaVersion "5.1", so those errors surface here
// in <1s instead of after a deploy + game restart.
//
// Usage:  node syntax-check.mjs
// Exit:   0 = all files parse, 1 = at least one parse error.
import { readFileSync } from "node:fs";
import luaparse from "luaparse";
import { findLuaFiles, rel, c } from "./lib.mjs";

const files = findLuaFiles();
let errors = 0;

for (const file of files) {
  const code = readFileSync(file, "utf8");
  try {
    luaparse.parse(code, {
      luaVersion: "5.1",
      comments: false,
      locations: true,
      ranges: false,
    });
  } catch (err) {
    errors++;
    // luaparse SyntaxError carries .line / .column / .index
    const line = err.line ?? "?";
    const col = (err.column ?? 0) + 1;
    const srcLine = (code.split("\n")[(err.line ?? 1) - 1] || "").replace(/\t/g, "  ");
    console.log(`${c.red("✗")} ${c.bold(rel(file))}:${line}:${col}`);
    console.log(`  ${c.red(err.message.replace(/\s*\[\d+:\d+\].*$/, ""))}`);
    if (srcLine.trim()) console.log(`  ${c.dim("| " + srcLine.trim())}`);
  }
}

const n = files.length;
if (errors === 0) {
  console.log(c.green(`✓ Lua 5.1 syntax OK — ${n} file${n === 1 ? "" : "s"} parsed.`));
  process.exit(0);
} else {
  console.log(c.red(`\n${errors} syntax error${errors === 1 ? "" : "s"} across ${n} files.`));
  process.exit(1);
}

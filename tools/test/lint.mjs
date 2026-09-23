// lint.mjs - FS25-specific footgun linter.
//
// Catches patterns that parse fine under Lua 5.1 but break (or silently no-op) inside
// the FS25 sandbox, per the "What DOESN'T Work" table in CLAUDE.md. Syntax-level issues
// (goto, ::labels::, bare `continue`) are already caught by syntax-check.mjs.
//
// Usage:  node lint.mjs
// Exit:   0 = clean, 1 = at least one error-severity finding.
import { readFileSync } from "node:fs";
import { findLuaFiles, rel, c } from "./lib.mjs";

// Strip Lua comments so we don't flag patterns that only appear in prose. Naive but
// adequate: removes --[[ block ]] comments and -- line comments. (Does not parse string
// literals, which is fine for the os.* patterns below.)
function stripComments(code) {
  return code
    .replace(/--\[\[[\s\S]*?\]\]/g, "")
    .replace(/--.*$/gm, "");
}

const RULES = [
  {
    name: "no-os-time",
    re: /\bos\.(time|date|clock)\s*\(/,
    severity: "error",
    msg: "os.time/os.date/os.clock are not available in the FS25 Lua sandbox - use g_currentMission.time or .environment.currentDay.",
  },
  {
    name: "no-goto",
    re: /\bgoto\b|::[A-Za-z_]\w*::/,
    severity: "error",
    msg: "goto/labels do not exist in Lua 5.1 (FS25). Use if/else or an early return.",
  },
  {
    // MAINTENANCE row 59: I18N.lua:186 returns "Missing '<key>' in l10n<suffix>.xml" for
    // an absent key, never nil, so an `or` after getText never fires and the player is
    // shown the engine's diagnostic. A hasText-gated ternary on the same line is fine.
    name: "l10n-dead-or-fallback",
    re: /getText\s*\([^()]*\)\s*\)*\s+or\s+(?!g?_?i18n[.:])/,
    unless: /hasText/,
    severity: "error",
    msg: "an `or` after getText never fires (I18N.lua:186 never returns nil). Use SoilL10n.tr(key, fallback).",
  },
];

// MAINTENANCE row 60: a file that tests a translation against the "$l10n_" attribute
// prefix (a string getText cannot return) must gate on hasText as well, or it gates
// on nothing. File-level, because the defended helpers keep the prefix test as a
// second line of defence AFTER hasText. The one allowed exception is the shared Esc
// door page, byte-matched across ten door mods and repaired as one ten-mod item.
const PREFIX_RULE = {
  name: "l10n-prefix-without-hastext",
  allow: ["src/ui/RfPdaMenuPage.lua"],
  msg: "compares against \"$l10n_\" without calling hasText anywhere in the file. hasText is the gate; the prefix test guards nothing on its own.",
};

const files = findLuaFiles();
let errors = 0,
  warnings = 0;

for (const file of files) {
  const code = stripComments(readFileSync(file, "utf8"));
  const lines = code.split("\n");
  lines.forEach((line, i) => {
    for (const rule of RULES) {
      if (rule.re.test(line) && !(rule.unless && rule.unless.test(line))) {
        const tag = rule.severity === "error" ? c.red("error") : c.yellow("warn ");
        if (rule.severity === "error") errors++;
        else warnings++;
        console.log(`${tag} ${c.bold(rel(file))}:${i + 1}  ${c.dim("[" + rule.name + "]")}`);
        console.log(`  ${rule.msg}`);
      }
    }
  });
  const relPath = rel(file).replace(/\\/g, "/");
  if (/\$l10n_/.test(code) && !/\bhasText\b/.test(code) && !PREFIX_RULE.allow.includes(relPath)) {
    errors++;
    console.log(`${c.red("error")} ${c.bold(rel(file))}  ${c.dim("[" + PREFIX_RULE.name + "]")}`);
    console.log(`  ${PREFIX_RULE.msg}`);
  }
}

const n = files.length;
if (errors === 0) {
  console.log(
    c.green(`✓ Lint clean - ${n} files`) +
      (warnings ? c.yellow(` (${warnings} warning${warnings === 1 ? "" : "s"})`) : "")
  );
  process.exit(0);
} else {
  console.log(c.red(`\n${errors} lint error${errors === 1 ? "" : "s"} across ${n} files.`));
  process.exit(1);
}

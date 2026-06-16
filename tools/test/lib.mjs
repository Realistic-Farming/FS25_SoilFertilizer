// Shared helpers for the FS25_SoilFertilizer test tooling.
import { readdirSync, statSync } from "node:fs";
import { join, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));

// Repo root is two levels up from tools/test/
export const REPO_ROOT = resolve(__dirname, "..", "..");
export const SRC_DIR = join(REPO_ROOT, "src");

/** Recursively collect every *.lua file under `dir`. */
export function findLuaFiles(dir = SRC_DIR) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...findLuaFiles(full));
    } else if (entry.endsWith(".lua")) {
      out.push(full);
    }
  }
  return out.sort();
}

/** Path relative to repo root, with forward slashes (clickable in terminals). */
export function rel(p) {
  return relative(REPO_ROOT, p).replace(/\\/g, "/");
}

// Minimal ANSI colour (skipped when not a TTY).
const useColor = process.stdout.isTTY;
const wrap = (code) => (s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : s);
export const c = {
  red: wrap("31"),
  green: wrap("32"),
  yellow: wrap("33"),
  cyan: wrap("36"),
  dim: wrap("2"),
  bold: wrap("1"),
};

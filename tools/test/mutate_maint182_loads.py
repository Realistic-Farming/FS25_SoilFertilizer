# MAINTENANCE row 182 battery (targeted, R-25): the --loads path normalization and the src/ loader
# check in tools/test/run-tests.mjs. The bar is loads-selection-bar.mjs.
#
# One mutant per changed rule, on the lines this change added. A mutant counts as KILLED only when
# the bar ran to its summary, exited non-zero, and every row the mutant targets is among its FAIL
# rows. Anything else is SURVIVED. Four mutants only change anything on Windows (case folding and
# backslash separators); elsewhere they are reported as not applicable.
#
# Each run asserts the edit LANDED (exact occurrence count), restores byte-for-byte and PROVES the
# restore with a hash.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits a file in place.
#
# Usage: py tools/test/mutate_maint182_loads.py
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
RUNNER = os.path.join(TEST_DIR, "run-tests.mjs")
WINDOWS = sys.platform == "win32"

# (id, old line(s), new line(s), rows that must fail, Windows only)
MUTANTS = [
    ("M1-no-case-fold",
     'const fold = process.platform === "win32" ? (s) => s.toLowerCase() : (s) => s;\n',
     'const fold = (s) => s;\n', ["A6"], True),
    ("M2-join-not-resolve",
     r'  const abs = resolve(REPO_ROOT, arg.replace(/\\/g, "/"));' + "\n",
     r'  const abs = join(REPO_ROOT, arg.replace(/\\/g, "/"));' + "\n", ["A4"], False),
    ("M3-no-outside-check",
     '  if (inRepo === ".." || inRepo.startsWith(".." + sep) || isAbsolute(inRepo)) {\n',
     '  if (false) {\n', ["A7", "A8"], False),
    ("M4-no-dotdot-prefix-check",
     '  if (inRepo === ".." || inRepo.startsWith(".." + sep) || isAbsolute(inRepo)) {\n',
     '  if (inRepo === ".." || isAbsolute(inRepo)) {\n', ["A7", "A8"], False),
    ("M5-no-isFile-check",
     '  if (!existsSync(abs) || !statSync(abs).isFile()) {\n',
     '  if (!existsSync(abs)) {\n', ["A9"], False),
    ("M6-keep-native-separators",
     '  loadsPaths.push(inRepo.split(sep).join("/"));\n',
     '  loadsPaths.push(inRepo);\n', ["A2"], True),
    ("M7-check-not-called",
     '  const loaderRefs = srcLoaderRefs();\n',
     '  const loaderRefs = [];\n', ["B2"], False),
    ("M8-check-hits-ignored",
     '  if (loaderRefs.length) {\n',
     '  if (false) {\n', ["B2"], False),
    ("M9-main-lua-not-exempt",
     '    if (where === "src/main.lua") continue;\n',
     '    if (where === "src/main.lua.x") continue;\n', ["A1", "B1"], False),
    ("M10-locals-count",
     '      if (node.type === "Identifier" && !node.isLocal\n',
     '      if (node.type === "Identifier"\n', ["A1", "B1"], False),
    ("M11-member-names-count",
     '          && !(parent?.type === "MemberExpression" && key === "identifier")\n',
     '', ["B1"], False),
    ("M12-table-keys-count",
     '          && !(parent?.type === "TableKeyString" && key === "key")) {\n',
     '          ) {\n', ["B1"], False),
    ("M13-no-G-member-rule",
     '      } else if (node.type === "MemberExpression" && isGlobalG(node.base)) {\n',
     '      } else if (false) {\n', ["B8"], False),
    ("M14-no-G-index-rule",
     '      } else if (node.type === "IndexExpression" && isGlobalG(node.base) && node.index.type === "StringLiteral") {\n',
     '      } else if (false) {\n', ["B9"], False),
    ("M15-no-rawget-rule",
     '      } else if (node.type === "CallExpression" && node.base.type === "Identifier" && node.base.name === "rawget"\n',
     '      } else if (false && node.base.name === "rawget"\n', ["B10"], False),
    ("M16-parse-failure-ignored",
     r'      hits.push(`${where}: does not parse as Lua 5.1 (${e.message}), so it cannot be checked`);' + "\n",
     '      // parse failure ignored\n', ["B11"], False),
    ("M17-prefilter-drops-require",
     r'const LOADER_WORD = /\b(source|loadfile|dofile|loadstring|require)\b/;' + "\n",
     r'const LOADER_WORD = /\b(source|loadfile|dofile|loadstring)\b/;' + "\n", ["B6"], False),
    ("M18-loaders-drop-source",
     'const LOADERS = new Set(["source", "loadfile", "dofile", "loadstring", "require"]);\n',
     'const LOADERS = new Set(["loadfile", "dofile", "loadstring", "require"]);\n', ["B2", "B8"], False),
    ("M19-string-text-null",
     '  return m ? (m[1] ?? m[2] ?? m[4]) : null;\n',
     '  return null;\n', ["B9", "B10"], False),
    ("M20-path-not-folded",
     '    return parseDeps(text).includes("src/main.lua") || loadsPaths.some((p) => text.includes(fold(p)));\n',
     '    return parseDeps(text).includes("src/main.lua") || loadsPaths.some((p) => text.includes(p));\n', ["A6"], True),
    ("M21-test-text-not-folded",
     '    const text = fold(readFileSync(join(LUA_DIR, tf), "utf8"));\n',
     '    const text = readFileSync(join(LUA_DIR, tf), "utf8");\n', ["A6"], True),
]

def sha(b): return hashlib.sha256(b).hexdigest()
def run_bar():
    r = subprocess.run(["node", "loads-selection-bar.mjs"], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    failed = re.findall(r"^\s+FAIL ([AB]\d+) ", out, re.M)
    summary = re.search(r"^(PASS|FAIL) - \d+ of \d+ rows passed\.$", out, re.M) is not None
    return r.returncode, failed, summary, out

rc, failed, summary, _ = run_bar()
if rc != 0 or failed or not summary:
    print("BASELINE IS NOT GREEN; fix that before trusting the battery.")
    sys.exit(2)
print("baseline green")

original = open(RUNNER, "rb").read()
crlf = b"\r\n" in original
enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")
killed = survived = bad = na = 0
for mid, old, new, want, win_only in MUTANTS:
    if win_only and not WINDOWS:
        na += 1
        print("  n/a      %s (changes nothing off Windows)" % mid)
        continue
    n = original.count(enc(old))
    if n != 1:
        bad += 1
        print("  !! %s: ANCHOR MISMATCH (%d != 1), mutation NOT applied" % (mid, n))
        continue
    line = original[:original.index(enc(old))].count(b"\n") + 1
    mutated = original.replace(enc(old), enc(new), 1)
    open(RUNNER, "wb").write(mutated)
    try:
        assert open(RUNNER, "rb").read() == mutated and mutated != original, "edit did not land"
        rc, failed, summary, out = run_bar()
    finally:
        open(RUNNER, "wb").write(original)
    if sha(open(RUNNER, "rb").read()) != sha(original):
        print("  !! RESTORE FAILED after %s" % mid)
        sys.exit(3)
    ok = rc != 0 and summary and all(w in failed for w in want)
    if ok:
        killed += 1
    else:
        survived += 1
    print("  %s %s  [run-tests.mjs:%d]  target %s, bar failed %s" % (
        "KILLED  " if ok else "SURVIVED", mid, line, "+".join(want), ",".join(failed) or "nothing"))
    if not summary:
        print("        the bar did not reach its summary:\n        " + out[-400:].replace("\n", "\n        "))

print("\n==== MUTATION RESULT ====")
print("killed   %d (each on an assertion in its target row)" % killed)
print("survived %d" % survived)
print("bad edit %d" % bad)
print("n/a      %d" % na)
print("all files restored byte-identical (hash-checked)")
sys.exit(0 if survived == 0 and bad == 0 else 1)

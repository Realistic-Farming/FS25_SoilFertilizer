# MAINTENANCE row 177 battery (targeted, R-25): the daily weed-read queue applies the
# pass's FieldSentry gate (src/SoilFertilitySystem.lua, _queueDailyWeedReads). The bar is
# groups M and Z of SF-1037-whole_field_weed_read_spec_test.lua.
#
# One mutant per changed line. Each runs under --loads src/SoilFertilitySystem.lua (Tyson's
# battery ruling, 2026-09-30); a survivor is re-run under the whole suite. A mutant counts
# as KILLED only when the run reached its summary, failed, and every row it targets in
# SF-1037 is among that file's FAIL lines. Anything else is SURVIVED.
#
# Each run asserts the edit LANDED (exact occurrence count), restores byte-for-byte and
# PROVES the restore with a hash.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits a production file in place.
#
# Usage: py tools/test/mutate_maint177_weed_meadow_gate.py [T2 T3 ...] [--skip-baseline] [--via <repo path>]
#   Name mutant ids to run only those (one per call keeps each run short on a busy
#   machine). --skip-baseline is for a rerun on a head whose baseline was already green.
#   --via src/FieldSentry.lua selects only the six tests that load the real FieldSentry,
#   the only ones where this gate can change anything (with FieldSentry absent it
#   behaves as before), for a machine short of memory. Under --via a survivor is reported,
#   not re-run on the whole suite; re-run it without --via when the machine has room.
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
TARGET = os.path.join(ROOT, "src", "SoilFertilitySystem.lua")
BAR = "SF-1037-whole_field_weed_read_spec_test.lua"

# (id, old line, new line, rows in the bar that must fail)
MUTANTS = [
    ("T1-meadow-not-in-condition",
     '        if field and not asleep and not meadow and not (cropLower and nonCrops[cropLower]) then\n',
     '        if field and not asleep and not (cropLower and nonCrops[cropLower]) then\n', ["M1", "M2"]),
    ("T2-meadow-never-set",
     '            meadow = isMeadow == true\n',
     '            meadow = false\n', ["M1", "M2"]),
    ("T3-meadow-from-the-reason",
     '            local disabled, _, isMeadow = FieldSentry_API.isFieldSimDisabled(fieldId)\n',
     '            local disabled, isMeadow = FieldSentry_API.isFieldSimDisabled(fieldId)\n', ["M1", "M2"]),
    ("T4-sleep-never-set",
     '            asleep = disabled == true\n',
     '            asleep = false\n', ["Z1", "Z2"]),
    ("T5-meadow-inverted",
     '            meadow = isMeadow == true\n',
     '            meadow = isMeadow ~= true\n', ["M1", "M2", "M4"]),
    ("T6-fieldsentry-never-asked",
     '        if FieldSentry_API ~= nil and type(FieldSentry_API.isFieldSimDisabled) == "function" then\n',
     '        if false then\n', ["M1", "M2", "Z1", "Z2"]),
]

VIA = "src/SoilFertilitySystem.lua"
if "--via" in sys.argv:
    i = sys.argv.index("--via")
    VIA = sys.argv[i + 1]
    del sys.argv[i:i + 2]

def sha(b): return hashlib.sha256(b).hexdigest()
def run(full):
    args = ["node", "run-tests.mjs"] + ([] if full else ["--loads", VIA])
    r = subprocess.run(args, cwd=TEST_DIR, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    lines = out.splitlines()
    summary = any(re.match(r"^(PASS|FAIL) - \d+ assertions? passed", l) for l in lines)
    bar_fails, in_bar = [], False
    for l in lines:
        if re.match(r"^\S+ \S+_test\.lua", l):
            in_bar = BAR in l
        elif in_bar and l.strip().startswith("FAIL "):
            m = re.match(r"\s*FAIL ([A-Z]\d+) ", l)
            if m:
                bar_fails.append(m.group(1))
    crashed = any(BAR in l and "Lua error" in l for l in lines)
    return r.returncode, summary, bar_fails, crashed

only = [a for a in sys.argv[1:] if not a.startswith("--")]
if only:
    unknown = [a for a in only if a not in [m[0].split("-")[0] for m in MUTANTS]]
    if unknown:
        print("unknown mutant id(s): %s" % ", ".join(unknown))
        sys.exit(2)
    MUTANTS = [m for m in MUTANTS if m[0].split("-")[0] in only]

if "--skip-baseline" in sys.argv:
    print("baseline skipped (--skip-baseline)")
else:
    rc, summary, bar_fails, crashed = run(False)
    if rc != 0 or not summary or bar_fails or crashed:
        print("BASELINE IS NOT GREEN under --loads; fix that before trusting the battery.")
        sys.exit(2)
    print("baseline green (--loads %s)" % VIA)

original = open(TARGET, "rb").read()
crlf = b"\r\n" in original
enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")
killed = survived = bad = 0
for mid, old, new, want in MUTANTS:
    n = original.count(enc(old))
    if n != 1:
        bad += 1
        print("  !! %s: ANCHOR MISMATCH (%d != 1), mutation NOT applied" % (mid, n))
        continue
    line = original[:original.index(enc(old))].count(b"\n") + 1
    mutated = original.replace(enc(old), enc(new), 1)
    open(TARGET, "wb").write(mutated)
    try:
        assert open(TARGET, "rb").read() == mutated and mutated != original, "edit did not land"
        rc, summary, bar_fails, crashed = run(False)
        ok = rc != 0 and summary and not crashed and all(w in bar_fails for w in want)
        how = "--loads " + VIA
        if not ok and VIA == "src/SoilFertilitySystem.lua":
            rc, summary, bar_fails, crashed = run(True)
            ok = rc != 0 and summary and not crashed and all(w in bar_fails for w in want)
            how = "whole suite"
    finally:
        open(TARGET, "wb").write(original)
    if sha(open(TARGET, "rb").read()) != sha(original):
        print("  !! RESTORE FAILED after %s" % mid)
        sys.exit(3)
    killed += 1 if ok else 0
    survived += 0 if ok else 1
    print("  %s %s  [SoilFertilitySystem.lua:%d]  target %s, bar failed %s (%s)%s" % (
        "KILLED  " if ok else "SURVIVED", mid, line, "+".join(want), ",".join(bar_fails) or "nothing", how,
        " (bar crashed)" if crashed else ""))

print("\n==== MUTATION RESULT ====")
print("killed   %d (each on an assertion in its target rows)" % killed)
print("survived %d" % survived)
print("bad edit %d" % bad)
print("all files restored byte-identical (hash-checked)")
sys.exit(0 if survived == 0 and bad == 0 else 1)

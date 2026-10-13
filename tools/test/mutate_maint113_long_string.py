# MAINTENANCE row 113 battery (row 87's, FertilizerDepot #80, ported): the runner's luaLongString level choice (tools/test/run-tests.mjs).
# The bar is MAINT-113-long_string_boundary_test.lua.
#
# One mutation: the loop reverted to the content alone. Its only observable is that the bar's
# program no longer compiles (the long string closes early), so the kill is a Lua LOAD error by
# construction. It counts as KILLED only when it is ATTRIBUTABLE: the load error is reported for
# MAINT-113-long_string_boundary_test.lua, its message is a syntax error, and no other file failed.
# Anything else is reported as a failure of the battery.
#
# Each run asserts the edit LANDED (exact occurrence count), restores byte-for-byte and PROVES the
# restore with a hash.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint113_long_string.py
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # the runner prints marks a cp1252 console cannot
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = os.path.join(ROOT, "tools", "test", "run-tests.mjs")
BAR = "MAINT-113-long_string_boundary_test.lua"
OLD = '  while ((text + "]").includes("]" + "=".repeat(level) + "]")) level += 1;\n'
NEW = '  while (text.includes("]" + "=".repeat(level) + "]")) level += 1;\n'

def sha(b): return hashlib.sha256(b).hexdigest()
def run():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    return r.returncode, out.splitlines()

rc, lines = run()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting the mutation.")
    sys.exit(2)
print("baseline green")

original = open(RUNNER, "rb").read()
crlf = b"\r\n" in original
enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")
n = original.count(enc(OLD))
if n != 1:
    print("  !! L1: ANCHOR MISMATCH (%d != 1), mutation NOT applied" % n)
    sys.exit(1)
mutated = original.replace(enc(OLD), enc(NEW), 1)
open(RUNNER, "wb").write(mutated)
try:
    assert open(RUNNER, "rb").read() == mutated and mutated != original, "edit did not land"
    rc, lines = run()
finally:
    open(RUNNER, "wb").write(original)
if sha(open(RUNNER, "rb").read()) != sha(original):
    print("  !! RESTORE FAILED")
    sys.exit(3)

crashed = [l.strip() for l in lines if "Lua error while loading/running" in l]
failed = [l.strip() for l in lines if l.strip().startswith("FAIL ") and "assertions passed" not in l]
idx = next((i for i, l in enumerate(lines) if BAR in l and "Lua error" in l), None)
msg = lines[idx + 1].strip() if idx is not None and idx + 1 < len(lines) else ""
attributable = (rc != 0 and len(crashed) == 1 and BAR in crashed[0] and not failed
                and ("unexpected symbol" in msg or "unfinished" in msg or "expected" in msg))
print("  %s L1-level-from-content-alone  [tools/test/run-tests.mjs]" % ("KILLED  " if attributable else "SURVIVED"))
print("        (the long string closes at the file's last bracket and the bar does not load)")
for l in crashed[:2]:
    print("        CRASH " + l[:160])
print("        " + msg[:160])
print("\n==== MUTATION RESULT ====")
print("killed   %d (attributable load error in %s only)" % (1 if attributable else 0, BAR))
print("survived %d" % (0 if attributable else 1))
print("bad edit 0")
print("all files restored byte-identical (hash-checked)")
sys.exit(0 if attributable else 1)

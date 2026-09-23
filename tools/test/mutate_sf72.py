# SoilFertilizer MAINTENANCE row 72 mutation battery: the positional pH sub-step bank
# keeps its remainders separate per cause, kind and domain in use (src/PositionalPH.lua)
# and on both save paths (src/PositionalPH.lua XML, src/SoilFertilitySystem.lua ledger).
# Rows live in SF-79-ph_bank_cause_kind_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the XML save's #cause/#kind attributes: unchanged by this item and already pinned
#     by the SF-79 persistence rows (a save that dropped them would fail C1 too);
#   - the amount's infinity checks in isValidPending: no caller can produce one (the
#     writer clamps), and a NaN row (B6) covers the "not a finite number" branch;
#   - the ledger site's guard on _phRestorePending being a function: PositionalPH.lua is
#     always sourced by main.lua, and a system without it has no bank to restore.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the machine test lock. A battery edits production files in
# place while it works.
#
# Usage: py tools/test/mutate_sf72.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

PH = "src/PositionalPH.lua"
SFS = "src/SoilFertilitySystem.lua"

MUTATIONS = [
 # ── the take ───────────────────────────────────────────────────────────────
 ("T1-take-ignores-cause", PH,
  [("        if p.domainKey == domainKey and p.cause == cause and p.kind == kind then",
    "        if p.domainKey == domainKey and p.kind == kind then", 1)],
  "another cause of the same kind takes the remainder (B1, B2)"),
 ("T2-take-ignores-kind", PH,
  [("        if p.domainKey == domainKey and p.cause == cause and p.kind == kind then",
    "        if p.domainKey == domainKey and p.cause == cause then", 1)],
  "a plow NORMALIZE remainder would ride a plow DELTA; with the callers' distinct causes it shows on the direct rows"),
 ("T3-take-ignores-domain", PH,
  [("        if p.domainKey == domainKey and p.cause == cause and p.kind == kind then",
    "        if p.cause == cause and p.kind == kind then", 1)],
  "another domain takes the remainder (B4)"),
 ("T4-take-by-domain-alone", PH,
  [("        if p.domainKey == domainKey and p.cause == cause and p.kind == kind then",
    "        if p.domainKey == domainKey then", 1)],
  "the defect itself: the rain takes the plow's magnitude and its step is cancelled (A2)"),
 ("T5-take-returns-the-kept", PH,
  [("    field._phPending = keep\n    return take\nend\n\n--- Restore", "    field._phPending = take\n    return keep\nend\n\n--- Restore", 1)],
  "the bank hands back everything else and keeps the match"),
 ("T6-apply-takes-without-cause-and-kind", PH,
  [("        local pending = self:_phTakePending(fieldId, domainKey, source, operation)",
    "        local pending = self:_phTakePending(fieldId, domainKey)", 1)],
  "the write never gets its own remainders back: the plow bank never crosses a step (A6)"),

 # ── the add ────────────────────────────────────────────────────────────────
 ("A1-add-banks-an-invalid-entry", PH,
  [("    if not PositionalPH.isValidPending(entry) then\n        -- Nothing can ever take such an entry back", "    if false then\n        -- Nothing can ever take such an entry back", 1)],
  "a cause-less remainder is banked and can never be taken (B6)"),
 ("A2-add-refuses-everything", PH,
  [("    if amount == 0 then return false end\n    field._phPending = field._phPending or {}", "    if true then return false end\n    field._phPending = field._phPending or {}", 1)],
  "nothing is ever banked (A1)"),
 ("A3-refusal-said-every-time", PH,
  [("        if not PositionalPH._pendingRefusedLogged and SoilLogger ~= nil", "        if SoilLogger ~= nil", 1)],
  "the refusal is logged per call (B7)"),

 # ── the validity rule ──────────────────────────────────────────────────────
 ("V1-cause-not-required", PH,
  [("    if type(p.cause) ~= 'string' or p.cause == '' then return false end\n", "", 1)],
  "an older save's cause-less remainder is kept (C4, D3)"),
 ("V2-kind-not-required", PH,
  [("    if p.kind ~= PositionalPH.OP_DELTA and p.kind ~= PositionalPH.OP_NORMALIZE then return false end\n", "", 1)],
  "a remainder with a cause but no kind is kept (C4, D3) and a SET kind is banked (B6)"),
 ("V3-domain-not-required", PH,
  [("    if type(p.domainKey) ~= 'string' then return false end\n", "", 1)],
  "a mirror entry with no domain is kept (D3)"),
 ("V4-nan-amount-accepted", PH,
  [("    if type(a) ~= 'number' or a ~= a or a == math.huge or a == -math.huge then return false end", "    if type(a) ~= 'number' then return false end", 1)],
  "a NaN remainder is banked (B6)"),

 # ── the two restores ───────────────────────────────────────────────────────
 ("R1-restore-keeps-everything", PH,
  [("        if PositionalPH.isValidPending(p) then\n            field._phPending[#field._phPending + 1] = {", "        if true then\n            field._phPending[#field._phPending + 1] = {", 1)],
  "the restore never drops (C4, D3)"),
 ("R2-drop-not-said", PH,
  [("    if dropped > 0 and SoilLogger ~= nil and type(SoilLogger.warning) == 'function' then", "    if false then", 1)],
  "a dropped remainder is silent (C5, D4)"),
 ("R3-xml-load-bypasses-the-restore", PH,
  [("    self:_phRestorePending(field.id or fieldKey, field, list, 'xml')", "    field._phPending = list", 1)],
  "the XML path keeps cause-less entries (C4)"),
 ("R4-ledger-restore-bypasses-the-rule", SFS,
  [("            if type(self._phRestorePending) == \"function\" then\n                self:_phRestorePending(fieldId, f, e.sf79PHPending, \"ledger\")\n            end",
    "            if type(e.sf79PHPending) == \"table\" then\n                for _, p in ipairs(e.sf79PHPending) do f._phPending[#f._phPending + 1] = p end\n            end", 1)],
  "the mirror restores everything as before (D3)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l or "error:" in l.lower() and "FAIL" not in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)

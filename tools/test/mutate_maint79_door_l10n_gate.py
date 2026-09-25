# MAINTENANCE row 79 battery: the shared Esc door page's tr (src/ui/RfPdaMenuPage.lua, byte-identical
# in all ten door mods; this repo carries the bench). Rows live in MAINT-79-door_l10n_gate_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# Each mutation restores the old probe or removes the new gate and must be KILLED by a named row.
# For each: assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. KILLED* means
# killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the Refined fork's probe (FS25_SoilFertilizer_Refined): no world loads that fork, so the
#     probe answers false either way; it is kept only for the probe order.
#   - the pcall around hasText: removing it raises inside the page, which surfaces as a Lua error
#     rather than a named row (C5 is the observable; a crash kill is unattributable).
#   - the five keyless belts elsewhere in the file (:345 and the rest): untouched by this PR.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint79_door_l10n_gate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

DOOR = "src/ui/RfPdaMenuPage.lua"

MUTATIONS = [
 ("G1-named-mod-read-through-dot-i18n", DOOR,
  [("        return probe(name)\n",
    "        local modEnv = g_modEnvironments and g_modEnvironments[name]\n        if modEnv == nil or modEnv.i18n == nil then return nil end\n        return probe(nil)\n", 1)],
  "the old probe: a named mod is asked through g_modEnvironments[name].i18n, which the engine never sets"),
 ("G2-no-hastext", DOOR,
  [("        local okHas, has = pcall(i18n.hasText, i18n, key, customEnv)\n        if not okHas or has ~= true then\n            return nil\n        end\n", "", 1)],
  "getText is trusted for a key no mod ships and the engine's Missing sentence is painted"),
 ("G3-missing-sniff-restored", DOOR,
  [("        if not ok or type(text) ~= \"string\" or text == \"\" then\n            return nil\n        end\n        return text\n",
    "        if not ok or type(text) ~= \"string\" or text == \"\" then\n            return nil\n        end\n        if text:lower():find(\"^missing\") then\n            return nil\n        end\n        return text\n", 1)],
  "a real text that begins 'Missing' is refused"),
 ("G4-soil-not-asked", DOOR,
  [("        or tryMod(\"FS25_SoilFertilizer\")\n", "", 1)],
  "the door never asks Soil, so a non-Soil host shows Soil's chrome in English"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
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

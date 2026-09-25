# MAINTENANCE row 137 mutation battery (targeted, a small logic change): the ground index's
# stamp and the availability overlay's save. The per-layer save result (src/maps/SoilValueMaps.lua),
# the stamp written after the layers (src/SoilFertilityManager.lua saveSoilData), the marker's
# generation in both states and the stamp reader (src/integrations/SoilMaterialDownBridge.lua), the
# trust check, the hold and the restore (src/ground/GroundConditionCoordinator.lua), the observers
# and the contributor (src/MaterialDown.lua). Rows live in MAINT-137-overlay_save_index_stamp_spec_test.lua;
# every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the reader's own guards (no savegame directory, no file): the S4 row reaches the no-marker
#   path; a directory-less mission is a pure client, where the coordinator never arms.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_maint137_overlay_stamp.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

VM = "src/maps/SoilValueMaps.lua"
SFM = "src/SoilFertilityManager.lua"
BR = "src/integrations/SoilMaterialDownBridge.lua"
GC = "src/ground/GroundConditionCoordinator.lua"
MD = "src/MaterialDown.lua"

MUTATIONS = [
 ("T1-stamp-without-the-layers", SFM,
  [("       and savedByKey.groundMembership and savedByKey[MaterialDown.LAYER_KEY] and savedByKey[MaterialWetness.LAYER_KEY] then\n",
    "       then\n", 1)],
  "the stamp is written even when a layer save failed"),
 ("T2-layer-failure-reported-as-saved", VM,
  [("            if ok then\n                saved = saved + 1\n                savedByKey[key] = true\n",
    "            savedByKey[key] = true\n            if ok then\n                saved = saved + 1\n", 1)],
  "a layer whose save threw is reported as saved"),
 ("G1-generation-not-compared", GC,
  [("            and marker.generation > 0 and stamp == marker.generation\n",
    "            and marker.generation > 0\n", 1)],
  "a stamp from another save is trusted"),
 ("G2-unavailable-marker-without-generation", BR,
  [("        SoilMaterialDownBridge.writeMarker(careerXml, backend, envelope.saveGeneration, \"UNAVAILABLE\")\n",
    "        SoilMaterialDownBridge.writeMarker(careerXml, backend, 0, \"UNAVAILABLE\")\n", 1)],
  "a save whose own file failed leaves no generation, so its layers' index is rebuilt at the next arm"),
 ("H1-hold-dropped", GC,
  [("    if self.overlayPending then return true end\n", "", 1)],
  "until the store decides, cells read available from the empty overlay"),
 ("O1-restored-without-modern", GC,
  [("    if MaterialDown ~= nil and state == MaterialDown.LOAD.MODERN and type(payload) == \"table\"\n",
    "    if MaterialDown ~= nil and type(payload) == \"table\"\n", 1)],
  "a legacy save's overlay is restored though nothing paired it"),
 ("O2-restore-replaces", GC,
  [("    -- [MAINTENANCE row 137] MERGED over the live overlay, never replacing it: a cell marked\n",
    "    self.unavailable = {}\n    self.unavailableCount = 0\n    -- [MAINTENANCE row 137] MERGED over the live overlay, never replacing it: a cell marked\n", 1)],
  "a restore wipes the cells marked while the hold lasted"),
 ("C1-overlay-not-saved", GC,
  [("        materialDown:addEnvelopeContributor(\"groundAvailability\", function() return self:serialize() end)\n", "", 1)],
  "the overlay is never put in the envelope"),
 ("M1-coordinator-trigger-dropped", GC,
  [("    if md ~= nil and type(md.finishLoad) == \"function\" then\n        pcall(md.finishLoad, md)\n    end\n", "", 1)],
  "the coordinator waits on the yard ladder to decide the store: with no armed ladder the hold never ends"),
 ("C2-contributors-ignored", MD,
  [("    for name, part in pairs(parts) do\n        if envelope[name] == nil then envelope[name] = part end\n    end\n", "", 1)],
  "the envelope drops every contributor's table"),
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
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)

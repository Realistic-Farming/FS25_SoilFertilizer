# MAINTENANCE row 172 battery (the R8 residual): the later-vehicle routes on one
# VehicleSystem.addVehicle class wrap, each site's teardown, and the copied instance-function
# teardown (src/hooks/HookManager.lua). The bar is MAINT-172-vehicle_routes_entry_spec_test.lua;
# the two gate mutants are killed by RSF-F226-R8-permanent_gate_entry_spec_test.lua.
#
# TARGETED ONLY (Tyson's ruling, 2026-09-30): each mutant runs against the test files that
# load the code it changes, never the whole suite. The default selection is
# --loads tools/test/lua/RSF-F211-s6b-baler_model.lua: the three bars built on the baler
# world (the MAINT-172 bar, F211 s6b and F215 s7), which load HookManager.lua whole. The gate
# mutants need R8's bar, which names no file the others do not, so they select
# --loads src/hooks/HookManager.lua.
#
# A mutant counts as KILLED only when the run reached its summary, failed, and every row it
# targets is among the FAIL lines of its bar. Anything else is SURVIVED. Each run asserts the
# edit LANDED (exact occurrence count), restores byte-for-byte and PROVES the restore with a
# hash.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits a production file in place.
#
# Usage: py tools/test/mutate_maint172_vehicle_routes.py [ids ...] [--skip-baseline] [--check]
#   --check only counts every anchor and runs nothing.
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
TARGET = os.path.join(ROOT, "src", "hooks", "HookManager.lua")
BAR = "MAINT-172-vehicle_routes_entry_spec_test.lua"
R8 = "RSF-F226-R8-permanent_gate_entry_spec_test.lua"
SMALL = "tools/test/lua/RSF-F211-s6b-baler_model.lua"
WHOLE_FILE = "src/hooks/HookManager.lua"

def teardown_line(fn):
    return '    self:registerSiteTeardown(SITE, route, activated, "%s")\n' % fn

# (id, [(old, new)], bar file, rows that must fail, selection)
MUTANTS = [
    ("W1-instance-writer-back",
     [("    local route = self:addVehicleRoute(SITE, tedderVehicle)\n",
       "    local route = nil\n"
       "    if vs and type(vs.addVehicle) == \"function\" then\n"
       "        local origAdd = vs.addVehicle\n"
       "        vs.addVehicle = function(s, vehicle, ...) tedderVehicle(vehicle) return origAdd(s, vehicle, ...) end\n"
       "    end\n")],
     BAR, ["E2", "R1"], SMALL),
    ("W2-routes-on-any-result",
     [("        if addRecord.active and results[1] == true then\n", "        if addRecord.active then\n")],
     BAR, ["R1"], SMALL),
    ("W3-route-throw-not-isolated",
     [("                    local ok, err = pcall(route.fn, vehicle)\n",
       "                    local ok, err = true, route.fn(vehicle)\n")],
     BAR, ["T1", "T2"], SMALL),
    ("W4-add-drops-return",
     [("        return unpack(results, 1, results.n)\n", "        return nil\n")],
     BAR, ["E4", "R1"], SMALL),
    ("W5-wrap-needs-sprayer",
     [("    self._vehicleRoutes = nil\n", "    self._vehicleRoutes = nil\n    if Sprayer == nil then return false end\n")],
     BAR, ["E3", "E4"], SMALL),
    ("W6-wrap-left-active",
     [("        addRecord.active = false\n", "")],
     BAR, ["C2"], SMALL),
    ("W7-class-restore-unconditional",
     [("        if VehicleSystem.addVehicle == ourAdd then\n", "        if true then\n")],
     BAR, ["C1"], SMALL),
    ("S1-tedder-no-route",
     [("    local route = self:addVehicleRoute(SITE, tedderVehicle)\n", "    local route = nil\n")],
     BAR, ["E3", "E4"], SMALL),
    ("S2-mower-no-route",
     [("    local route = self:addVehicleRoute(SITE, function(vehicle)\n        wrapCut(vehicle)\n        wrapDrop(vehicle)\n    end)\n",
       "    local route = nil\n")],
     BAR, ["E3", "E4", "E5"], SMALL),
    ("S3-baler-no-route",
     [("    local route = self:addVehicleRoute(SITE, wrapBaler)\n", "    local route = nil\n")],
     BAR, ["E3", "E4", "E6"], SMALL),
    ("S5-windrower-no-route",
     [("    local route = self:addVehicleRoute(SITE, windrowerVehicle)\n", "    local route = nil\n")],
     BAR, ["E3", "E4"], SMALL),
    ("S6-swath-no-route",
     [("    local route = self:addVehicleRoute(SITE, swathVehicle)\n", "    local route = nil\n")],
     BAR, ["E3", "E4"], SMALL),
    ("S7-wagon-no-route",
     [("    local route = self:addVehicleRoute(SITE, wrapWagon)\n", "    local route = nil\n")],
     BAR, ["E3", "E4", "E7"], SMALL),
    ("S4-mower-route-drops-the-drop",
     [("        wrapCut(vehicle)\n        wrapDrop(vehicle)\n", "        wrapCut(vehicle)\n")],
     BAR, ["E5"], SMALL),
    ("D1-tedder-no-teardown", [(teardown_line("processTedderArea"), "")], BAR, ["D1"], SMALL),
    ("D2-windrower-no-teardown", [(teardown_line("processWindrowerArea"), "")], BAR, ["D2"], SMALL),
    ("D3-swath-no-teardown", [(teardown_line("processCombineSwathArea"), "")], BAR, ["D1"], SMALL),
    ("D4-mower-no-teardown",
     [("    self:registerSiteTeardown(SITE, route, activated, \"processMowerArea\", function()\n",
       "    local noTeardown = (function() end)(SITE, route, activated, \"processMowerArea\", function()\n")],
     BAR, ["D1", "D4"], SMALL),
    ("D5-baler-no-teardown",
     [("    self:registerSiteTeardown(SITE, route, activated, \"processBalerArea\", function()\n",
       "    local noTeardown = (function() end)(SITE, route, activated, \"processBalerArea\", function()\n")],
     BAR, ["D1", "D6"], SMALL),
    ("D6-wagon-no-teardown",
     [("    self:registerSiteTeardown(SITE, route, activated, \"processForageWagonArea\", function()\n",
       "    local noTeardown = (function() end)(SITE, route, activated, \"processForageWagonArea\", function()\n")],
     BAR, ["D1", "D5"], SMALL),
    ("D7-slot-restore-unconditional",
     [("    for workArea in pairs(activated) do\n        local result = HookManager.releaseWorkAreaSlot(workArea, functionName)\n",
       "    for workArea in pairs(activated) do\n"
       "        local rec = HookManager.workAreaRecord(workArea, functionName)\n"
       "        if rec then workArea.processingFunction = rec.predecessor HookManager.workAreaRecords[workArea][functionName] = nil end\n"
       "        local result = rec and \"restored\" or nil\n")],
     BAR, ["D2"], SMALL),
    ("D8-route-left-active",
     [("        if route ~= nil then route.active = false end\n", "")],
     BAR, ["K2"], SMALL),
    ("D9-no-pass-through-when-inactive",
     [("            if not record.active then return predecessor(...) end\n", "")],
     BAR, ["D3"], SMALL),
    ("I1-instance-restore-unconditional",
     [("        if rawget(vehicle, name) == w.wrapper then\n", "        if true then\n")],
     BAR, ["D6"], SMALL),
    ("I2-instance-rewrapped-under-foreign",
     [("    if wraps ~= nil and wraps[name] ~= nil then return false end\n", "")],
     BAR, ["D13"], SMALL),
    ("I3-instance-record-kept-after-restore",
     [("    if next(wraps) == nil then rawset(vehicle, markerKey, nil) end\n", "")],
     BAR, ["D4", "D5"], SMALL),
    ("I4-restored-entry-kept",
     [("            wraps[name] = nil\n            restored = restored + 1\n", "            restored = restored + 1\n")],
     BAR, ["D6", "D13"], SMALL),
    ("G1-gate-no-route",
     [("    local route = self:addVehicleRoute(SITE, gateVehicle)\n", "    local route = nil\n")],
     R8, ["E3"], WHOLE_FILE),
    ("G2-gate-no-teardown",
     [(teardown_line("processSprayerArea"), "")],
     R8, ["I15", "I16"], WHOLE_FILE),
]

def sha(b): return hashlib.sha256(b).hexdigest()
def run(selection):
    r = subprocess.run(["node", "run-tests.mjs", "--loads", selection], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    lines = out.splitlines()
    summary = any(re.match(r"^(PASS|FAIL) - \d+ assertions? passed", l) for l in lines)
    fails, current = {}, None
    for l in lines:
        m = re.match(r"^\S+ (\S+_test\.lua)", l)
        if m:
            current = m.group(1)
            if "Lua error" in l:
                fails.setdefault(current, []).append("CRASH")
        elif current and l.strip().startswith("FAIL "):
            m2 = re.match(r"\s*FAIL ([A-Z]+\d*[a-z]?)\b", l)
            if m2:
                fails.setdefault(current, []).append(m2.group(1))
    return r.returncode, summary, fails

original = open(TARGET, "rb").read()
crlf = b"\r\n" in original
enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

args = [a for a in sys.argv[1:] if not a.startswith("--")]
todo = [m for m in MUTANTS if not args or any(m[0].startswith(a) for a in args)]

if "--check" in sys.argv:
    bad = 0
    for mid, edits, _, _, _ in todo:
        for old, _ in edits:
            n = original.count(enc(old))
            if n != 1:
                bad += 1
                print("  !! %s: anchor matched %d times" % (mid, n))
    print("%d mutants, %d anchor(s) off" % (len(todo), bad))
    sys.exit(1 if bad else 0)

if "--skip-baseline" in sys.argv:
    print("baseline skipped (--skip-baseline)")
else:
    for sel in sorted(set(m[4] for m in todo)):
        rc, summary, fails = run(sel)
        if rc != 0 or not summary or fails:
            print("BASELINE IS NOT GREEN under --loads %s; fix that before trusting the battery." % sel)
            sys.exit(2)
        print("baseline green (--loads %s)" % sel)

killed = survived = bad = 0
for mid, edits, bar, want, sel in todo:
    mutated, ok = original, True
    for old, new in edits:
        if mutated.count(enc(old)) != 1:
            ok = False
            break
        mutated = mutated.replace(enc(old), enc(new), 1)
    if not ok:
        bad += 1
        print("  !! %s: ANCHOR MISMATCH, mutation NOT applied" % mid)
        continue
    open(TARGET, "wb").write(mutated)
    try:
        assert open(TARGET, "rb").read() == mutated and mutated != original, "edit did not land"
        rc, summary, fails = run(sel)
    finally:
        open(TARGET, "wb").write(original)
    if sha(open(TARGET, "rb").read()) != sha(original):
        print("  !! RESTORE FAILED after %s" % mid)
        sys.exit(3)
    got = fails.get(bar, [])
    hit = rc != 0 and summary and all(w in got for w in want)
    killed += 1 if hit else 0
    survived += 0 if hit else 1
    print("  %s %s  target %s in %s, it failed %s%s" % (
        "KILLED  " if hit else "SURVIVED", mid, "+".join(want), bar.split("_")[0],
        ",".join(sorted(set(got))) or "nothing", "" if summary else " (no summary)"))

print("\n==== MUTATION RESULT ====")
print("killed   %d (each on assertions in its target rows)" % killed)
print("survived %d" % survived)
print("bad edit %d" % bad)
print("all files restored byte-identical (hash-checked)")
sys.exit(0 if survived == 0 and bad == 0 else 1)

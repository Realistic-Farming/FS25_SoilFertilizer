# SoilFertilizer RSF-F190 own-farm barn-warning privacy mutation battery (Implementation brief v1.0 over #1054):
# src/DogEarlyWarning.lua's presentation context, its farm-change subscriber, the barn bindings, the barn notifier,
# the getter and the scan's crop-walk commit, and src/main.lua's release at unload. Rows live in
# RSF-F190-barn_privacy_spec_test.lua, beside RSF-F190-livestock_warning_reader_test.lua and
# RSF-F192-dog_warning_l10n_test.lua.
#
# The repair is an RSF repair, so every changed line is mutated; on Tyson's small-runs rule (2026-09-30) each mutant
# runs through `node run-tests.mjs --loads src/DogEarlyWarning.lua` (3 files: the three benches above, which are
# every bench that loads the dog). The main.lua mutant uses the same selection: the privacy bar reads main.lua's
# release site from its text. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - onPlayerFarmChanged's `player ~= g_localPlayer` test: the refresh it guards reads g_localPlayer itself and
#     is idempotent, so another player's publish refreshes nothing either way (T6 pins the outcome);
#   - the barn branch's own hasDogOnFarm test in _notify: scan, its only caller, returns before _notify on a farm
#     with no dog (D4 pins that path; T9 calls the notifier directly with a dog);
#   - subscribe's and delete's guards on a missing g_messageCenter, MessageType or method: the bench has them all,
#     and their absence is the existing benches' world, where the dog builds without subscribing;
#   - presentationContext's inline ordinary-farm fallback for a tree without SpatialScouting: Soil always loads it;
#   - _barnStillOwned's flag fallback for a placeable without getIsBeingDeleted: the engine's Placeable has it;
#   - the crop branch, kept as it was (its keys, its HUD loop, its formatter), and the comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_f190_privacy.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_f190_privacy.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_f190_privacy.py --baseline the selected benches, unmutated
#        py tools/test/mutate_f190_privacy.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

DOG = "src/DogEarlyWarning.lua"
MAIN = "src/main.lua"
SELECT = ["--loads", "src/DogEarlyWarning.lua"]

MUTATIONS = [
 ("F01-any-farm-is-ordinary", DOG,
  [("    if not ordinary then return nil, nil end\n", "", 1)],
  "a spectator or non-ordinary farm gets a presentation context (T2b)"),
 ("F02-default-farm-one", DOG,
  [("    if type(actor) ~= \"table\" then return nil, nil end\n",
    "    if type(actor) ~= \"table\" then actor = { farmId = 1 } end\n", 1)],
  "a machine with no local player presents farm 1 (T1)"),
 ("F03-no-clear-on-change", DOG,
  [("    if ctx ~= nil then self:_clearLivestock(ctx.farmId) end\n    if farmId ~= nil then self:_clearLivestock(farmId) end\n", "", 1)],
  "a context change keeps the old context's barn rows and keys (T5b, M5)"),
 ("F04-context-never-set", DOG,
  [("    self.ctx = actor ~= nil and { actor = actor, farmId = farmId } or nil\n", "", 1)],
  "the presentation context is never established (E3, D1)"),
 ("F05-refresh-not-idempotent", DOG,
  [("    if ctx ~= nil and ctx.actor == actor and ctx.farmId == farmId then return false end\n", "", 1)],
  "every refresh clears, so a second publish of one switch clears again (E4)"),
 ("F06-not-subscribed", DOG,
  [("    self.subscribed = false\n    self:subscribe()\n    return self\n", "    self.subscribed = false\n    return self\n", 1)],
  "the dog never subscribes to PLAYER_FARM_CHANGED (E0c)"),
 ("F07-delete-keeps-subscriber", DOG,
  [("        g_messageCenter:unsubscribe(MessageType.PLAYER_FARM_CHANGED, self, DogEarlyWarning.onPlayerFarmChanged)\n", "", 1)],
  "the subscriber outlives the mission (T8)"),
 ("F08-delete-keeps-rows", DOG,
  [("    self.subscribed = false\n    self.warnings = {}\n", "    self.subscribed = false\n", 1)],
  "the rows and their bindings outlive the mission (T8)"),
 ("F09-no-binding-needed", DOG,
  [("    if p == nil then return false end\n", "    if p == nil then return true end\n", 1)],
  "a row with no binding (a display id alone) is authorized (T9)"),
 ("F10-no-roster-check", DOG,
  [("        if not inRoster then return false end\n", "", 1)],
  "a barn removed from the roster is still returned (D6)"),
 ("F11-no-deletion-check", DOG,
  [("            if p:getIsBeingDeleted() then return false end\n", "", 1)],
  "a barn pending deletion is still returned (D6)"),
 ("F12-no-owner-check", DOG,
  [("        return p:getOwnerFarmId() == farmId\n", "        return true\n", 1)],
  "a transferred barn is still returned and still holds the shared key (D6, M3)"),
 ("F13-no-husbandry-check", DOG,
  [("        if p.spec_husbandryAnimals == nil then return false end\n        local ps = g_currentMission and g_currentMission.placeableSystem\n        if ps == nil or type(ps.placeables) ~= \"table\" then return false end\n        local inRoster",
    "        local ps = g_currentMission and g_currentMission.placeableSystem\n        if ps == nil or type(ps.placeables) ~= \"table\" then return false end\n        local inRoster", 1)],
  "a binding that is not a husbandry passes (T9b)"),
 ("F14-crop-membership-not-checked", DOG,
  [("            keep = self:_cropStillOwned(r, ctxFarm)\n", "            keep = true\n", 1)],
  "a field transferred between scans is still returned (M4)"),
 ("F15-getter-aliases", DOG,
  [("        if keep then out[#out + 1] = { fieldId = r.fieldId, type = r.type } end\n", "        if keep then out[#out + 1] = r end\n", 1)],
  "the getter returns the cached rows themselves, binding and all (D1)"),
 ("F16-getter-any-farm", DOG,
  [("ctx.farmId ~= ctxFarm or farmId ~= ctxFarm then\n", "ctx.farmId ~= ctxFarm then\n", 1)],
  "the getter answers a farm other than the context's (E2b)"),
 ("F17-getter-stale-context", DOG,
  [("    if actor == nil or ctx == nil or ctx.actor ~= actor or ctx.farmId ~= ctxFarm or farmId ~= ctxFarm then\n",
    "    if actor == nil or ctx == nil or farmId ~= ctx.farmId then\n", 1)],
  "the getter serves a context the update has not caught up with (T5)"),
 ("F18-getter-no-live-dog", DOG,
  [("    if not self:hasDogOnFarm(ctxFarm) then return out end\n    for _, r in ipairs(self.warnings[ctxFarm] or {}) do\n",
    "    for _, r in ipairs(self.warnings[ctxFarm] or {}) do\n", 1)],
  "the getter trusts the cached dog (D4b)"),
 ("F19-dog-loss-keeps-keys", DOG,
  [("        self:_clearLivestock(farmId)\n        self.warnings[farmId] = nil\n        return\n",
    "        self.warnings[farmId] = nil\n        return\n", 1)],
  "dog loss keeps the barn key, so the regained dog stays silent (D4)"),
 ("F20-partial-walk-commits", DOG,
  [("    cropComplete = okWalk and cropRows ~= nil\n", "    cropComplete = true\n    cropRows = cropRows or {}\n", 1)],
  "a crop walk that fails part-way is committed as complete (M1)"),
 ("F21-nil-fields-skip-barns", DOG,
  [("    cropComplete = okWalk and cropRows ~= nil\n", "    cropComplete = okWalk and cropRows ~= nil\n    if cropRows == nil and okWalk then return end\n", 1)],
  "a nil field list returns before the barn walk again (D5)"),
 ("F22-client-walks-every-farm", DOG,
  [("    local walkBarns = g_server ~= nil or farmId == ctxFarm\n", "    local walkBarns = true\n", 1)],
  "a pure client walks other farms' barns (T3)"),
 ("F23-key-before-hud", DOG,
  [("        if not notified[key] then\n            local msg = DogEarlyWarning.formatWarning(DogEarlyWarning.BARN_WARNING_KEY,\n",
    "        if not notified[key] then\n            notified[key] = true\n            local msg = DogEarlyWarning.formatWarning(DogEarlyWarning.BARN_WARNING_KEY,\n", 1)],
  "a barn key is marked before the HUD call, so a missing or throwing HUD consumes it (D2, D3)"),
 ("F24-ack-on-throw", DOG,
  [("                if ok then notified[key] = true end\n", "                notified[key] = true\n", 1)],
  "a throwing HUD acknowledges the key (D3)"),
 ("F25-any-farm-toasts", DOG,
  [("    if ctxFarm ~= nil and farmId == ctxFarm and self:hasDogOnFarm(farmId) then\n",
    "    if self:hasDogOnFarm(farmId) then\n", 1)],
  "every scanned farm's barn reaches this machine's HUD (E1)"),
 ("F26-barn-prune-hits-crop", DOG,
  [("        if key:sub(-5) ~= \"_crop\" and not active[key] then\n", "        if not active[key] then\n", 1)],
  "the barn prune deletes crop keys (M0, M1)"),
 ("F27-crop-prune-when-incomplete", DOG,
  [("    if cropComplete then\n        for _, w in ipairs(flagged) do\n            if w.type == \"crop\" then\n                local key",
    "    if true then\n        for _, w in ipairs(flagged) do\n            if w.type == \"crop\" then\n                local key", 1)],
  "an unavailable crop walk runs the crop notifier and prune (M6)"),
 ("F28-clear-takes-crop", DOG,
  [("            if r.type == \"crop\" then kept[#kept + 1] = r end\n        end\n        self.warnings[farmId] = #kept > 0 and kept or nil\n",
    "        end\n        self.warnings[farmId] = #kept > 0 and kept or nil\n", 1)],
  "a context or dog clear drops crop rows too (M5)"),
 ("F29-clear-takes-crop-keys", DOG,
  [("            if key:sub(-5) ~= \"_crop\" then notified[key] = nil end\n", "            notified[key] = nil\n", 1)],
  "a context or dog clear drops crop keys too (M5)"),
 ("F30-check-after-cadence", DOG,
  [("    self:_refreshContext()\n    self.lastScan = self.lastScan + dt\n    if self.lastScan < DogEarlyWarning.CADENCE_MS then return end\n",
    "    self.lastScan = self.lastScan + dt\n    if self.lastScan < DogEarlyWarning.CADENCE_MS then return end\n    self:_refreshContext()\n", 1)],
  "the update-time context check waits for the cadence (T5b)"),
 ("F31-no-release-at-unload", MAIN,
  [("    if dogWarning ~= nil and dogWarning.delete ~= nil then pcall(dogWarning.delete, dogWarning) end\n", "", 1)],
  "main.lua's unload drops the dog without releasing it (T7, T8)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o, n = old.encode("utf-8"), new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_bench():
    r = subprocess.run(["node", "run-tests.mjs"] + SELECT, cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL ") or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:32s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, _, out = run_bench()
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.strip().splitlines()]
        print(lines[-1] if lines else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertionFails = [f for f in fails if "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:3]: print("    " + f[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

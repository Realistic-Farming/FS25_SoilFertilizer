-- SF-79-ph_auto_whole_rate_test.lua: the pH AUTO whole-rate, three defects.
--
-- DEFECT 1. updatePHWorkAuto read workAreaParameters.sprayFillType and tested
-- fillType.name on it. That field is a fill-type INDEX (Sprayer.lua:926 assigns it
-- from externalFillType; :316 and :922 compare it to FillType.UNKNOWN). Indexing a
-- number raised inside the caller's pcall, whose assignment happens only on
-- success, so the factor stayed at its initialised 1.0 on every path. AUTO had
-- never changed a rate.
--
-- DEFECT 2, invisible until the first is fixed. The only coordinate the read had
-- was _lastSprayX/Z, written by the AREA hook, which runs AFTER this start hook in
-- the same tick: the previous tick's point, or nil on the first. SF-79 section D:
-- "use current nodes/section state, never the previous interval's". The engine
-- hands the function the CURRENT work-area list (WorkArea.lua:126) and the caller
-- passes it through; the function ignored it.
--
-- DEFECT 3, in the CALLER, found by group F. HookManager's rate-multiplier append
-- passed spec.workArea and spec.workArea.workAreas with spec being spec_sprayer,
-- and the engine's sprayer spec has no workArea member (the list lives on
-- spec_workArea, WorkArea.lua:74), so AUTO received nil on every real vehicle and
-- would have retained 1.0 with defects 1 and 2 fixed. The append now takes the list
-- the engine raises the start event with, falling back to the vehicle's own.
--
-- Each row is tagged with what it defends: [D1 the index], [D2 the coordinate],
-- [D3 the caller], or a clause kept unchanged.
--
-- WHAT THIS BAR PROVES, and how. The engine boundary, getWorldTranslation, is a
-- node-to-coordinate map here, because a bench has no scene graph. What the rows
-- pin is WHERE THE INPUT COMES FROM: the coordinate is derived from the nodes of
-- the work areas PASSED AS THE ARGUMENT, and from nothing else. Group B plants the
-- stale point over different ground from the areas, removes it entirely, hands the
-- sprayer's own list different ground from the argument, and skips auxiliary and
-- inactive areas, so a fix that reached for any other source fails a named row.
-- Group F drives the REAL rate-multiplier append and proves the factor is applied
-- to the dose exactly once.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua

local saved = { gwt = getWorldTranslation, WorkAreaType = WorkAreaType, FillType = FillType, Utils = Utils, Sprayer = Sprayer,
                g_server = g_server, g_fillTypeManager = g_fillTypeManager, g_SoilFertilityManager = g_SoilFertilityManager,
                time = g_currentMission.time }

local L = SoilConstants.NUTRIENT_LIMITS
local PF = SoilConstants.FERTILIZER_PROFILES

-- ── the engine boundary: nodes to coordinates, and the map: coordinates to pH ──
local NODES = {}
local function node(id, x, z) NODES[id] = { x = x, z = z }; return id end
getWorldTranslation = function(n) local p = NODES[n]; if p == nil then error("no such node " .. tostring(n)) end return p.x, 0, p.z end
WorkAreaType = WorkAreaType or { SPRAYER = 5, AUXILIARY = 9 }
FillType = FillType or { UNKNOWN = 0 }

-- Ground: x < 50 is ACID (5.5), 50..150 is IN-BAND (6.8), x > 150 is ALKALINE (7.3),
-- x < 0 is UNRECORDED (nil).
local function phAt(x, z)
  if x < 0 then return nil end
  if x < 50 then return 5.5 end
  if x <= 150 then return 6.8 end
  return 7.3
end
-- A work area over x: its width/height nodes straddle (x, 20) so the centre is (x, 20).
local nextNode = 100
local function area(x, opts)
  opts = opts or {}
  nextNode = nextNode + 3
  return { type = opts.aux and WorkAreaType.AUXILIARY or WorkAreaType.SPRAYER, active = opts.active,
           start = node(nextNode, x - 5, 10), width = node(nextNode + 1, x + 5, 10), height = node(nextNode + 2, x - 5, 30) }
end
local ACID, BAND, ALK, UNREC = 10, 100, 200, -10

local FT = { LIME = 30, GYPSUM = 31, UREA = 32, LIQUIDLIME = 33 }
g_fillTypeManager = { getFillTypeByIndex = function(_, i)
  for name, idx in pairs(FT) do if idx == i then return { name = name, index = i } end end
  return nil
end }
local autoOn = {}
g_SoilFertilityManager = { sprayerRateManager = {
  getAutoMode = function(_, id) return autoOn[id] == true end,
  getMultiplier = function() return 1.0 end,
} }
g_server = true

local function newSys(opts)
  opts = opts or {}
  local s = setmetatable({
    settings = { enabled = opts.enabled ~= false },
    valueMaps = { available = true, readValueAtWorld = function(_, layer, x, z) return phAt(x, z) end },
    _lastSprayX = opts.staleX, _lastSprayZ = opts.staleX and 20 or nil,
  }, { __index = SoilFertilitySystem })
  return s
end
local function newSprayer(id, ftIdx, ownAreas)
  return { id = id, isServer = true,
           spec_sprayer = { workAreaParameters = { sprayFillType = ftIdx } },
           spec_workArea = { workAreas = ownAreas or {} },
           getIsWorkAreaActive = function(_, wa) return wa.active ~= false end }
end
local function factor(s, sprayer, areas) return s:updatePHWorkAuto(sprayer, 16, areas) end
local function boost(ph) return 1.0 + math.min(0.5, (L.PH_NEUTRAL_LOW - ph) / math.max(0.001, L.PH_NEUTRAL_LOW - L.PH_MIN)) end
local function gypsumBoost(ph) return 1.0 + math.min(0.5, (ph - L.PH_NEUTRAL_HIGH) / math.max(0.001, L.PH_MAX - L.PH_NEUTRAL_HIGH)) end

g_currentMission.time = 100000
autoOn[7] = true

-- =====================================================================
-- GROUP A: defect 1, the index resolved to a descriptor.
-- =====================================================================
do
  local s = newSys()
  local f = factor(s, newSprayer(7, FT.LIME), { area(ACID) })
  T.near("AUTO A1 [D1 the index]: a NUMERIC fill-type index resolves to LIME and the factor moves (acid ground, boost)", f, boost(5.5), 1e-9)
  T.ok("AUTO A2 [D1 the index]: which is not 1.0, the value AUTO returned on every path before", math.abs(f - 1.0) > 0.1)
end
T.eq("AUTO A3 [D1 the index]: a product without a pH profile (UREA) is neutral", factor(newSys(), newSprayer(7, FT.UREA), { area(ACID) }), 1.0)
T.eq("AUTO A4 [D1 the index]: FillType.UNKNOWN is neutral", factor(newSys(), newSprayer(7, FillType.UNKNOWN), { area(ACID) }), 1.0)
T.eq("AUTO A5 [D1 the index]: an index the manager cannot resolve is neutral", factor(newSys(), newSprayer(7, 999), { area(ACID) }), 1.0)
T.eq("AUTO A6 [D1 the index]: a descriptor TABLE where the engine puts an index is neutral, not a crash", factor(newSys(), newSprayer(7, { name = "LIME" }), { area(ACID) }), 1.0)
T.near("AUTO A7 [D1 the index]: LIQUIDLIME resolves too", factor(newSys(), newSprayer(7, FT.LIQUIDLIME), { area(ACID) }), boost(5.5), 1e-9)

-- =====================================================================
-- GROUP B: defect 2, the coordinate comes from the PASSED work areas' CURRENT nodes.
-- =====================================================================
g_currentMission.time = 200000
do
  -- The stale point sits over in-band ground (would give 0.5); the areas sit over acid (boost).
  local s = newSys({ staleX = BAND })
  T.near("AUTO B1 [D2 the coordinate]: the factor follows the work areas (acid), not the stale point (in band)", factor(s, newSprayer(7, FT.LIME), { area(ACID) }), boost(5.5), 1e-9)
end
g_currentMission.time = 300000
do
  local s = newSys({ staleX = ACID })
  T.eq("AUTO B2 [D2 the coordinate]: the reverse: stale over acid, areas over in-band: 0.5 (the areas win)", factor(s, newSprayer(7, FT.LIME), { area(BAND) }), 0.5)
end
g_currentMission.time = 400000
T.near("AUTO B3 [D2 the coordinate]: with NO stale point at all the areas still decide", factor(newSys(), newSprayer(7, FT.LIME), { area(ACID) }), boost(5.5), 1e-9)
g_currentMission.time = 500000
T.eq("AUTO B4 [D2 the coordinate]: no work areas passed: the selected rate is retained (1.0), even with a stale point over acid", factor(newSys({ staleX = ACID }), newSprayer(7, FT.LIME), nil), 1.0)
g_currentMission.time = 600000
T.eq("AUTO B5 [D2 the coordinate]: an empty list: retained", factor(newSys({ staleX = ACID }), newSprayer(7, FT.LIME), {}), 1.0)
g_currentMission.time = 700000
do
  -- The sprayer's OWN list sits over acid; the ARGUMENT sits over in-band. The brief's
  -- signature names the argument; the function must not reach into the sprayer for it.
  local sp = newSprayer(7, FT.LIME, { area(ACID) })
  T.eq("AUTO B6 [D2 the coordinate]: the ARGUMENT list is the source, not the sprayer's own work-area list", factor(newSys(), sp, { area(BAND) }), 0.5)
end
g_currentMission.time = 800000
T.eq("AUTO B7 [D2 the coordinate]: an AUXILIARY area over acid is skipped; the sprayer area over in-band decides", factor(newSys(), newSprayer(7, FT.LIME), { area(ACID, { aux = true }), area(BAND) }), 0.5)
g_currentMission.time = 900000
T.eq("AUTO B8 [D2 the coordinate]: an INACTIVE section over acid is skipped (current section state)", factor(newSys(), newSprayer(7, FT.LIME), { area(ACID, { active = false }), area(BAND) }), 0.5)
g_currentMission.time = 1000000
T.near("AUTO B9 [D2 the coordinate]: two active areas straddling acid and in-band: the mean local pH decides", factor(newSys(), newSprayer(7, FT.LIME), { area(ACID), area(BAND) }), boost((5.5 + 6.8) / 2), 1e-9)
g_currentMission.time = 1100000
T.eq("AUTO B10 [D2 the coordinate]: unrecorded ground under every area: no sample, the rate is retained", factor(newSys(), newSprayer(7, FT.LIME), { area(UNREC) }), 1.0)
g_currentMission.time = 1200000
T.near("AUTO B11 [D2 the coordinate]: unrecorded under one area, acid under another: the numeric sample decides", factor(newSys(), newSprayer(7, FT.LIME), { area(UNREC), area(ACID) }), boost(5.5), 1e-9)
g_currentMission.time = 1300000
do
  -- Nodes that do not resolve (a missing width node) do not throw; that area is skipped.
  local broken = area(ACID); broken.width = nil
  T.eq("AUTO B12 [D2 the coordinate]: an area with a missing node is skipped, not fatal", factor(newSys(), newSprayer(7, FT.LIME), { broken, area(BAND) }), 0.5)
end
g_currentMission.time = 1400000
do
  -- A sprayer without getIsWorkAreaActive (a bench, or a foreign type): every area counts.
  local sp = newSprayer(7, FT.LIME); sp.getIsWorkAreaActive = nil
  T.near("AUTO B13 [D2 the coordinate]: no activity method: every non-auxiliary area counts", factor(newSys(), sp, { area(ACID, { active = false }) }), boost(5.5), 1e-9)
end

-- =====================================================================
-- GROUP C: the existing curve and limits, unchanged.
-- =====================================================================
g_currentMission.time = 1500000
T.eq("AUTO C1 [curve kept]: LIME over alkaline ground reduces to 0.5", factor(newSys(), newSprayer(7, FT.LIME), { area(ALK) }), 0.5)
g_currentMission.time = 1600000
T.near("AUTO C2 [curve kept]: GYPSUM (pH-down) over alkaline ground boosts by the excess curve", factor(newSys(), newSprayer(7, FT.GYPSUM), { area(ALK) }), gypsumBoost(7.3), 1e-9)
g_currentMission.time = 1700000
T.eq("AUTO C3 [curve kept]: GYPSUM over in-band ground reduces to 0.5", factor(newSys(), newSprayer(7, FT.GYPSUM), { area(BAND) }), 0.5)
g_currentMission.time = 1800000
T.eq("AUTO C4 [curve kept]: GYPSUM over acid ground reduces to 0.5", factor(newSys(), newSprayer(7, FT.GYPSUM), { area(ACID) }), 0.5)
T.ok("AUTO C5 [curve kept]: the boost is capped at 1.5", boost(5.0) <= 1.5 and boost(5.5) <= 1.5)

-- =====================================================================
-- GROUP D: the five-second cadence per working vehicle, unchanged.
-- =====================================================================
do
  local s = newSys()
  g_currentMission.time = 2000000
  local first = factor(s, newSprayer(7, FT.LIME), { area(ACID) })
  g_currentMission.time = 2003000
  local second = factor(s, newSprayer(7, FT.LIME), { area(BAND) })   -- the ground changed, within 5 s
  T.near("AUTO D1 [cadence kept]: within five seconds the cached factor is returned", second, first, 1e-12)
  g_currentMission.time = 2005001
  local third = factor(s, newSprayer(7, FT.LIME), { area(BAND) })
  T.eq("AUTO D2 [cadence kept]: after five seconds it is recomputed from the current areas", third, 0.5)
  g_currentMission.time = 2005500
  autoOn[8] = true
  local other = factor(s, newSprayer(8, FT.LIME), { area(ACID) })
  T.near("AUTO D3 [cadence kept]: another vehicle has its own cache", other, boost(5.5), 1e-9)
  T.eq("AUTO D4 [cadence kept]: and did not disturb the first's", factor(s, newSprayer(7, FT.LIME), { area(ACID) }), 0.5)
end

-- =====================================================================
-- GROUP E: the gates, unchanged.
-- =====================================================================
g_currentMission.time = 3000000
autoOn[7] = false
T.eq("AUTO E1 [gates kept]: AUTO off for the vehicle: 1.0", factor(newSys(), newSprayer(7, FT.LIME), { area(ACID) }), 1.0)
autoOn[7] = true
g_currentMission.time = 3100000
T.eq("AUTO E2 [gates kept]: mod disabled: 1.0", factor(newSys({ enabled = false }), newSprayer(7, FT.LIME), { area(ACID) }), 1.0)
g_currentMission.time = 3200000
do
  local sg = g_server; g_server = nil
  T.eq("AUTO E3 [gates kept]: not the server: 1.0 (pure-client AUTO is display-only)", factor(newSys(), newSprayer(7, FT.LIME), { area(ACID) }), 1.0)
  g_server = sg
end
g_currentMission.time = 3300000
do
  local s = newSys(); s.valueMaps.available = false
  T.eq("AUTO E4 [gates kept]: value maps unavailable: 1.0", factor(s, newSprayer(7, FT.LIME), { area(ACID) }), 1.0)
end

-- =====================================================================
-- GROUP F: the REAL rate-multiplier append applies the factor to the dose ONCE.
-- =====================================================================
Utils = {
  prependedFunction = function(orig, new) return function(...) new(...) if orig then return orig(...) end end end,
  appendedFunction  = function(orig, new) return function(...) local r = orig and { orig(...) } or {} new(...) return unpack(r) end end,
}
do
  g_currentMission.time = 4000000
  local s = newSys()
  g_SoilFertilityManager.soilSystem = s
  Sprayer = { onStartWorkAreaProcessing = function(self, dt)
    self.spec_sprayer.workAreaParameters.usage = 0.5
    self.spec_sprayer.workAreaParameters.usagePerMin = 30
  end }
  local hm = setmetatable({ hooks = {}, register = function() end, registerCleanup = function() end }, { __index = HookManager })
  HookManager.installSprayerStartHook(hm)
  local sp = newSprayer(7, FT.LIME, { area(ACID) })
  Sprayer.onStartWorkAreaProcessing(sp, 16)
  T.near("AUTO F1 [applied once]: the dose is multiplied by the AUTO factor, once", sp.spec_sprayer.workAreaParameters.usage, 0.5 * boost(5.5), 1e-9)
  T.near("AUTO F2 [applied once]: and usagePerMin with it", sp.spec_sprayer.workAreaParameters.usagePerMin, 30 * boost(5.5), 1e-9)
  g_currentMission.time = 4001000
  Sprayer.onStartWorkAreaProcessing(sp, 16)
  T.near("AUTO F3 [applied once]: the next frame applies the (cached) factor once again to a fresh native dose, not compounding", sp.spec_sprayer.workAreaParameters.usage, 0.5 * boost(5.5), 1e-9)
  -- THE THIRD DEFECT, in the caller: it read spec_sprayer.workArea, a member the engine
  -- never sets, so AUTO received nil on every real vehicle. Now the list the engine
  -- RAISED the event with wins (WorkArea.lua:126), and the vehicle's own list is the
  -- fallback when no list was raised (F1 to F3 above).
  g_currentMission.time = 4010000
  autoOn[9] = true
  local sp2 = newSprayer(9, FT.LIME, { area(ACID) })          -- its own list: acid
  Sprayer.onStartWorkAreaProcessing(sp2, 16, { area(BAND) })   -- the engine raised: in band
  T.eq("AUTO F4 [D3 the caller]: the list the engine raised the event with is the one AUTO samples (in band: 0.5), not the vehicle's own", sp2.spec_sprayer.workAreaParameters.usage, 0.5 * 0.5)
  g_currentMission.time = 4020000
  autoOn[10] = true
  local sp3 = newSprayer(10, FT.LIME, { area(ACID) })
  sp3.spec_sprayer.workArea = nil                               -- what the engine's sprayer spec actually has: nothing
  Sprayer.onStartWorkAreaProcessing(sp3, 16)
  T.near("AUTO F5 [D3 the caller]: with no raised list and no spec_sprayer.workArea (the engine's real shape) the vehicle's own list is used", sp3.spec_sprayer.workAreaParameters.usage, 0.5 * boost(5.5), 1e-9)
end

-- ── restore ──
getWorldTranslation, WorkAreaType, FillType, Utils, Sprayer = saved.gwt, saved.WorkAreaType, saved.FillType, saved.Utils, saved.Sprayer
g_server, g_fillTypeManager, g_SoilFertilityManager = saved.g_server, saved.g_fillTypeManager, saved.g_SoilFertilityManager
g_currentMission.time = saved.time

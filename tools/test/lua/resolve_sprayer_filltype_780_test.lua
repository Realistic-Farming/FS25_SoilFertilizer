-- resolve_sprayer_filltype_780_test.lua - #780 side-tank NPK credit.
--   When vanilla draws product from an EXTERNAL source (tractor side tank / nurse tank /
--   attached supply implement), wap.sprayVehicle points at that vehicle. Once the planter's
--   own tank reads 0, getActiveSprayType() returns nil and getSprayerFillUnitIndex() falls
--   back to spec.fillUnitIndex - which may be a DIFFERENT local unit still holding a valid
--   product (seed tank, second product tank). Trusting that stale local type overrides the
--   correct wap.sprayFillType and silently kills NPK credit. The external-source guard makes
--   wap.sprayFillType authoritative in that case.
--   The contract this bench locks: external supply wins, local-tank supply preserves the
--   #708 physical-tank rule, BUY mode falls through to the physical tank, and malformed
--   sprayers fail safe to the fallback.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/utils/SoilUtils.lua

FillType = FillType or { UNKNOWN = 0 }

-- A sprayer whose spec/work-area look exactly like vanilla's Sprayer spec table.
local function sprayerWith(wap, methods)
  local sprayer = {
    spec_sprayer = { workAreaParameters = wap },
    getSprayerFillUnitIndex = function() return 2 end,
    getFillUnitFillType = function(_self, idx) return 100 + idx end,  -- a valid local type
    getFillUnitFillLevel = function(_self, _idx) return 10 end,       -- a valid level > 0
  }
  for k, v in pairs(methods or {}) do sprayer[k] = v end
  return sprayer
end

-- ── The fix: external source active -> wap.sprayFillType is authoritative ──
do
  -- Side tank supplies: wap.sprayVehicle is the side tank, not the planter.
  local sideTank = {}
  local wap = { sprayVehicle = sideTank, sprayFillType = 900 }
  local sprayer = sprayerWith(wap)
  local localType = sprayer:getFillUnitFillType(2)  -- wrong-but-valid local product
  T.ok("780: local tank holds a valid product (the trap)", localType > 0 and localType ~= FillType.UNKNOWN)
  T.eq("780: external source active -> returns the wap/sprayFillType fallback",
       SoilUtils.resolveSprayerFillTypeIndex(sprayer, 900), 900)
end

-- ── Regression #708: local tank supplies -> physical tank wins ──
do
  -- Planter's own tank is the source: wap.sprayVehicle == sprayer itself.
  local sprayer = sprayerWith({ sprayVehicle = nil })
  -- nil wap.sprayVehicle also falls through; set it explicitly to self to mirror vanilla.
  sprayer.spec_sprayer.workAreaParameters = { sprayVehicle = sprayer, sprayFillType = 1 }
  T.eq("780: local tank wins over a stale wap type (#708)",
       SoilUtils.resolveSprayerFillTypeIndex(sprayer, 1), 102)
end

-- ── BUY / external-fill mode (no sprayVehicle): physical tank (or wap) wins ──
do
  local sprayer = sprayerWith({ sprayVehicle = nil, sprayFillType = 7 })
  -- physical tank still holds product -> tank wins, #205 custom-fill stamp preserved
  T.eq("780: BUY mode with a loaded tank keeps the physical type",
       SoilUtils.resolveSprayerFillTypeIndex(sprayer, 7), 102)
end

-- ── Fallback: empty/UNKNOWN physical tank -> wap fallback ──
do
  local sprayer = sprayerWith({ sprayVehicle = nil, sprayFillType = 7 }, {
    getFillUnitFillType = function() return FillType.UNKNOWN end,
    getFillUnitFillLevel = function() return 0 end,
  })
  T.eq("780: empty local tank -> wap fallback survives",
       SoilUtils.resolveSprayerFillTypeIndex(sprayer, 7), 7)
end

-- ── Fail-safe: malformed sprayer -> fallback, never a crash ──
do
  T.eq("780: nil sprayer -> fallback", SoilUtils.resolveSprayerFillTypeIndex(nil, 4), 4)
  T.eq("780: sprayer without methods -> fallback",
       SoilUtils.resolveSprayerFillTypeIndex({ spec_sprayer = {} }, 4), 4)
  -- sprayer methods that throw must not crash the caller (pcall wraps them)
  local thrower = sprayerWith({ sprayVehicle = nil }, {
    getSprayerFillUnitIndex = function() error("boom") end,
  })
  T.eq("780: a throwing getSprayerFillUnitIndex fails safe to fallback",
       SoilUtils.resolveSprayerFillTypeIndex(thrower, 4), 4)
end

-- ── External source guard fires even when the local tank holds a valid product ──
do
  -- The exact #780 shape: planter liquid tank drained, seed tank still loaded.
  local sprayer = sprayerWith({ sprayVehicle = { id = "tractor" }, sprayFillType = 900 })
  T.eq("780: external source beats a valid local product (the #780 kill)",
       SoilUtils.resolveSprayerFillTypeIndex(sprayer, 900), 900)
end

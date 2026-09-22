-- rsf_f187_gypsum_identity_test.lua - RSF-F187: gypsum's runtime spray identity.
--
-- fillTypes.xml now declares GYPSUM's sprayType as FERTILIZER, matching what
-- registerCustomSprayTypes registers at runtime. The engine never reads that XML
-- token (SprayTypeManager only fills fillTypeIndexToSprayType through
-- addSprayType), so the XML edit is a declaration-consistency fix. This test pins
-- the runtime side: run the real registerCustomSprayTypes against a recording
-- spray-type manager that derives isFertilizer/isLime exactly as the engine does
-- (misc/SprayTypeManager.lua:61-62), and assert GYPSUM comes out FERTILIZER and
-- no solid type comes out LIME. The fillTypes.xml token and the two
-- limeCompatNames sites are text-level facts checked in the PR, not here:
-- fengari has no io.open.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local vanilla = {
  LIQUIDFERTILIZER = { litersPerSecond = 0.0081, sprayGroundType = 2 },
  FERTILIZER       = { litersPerSecond = 0.0060, sprayGroundType = 3 },
  LIME             = { litersPerSecond = 0.0040, sprayGroundType = 4 },
  FUNGICIDE        = { litersPerSecond = 0.0028, sprayGroundType = 5 },
}
local registered = {}
local nextIndex = 100
g_sprayTypeManager = {
  getSprayTypeByName = function(_self, name) return registered[name] or vanilla[name] end,
  addSprayType = function(_self, name, lps, typeName, groundType)
    typeName = string.upper(typeName or "")
    nextIndex = nextIndex + 1
    local st = { name = name, index = nextIndex, litersPerSecond = lps, sprayGroundType = groundType,
                 isFertilizer = typeName == "FERTILIZER", isLime = typeName == "LIME",
                 isHerbicide = typeName == "HERBICIDE", typeName = typeName }
    registered[name] = st
    return st
  end,
}
local fillTypes = {}
g_fillTypeManager = {
  getFillTypeByName = function(_self, name)
    fillTypes[name] = fillTypes[name] or { name = name, index = #name }
    return fillTypes[name]
  end,
  getFillTypeIndexByName = function(_self, name) return #name end,
}

local hm = setmetatable({}, { __index = HookManager })
-- The engine global the catalogue rebuild reads (registration now builds the identity
-- catalogue on every attempt, and rebuildCustomProductCatalogue compares to FillType.UNKNOWN).
FillType = FillType or { UNKNOWN = 0 }
local ok, err = pcall(HookManager.registerCustomSprayTypes, hm)
T.ok("F187 registerCustomSprayTypes runs", ok, err)

local g = registered.GYPSUM
T.ok("F187 GYPSUM registered", g ~= nil)
if g then
  T.eq("F187 GYPSUM typeName FERTILIZER", g.typeName, "FERTILIZER")
  T.eq("F187 GYPSUM isFertilizer", g.isFertilizer, true)
  T.eq("F187 GYPSUM isLime", g.isLime, false)
  T.eq("F187 GYPSUM ground type is the dry FERTILIZER one", g.sprayGroundType, 3)
end

-- LIQUIDLIME is the only registration allowed to carry LIME identity; no solid does.
local limeTyped = {}
for name, st in pairs(registered) do
  if st.isLime then limeTyped[#limeTyped + 1] = name end
end
table.sort(limeTyped)
T.eq("F187 only LIQUIDLIME is registered as LIME", table.concat(limeTyped, ","), "LIQUIDLIME")

-- The other solids share GYPSUM's identity, so the runtime list is consistent.
for _, name in ipairs({ "UREA", "AMS", "AN", "MAP", "DAP", "POTASH", "POLIFOSKA",
                        "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE" }) do
  T.eq("F187 solid " .. name .. " is FERTILIZER", registered[name] and registered[name].typeName, "FERTILIZER")
end

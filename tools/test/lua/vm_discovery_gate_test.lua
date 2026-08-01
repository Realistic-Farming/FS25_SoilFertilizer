-- vm_discovery_gate_test.lua - the display-layer discovery gate. An active but
-- unscouted infection must read EXACTLY like a clean field on every painted
-- surface (the disease map and the urgency map, and via the mirror the MP-synced
-- picture), so the scouting economy still has something to sell. Scouting reveals
-- it; pest has no discovery concept and is never gated.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SoilFertilitySystem.lua

local function sys() return setmetatable({}, { __index = SoilFertilitySystem }) end
local s = sys()

local base = { nitrogen = 80, phosphorus = 80, potassium = 80, pH = 6.5, weedPressure = 0, pestPressure = 0 }
local function withDisease(pressure, discovered)
  local f = {}
  for k, v in pairs(base) do f[k] = v end
  f.diseasePressure = pressure
  f.activeDisease = "SEPTORIA"
  f.diseaseDiscovered = discovered
  return f
end

local hidden = withDisease(60, false)   -- infected, not scouted
local shown  = withDisease(60, true)    -- infected, scouted
local clean  = withDisease(0, false)    -- genuinely clean

-- the gate itself
T.near("undiscovered disease -> shown pressure 0", s:_vmShownDiseasePressure(hidden), 0, 1e-9)
T.near("discovered disease -> shown real pressure", s:_vmShownDiseasePressure(shown), 60, 1e-9)

local dHidden = s:_vmDisplayValues(hidden)
local dShown  = s:_vmDisplayValues(shown)
local dClean  = s:_vmDisplayValues(clean)

T.near("disease map: undiscovered paints 0 (healthy)", dHidden.diseasePressure, 0, 1e-9)
T.near("disease map: discovered paints real value",    dShown.diseasePressure, 60, 1e-9)

-- THE INVARIANT: an unscouted infected field is indistinguishable from a clean one.
T.near("undiscovered == clean on disease map", dHidden.diseasePressure, dClean.diseasePressure, 1e-9)
T.near("undiscovered == clean on urgency",     dHidden.urgency,         dClean.urgency,         1e-9)

-- Scouting reveals it: urgency jumps once the disease is allowed through.
T.ok("scouting raises urgency above the hidden state", dShown.urgency > dHidden.urgency + 1)

-- Pest has no discovery gate: it shows through regardless.
local pest = {}
for k, v in pairs(base) do pest[k] = v end
pest.pestPressure = 50
pest.diseasePressure = 0
pest.diseaseDiscovered = false
T.near("pest is not gated by discovery", s:_vmDisplayValues(pest).pestPressure, 50, 1e-9)

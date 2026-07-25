-- organic_status_layer_test.lua - the organicStatus backing layer. Its three cert
-- states must encode to three distinct DMV colour states, with CONVENTIONAL
-- collapsing into the transparent no-data state so a conventional field is never
-- tinted (the deliberate encoding choice from the build note). The layer is
-- ephemeral (no savegame file); it is rebuilt from each field's organic state.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/maps/SoilValueMaps.lua

local function defFor(key)
  for _, d in ipairs(SoilValueMaps.LAYER_DEFS) do
    if d.key == key then return d end
  end
  return nil
end

local def = defFor("organicStatus")
T.ok("layer: organicStatus is defined", def ~= nil)

-- Ephemeral (no file), and NO rawFloor: conventional must be able to reach the
-- transparent state, not be floored up into a visible band like the display layers.
T.ok("layer: organicStatus is ephemeral (no file)", def.file == nil)
T.ok("layer: organicStatus has no rawFloor", def.rawFloor == nil)
T.eq("layer: minVal is 0", def.minVal, 0)
T.eq("layer: maxVal is 2", def.maxVal, 2)

-- DMV colour state = top 4 bits of the 8-bit raw (firstChannel 4, numChannels 4),
-- i.e. floor(raw / 16). State 0 (raw 0-15, incl. the no-data sentinel) is transparent.
local function dmvState(raw) return math.floor(raw / 16) end

local rawConv  = SoilValueMaps._encode(0, def)
local rawTrans = SoilValueMaps._encode(1, def)
local rawCert  = SoilValueMaps._encode(2, def)

-- Conventional collapses with the raw-0 no-data sentinel: DMV state 0 = untinted.
T.eq("conventional -> DMV state 0 (untinted, collapses with no-data)", dmvState(rawConv), 0)

-- Transitioning and certified land in visible, distinct DMV states.
T.ok("transitioning -> a visible DMV state", dmvState(rawTrans) > 0)
T.ok("certified -> a visible DMV state", dmvState(rawCert) > 0)
T.ok("transitioning and certified are distinct states", dmvState(rawTrans) ~= dmvState(rawCert))
T.ok("certified reads stronger than transitioning", dmvState(rawCert) > dmvState(rawTrans))

-- Exact raw values are stable: conventional 1 (state 0), transitioning 128 (state 8),
-- certified 255 (state 15). Locks the encoding a future change would have to justify.
T.eq("conventional encodes to raw 1", rawConv, 1)
T.eq("transitioning encodes to raw 128", rawTrans, 128)
T.eq("certified encodes to raw 255", rawCert, 255)

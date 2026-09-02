-- resistance_bands_cd11_test.lua - CD-11, the resistance data contract.
--
-- CD-9 simulates resistance and persists it four ways; no client could ever see it
-- (F67: `resistance` occurred zero times in NetworkEvents.lua). This is the fifth path.
-- The contract these assertions hold:
--   * the server bands, the client reads; a raw score never crosses the wire
--   * UNKNOWN is a value, not an absence, and never degrades to WORKING
--   * unscouted ground never publishes a band at all
--   * the gate is the durable fieldEverScouted bit, not the per-outbreak diseaseDiscovered
--     flag, so resistance history survives a fresh infection
--   * a pure client reads UNKNOWN until the server has delivered the field once
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/SoilFertilitySystem.lua, src/ResistanceBands.lua, src/HybridStrains.lua

local R  = SoilConstants.RESISTANCE
local B  = R.BANDS
local RB = ResistanceBands

-- A revealed field carries the DURABLE scout bit. diseaseDiscovered is set too because
-- that is what a freshly scouted field looks like, but it is not what the gate reads.
local function revealed(resistance)
  return { diseaseDiscovered = true, fieldEverScouted = true, resistance = resistance or {} }
end

-- ── The natural/synthetic ceiling split. This is the brief's own pseudocode bug: it says
-- isNaturalFungicide(mode), which takes a fill-type NAME, so every mode returns false.
do
  T.eq("ceiling: synthetic FRAC 3 caps at MAX_SYNTHETIC",  RB.ceilingForMode("3"),  R.MAX_SYNTHETIC)
  T.eq("ceiling: natural FRAC M2 caps at MAX_NATURAL",     RB.ceilingForMode("M2"), R.MAX_NATURAL)
  T.eq("ceiling: natural FRAC M1 caps at MAX_NATURAL",     RB.ceilingForMode("M1"), R.MAX_NATURAL)
  T.ok("ceiling: the two ceilings actually differ",        R.MAX_NATURAL ~= R.MAX_SYNTHETIC)
end

-- NATURAL_MODES must stay in step with CD-9's own chemical->FRAC mapping. Adding a natural
-- chemical without updating the constant fails HERE rather than shipping a wrong ceiling.
do
  local derived = {}
  for _, name in ipairs(SoilConstants.PHYSICAL_FUNGICIDE_ORDER) do
    if SoilFertilitySystem.isNaturalFungicide(name) then
      derived[SoilFertilitySystem.getModeForFillType(name)] = true
    end
  end
  for mode in pairs(derived) do
    T.ok("NATURAL_MODES agrees with CD-9 mapping: " .. mode, R.NATURAL_MODES[mode] == true)
  end
  for mode in pairs(R.NATURAL_MODES) do
    T.ok("NATURAL_MODES has no mode CD-9 does not call natural: " .. mode, derived[mode] == true)
  end
end

-- ── Band cut points. FINISHED is anchored at ratio 1.0 by the SDS because that is exactly
-- where the CD-9 penalty (1 - score/maxRes) reaches zero.
do
  T.eq("band: a clean mode is WORKING",              RB.bandFromRatio(0),    B.WORKING)
  T.eq("band: just under the slipping cut",          RB.bandFromRatio(0.49), B.WORKING)
  T.eq("band: at the slipping cut",                  RB.bandFromRatio(0.5),  B.SLIPPING)
  T.eq("band: just under saturation",                RB.bandFromRatio(0.99), B.SLIPPING)
  T.eq("band: at ratio 1.0 the mode is FINISHED",    RB.bandFromRatio(1.0),  B.FINISHED)
  T.eq("band: above the ceiling stays FINISHED",     RB.bandFromRatio(2.0),  B.FINISHED)
  T.eq("band: FINISHED is anchored where the penalty is zero", R.BAND_CUT_FINISHED, 1.0)
end

-- A saturated NATURAL must read FINISHED. Under the brief's pseudocode it would divide by
-- the synthetic ceiling and read WORKING - a burned-out sulfur reported as fine.
do
  local f = revealed({ M2 = R.MAX_NATURAL })
  T.eq("a saturated natural reads FINISHED", RB.computeBand(f, "M2"), B.FINISHED)
  T.ok("...and would NOT have, banded against the synthetic ceiling",
       RB.bandFromRatio(R.MAX_NATURAL / R.MAX_SYNTHETIC) ~= B.FINISHED)
end

-- ── THE GATE. Unscouted ground publishes nothing and reads UNKNOWN, whether or not it
-- currently carries a disease. This is the inverted-expression defect the brief names:
-- getScoutReport's `activeDisease and not diseaseDiscovered` lets a disease-free field
-- fall through and read as scouted.
do
  local unscoutedInfected = { diseaseDiscovered = false, fieldEverScouted = false, activeDisease = "rust",
                              resistance = { ["3"] = R.MAX_SYNTHETIC } }
  local unscoutedClean    = { diseaseDiscovered = false, fieldEverScouted = false, activeDisease = nil,
                              resistance = { ["3"] = R.MAX_SYNTHETIC } }

  T.eq("gate: unscouted + infected reads UNKNOWN", RB.computeBand(unscoutedInfected, "3"), B.UNKNOWN)
  T.eq("gate: unscouted + NO disease also reads UNKNOWN (the inverted-gate trap)",
       RB.computeBand(unscoutedClean, "3"), B.UNKNOWN)
  T.eq("gate: unscouted publishes NO bands at all", #RB.encodeFieldBands(unscoutedInfected), 0)
  T.eq("gate: a nil field reads UNKNOWN", RB.getBand(nil, "3"), B.UNKNOWN)
  T.ok("gate: UNKNOWN is distinct from every real band",
       B.UNKNOWN ~= B.WORKING and B.UNKNOWN ~= B.SLIPPING and B.UNKNOWN ~= B.FINISHED)

  -- The gate is the DURABLE bit. diseaseDiscovered alone (an optimistic client mark, or a
  -- record the migration has not seeded) does not reveal; a field with no key at all does
  -- not reveal; a field whose current outbreak re-hid the disease but which was scouted
  -- once before stays revealed, because resistance follows the ground, not the outbreak.
  local discoveredOnly = { diseaseDiscovered = true, resistance = { ["3"] = R.MAX_SYNTHETIC } }
  local absentKey      = { resistance = { ["3"] = R.MAX_SYNTHETIC } }
  local reHidden       = { diseaseDiscovered = false, fieldEverScouted = true, activeDisease = "rust",
                           resistance = { ["3"] = R.MAX_SYNTHETIC } }
  T.ok("gate: isFieldRevealed reads ONLY fieldEverScouted == true (discoveredOnly)",
       not RB.isFieldRevealed(discoveredOnly))
  T.ok("gate: an absent key is not revealed", not RB.isFieldRevealed(absentKey))
  T.ok("gate: a re-hidden outbreak on scouted ground stays revealed", RB.isFieldRevealed(reHidden))
  T.eq("gate: diseaseDiscovered without the durable bit reads UNKNOWN",
       RB.computeBand(discoveredOnly, "3"), B.UNKNOWN)
  T.eq("gate: ...and publishes no bands", #RB.encodeFieldBands(discoveredOnly), 0)
  T.eq("gate: a fresh outbreak does not hide learned resistance history",
       RB.computeBand(reHidden, "3"), B.FINISHED)
  T.eq("gate: ...and still publishes it", #RB.encodeFieldBands(reHidden), 2)
end

-- A revealed field with no resistance yet reads WORKING, not UNKNOWN: the player has
-- scouted this ground and has simply never burned that mode.
do
  T.eq("a revealed field with no score on a mode reads WORKING",
       RB.computeBand(revealed({}), "3"), B.WORKING)
end

-- ── Encode: only modes carrying resistance travel, and they travel as BANDS.
do
  local f = revealed({ ["3"] = R.MAX_SYNTHETIC, ["11"] = R.MAX_SYNTHETIC * 0.6, ["7"] = 0 })
  local flat = RB.encodeFieldBands(f)
  T.eq("encode: emits one pair per non-zero mode", #flat, 4)

  local seen = {}
  for i = 1, #flat - 1, 2 do seen[flat[i]] = flat[i + 1] end
  T.eq("encode: saturated mode travels as FINISHED", seen["3"],  B.FINISHED)
  T.eq("encode: 60% mode travels as SLIPPING",       seen["11"], B.SLIPPING)
  T.ok("encode: a zero mode is not sent",            seen["7"] == nil)

  -- The load-bearing one: no raw score is anywhere on the wire.
  for i = 2, #flat, 2 do
    T.ok("encode: every payload value is a band enum, never a raw score",
         flat[i] >= B.WORKING and flat[i] <= B.FINISHED)
  end
end

-- ── Apply: the client's picture round-trips, and a client NEVER computes from raw.
do
  local server = revealed({ ["3"] = R.MAX_SYNTHETIC, ["M2"] = R.MAX_NATURAL * 0.7 })
  local client = { diseaseDiscovered = true, fieldEverScouted = true }   -- no `resistance` key: clients never get one
  T.ok("roundtrip: no receipt before the wire speaks", client.resistanceBandsReceived == nil)
  RB.applyFieldBands(client, RB.encodeFieldBands(server))

  T.eq("roundtrip: FINISHED survives the wire", client.resistanceBands["3"],  B.FINISHED)
  T.eq("roundtrip: SLIPPING survives the wire", client.resistanceBands["M2"], B.SLIPPING)
  T.ok("roundtrip: the client holds no raw scores", client.resistance == nil)
  T.ok("roundtrip: applyFieldBands stamps the receipt", client.resistanceBandsReceived == true)
end

-- A field with nothing to say keeps no sub-table, mirroring applyFieldOrganic. The receipt
-- is stamped BEFORE the empty test: "nothing on this field" is an answer, not silence.
do
  local f = { diseaseDiscovered = true, fieldEverScouted = true, resistanceBands = { ["3"] = B.FINISHED } }
  RB.applyFieldBands(f, {})
  T.ok("apply: an empty payload clears the sub-table", f.resistanceBands == nil)
  T.ok("apply: an empty payload still counts as a receipt", f.resistanceBandsReceived == true)
  local g = { fieldEverScouted = true }
  RB.applyFieldBands(g, nil)
  T.ok("apply: a nil payload still counts as a receipt", g.resistanceBandsReceived == true)
end

-- A malformed or hostile payload cannot invent a band.
do
  local f = { diseaseDiscovered = true, fieldEverScouted = true }
  RB.applyFieldBands(f, { "3", 99, "11", -5, "7", B.SLIPPING, 42, B.WORKING })
  T.ok("apply: an out-of-range band is dropped", f.resistanceBands["3"] == nil)
  T.ok("apply: a negative band is dropped",      f.resistanceBands["11"] == nil)
  T.eq("apply: the valid entry survives",        f.resistanceBands["7"], B.SLIPPING)
  T.ok("apply: a non-string mode key is dropped", f.resistanceBands[42] == nil)
end

-- ── getBand resolution. The server bands its own raw score; a pure client reads only what
-- arrived and never touches a raw value.
do
  local prevServer = g_server

  g_server = {}   -- server / listen host / single player
  local sp = revealed({ ["3"] = R.MAX_SYNTHETIC })
  T.eq("getBand: a server picture bands its own raw score", RB.getBand(sp, "3"), B.FINISHED)
  T.ok("getBand: hasServerPicture is true with g_server set", RB.hasServerPicture())

  g_server = nil  -- pure client
  local sent = { diseaseDiscovered = true, fieldEverScouted = true,
                 resistanceBandsReceived = true, resistanceBands = { ["3"] = B.SLIPPING } }
  T.eq("getBand: a client reads the band it was sent", RB.getBand(sent, "3"), B.SLIPPING)

  -- A raw score sitting on a client field must NOT be banded locally.
  local rogue = { diseaseDiscovered = true, fieldEverScouted = true, resistanceBandsReceived = true,
                  resistance = { ["3"] = R.MAX_SYNTHETIC } }
  T.ok("getBand: a client never bands a raw score itself", RB.getBand(rogue, "3") ~= B.FINISHED)

  -- Unscouted still wins over anything the field carries.
  local hidden = { diseaseDiscovered = false, fieldEverScouted = false, resistanceBandsReceived = true,
                   resistanceBands = { ["3"] = B.FINISHED } }
  T.eq("getBand: the gate outranks a sent band", RB.getBand(hidden, "3"), B.UNKNOWN)

  -- THE RECEIPT. A pure client that has not been delivered the field yet knows nothing
  -- about any mode and says UNKNOWN; the same silence AFTER a receipt means "zero on that
  -- mode" and bands WORKING. Never a guessed WORKING before the server has spoken.
  local waiting = { diseaseDiscovered = true, fieldEverScouted = true }
  T.eq("getBand: a pure client reads UNKNOWN before receipt", RB.getBand(waiting, "3"), B.UNKNOWN)
  RB.applyFieldBands(waiting, RB.encodeFieldBands(revealed({ ["11"] = R.MAX_SYNTHETIC })))
  T.eq("getBand: after receipt a delivered mode reads its band", RB.getBand(waiting, "11"), B.FINISHED)
  T.eq("getBand: after receipt a silent mode reads WORKING", RB.getBand(waiting, "3"), B.WORKING)
  RB.applyFieldBands(waiting, {})
  T.eq("getBand: an empty delivery is a receipt, silent mode reads WORKING", RB.getBand(waiting, "3"), B.WORKING)

  -- The receipt never leaks into the server picture: a server bands raw regardless.
  g_server = {}
  local serverNoReceipt = revealed({ ["3"] = R.MAX_SYNTHETIC })
  T.eq("getBand: a server picture needs no receipt", RB.getBand(serverNoReceipt, "3"), B.FINISHED)
  T.eq("getBand: a server picture with a clean mode reads WORKING without a receipt",
       RB.getBand(serverNoReceipt, "11"), B.WORKING)

  g_server = prevServer
end

-- ── The durable bit is written by scoutField on the server only, and it survives the
-- outbreak reset that clears diseaseDiscovered.
do
  local prevServer, prevMission, prevClient = g_server, g_currentMission, g_client
  local function newSys()
    return setmetatable({ settings = { diseasePressure = true },
                          -- no activeDisease: the report walk needs SoilDiseaseSystem, which
                          -- this test does not load; the flags are the subject here.
                          fieldData = { [1] = { diseaseDiscovered = false, fieldEverScouted = false,
                                                resistance = { ["3"] = R.MAX_SYNTHETIC } } } },
                        { __index = SoilFertilitySystem })
  end

  -- Single player / server: one scout sets both flags.
  g_server = {}
  g_currentMission = { missionDynamicInfo = { isMultiplayer = false } }
  local sp = newSys()
  sp:scoutField(1)
  T.ok("scoutField (server): diseaseDiscovered set", sp.fieldData[1].diseaseDiscovered == true)
  T.ok("scoutField (server): fieldEverScouted set", sp.fieldData[1].fieldEverScouted == true)
  T.eq("scoutField (server): the band is readable right after", sp:getResistanceBand(1, "3"), B.FINISHED)

  -- A fresh outbreak clears ONLY diseaseDiscovered; the history stays readable.
  sp.fieldData[1].diseaseDiscovered = false
  T.eq("outbreak reset: resistance history survives", sp:getResistanceBand(1, "3"), B.FINISHED)

  -- Pure client: optimistic disease mark, NEVER the durable bit, and it asks the server.
  g_server = nil
  local sent = 0
  g_client = { getServerConnection = function() return { sendEvent = function() sent = sent + 1 end } end }
  g_currentMission = { missionDynamicInfo = { isMultiplayer = true } }
  local prevEvent = SoilScoutFieldEvent
  SoilScoutFieldEvent = { new = function(id) return { fieldId = id } end }
  local cl = newSys()
  cl:scoutField(1)
  T.ok("scoutField (client): diseaseDiscovered marked optimistically", cl.fieldData[1].diseaseDiscovered == true)
  T.ok("scoutField (client): the durable bit is NOT written by a client", cl.fieldData[1].fieldEverScouted ~= true)
  T.eq("scoutField (client): one scout event sent", sent, 1)
  T.eq("scoutField (client): still UNKNOWN until the server writes and delivers", cl:getResistanceBand(1, "3"), B.UNKNOWN)
  -- Already revealed locally but the durable bit never came back: ask again, once per scout.
  cl:scoutField(1)
  T.eq("scoutField (client): re-asks while the durable bit is missing", sent, 2)
  -- Once the server's delivery carried the bit, a further scout is silent.
  cl.fieldData[1].fieldEverScouted = true
  cl:scoutField(1)
  T.eq("scoutField (client): no event once the bit has arrived", sent, 2)

  SoilScoutFieldEvent = prevEvent
  g_server, g_currentMission, g_client = prevServer, prevMission, prevClient
end

-- ── The system-level getter, which is the whole surface the presentation build consumes.
do
  local prevServer = g_server
  g_server = {}
  local sys = setmetatable({ fieldData = { [1] = revealed({ ["3"] = R.MAX_SYNTHETIC }) } },
                           { __index = SoilFertilitySystem })

  T.eq("getResistanceBand: resolves a known field", sys:getResistanceBand(1, "3"), B.FINISHED)
  T.eq("getResistanceBand: an unknown field id is UNKNOWN, never nil",
       sys:getResistanceBand(999, "3"), B.UNKNOWN)

  -- By chemical, since a player picks a jug and not a FRAC group.
  T.eq("byChemical: PROPICONAZOLE resolves through FRAC 3",
       sys:getResistanceBandForChemical(1, "PROPICONAZOLE"), B.FINISHED)
  T.eq("byChemical: TEBUCONAZOLE shares FRAC 3, so it is burned too",
       sys:getResistanceBandForChemical(1, "TEBUCONAZOLE"), B.FINISHED)
  T.eq("byChemical: AZOXYSTROBIN is a different mode and still works",
       sys:getResistanceBandForChemical(1, "AZOXYSTROBIN"), B.WORKING)
  T.eq("byChemical: generic FUNGICIDE has no mode and reads UNKNOWN",
       sys:getResistanceBandForChemical(1, "FUNGICIDE"), B.UNKNOWN)

  g_server = prevServer
end

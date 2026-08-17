-- sf19_see_and_spray_repoint_test.lua - SF-19 item 5: the See & Spray section
-- decision must read pest/disease from the SYNCED per-pixel display maps first,
-- then the zoneData cell, then the field scalar. On a client the cell is the
-- flattened copy, so preferring the value maps is what makes a client's section
-- sprayer fire and skip where the host's would.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

-- ── 1. Value maps win when they carry a real value ─────────────────────────
do
  local vm = { available = true,
    readValueAtWorld = function(_self, key, _x, _z)
      if key == "pestPressure"    then return 44 end
      if key == "diseasePressure" then return 88 end
      return nil
    end }
  local soilSys = { valueMaps = vm, vmAvailable = function() return true end }
  local fd   = { pestPressure = 20, diseasePressure = 60 }
  local cell = { pestPressure = 30, diseasePressure = 70 }
  local pest, disease = HookManager.resolveCellPressure(soilSys, fd, cell, 10, 20)
  T.eq("pest from the value maps", pest, 44)
  T.eq("disease from the value maps", disease, 88)
end

-- ── 2. Unwritten value-map pixel -> zoneData cell ──────────────────────────
do
  local vm = { available = true,
    readValueAtWorld = function() return nil end }
  local soilSys = { valueMaps = vm, vmAvailable = function() return true end }
  local fd   = { pestPressure = 20, diseasePressure = 60 }
  local cell = { pestPressure = 30, diseasePressure = 70 }
  local pest, disease = HookManager.resolveCellPressure(soilSys, fd, cell, 10, 20)
  T.eq("pest falls back to the cell", pest, 30)
  T.eq("disease falls back to the cell", disease, 70)
end

-- ── 3. No cell -> field scalar ─────────────────────────────────────────────
do
  local vm = { available = true,
    readValueAtWorld = function() return nil end }
  local soilSys = { valueMaps = vm, vmAvailable = function() return true end }
  local fd   = { pestPressure = 20, diseasePressure = 60 }
  local pest, disease = HookManager.resolveCellPressure(soilSys, fd, nil, 10, 20)
  T.eq("pest falls back to the field scalar", pest, 20)
  T.eq("disease falls back to the field scalar", disease, 60)
end

-- ── 4. No value maps at all -> cell then field (the pre-re-point behaviour) ──
do
  local soilSys = { valueMaps = nil }
  local fd   = { pestPressure = 20, diseasePressure = 60 }
  local cell = { pestPressure = 30, diseasePressure = 70 }
  local pest, disease = HookManager.resolveCellPressure(soilSys, fd, cell, 10, 20)
  T.eq("no maps: pest from the cell", pest, 30)
  T.eq("no maps: disease from the cell", disease, 70)
end

-- ── 5. Nothing anywhere -> zeros (skip-safe) ───────────────────────────────
do
  local pest, disease = HookManager.resolveCellPressure(nil, nil, nil, 0, 0)
  T.eq("nothing available: pest is 0", pest, 0)
  T.eq("nothing available: disease is 0", disease, 0)
end

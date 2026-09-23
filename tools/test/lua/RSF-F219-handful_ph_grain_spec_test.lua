-- RSF-F219-handful_ph_grain_spec_test.lua - honest pH grain on the handful,
-- map tooltip and sprayer cab (RSF-F219 IMPLEMENTATION-BRIEF v1.3).
--
-- The farmer kneeling on a corner gets the pH of that sample or an honest
-- unavailable result with separately labelled last-known information. This
-- bench drives the real producer, the real HandfulRead assembly, the real
-- handful dialog populate, the real map tooltip builder and the real sprayer
-- cab update and draw loops against engine stubs, and pins the seven items:
--   1  positional miss assigned outside the report-helper guard (nil pH,
--      UNAVAILABLE, nil grain), non-positional path unchanged, coordinate 0 is
--      present, _phReportRead never runs on the positional path
--   2  a CURRENT report supplies pHLastKnown only
--   3  HandfulRead forwards pHStatus / pHGrainMetres / pHLastKnown
--   4  the pH tile carries its own status word, never the shared header's
--   5  the map click tooltip is nil-safe at the format call, on any layer
--   6  the sprayer pH row goes unavailable as a whole (no 0, no lerp to 0,
--      dash, dim colour, empty bar) and recovers from a real sample
--   7  (locale keys are checked by the shell gate; wording is not a Lua fact)
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/SpatialScouting.lua, src/HandfulRead.lua, src/ui/SoilHandfulDialog.lua, src/ui/SoilMapOverlay.lua, src/ui/SoilSprayerInfoPanel.lua

local READ_LOCAL = PositionalPH.READ_LOCAL
local READ_APPROX = PositionalPH.READ_APPROXIMATE
local READ_FIELD = PositionalPH.READ_FIELD
local READ_UNAVAILABLE = PositionalPH.READ_UNAVAILABLE

-- ============================================================
-- Part A: the producer (items 1 and 2), real getFieldInfo
-- ============================================================

local function newSystem(opt)
  opt = opt or {}
  local sys = setmetatable({
    fieldData = {
      [1] = { nitrogen = 40, phosphorus = 30, potassium = 50, pH = 6.2,
              organicMatter = 3.0, fieldArea = 2.0, lastHarvest = 0, zoneData = opt.zoneData },
    },
    settings = { enabled = false },
    _phMapRevision = 3,
    valueMaps = {
      available = opt.vmAvailable ~= false,
      readValueAtWorld = function(_self, key, _x, _z)
        return opt.px and opt.px[key] or nil
      end,
      getGrainMetres = function() return 2.0 end,
    },
  }, { __index = SoilFertilitySystem })
  sys._rotationStatusFor = function() return "OK" end
  sys._scsYieldKeepFactor = function() return 1 end
  sys._yieldModifierFromNutrients = function() return 1 end
  sys.warning = function() end
  sys._reportReadCalls = 0
  sys._phReportRead = function(self, id)
    self._reportReadCalls = self._reportReadCalls + 1
    return SoilFertilitySystem._phReportRead(self, id)
  end
  if opt.report == "absent" then
    sys._ensurePHReport = false
  elseif opt.report ~= nil then
    sys._ensurePHReport = function(_self, _id) return opt.report end
  else
    sys._ensurePHReport = function(_self, _id) return nil end
  end
  return sys
end

local CURRENT = { status = PositionalPH.REPORT_CURRENT, value = 6.9 }
local EMPTY = { status = PositionalPH.REPORT_EMPTY, value = nil }

-- A1 LOCAL hit: numeric pH, LOCAL, grain from the carrier.
do
  local sys = newSystem({ px = { pH = 5.8, nitrogen = 41 }, report = CURRENT })
  local info = sys:getFieldInfo(1, 10, 20)
  T.eq("A1 LOCAL pH is the pixel", info.pH, 5.8)
  T.eq("A1 status LOCAL", info.pHStatus, READ_LOCAL)
  T.eq("A1 grain is the carrier grain", info.pHGrainMetres, 2.0)
  T.eq("A1 last-known stays the field scalar", info.pHLastKnown, 6.2)
  T.eq("A1 fromZoneCell true", info.fromZoneCell, true)
  T.eq("A1 needsFertilization known", info.needsFertilizationKnown, true)
end

-- A2 positional miss with a CURRENT report: nil pH, UNAVAILABLE, nil grain,
-- last-known refreshed from the report, no seed leaks.
do
  local sys = newSystem({ px = { nitrogen = 41 }, report = CURRENT })
  local info = sys:getFieldInfo(1, 10, 20)
  T.eq("A2 pH nil on a positional miss", info.pH, nil)
  T.eq("A2 status UNAVAILABLE", info.pHStatus, READ_UNAVAILABLE)
  T.eq("A2 grain nil", info.pHGrainMetres, nil)
  T.eq("A2 last-known is the CURRENT report value", info.pHLastKnown, 6.9)
  T.eq("A2 _phReportRead never runs on the positional path", sys._reportReadCalls, 0)
  T.eq("A2 the nutrients still refine", info.fromZoneCell, true)
  T.eq("A2 unknown pH with no other need is an unknown result", info.needsFertilizationKnown, false)
  T.eq("A2 needsFertilization false when unknown", info.needsFertilization, false)
end

-- A3 positional miss, EMPTY report: last-known keeps the captured scalar.
do
  local sys = newSystem({ px = { nitrogen = 41 }, report = EMPTY })
  local info = sys:getFieldInfo(1, 10, 20)
  T.eq("A3 pH nil", info.pH, nil)
  T.eq("A3 UNAVAILABLE", info.pHStatus, READ_UNAVAILABLE)
  T.eq("A3 last-known is the field scalar", info.pHLastKnown, 6.2)
end

-- A4 positional miss where no pixel of any kind answers (vm answers nothing):
-- still nil pH and UNAVAILABLE, not the seed.
do
  local sys = newSystem({ px = {}, report = CURRENT })
  local info = sys:getFieldInfo(1, 10, 20)
  T.eq("A4 pH nil when the vm answers nothing", info.pH, nil)
  T.eq("A4 UNAVAILABLE", info.pHStatus, READ_UNAVAILABLE)
  T.eq("A4 fromZoneCell false", info.fromZoneCell, false)
  T.eq("A4 last-known from the report", info.pHLastKnown, 6.9)
end

-- A5 helper absent: the miss is still assigned (outside the guard).
do
  local sys = newSystem({ px = {}, report = "absent" })
  local info = sys:getFieldInfo(1, 10, 20)
  T.eq("A5 pH nil without _ensurePHReport", info.pH, nil)
  T.eq("A5 UNAVAILABLE without the helper", info.pHStatus, READ_UNAVAILABLE)
  T.eq("A5 grain nil", info.pHGrainMetres, nil)
  T.eq("A5 last-known retains the historical field.pH", info.pHLastKnown, 6.2)
end

-- A6 coordinate 0 is present.
do
  local sys = newSystem({ px = {}, report = CURRENT })
  local info = sys:getFieldInfo(1, 0, 0)
  T.eq("A6 (0,0) is a positional request: pH nil", info.pH, nil)
  T.eq("A6 (0,0) UNAVAILABLE", info.pHStatus, READ_UNAVAILABLE)
end

-- A7 one coordinate absent: the non-positional path, unchanged.
do
  local sys = newSystem({ px = {}, report = CURRENT })
  local info = sys:getFieldInfo(1, 10, nil)
  T.eq("A7 x only: FIELD_REPORT value", info.pH, 6.9)
  T.eq("A7 x only: status FIELD_REPORT", info.pHStatus, READ_FIELD)
  local sys2 = newSystem({ px = {}, report = EMPTY })
  local info2 = sys2:getFieldInfo(1, nil, 20)
  T.eq("A7 z only, no report: pH nil", info2.pH, nil)
  T.eq("A7 z only, no report: UNAVAILABLE", info2.pHStatus, READ_UNAVAILABLE)
  T.eq("A7 z only: last-known scalar", info2.pHLastKnown, 6.2)
end

-- A8 non-positional with the helper absent keeps the pre-F219 values (seed and
-- FIELD_REPORT), exactly as before.
do
  local sys = newSystem({ px = {}, report = "absent" })
  local info = sys:getFieldInfo(1)
  T.eq("A8 non-positional without helper keeps the scalar", info.pH, 6.2)
  T.eq("A8 status FIELD_REPORT", info.pHStatus, READ_FIELD)
end

-- A9 APPROXIMATE from a zone cell when the value maps are unavailable.
do
  local zone = SoilConstants.ZONE
  local cs = zone.CELL_SIZE
  local x, z = 3 * cs + 1, 4 * cs + 1
  local key = tostring(math.floor(x / cs) * 10000 + math.floor(z / cs))
  local sys = newSystem({ vmAvailable = false, report = CURRENT,
    zoneData = { [key] = { N = 30, P = 20, K = 40, pH = 6.4, OM = 3 } } })
  local info = sys:getFieldInfo(1, x, z)
  T.eq("A9 zone cell pH is APPROXIMATE", info.pHStatus, READ_APPROX)
  T.eq("A9 zone cell value", info.pH, 6.4)
  local sys2 = newSystem({ vmAvailable = false, report = CURRENT,
    zoneData = { [key] = { N = 30, P = 20, K = 40, OM = 3 } } })
  local info2 = sys2:getFieldInfo(1, x, z)
  T.eq("A9 zone cell without pH: positional miss, nil", info2.pH, nil)
  T.eq("A9 zone cell without pH: UNAVAILABLE", info2.pHStatus, READ_UNAVAILABLE)
  T.eq("A9 zone cell without pH: last-known from report", info2.pHLastKnown, 6.9)
  T.eq("A9 zone cell nutrients still refine", info2.fromZoneCell, true)
end

-- A10 a positional miss with another known deficiency keeps needsFertilization.
do
  local sys = newSystem({ px = {}, report = EMPTY })
  sys.fieldData[1].nitrogen = 5
  local info = sys:getFieldInfo(1, 10, 20)
  T.eq("A10 other deficiency stays true", info.needsFertilization, true)
  T.eq("A10 and is known", info.needsFertilizationKnown, true)
end

-- ============================================================
-- Part B: HandfulRead forwards the pH fields (item 3)
-- ============================================================
do
  local captured
  g_SoilFertilityManager = { soilSystem = {
    fieldData = { [1] = { pH = 6.2 } },
    getFieldInfo = function(_self, fieldId, x, z)
      captured = { fieldId, x, z }
      return { pH = nil, pHStatus = READ_UNAVAILABLE, pHGrainMetres = nil, pHLastKnown = 6.9,
               nitrogen = { value = 40, status = "Good" }, fromZoneCell = true }
    end,
  } }
  local p = HandfulRead.assemble({ fieldId = 1, x = 5, z = 6 })
  T.eq("B1 assemble passes both coordinates", captured[2] .. "," .. captured[3], "5,6")
  T.eq("B1 pH nil forwarded", p.pH, nil)
  T.eq("B1 pHStatus forwarded", p.pHStatus, READ_UNAVAILABLE)
  T.eq("B1 pHGrainMetres nil forwarded", p.pHGrainMetres, nil)
  T.eq("B1 pHLastKnown forwarded", p.pHLastKnown, 6.9)
  T.eq("B1 fromZoneCell still rides for N/P/K/OM", p.fromZoneCell, true)
  g_SoilFertilityManager.soilSystem.getFieldInfo = function()
    return { pH = 5.9, pHStatus = READ_LOCAL, pHGrainMetres = 2.0, pHLastKnown = 6.2 }
  end
  local q = HandfulRead.assemble({ fieldId = 1, x = 5, z = 6 })
  T.eq("B2 LOCAL pH forwarded", q.pH, 5.9)
  T.eq("B2 LOCAL status forwarded", q.pHStatus, READ_LOCAL)
  T.eq("B2 grain forwarded", q.pHGrainMetres, 2.0)
  g_SoilFertilityManager = nil
end

-- ============================================================
-- Part C: the handful pH tile (item 4)
-- ============================================================
g_i18n = { getText = function(_self, _key) return "" end, hasText = function() return false end }

local function el()
  local e = { text = "", visible = true, color = nil }
  e.setText = function(_self, t) e.text = t or "" end
  e.setVisible = function(_self, v) e.visible = v end
  e.setTextColor = function(_self, r, g, b, a) e.color = { r, g, b, a } end
  return e
end
local IDS = {
  "hfField", "hfGrain", "hfLblN", "hfValN", "hfLblP", "hfValP", "hfLblK", "hfValK",
  "hfLblPh", "hfValPh", "hfPhGrain", "hfLblOm", "hfValOm", "hfLblComp", "hfValComp",
  "hfLblMoist", "hfValMoist", "hfLblDis", "hfValDis", "hfLblPest", "hfValPest",
  "hfLblWeed", "hfValWeed", "hfDisGrain", "hfCrops", "hfRotation", "hfOrganic",
  "hfSecMaterial", "hfLblWet", "hfValWet", "hfLblDown", "hfValDown",
  "hfLblVerdict", "hfValVerdict", "hfFooter",
}
local function render(payload)
  local p = { _payload = payload }
  for _, id in ipairs(IDS) do p[id] = el() end
  SoilHandfulDialog._populate(p)
  return p
end
local function base(over)
  local p = { fieldId = 7, fromZoneCell = true, clauses = HandfulRead.CLAUSES,
    N = { value = 42, status = "Good" }, P = { value = 30, status = "Fair" },
    K = { value = 12, status = "Poor" }, OM = 4.2 }
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end
local NEUTRAL = { 0.55, 0.55, 0.55, 1 }
local function sameColor(a, b)
  return a ~= nil and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

-- C1 LOCAL without the kit: band, own word says spot at the grain.
do
  local p = render(base({ pH = 6.5, pHStatus = "LOCAL", pHGrainMetres = 2.0, pHLastKnown = 6.2 }))
  T.eq("C1 LOCAL band", p.hfValPh.text, "Good")
  T.ok("C1 own word says spot", has(p.hfPhGrain.text, "spot"))
  T.ok("C1 own word carries the grain", has(p.hfPhGrain.text, "2.0 m"))
  T.eq("C1 header still says spot for N/P/K/OM", p.hfGrain.text, "spot")
end
-- C2 LOCAL with the kit: band plus one decimal.
do
  local p = render(base({ testKitActive = true, pH = 6.5, pHStatus = "LOCAL", pHGrainMetres = 2.0 }))
  T.eq("C2 kit LOCAL band and figure", p.hfValPh.text, "Good 6.5")
  T.ok("C2 kit LOCAL word spot", has(p.hfPhGrain.text, "spot"))
end
-- C3 LOCAL without a grain figure: plain spot.
do
  local p = render(base({ pH = 6.5, pHStatus = "LOCAL" }))
  T.eq("C3 spot without grain", p.hfPhGrain.text, "spot")
end
-- C4 APPROXIMATE: its own word.
do
  local p = render(base({ pH = 5.2, pHStatus = "APPROXIMATE" }))
  T.eq("C4 approximate band", p.hfValPh.text, "Acidic")
  T.eq("C4 approximate word", p.hfPhGrain.text, "approximate")
  local q = render(base({ testKitActive = true, pH = 5.2, pHStatus = "APPROXIMATE" }))
  T.eq("C4 kit approximate", q.hfValPh.text, "Acidic 5.2")
end
-- C5 UNAVAILABLE with a numeric last-known: band under the recorded-field label.
do
  local p = render(base({ pH = nil, pHStatus = "UNAVAILABLE", pHLastKnown = 7.8 }))
  T.eq("C5 recorded band", p.hfValPh.text, "Alkaline")
  T.eq("C5 recorded label", p.hfPhGrain.text, "recorded field value")
  T.ok("C5 recorded band keeps its severity colour, under its label", p.hfValPh.color ~= nil and p.hfValPh.color[1] == 0.90)
  local q = render(base({ testKitActive = true, pH = nil, pHStatus = "UNAVAILABLE", pHLastKnown = 7.8 }))
  T.eq("C5 kit recorded band and figure", q.hfValPh.text, "Alkaline 7.8")
  T.eq("C5 kit recorded label", q.hfPhGrain.text, "recorded field value")
end
-- C6 UNAVAILABLE without a last-known: dash under unavailable.
do
  local p = render(base({ pH = nil, pHStatus = "UNAVAILABLE" }))
  T.eq("C6 dash", p.hfValPh.text, "--")
  T.ok("C6 neutral colour", sameColor(p.hfValPh.color, NEUTRAL))
  T.eq("C6 unavailable word", p.hfPhGrain.text, "unavailable here")
  local q = render(base({ pH = nil, pHStatus = "UNAVAILABLE", pHLastKnown = "6.5" }))
  T.eq("C6 string last-known is not a number: dash", q.hfValPh.text, "--")
end
-- C7 no silent substitution: UNAVAILABLE with a numeric pH in the slot still
-- never reads it as current (the producer never sends this; defensive).
do
  local p = render(base({ pH = 7.0, pHStatus = "UNAVAILABLE" }))
  T.eq("C7 UNAVAILABLE ignores a stray current value", p.hfValPh.text, "--")
end
-- C8 STALE, unknown and absent statuses dash and never inherit the header word.
do
  for _, st in ipairs({ "STALE", "SOMETHING", false }) do
    local over = { pH = 6.5 }
    if st ~= false then over.pHStatus = st end
    local p = render(base(over))
    T.eq("C8 " .. tostring(st) .. " dashes", p.hfValPh.text, "--")
    T.eq("C8 " .. tostring(st) .. " no word", p.hfPhGrain.text, "")
    T.ok("C8 " .. tostring(st) .. " neutral", sameColor(p.hfValPh.color, NEUTRAL))
  end
end
-- C9 the shared header flag does not decide the pH word.
do
  local p = render(base({ fromZoneCell = false, pH = 6.5, pHStatus = "LOCAL" }))
  T.eq("C9 header field average", p.hfGrain.text, "field average")
  T.ok("C9 pH word still spot", has(p.hfPhGrain.text, "spot"))
  local q = render(base({ fromZoneCell = true, pH = nil, pHStatus = "UNAVAILABLE", pHLastKnown = 6.5 }))
  T.eq("C9 header spot", q.hfGrain.text, "spot")
  T.eq("C9 pH word recorded", q.hfPhGrain.text, "recorded field value")
end
-- C10 FIELD_REPORT (defensive totality only).
do
  local p = render(base({ pH = 6.5, pHStatus = "FIELD_REPORT" }))
  T.eq("C10 field report word", p.hfPhGrain.text, "field average")
  T.eq("C10 field report band", p.hfValPh.text, "Good")
end
-- C11 the new element id is registered so onGuiSetupFinished binds it.
do
  local bound = {}
  local fake = { getDescendantById = function(_self, id) bound[id] = true; return el() end }
  local savedSuper = SoilHandfulDialog.superClass
  SoilHandfulDialog.superClass = function() return { onGuiSetupFinished = function() end } end
  local ok, err = pcall(function() SoilHandfulDialog.onGuiSetupFinished(fake) end)
  SoilHandfulDialog.superClass = savedSuper
  if not ok then print("C11 error: " .. tostring(err)) end
  T.ok("C11 onGuiSetupFinished runs", ok)
  T.eq("C11 hfPhGrain is bound", bound.hfPhGrain, true)
end

-- ============================================================
-- Part D: map click tooltip nil-safe (item 5)
-- ============================================================
local drawn = {}
renderText = function(_x, _y, _sz, text) drawn[#drawn + 1] = tostring(text) end
setTextBold = function() end
setTextColor = function() end
setTextAlignment = function() end
setTextVerticalAlignment = function() end
getTextWidth = function() return 0.05 end
getTextHeight = function() return 0.02 end
getNormalizedScreenValues = function(a, b) return a, b end
drawFilledRect = function() end
RenderText = RenderText or { ALIGN_LEFT = 0, ALIGN_RIGHT = 1, ALIGN_CENTER = 2, VERTICAL_ALIGN_MIDDLE = 1 }
-- A locale in which every key is present and translates to its own name. The
-- assertions below pin WHICH key the overlay reached for, which is why the
-- translation is the key rather than English text. hasText must answer, and must
-- answer true, because the repaired gates require it (I18N.lua:194); a fixture
-- with getText alone is refused and every row would silently read as English.
g_i18n = {
  hasText = function(_self, key) return key ~= nil end,
  getText = function(_self, key) return key end,
}

local function newOverlay(info, layer)
  local ov = setmetatable({
    settings = { activeMapLayer = layer or 4 },
    soilSystem = { getFieldInfo = function() return info end },
  }, { __index = SoilMapOverlay })
  ov.screenToWorldPosition = function() return 100.5, 200.5 end
  ov.worldToScreenPosition = function() return 0.5, 0.5 end
  ov.statusColors = function() return { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 } end
  ov.getSidebarBounds = function() return 0, 0, 0, 0 end
  ov._readCellGrowth = function() return { state = "unknown" } end
  return ov
end
g_farmlandManager = { getFarmlandAtWorldPosition = function() return { id = 3 } end }

local function tooltipStrings(ov)
  drawn = {}
  local ok, err = pcall(function() ov:drawCellTooltip({}, 0, 0, 1, 1) end)
  return ok, err, drawn
end
local function any(list, sub)
  for _, s in ipairs(list) do if has(s, sub) then return true end end
  return false
end

-- D1 direct pH click on a positional miss: No data, no numeric row, no error.
do
  local ov = newOverlay({ pH = nil, pHStatus = READ_UNAVAILABLE, pHLastKnown = 6.9, fromZoneCell = true,
    nitrogen = { value = 40 }, phosphorus = { value = 30 }, potassium = { value = 50 } }, 4)
  ov:onMapClick({}, 0.5, 0.5)
  T.ok("D1 click stored the cell", ov.selectedCell ~= nil)
  local ok, err, out = tooltipStrings(ov)
  T.ok("D1 no exception: " .. tostring(err), ok)
  T.ok("D1 No data condition row", any(out, "sf_map_target_no_data"))
  T.ok("D1 no numeric pH row", not any(out, "6.9") and not any(out, "0.0"))
end
-- D2 click on another layer, then the settings-panel switch to pH (no setLayer).
do
  local ov = newOverlay({ pH = nil, pHStatus = READ_UNAVAILABLE, pHLastKnown = 6.9, fromZoneCell = true,
    nitrogen = { value = 40, status = "Good" }, phosphorus = { value = 30 }, potassium = { value = 50 } }, 1)
  ov:onMapClick({}, 0.5, 0.5)
  local ok1 = select(1, tooltipStrings(ov))
  T.ok("D2 nitrogen layer draws", ok1)
  ov.settings.activeMapLayer = 4
  T.ok("D2 selection retained across the settings-panel write", ov.selectedCell ~= nil)
  local ok, err, out = tooltipStrings(ov)
  T.ok("D2 pH branch safe after the panel switch: " .. tostring(err), ok)
  T.ok("D2 No data", any(out, "sf_map_target_no_data"))
  T.ok("D2 no last-known shown as current", not any(out, "6.9"))
end
-- D3 setLayer dismisses the tooltip.
do
  local ov = newOverlay({ pH = nil, pHStatus = READ_UNAVAILABLE, nitrogen = { value = 40 }, phosphorus = { value = 30 }, potassium = { value = 50 } }, 1)
  ov:onMapClick({}, 0.5, 0.5)
  ov:setLayer(4)
  T.eq("D3 setLayer clears the selection", ov.selectedCell, nil)
  local ok, _, out = tooltipStrings(ov)
  T.ok("D3 nothing drawn", ok and #out == 0)
end
-- D4 a known pH still draws its numeric row.
do
  local ov = newOverlay({ pH = 6.94, pHStatus = READ_LOCAL, fromZoneCell = true,
    nitrogen = { value = 40 }, phosphorus = { value = 30 }, potassium = { value = 50 } }, 4)
  ov:onMapClick({}, 0.5, 0.5)
  local ok, err, out = tooltipStrings(ov)
  T.ok("D4 draws: " .. tostring(err), ok)
  T.ok("D4 numeric pH row present", any(out, "6.9"))
  T.ok("D4 optimal condition", any(out, "sf_map_ph_optimal"))
end

-- ============================================================
-- Part E: sprayer cab pH row (item 6)
-- ============================================================
g_currentMission = g_currentMission or {}
g_currentMission.isRunning = true
g_currentMission.hud = nil

local function newPanel()
  local panel = SoilSprayerInfoPanel.new({}, { enabled = true })
  panel.initialized = true
  panel._cachedSprayer = {}
  panel.getSprayerFillType = function() return { name = "LIME" } end
  panel._detectTimer = 1000
  return panel
end
local function step(panel, info, dt)
  panel._fieldInfo = info
  panel:update(dt or 16)
end
local textColors = {}
setTextColor = function(r, g, b, a) textColors[#textColors + 1] = { r, g, b, a } end
local function drawPanel(panel)
  drawn = {}
  textColors = {}
  local ok, err = pcall(function() panel:draw() end)
  return ok, err
end
local function lastValueDraw()
  -- the pH row value is the first "--" or one-decimal figure drawn; the stats
  -- bar below it draws its own days-since-harvest dash later
  for i = 1, #drawn do
    local s = drawn[i]
    if s == "--" or s:match("^%d+%.%d$") then return s, i end
  end
  return nil
end

-- E1 known pH smooths and draws a figure.
do
  local panel = newPanel()
  step(panel, { pH = 6.4, nitrogen = { value = 40 } })
  T.eq("E1 first sample snaps in", panel._smoothValues.pH, 6.4)
  local ok, err = drawPanel(panel)
  T.ok("E1 draw runs: " .. tostring(err), ok)
  T.eq("E1 figure drawn", (lastValueDraw()), "6.4")
end
-- E2 unavailable pH clears the slot: never 0, never a lerp toward 0.
do
  local panel = newPanel()
  step(panel, { pH = 6.4 })
  step(panel, { pH = nil, pHStatus = READ_UNAVAILABLE, pHLastKnown = 6.4 })
  T.eq("E2 smoothed pH cleared", panel._smoothValues.pH, nil)
  step(panel, { pH = nil }, 400)
  T.eq("E2 stays cleared", panel._smoothValues.pH, nil)
  local ok, err = drawPanel(panel)
  T.ok("E2 draw runs: " .. tostring(err), ok)
  local s = lastValueDraw()
  T.eq("E2 host dash drawn", s, "--")
  local dimSeen = false
  for _, c in ipairs(textColors) do
    if c[1] == SoilSprayerInfoPanel.C_DIM[1] and c[2] == SoilSprayerInfoPanel.C_DIM[2] then dimSeen = true end
  end
  T.ok("E2 dash drawn in the dim colour", dimSeen)
  local poorSeen = false
  for _, c in ipairs(textColors) do
    if c[1] == SoilSprayerInfoPanel.C_POOR[1] and c[2] == SoilSprayerInfoPanel.C_POOR[2] then poorSeen = true end
  end
  T.ok("E2 no poor verdict on the unknown value", not poorSeen)
end
-- E3 recovery: a real sample snaps in from the actual pH, not from zero.
do
  local panel = newPanel()
  step(panel, { pH = nil })
  step(panel, { pH = 7.1 })
  T.eq("E3 snaps to the real sample", panel._smoothValues.pH, 7.1)
  step(panel, { pH = 7.1 }, 16)
  T.eq("E3 holds", panel._smoothValues.pH, 7.1)
end
-- E4 other nutrients keep smoothing while pH is unavailable.
do
  local panel = newPanel()
  step(panel, { pH = nil, nitrogen = { value = 0 }, organicMatter = 0 })
  step(panel, { pH = nil, nitrogen = { value = 100 }, organicMatter = 10 }, 16)
  local n = panel._smoothValues.nitrogen
  T.ok("E4 nitrogen eases toward the target", n > 0 and n < 100)
  T.ok("E4 organic matter eases", panel._smoothValues.organicMatter > 0 and panel._smoothValues.organicMatter < 10)
  T.eq("E4 pH stays unavailable", panel._smoothValues.pH, nil)
end
-- E5 a pH value that is a table (a stray clause) is not coerced either.
do
  local panel = newPanel()
  step(panel, { pH = { value = 6 } })
  T.eq("E5 non-numeric pH clears", panel._smoothValues.pH, nil)
end
-- E6 no field at all clears everything (unchanged behaviour).
do
  local panel = newPanel()
  step(panel, { pH = 6.4 })
  step(panel, nil)
  T.eq("E6 no field clears pH", panel._smoothValues.pH, nil)
end

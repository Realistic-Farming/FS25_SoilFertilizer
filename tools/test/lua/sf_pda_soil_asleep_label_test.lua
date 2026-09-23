-- sf_pda_soil_asleep_label_test.lua - Field Sentry "sim asleep" on the RF PDA Soil tab
-- (tester xrhec, Field 33; PLAYER-REPORTS row 30). The field detail dialog and the HUD
-- already show that a slept field's soil is frozen by intent; RfPdaSoilPanel read
-- getFieldInfo's simDisabled flags nowhere, so the PDA row showed an urgency the player
-- could not act on and the treatment plan read as live advice.
--
-- ENTRY POINT: the real RfPdaSoilPanel.rebuildFieldData over a real SoilFertilitySystem
-- whose getFieldInfo publishes the Field Sentry state, set through FieldSentry_API the
-- way the player sets it (setFieldManual); then the real populateFieldRow and the real
-- refreshTreatmentPlan. No info table is written by hand; the page fixture carries the
-- widgets the panel paints and records what it painted. The page translator is the
-- fixture's, marking every key it is asked for, so a raw getText cannot pass as tr.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/FieldSentry.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/ui/RfPdaSoilPanel.lua

local FIELD = 33

-- ── the soil world: one field with soil data, owned by nobody (all-fields fallback) ──
local function newSoil()
  -- The field record shape the F219 bar gives the real getFieldInfo (area, last harvest,
  -- value maps unavailable so the FIELD_REPORT path serves pH); nothing in it is a
  -- Field Sentry flag, those come from FieldSentry_API below.
  local sys = setmetatable({
    fieldData         = {},
    settings          = { enabled = true, nutrientCycles = true },
    _dailyBatchDay    = 1,
    _dailyBatchSeason = 1,
    _phMapRevision    = 1,
    valueMaps         = { available = false, readValueAtWorld = function() return nil end,
                          getGrainMetres = function() return 2.0 end },
  }, { __index = SoilFertilitySystem })
  sys.fieldData[FIELD] = { pH = 6.5, nitrogen = 40, phosphorus = 35, potassium = 45, organicMatter = 3.0,
                           fieldArea = 2.0, lastHarvest = 0, nutrientBuffer = {} }
  g_SoilFertilityManager = { soilSystem = sys, settings = {} }
  g_farmlandManager = nil
  return sys
end

-- ── the page and its widgets ─────────────────────────────────────────────────
local function widget(name)
  local w = { name = name, text = nil, color = nil, visible = nil }
  function w:setText(t) self.text = t end
  function w:setTextColor(r, g, b, a) self.color = { r, g, b, a } end
  function w:setVisible(v) self.visible = v end
  return w
end
local function newCell()
  local cell = { widgets = {} }
  function cell:getDescendantByName(name)
    if self.widgets[name] == nil then self.widgets[name] = widget(name) end
    return self.widgets[name]
  end
  return cell
end
--- A translator that marks every key it resolves, so the bar can tell a key read
--- through the page's tr from raw English or a raw getText.
local function markingTr(k, _fb) return "L:" .. tostring(k) end
local function newPage(tr)
  return { _rfTr = tr, fieldData = {}, selectedFieldId = nil, treatSelectedLabel = widget("treatSelectedLabel") }
end

local function paintRow(page, index)
  local cell = newCell()
  RfPdaSoilPanel.populateFieldRow(page, index, cell)
  return cell.widgets
end

-- =====================================================================
-- A. a MANUALLY slept field: row status says asleep, plan line carries the reason
-- =====================================================================
do
  newSoil()
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(FIELD, true)          -- the player sleeps the field
  local page = newPage(markingTr)
  RfPdaSoilPanel.rebuildFieldData(page)
  T.eq("A1 the roster has the field", #page.fieldData, 1)
  local info = page.fieldData[1] and page.fieldData[1].info
  T.eq("A2 the info came from the real getFieldInfo: simDisabled", info and info.simDisabled, true)
  T.eq("A3 with the reason name", info and info.simDisabledReason, "manual")
  T.eq("A4 and the reason key", info and info.simDisabledReasonKey, "sf_fs_reason_manual")

  local w = paintRow(page, 1)
  T.eq("A5 the STATUS cell reads the asleep key through the page translator", w.fieldRowStatus.text, "L:sf_fieldsentry_asleep")
  local c = w.fieldRowStatus.color or {}
  T.ok("A6 in the panel's dim colour (white at 55% alpha), not an urgency colour",
       c[1] == 1.0 and c[2] == 1.0 and c[3] == 1.0 and c[4] ~= nil and math.abs(c[4] - 0.55) < 1e-9)
  T.eq("A7 N stays", w.fieldRowN.text, "40%")
  T.eq("A8 P stays", w.fieldRowP.text, "35%")
  T.eq("A9 K stays", w.fieldRowK.text, "45%")
  T.eq("A10 pH stays", w.fieldRowPH.text, "6.5")

  page.selectedFieldId = FIELD
  RfPdaSoilPanel.refreshTreatmentPlan(page)
  local label = page.treatSelectedLabel.text or ""
  T.ok("A11 the selected line carries the asleep state and the reason, both through tr",
       label:find("(L:sf_fieldsentry_asleep: L:sf_fs_reason_manual)", 1, true) ~= nil)
  T.ok("A12 after the field line, not instead of it", label:find("L:rf_pda_treatment_selected", 1, true) == 1)
end

-- =====================================================================
-- B. the same field awake: status is an urgency word, the plan line is plain
-- =====================================================================
do
  newSoil()
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(FIELD, false)
  local page = newPage(markingTr)
  RfPdaSoilPanel.rebuildFieldData(page)
  local info = page.fieldData[1] and page.fieldData[1].info
  T.eq("B1 awake: simDisabled false from getFieldInfo", info and info.simDisabled, false)
  local w = paintRow(page, 1)
  T.ok("B2 awake: the STATUS cell is an urgency word, never asleep",
       w.fieldRowStatus.text ~= "L:sf_fieldsentry_asleep"
       and (w.fieldRowStatus.text == "L:rf_pda_status_urgent" or w.fieldRowStatus.text == "L:rf_pda_status_ok"
            or w.fieldRowStatus.text == "L:sf_pda_status_fair"))
  page.selectedFieldId = FIELD
  RfPdaSoilPanel.refreshTreatmentPlan(page)
  local label = page.treatSelectedLabel.text or ""
  T.ok("B3 awake: the selected line has no asleep suffix", label:find("asleep", 1, true) == nil and label:find("(", 1, true) == nil)
end

-- =====================================================================
-- C. no page translator: the English fallbacks, the shape the tester saw elsewhere
-- =====================================================================
do
  newSoil()
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(FIELD, true)
  local page = newPage(nil)
  RfPdaSoilPanel.rebuildFieldData(page)
  local w = paintRow(page, 1)
  T.eq("C1 fallback status text", w.fieldRowStatus.text, "sim asleep")
  page.selectedFieldId = FIELD
  RfPdaSoilPanel.refreshTreatmentPlan(page)
  T.eq("C2 fallback selected line", page.treatSelectedLabel.text, "Selected field: Field 33  (sim asleep: manual)")
end

-- =====================================================================
-- D. no Field Sentry state at all for the field (never touched): awake shape
-- =====================================================================
do
  newSoil()
  FieldSentry_API.reset()
  local page = newPage(markingTr)
  RfPdaSoilPanel.rebuildFieldData(page)
  local w = paintRow(page, 1)
  T.ok("D1 an untouched field is not asleep", w.fieldRowStatus.text ~= "L:sf_fieldsentry_asleep")
end

FieldSentry_API.reset()
g_SoilFertilityManager = nil

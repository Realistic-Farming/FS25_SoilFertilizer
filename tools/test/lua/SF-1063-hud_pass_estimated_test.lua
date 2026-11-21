-- SF-1063-hud_pass_estimated_test.lua
--
-- #1063: the HUD's per-pass "Pass: N% (product)" line says "estimated" when the coverage
-- behind it was worked out from litres rather than counted from boom cells, the same test
-- the pass-coverage notice uses (not field._geometricCoverageOwner). The 2026-10-02 coverage
-- and 1.0x ruling (section 2) says a volume-derived fallback is labelled estimated and never
-- advertised as measured hectares. The notice has said so since W3; the HUD line did not.
--
-- WHERE THE BAR STARTS. A real field record (getOrCreateField) has the coverage tracker's
-- state set on it by hand: the session coverage, its product and whether boom cells own it.
-- The tracker's own writes are not under test here (the pass-coverage benches run those from
-- the sprayer tick). From there it is production code: the real SoilFertilitySystem:getFieldInfo,
-- whose result the real SoilHUD:update() turns into the pre-formatted coverage lines (group E),
-- the real drawPanel (group P), the real SoilHUD:drawCoverageLines, which also draws a row wider
-- than the panel smaller instead of letting it spill past the edge (group D), and the real
-- SoilSprayerInfoPanel:draw, whose stats bar shows the same coverage in two cells (group Q).
-- The fixture supplies the world only: the player in a sprayer holding UREA, the settings and
-- the English texts as the shipped language file has them. Group L reads the shipped
-- language files as text.
--
-- Groups:
--   E  the line says estimated for litre-derived coverage and not for boom-cell coverage; the
--      daily coverage line never carries it; no product; no session coverage; the field info
--      carries the flag
--   P  the real drawPanel: the labelled line, the daily line untouched, the next row one slot below
--   D  the coverage rows: one slot each, a row that fits is drawn at full size, a row too wide
--      is drawn smaller to the panel's inner width, at scale 1 and at another scale and font size
--   Q  the sprayer info panel's PASS and session-ha cells carry a "~" for litre-derived coverage
--      and not for boom-cell coverage
--   L  the new string in all 27 languages: present once, translated, the same word the
--      notice uses for "estimated", no specifier, no dash, the English text's hash
--
-- What this bar does NOT prove: the look of the line on screen and real text widths. The
-- TESTING row names those observations.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ui/SoilHUD.lua, src/ui/SoilSprayerInfoPanel.lua
--!text: translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml

SoilLogger.debug = function() end
SoilLogger.info = function() end
SoilLogger.warning = function() end

-- A group that raises must say so and not hide the groups after it.
local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " ran to its end without a Lua error (" .. tostring(err) .. ")", false) end
end

-- ── the shipped texts ───────────────────────────────────────────────────────
local LANGS = { "br", "cs", "ct", "cz", "da", "de", "ea", "en", "es", "fc", "fi", "fr", "hu", "id", "it", "jp",
                "kr", "nl", "no", "pl", "pt", "ro", "ru", "sv", "tr", "uk", "vi" }
local function unescape(v)
  return (v:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end
local LANG, COUNT = {}, {}
for _, l in ipairs(LANGS) do
  local text = SOURCE_TEXT["translations/translation_" .. l .. ".xml"] or ""
  local m, n = {}, {}
  for k, v, h in text:gmatch('<e k="([^"]+)" v="([^"]*)" eh="([^"]*)"') do
    m[k] = { v = unescape(v), eh = h }
    n[k] = (n[k] or 0) + 1
  end
  LANG[l], COUNT[l] = m, n
end
local EN = {}
for k, e in pairs(LANG.en) do EN[k] = e.v end
g_i18n = { texts = {}, hasText = function(_, k) return EN[k] ~= nil end,
           getText = function(_, k) return EN[k] or ("Missing '" .. tostring(k) .. "'") end }

-- ── the world: the player in a sprayer with UREA, one field with a coverage record ───
local UREA = { name = "UREA", index = 50, massPerLiter = 0.00077 }
FillType = FillType or { UNKNOWN = 0 }
g_fillTypeManager = { getFillTypeByIndex = function(_, i) if i == 50 then return UREA end end,
                      getFillTypeByName  = function(_, n) if n == "UREA" then return UREA end end }
g_sprayTypeManager = { getSprayTypeByFillTypeIndex = function() return nil end }

local FIELD_ID = 7
--- The coverage tracker's state on a real field record (getOrCreateField builds every other
--- slot the way the game does).
local function setCoverage(rec, opts)
  rec.coverageFraction, rec.sessionCoverageFraction = opts.day, opts.session
  rec.sessionLastProduct, rec._geometricCoverageOwner = opts.product, opts.geometric or nil
  if opts.compaction then rec.compaction = opts.compaction end
end
local function newSprayer()
  local v = { id = 4242, isServer = true, spec_sprayer = { workAreaParameters = { sprayFillType = 50 } } }
  v.rootVehicle = v
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function() return 50 end
  v.getFillUnitLastValidFillType = function() return 50 end
  v.getFillUnitFillLevel = function() return 500 end
  return v
end

--- The HUD after one frame of its own update(), with the field info the real getFieldInfo
--- builds from the record. Layout and the field-detect timer are set aside (not under test).
local function frame(opts)
  g_server = {}
  g_currentMission = { time = 10000 }
  local settings = { enabled = true, autoRateControl = false, replenishmentRate = 3, hudPosition = 1, compactionEnabled = true }
  local ss = setmetatable({ fieldData = {}, settings = settings }, { __index = SoilFertilitySystem })
  local rec = ss:getOrCreateField(FIELD_ID, true, 4.0)
  setCoverage(rec, opts)
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  local sprayer = newSprayer()
  g_localPlayer = { getIsInVehicle = function() return true end, getCurrentVehicle = function() return sprayer end }
  local hud = SoilHUD.new(ss, settings)
  hud.fieldDetectTimer = 0
  hud._heightDirty = false
  hud.lastHudPosition = settings.hudPosition
  local ok, info = xpcall(ss.getFieldInfo, function(e) return debug.traceback(tostring(e), 2) end, ss, FIELD_ID)
  hud.cachedFieldInfo = ok and info or nil
  hud:update(16)
  return hud, ok and info or nil, ok and nil or info
end

local function join(lines) return lines and table.concat(lines, " | ") or "(none)" end
local SAVE = EN.sf_hud_pass_estimated or "(missing key)"
local DAY_LINE = string.format(EN.sf_hud_coverage, 57, math.floor((SoilConstants.COVERAGE and SoilConstants.COVERAGE.MIN_FULL_CREDIT or 0.70) * 100 + 0.5))
local PASS_UREA = string.format(EN.sf_hud_pass_coverage, 57, "UREA")
local PASS_NONE = string.format(EN.sf_hud_pass_noproduct, 57)

-- =====================================================================
-- GROUP E: from the field record to the HUD's formatted lines
-- =====================================================================
group("block 1", function()
  T.eq("E0 the English label is the notice's word, in its own parentheses", SAVE, "(estimated)")
  -- Litres, not boom cells: the case this change is for.
  local hud, info, err = frame({ day = 0.57, session = 0.57, product = "UREA" })
  T.ok("E1 getFieldInfo ran on the record (" .. tostring(err) .. ")", info ~= nil)
  T.eq("E2 the field info says the coverage is estimated", info and info.sessionCoverageEstimated, true)
  T.eq("E3 the Pass line says estimated, after the product",
       join(hud._fmt_covLines), DAY_LINE .. " | " .. PASS_UREA .. " " .. SAVE)
end)
group("block 2", function()
  -- Counted from boom cells: no label.
  local hud, info = frame({ day = 0.57, session = 0.57, product = "UREA", geometric = true })
  T.eq("E4 boom-cell coverage: the field info says not estimated", info and info.sessionCoverageEstimated, false)
  T.eq("E5 and the Pass line carries no label", join(hud._fmt_covLines), DAY_LINE .. " | " .. PASS_UREA)
end)
group("block 3", function()
  -- No product recorded: the other string, still labelled.
  local hud = frame({ day = 0.57, session = 0.57, product = nil })
  T.eq("E6 with no product the Pass line is labelled too", join(hud._fmt_covLines), DAY_LINE .. " | " .. PASS_NONE .. " " .. SAVE)
end)
group("block 4", function()
  -- The daily coverage line is untouched in both cases.
  local est = frame({ day = 0.57, session = 0.57, product = "UREA" })
  local cnt = frame({ day = 0.57, session = 0.57, product = "UREA", geometric = true })
  T.eq("E7 the daily coverage line never carries the label (litres)", est._fmt_covLines[1], DAY_LINE)
  T.eq("E8 nor with boom cells", cnt._fmt_covLines[1], DAY_LINE)
end)
group("block 5", function()
  -- No session coverage: no Pass line, so nothing to label.
  local hud = frame({ day = 0.57, session = 0, product = "UREA" })
  T.eq("E9 no session coverage: the daily line alone, no label", join(hud._fmt_covLines), DAY_LINE)
  local none = frame({ day = 0, session = 0, product = nil })
  T.eq("E10 no coverage at all: no lines", none._fmt_covLines, nil)
end)

-- =====================================================================
-- GROUP D: the coverage rows as drawn
-- =====================================================================
local function drawRows(lines, widthOf, scale, fontScale)
  local drawn = {}
  local saved = { renderText, getTextWidth }
  renderText = function(x, y, size, t) drawn[#drawn + 1] = { x = x, y = y, size = size, text = t } end
  getTextWidth = widthOf
  local hud = setmetatable({}, { __index = SoilHUD })
  local px, cy, pw, s, fontMult = 0.1, 0.5, 0.2, scale or 1.0, fontScale or 1.0
  local ok, res = pcall(hud.drawCoverageLines, hud, lines, px, cy, pw, s, fontMult)
  renderText, getTextWidth = saved[1], saved[2]
  return ok, res, drawn, { px = px, cy = cy, pw = pw, s = s }
end
group("block 6", function()
  local lines = { "short", "also short" }
  local ok, res, drawn, g = drawRows(lines, function(size, t) return size * 0.5 * #t end)
  T.ok("D1 the rows drew (" .. tostring(res) .. ")", ok)
  T.eq("D2 one row per line, in order", #drawn == 2 and (drawn[1].text .. "|" .. drawn[2].text) or "wrong", "short|also short")
  T.near("D3 a row that fits is drawn at full size", drawn[1].size, 0.010, 1e-12)
  T.near("D4 each row has its own slot (the second sits one LINE_H below the first)",
         drawn[1].y - drawn[2].y, SoilHUD.LINE_H * g.s, 1e-12)
  T.near("D5 the returned y is the last row's slot", res, g.cy - 2 * SoilHUD.LINE_H * g.s, 1e-12)
  T.near("D6 rows start at the panel's left edge plus its padding", drawn[1].x, g.px + SoilHUD.PAD * g.s, 1e-12)
end)
group("block 7", function()
  -- A row 1.5x the inner width is drawn at two thirds size, so it ends at the inner edge.
  local pad = SoilHUD.PAD
  local inner = 0.2 - 2 * pad
  local widthOf = function(size, t) return (t == "wide") and size * (inner * 1.5 / 0.010) or size * 0.1 end
  local _, _, drawn = drawRows({ "wide", "narrow" }, widthOf)
  T.near("D7 a row wider than the inner width is drawn smaller to fit", widthOf(drawn[1].size, "wide"), inner, 1e-9)
  T.near("D8 and its size is the full size scaled by inner / width", drawn[1].size, 0.010 / 1.5, 1e-9)
  T.near("D9 the next row is unaffected", drawn[2].size, 0.010, 1e-12)
end)
group("block 8", function()
  -- No text-width function (a bench world): the rows still draw, at full size.
  local drawn = {}
  local saved = { renderText, getTextWidth }
  renderText = function(x, y, size, t) drawn[#drawn + 1] = size end
  getTextWidth = nil
  local ok = pcall(SoilHUD.drawCoverageLines, setmetatable({}, { __index = SoilHUD }), { "x" }, 0.1, 0.5, 0.2, 1.0, 1.0)
  renderText, getTextWidth = saved[1], saved[2]
  T.ok("D10 with no getTextWidth the row still draws, at full size", ok and drawn[1] == 0.010)
end)
group("block 9", function()
  -- At another HUD scale and font size the padding scales with the panel: a row at 1.2x the
  -- inner width is fitted to exactly that inner width, a row that fits keeps the scaled size.
  local s, fm, pw = 1.5, 1.2, 0.2
  local inner = pw - 2 * SoilHUD.PAD * s
  local full = 0.010 * fm * s
  local widthOf = function(size, t) return (t == "wide") and size * (inner * 1.2 / full) or size * (inner * 0.5 / full) end
  local ok, res, drawn = drawRows({ "wide", "fits" }, widthOf, s, fm)
  T.ok("D11 the rows drew at scale 1.5 and font 1.2 (" .. tostring(res) .. ")", ok and #drawn == 2)
  T.near("D12 a wide row is fitted to the scaled inner width", widthOf(drawn[1].size, "wide"), inner, 1e-9)
  T.near("D13 a row that fits keeps the scaled full size", drawn[2].size, full, 1e-12)
  T.near("D14 and each slot is one scaled LINE_H", drawn[1].y - drawn[2].y, SoilHUD.LINE_H * s, 1e-12)
end)

-- =====================================================================
-- GROUP L: the new string in all 27 languages
-- =====================================================================
-- The word the notice uses for "estimated" in a language, from its own _est sentence: the
-- last parenthesised group (ASCII or full width), up to a comma that joins the rate.
local function noticeWord(v)
  local inner
  for g in v:gmatch("%(([^()]*)%)") do inner = g end
  for g in v:gmatch("\239\188\136(.-)\239\188\137") do inner = g end   -- U+FF08 .. U+FF09
  if inner == nil then return nil end
  inner = inner:match("^([^,]+)") or inner
  local ideographic = inner:find("\227\128\129", 1, true)             -- U+3001, the comma before the rate
  if ideographic then inner = inner:sub(1, ideographic - 1) end
  return inner
end
local function stripParens(v)
  return v:match("^%((.-)%)$") or v:match("^\239\188\136(.-)\239\188\137$")
end
local missing, twice, copies, specs, dashes, hashes, words = {}, {}, {}, {}, {}, {}, {}
for _, l in ipairs(LANGS) do
  local e = LANG[l].sf_hud_pass_estimated
  if e == nil then
    missing[#missing + 1] = l
  else
    if COUNT[l].sf_hud_pass_estimated ~= 1 then twice[#twice + 1] = l end
    if l ~= "en" and e.v == EN.sf_hud_pass_estimated then copies[#copies + 1] = l end
    if e.v:find("%%") then specs[#specs + 1] = l end
    if e.v:find("-", 1, true) or e.v:find("\226\128\148", 1, true) or e.v:find("\226\128\147", 1, true) then dashes[#dashes + 1] = l end
    if e.eh ~= LANG.en.sf_hud_pass_estimated.eh then hashes[#hashes + 1] = l end
    local nw = noticeWord(LANG[l].sf_notify_pass_body_est and LANG[l].sf_notify_pass_body_est.v or "")
    if nw == nil or stripParens(e.v) ~= nw then words[#words + 1] = l .. ":" .. tostring(stripParens(e.v)) .. "~" .. tostring(nw) end
  end
end
T.eq("L1 the key is in all 27 languages", table.concat(missing, ","), "")
T.eq("L2 and once in each", table.concat(twice, ","), "")
T.eq("L3 translated, not the English copy", table.concat(copies, ","), "")
T.eq("L4 no format specifier (the line is joined in code)", table.concat(specs, ","), "")
T.eq("L5 no dash in any language", table.concat(dashes, ","), "")
T.eq("L6 every entry carries the English text's hash", table.concat(hashes, ","), "")
T.eq("L6b and that hash is md5 of the English text, the first 8 hex digits (lang_sync's get_hash)",
     LANG.en.sf_hud_pass_estimated and LANG.en.sf_hud_pass_estimated.eh, "f8db73c1")
T.eq("L7 each language says it with the word its own notice uses", table.concat(words, ","), "")
local unread = {}
for _, l in ipairs(LANGS) do
  if (SOURCE_TEXT["translations/translation_" .. l .. ".xml"] or "") == "" then unread[#unread + 1] = l end
end
T.eq("L8 every one of the 27 language files was read, none empty", table.concat(unread, ","), "")
T.eq("L9 and the list has all twenty-seven", #LANGS, 27)

-- =====================================================================
-- GROUP P: the real drawPanel, from the same world
-- =====================================================================
local function drawWholePanel(hud)
  local texts = {}
  local saved = { renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth }
  renderText = function(x, y, size, t) texts[#texts + 1] = { x = x, y = y, size = size, text = t } end
  setTextAlignment = function() end; setTextColor = function() end; setTextBold = function() end
  getTextWidth = function(size, t) return size * 0.3 * #tostring(t) end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  hud.visible = true
  local ok, err = pcall(hud.drawPanel, hud)
  renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth = saved[1], saved[2], saved[3], saved[4], saved[5]
  return ok, err, texts
end
local function textAt(texts, s)
  for _, t in ipairs(texts) do if t.text == s then return t end end
  return nil
end
group("P", function()
  local hud = frame({ day = 0.57, session = 0.57, product = "UREA" })
  local ok, err, texts = drawWholePanel(hud)
  T.ok("P1 the panel drew (" .. tostring(err) .. ")", ok)
  local day  = textAt(texts, DAY_LINE)
  local pass = textAt(texts, PASS_UREA .. " " .. SAVE)
  T.ok("P2 the daily coverage line reaches the screen as it was", day ~= nil)
  T.ok("P3 the Pass line reaches the screen with its label", pass ~= nil)
  T.ok("P4 the Pass line sits one slot below the daily line",
       day ~= nil and pass ~= nil and math.abs((day.y - pass.y) - SoilHUD.LINE_H * hud.scale) < 1e-9)
  local hud2 = frame({ day = 0.57, session = 0.57, product = "UREA", geometric = true })
  local _, _, texts2 = drawWholePanel(hud2)
  T.ok("P5 with boom cells the Pass line reaches the screen without it", textAt(texts2, PASS_UREA) ~= nil
       and textAt(texts2, PASS_UREA .. " " .. SAVE) == nil)
  -- The row under the coverage rows starts where the last one ended.
  local hud3 = frame({ day = 0.57, session = 0.57, product = "UREA", compaction = 40 })
  local _, _, texts3 = drawWholePanel(hud3)
  local pass3 = textAt(texts3, PASS_UREA .. " " .. SAVE)
  local comp3 = textAt(texts3, string.format(EN.sf_hud_compaction, 40))
  T.ok("P6 the compaction row is drawn", comp3 ~= nil)
  T.ok("P7 and sits one slot below the Pass line, not over it",
       pass3 ~= nil and comp3 ~= nil and math.abs((pass3.y - comp3.y) - SoilHUD.LINE_H * hud3.scale) < 1e-9)
end)

-- =====================================================================
-- GROUP Q: the sprayer info panel's stats bar, the same coverage in two cells
-- =====================================================================
local function has(list, s)
  for _, x in ipairs(list) do if x == s then return true end end
  return false
end
local function panelTexts(info)
  g_currentMission.isRunning = true
  g_currentMission.hud = nil
  local drawn = {}
  local saved = { renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth }
  renderText = function(_x, _y, _size, text) drawn[#drawn + 1] = text end
  setTextAlignment = function() end; setTextColor = function() end; setTextBold = function() end
  getTextWidth = function(size, text) return size * 0.3 * #tostring(text) end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  local panel = SoilSprayerInfoPanel.new({}, { enabled = true })
  panel.initialized = true
  panel._cachedSprayer = {}
  panel.getSprayerFillType = function() return { name = "UREA" } end
  panel._detectTimer = 1000
  panel._fieldInfo = info
  panel:update(16)
  local ok, err = pcall(function() panel:draw() end)
  renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth = saved[1], saved[2], saved[3], saved[4], saved[5]
  return ok, err, drawn
end
group("Q", function()
  -- 57% of a 4 ha field is 2.28 ha, the figures the cells show.
  local _, est = frame({ day = 0.57, session = 0.57, product = "UREA" })
  local ok, err, texts = panelTexts(est)
  T.ok("Q1 the sprayer info panel drew (" .. tostring(err) .. ")", ok)
  T.ok("Q2 litre-derived coverage: the PASS cell reads ~57%", has(texts, "~57%"))
  T.ok("Q3 and the session area reads ~2.28 ha", has(texts, "~2.28 ha"))
  T.ok("Q4 neither figure is drawn bare", not has(texts, "57%") and not has(texts, "2.28 ha"))
  T.ok("Q5 the PASS caption is still there", has(texts, "PASS"))
  local _, cnt = frame({ day = 0.57, session = 0.57, product = "UREA", geometric = true })
  local ok2, _, texts2 = panelTexts(cnt)
  T.ok("Q6 coverage counted from boom cells: 57% and 2.28 ha, no tilde", ok2 and has(texts2, "57%") and has(texts2, "2.28 ha")
       and not has(texts2, "~57%") and not has(texts2, "~2.28 ha"))
  -- Before anything is counted, after a reload or a product switch, and on a client, the
  -- session coverage is 0 and the flag is still true: nothing to estimate, so no tilde.
  local _, idle = frame({ day = 0, session = 0, product = nil })
  local ok3, _, texts3 = panelTexts(idle)
  T.eq("Q7 an idle rig (no pass yet): the flag reads true", idle.sessionCoverageEstimated, true)
  T.ok("Q8 and the panel shows 0% and 0.00 ha with no tilde", ok3 and has(texts3, "0%") and has(texts3, "0.00 ha")
       and not has(texts3, "~0%") and not has(texts3, "~0.00 ha"))
  local _, switched = frame({ day = 0.57, session = 0, product = "UREA" })
  local _, _, texts4 = panelTexts(switched)
  T.ok("Q9 a product switch (coverage reset to 0): no tilde either", has(texts4, "0%") and not has(texts4, "~0%"))
  local _, begun = frame({ day = 0, session = 0.004, product = "UREA" })
  local _, _, texts5 = panelTexts(begun)
  T.ok("Q10 a pass just begun (0.4% of the field) is a pass under way: it carries its tilde",
       has(texts5, "~0%") and has(texts5, "~0.02 ha"))
end)

-- SF-1063-w4_map_base_rate_test.lua
--
-- #1063 W4: 1.0x is the map's own base application rate for the product, not BASE_RATES
-- standing in for a rate the map never gave (the 2026-10-02 coverage and 1.0x ruling,
-- section 2). BASE_RATES carries 225 kg/ha for the base game's FERTILIZER, 93.5 L/ha for
-- LIQUIDFERTILIZER and a 93.5 L/ha DEFAULT for any other fill type, while the map's own spray
-- types drain 216 L/ha (180 on Homeland), 291.6 L/ha and whatever else they carry. The
-- rate readout and the ghost bar showed the table's figure. They now show the spray type's:
-- the native rate the usage formula uses (HookManager.getNativeSprayRatePerHa), in the
-- product's public unit. A product the map has no spray type for has no rate, and the
-- readout shows the multiplier alone, never an invented amount.
--
-- THE ENTRY-POINT BAR. The real SoilHUD (SoilHUD.new) runs its real update(), which reads
-- the sprayer the player sits in. Group R draws the rate row through the real
-- drawSprayerRatePanel (the current amount and the four neighbouring steps) and group G
-- draws the ghost bar through the real drawNutrientRow with the HUD's cached state. The
-- fixture supplies the world only: the player in a sprayer holding one product, the spray
-- type manager as a map registers it, the field record and the settings. Every expected
-- figure is worked out here from the spray type's litres per second, not read from the HUD.
-- Group C pins the resolver's own contract (HookManager.getMapBaseRate).
--
-- Groups:
--   R  the rate row: base game FERTILIZER on two maps, LIQUIDFERTILIZER, Soil's own dry and
--      liquid products unchanged, a map product BASE_RATES never named, a product with no
--      spray type, a usage scale, imperial units, the edit-mode placeholder
--   G  the ghost bar sized from the map's rate, and none where there is no rate
--   C  the resolver: nothing to read, a bad litres per second, the unit class, the
--      litres-to-mass conversion, the usage scale
--
-- What this bar does NOT prove: the look of the panel on screen and the real maps' spray
-- types. The TESTING row names those observations.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ui/SoilHUD.lua

SoilLogger.debug = function() end
SoilLogger.info = function() end

local SR  = SoilConstants.SPRAYER_RATE
local BR  = SR.BASE_RATES
local PF  = SoilConstants.FERTILIZER_PROFILES
local RR  = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[3]
local THR = SR.FERTILIZER_COVERAGE_THRESHOLD or 0.90
local STEPS = SR.STEPS
local IDX = SR.DEFAULT_INDEX

-- ── the fill types the world holds ──────────────────────────────────────────
local FT = {
  FERTILIZER      = { name = "FERTILIZER",      index = 42, massPerLiter = 0.001   },  -- base game, passthrough
  LIQUIDFERTILIZER= { name = "LIQUIDFERTILIZER",index = 43, massPerLiter = 0.001   },  -- base game liquid
  UREA            = { name = "UREA",            index = 50, massPerLiter = 0.00077 },  -- one of the twelve dry
  UAN32           = { name = "UAN32",           index = 51, massPerLiter = 0.001   },  -- Soil's own liquid
  MAPPELLETS      = { name = "MAPPELLETS",      index = 70, massPerLiter = 0.001   },  -- a map's own product
}
local BY_INDEX = {}
for _, ft in pairs(FT) do BY_INDEX[ft.index] = ft end
FillType = FillType or { UNKNOWN = 0 }
g_fillTypeManager = { getFillTypeByIndex = function(_, i) return BY_INDEX[i] end,
                      getFillTypeByName  = function(_, n) return FT[n] end }
g_i18n = { texts = {}, hasText = function() return false end, getText = function(_, k) return k end }

-- The spray types as a map registers them: litres per second per fill type index. Soil's own
-- products are registered as registerCustomSprayTypes does (a dry product's kg/ha over its
-- density, a liquid's L/ha, both over 36000); the base game's carry the map's own figure.
local SPRAY = {}
local function sprayAsSoilRegisters(ft)
  local kgPerLiter = HookManager.rateKgPerLiter(ft) or 1
  SPRAY[ft.index] = (BR[ft.name].value / kgPerLiter) / 36000
end
g_sprayTypeManager = { getSprayTypeByFillTypeIndex = function(_, i)
  local lps = SPRAY[i]
  if lps == nil then return nil end
  return { litersPerSecond = lps }
end }

-- ── the world: the player in a sprayer holding one product ──────────────────
local function newSprayer(ft, scales)
  local v = { id = 4242, isServer = true,
              spec_sprayer = { workAreaParameters = { sprayFillType = ft.index }, usageScale = scales } }
  v.rootVehicle = v
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function() return ft.index end
  v.getFillUnitLastValidFillType = function() return ft.index end
  v.getFillUnitFillLevel = function() return 500 end
  return v
end

local FIELD = { fieldArea = 2.0 }
local function world(ft, opts)
  opts = opts or {}
  g_server = {}
  g_currentMission = { time = 10000 }
  local settings = { enabled = true, autoRateControl = false, replenishmentRate = 3, hudPosition = 1,
                     useImperialUnits = opts.imperial == true }
  local ss = setmetatable({ fieldData = {}, settings = settings }, { __index = SoilFertilitySystem })
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  local sprayer = ft and newSprayer(ft, opts.scales) or nil
  g_localPlayer = { getIsInVehicle = function() return sprayer ~= nil end,
                    getCurrentVehicle = function() return sprayer end }
  local hud = SoilHUD.new(ss, settings)
  hud.fieldDetectTimer = 0
  hud._heightDirty = false
  hud.lastHudPosition = settings.hudPosition
  if opts.edit then hud.editMode = true end
  hud:update(16)
  return hud, sprayer
end

-- ── the rate panel, drawn as draw() draws it; the texts it renders ──────────
local function drawPanel(hud)
  local texts = {}
  local saved = { renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth }
  renderText = function(_x, _y, _size, t) texts[#texts + 1] = t end
  setTextAlignment = function() end
  setTextColor = function() end
  setTextBold = function() end
  getTextWidth = function(size, t) return size * 0.3 * #tostring(t) end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  local ok, err = pcall(hud.drawSprayerRatePanel, hud)
  renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth = saved[1], saved[2], saved[3], saved[4], saved[5]
  return ok, err, texts
end
local function has(texts, s) for _, t in ipairs(texts) do if t == s then return true end end return false end
local function anyUnit(texts)
  for _, t in ipairs(texts) do
    if type(t) == "string" and (t:find("kg/ha", 1, true) or t:find("L/ha", 1, true)
        or t:find("lb/ac", 1, true) or t:find("gal/ac", 1, true)) then return t end
  end
  return nil
end

-- The amount the readout should draw at a step: the map's litres per hectare (lps x 36000),
-- as mass for the twelve dry products, to the HUD's own rounding.
local function amount(ft, lps, step)
  local value = lps * 36000 * (HookManager.rateKgPerLiter(ft) or 1) * step
  return value
end
local function metric(value, unit) return string.format("%.0f %s", value, unit) end
local STEP_OFFSETS = { -2, -1, 1, 2 }

-- =====================================================================
-- GROUP R: the rate row, through the real drawSprayerRatePanel
-- =====================================================================
do
  -- The base game's FERTILIZER on a map whose spray type drains 216 L/ha (0.006).
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.006
  local hud = world(FT.FERTILIZER)
  local ok, err, texts = drawPanel(hud)
  T.ok("R1 the rate panel drew (" .. tostring(err) .. ")", ok)
  T.ok("R2 FERTILIZER reads the map's 216, not the table's 225", has(texts, "216 kg/ha"))
  T.ok("R3 and the table's figure is not drawn", not has(texts, "225 kg/ha"))
  for _, off in ipairs(STEP_OFFSETS) do
    local want = string.format("%.0f", amount(FT.FERTILIZER, 0.006, STEPS[IDX + off]))
    T.ok("R4 neighbouring step " .. off .. " reads " .. want, has(texts, want))
  end
end
do
  -- The same product on Homeland, whose spray type drains 180 L/ha (0.005): the report's map.
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.005
  local hud = world(FT.FERTILIZER)
  local _, _, texts = drawPanel(hud)
  T.ok("R5 on a map with 0.005 L/s the same product reads 180", has(texts, "180 kg/ha"))
end
do
  -- LIQUIDFERTILIZER: the table says 93.5 L/ha, the base game's spray type 0.0081 = 291.6.
  SPRAY = {}; SPRAY[FT.LIQUIDFERTILIZER.index] = 0.0081
  local hud = world(FT.LIQUIDFERTILIZER)
  local _, _, texts = drawPanel(hud)
  T.ok("R6 LIQUIDFERTILIZER reads the map's 292 L/ha", has(texts, "292 L/ha"))
  T.ok("R7 and not the table's 94", not has(texts, "94 L/ha"))
end
do
  -- Soil's own dry product, registered as production registers it: 168 kg/ha, as before.
  SPRAY = {}; sprayAsSoilRegisters(FT.UREA)
  local hud = world(FT.UREA)
  local _, _, texts = drawPanel(hud)
  T.ok("R8 UREA, one of the twelve, still reads its registered 168 kg/ha", has(texts, "168 kg/ha"))
  T.ok("R9 never the litres figure (218) in the mass unit", not has(texts, "218 kg/ha"))
  -- and a liquid of Soil's own
  SPRAY = {}; sprayAsSoilRegisters(FT.UAN32)
  local hud2 = world(FT.UAN32)
  local _, _, texts2 = drawPanel(hud2)
  T.ok("R10 UAN32 still reads its registered 61 L/ha", has(texts2, "61 L/ha"))
end
do
  -- A product the map added that BASE_RATES never named: its spray type's own rate, as litres.
  SPRAY = {}; SPRAY[FT.MAPPELLETS.index] = 0.0072     -- 259.2 L/ha
  local hud = world(FT.MAPPELLETS)
  local _, _, texts = drawPanel(hud)
  T.ok("R11 a map's own product reads its spray type's 259 L/ha", has(texts, "259 L/ha"))
  T.ok("R12 and not the DEFAULT's 94", not has(texts, "94 L/ha"))
end
do
  -- A product with no spray type at all: no rate, so the multiplier alone, no amount.
  SPRAY = {}
  local hud = world(FT.MAPPELLETS)
  local ok, err, texts = drawPanel(hud)
  T.ok("R13 the panel drew with no spray type (" .. tostring(err) .. ")", ok)
  T.ok("R14 the readout is the multiplier alone", has(texts, "1.00x"))
  T.eq("R15 no amount in any unit is drawn", anyUnit(texts), nil)
  for _, off in ipairs(STEP_OFFSETS) do
    local want = string.format("%.2f", STEPS[IDX + off])
    T.ok("R16 neighbouring step " .. off .. " reads the multiplier " .. want, has(texts, want))
  end
end
do
  -- A sprayer's own usage scale is part of the rate the usage formula applies.
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.006
  local hud = world(FT.FERTILIZER, { scales = { default = 1, fillTypeScales = { [FT.FERTILIZER.index] = 0.5 } } })
  local _, _, texts = drawPanel(hud)
  T.ok("R17 a 0.5 usage scale halves the rate to 108", has(texts, "108 kg/ha"))
end
do
  -- Imperial units: the same map rate, converted by the table's own factor.
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.006
  local hud = world(FT.FERTILIZER, { imperial = true })
  local _, _, texts = drawPanel(hud)
  T.ok("R18 imperial: 216 kg/ha shows as lb/ac", has(texts, string.format("%.0f lb/ac", 216 * SR.KG_PER_HA_TO_LB_PER_AC)))
  SPRAY = {}; SPRAY[FT.LIQUIDFERTILIZER.index] = 0.0081
  local hud2 = world(FT.LIQUIDFERTILIZER, { imperial = true })
  local _, _, texts2 = drawPanel(hud2)
  T.ok("R19 imperial: 291.6 L/ha shows as gal/ac", has(texts2, string.format("%.0f gal/ac", 291.6 * SR.L_PER_HA_TO_GAL_PER_AC)))
end
do
  -- Edit mode with no sprayer only previews the layout: the placeholder stays.
  SPRAY = {}
  local hud = world(nil, { edit = true })
  local ok, err, texts = drawPanel(hud)
  T.ok("R20 the edit-mode preview drew with no sprayer (" .. tostring(err) .. ")", ok)
  T.ok("R21 and keeps the placeholder rate", has(texts, "94 L/ha"))
end

-- =====================================================================
-- GROUP G: the ghost bar, through the real drawNutrientRow
-- =====================================================================
local function drawN(hud, ft, bufferLiters)
  local saved = { renderText = renderText, setTextAlignment = setTextAlignment, setTextColor = setTextColor,
                  getTextWidth = getTextWidth, setTextBold = setTextBold, hud = g_currentMission.masterHUD }
  local bars = {}
  renderText = function() end; setTextAlignment = function() end; setTextColor = function() end
  setTextBold = function() end; getTextWidth = function() return 0.01 end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  g_currentMission.masterHUD = { renderer = { renderProgressBar = function(_r, _x, _y, _w, _h, fill, _c, total)
    bars[#bars + 1] = { fill = fill, total = total } return true end } }
  local info = { fieldArea = FIELD.fieldArea, nutrientBuffer = { [ft.index] = bufferLiters } }
  local ok, err = pcall(hud.drawNutrientRow, hud, "N", "N", { value = 50, status = "Fair" }, 0.1, 0.5, 0.3, 1, 1,
    info, hud._cachedProfile, hud._cachedFillType, hud._cachedRateMult, nil)
  renderText, setTextAlignment, setTextColor = saved.renderText, saved.setTextAlignment, saved.setTextColor
  getTextWidth, setTextBold, g_currentMission.masterHUD = saved.getTextWidth, saved.setTextBold, saved.hud
  local ghost = bars[1] and (bars[1].total - bars[1].fill) or nil
  return ok, err, ghost
end
-- The ghost for this field and product, worked out from the spray type (independent of the HUD).
local function expectedGhost(ft, lps, buffer)
  local rate = lps * 36000 * (HookManager.rateKgPerLiter(ft) or 1)
  local threshold = FIELD.fieldArea * rate * THR
  local remaining = math.max(0, threshold - buffer * (HookManager.rateKgPerLiter(ft) or 1))
  local projected = PF[ft.name].N * (remaining / 1000) / FIELD.fieldArea * RR
  return math.min(1.0 - 0.5, projected / 100)
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-12 end
do
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.006
  local hud = world(FT.FERTILIZER)
  local ok, err, ghost = drawN(hud, FT.FERTILIZER, 200)
  T.ok("G1 the row drew (" .. tostring(err) .. ")", ok)
  T.ok("G2 the ghost is sized from the map's 216 (" .. tostring(ghost) .. ")", near(ghost, expectedGhost(FT.FERTILIZER, 0.006, 200)))
  -- the table's 225 would size it differently; the two figures are not within tolerance
  local fromTable = math.min(0.5, PF.FERTILIZER.N * (math.max(0, 2.0 * BR.FERTILIZER.value * THR - 200) / 1000) / 2.0 * RR / 100)
  T.ok("G3 which is not the table's figure", not near(ghost, fromTable))
end
do
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.005     -- Homeland
  local hud = world(FT.FERTILIZER)
  local _, _, ghost = drawN(hud, FT.FERTILIZER, 200)
  T.ok("G4 on a map with 0.005 L/s the ghost follows 180", near(ghost, expectedGhost(FT.FERTILIZER, 0.005, 200)))
end
do
  -- Soil's own dry product: the registered rate and the litres-to-mass conversion, as before.
  SPRAY = {}; sprayAsSoilRegisters(FT.UREA)
  local hud = world(FT.UREA)
  local _, _, ghost = drawN(hud, FT.UREA, 200)
  T.ok("G5 UREA's ghost is unchanged (168 kg/ha, buffer converted)", near(ghost, expectedGhost(FT.UREA, SPRAY[FT.UREA.index], 200)))
end
do
  -- No spray type, no rate: no projection, so the bar draws no ghost.
  SPRAY = {}
  local hud = world(FT.FERTILIZER)
  local ok, err, ghost = drawN(hud, FT.FERTILIZER, 200)
  T.ok("G6 the row drew with no spray type (" .. tostring(err) .. ")", ok)
  T.eq("G7 and shows no ghost", ghost, 0)
end

-- =====================================================================
-- GROUP C: the resolver's own contract
-- =====================================================================
do
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.006
  local r = HookManager.getMapBaseRate(nil, FT.FERTILIZER)
  T.ok("C1 a rate comes back", r ~= nil)
  T.near("C2 it is the spray type's litres per second x 36000", r.value, 216, 1e-9)
  T.eq("C3 in the table's unit class for the product (FERTILIZER is dry)", r.unit, "dry")
  T.eq("C4 LIQUIDFERTILIZER is liquid", (function() SPRAY[FT.LIQUIDFERTILIZER.index] = 0.0081
        return HookManager.getMapBaseRate(nil, FT.LIQUIDFERTILIZER).unit end)(), "liquid")
  SPRAY[FT.MAPPELLETS.index] = 0.0072
  T.eq("C5 a product the table never named is liquid", HookManager.getMapBaseRate(nil, FT.MAPPELLETS).unit, "liquid")
  T.near("C6 and carries its own spray type's rate, not DEFAULT's", HookManager.getMapBaseRate(nil, FT.MAPPELLETS).value, 259.2, 1e-9)
end
do
  SPRAY = {}; sprayAsSoilRegisters(FT.UREA)
  local r = HookManager.getMapBaseRate(nil, FT.UREA)
  T.near("C7 a dry product's litres are converted to its kg/ha (litres x density)", r.value, 168, 1e-9)
  T.eq("C8 and stay in the dry unit", r.unit, "dry")
end
do
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = 0.006
  local sprayer = newSprayer(FT.FERTILIZER, { default = 1, fillTypeScales = { [FT.FERTILIZER.index] = 0.5 } })
  T.near("C9 the sprayer's usage scale for the product applies", HookManager.getMapBaseRate(sprayer, FT.FERTILIZER).value, 108, 1e-9)
  local plain = newSprayer(FT.FERTILIZER, { default = 2 })
  T.near("C10 its default scale applies when the product has none", HookManager.getMapBaseRate(plain, FT.FERTILIZER).value, 432, 1e-9)
end
do
  SPRAY = {}
  T.eq("C11 no spray type: unavailable", HookManager.getMapBaseRate(nil, FT.FERTILIZER), nil)
  T.eq("C12 no fill type: unavailable", HookManager.getMapBaseRate(nil, nil), nil)
  T.eq("C13 a fill type with no index: unavailable", HookManager.getMapBaseRate(nil, { name = "FERTILIZER" }), nil)
  for _, bad in ipairs({ 0, -0.001, 0 / 0 }) do
    SPRAY = {}; SPRAY[FT.FERTILIZER.index] = bad
    T.eq("C14 a litres per second of " .. tostring(bad) .. ": unavailable", HookManager.getMapBaseRate(nil, FT.FERTILIZER), nil)
  end
  SPRAY = {}; SPRAY[FT.FERTILIZER.index] = "fast"
  T.eq("C15 a non-number litres per second: unavailable", HookManager.getMapBaseRate(nil, FT.FERTILIZER), nil)
  local saved = g_sprayTypeManager
  g_sprayTypeManager = nil
  T.eq("C16 no spray type manager: unavailable", HookManager.getMapBaseRate(nil, FT.FERTILIZER), nil)
  g_sprayTypeManager = saved
end

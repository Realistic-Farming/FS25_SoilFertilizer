-- handful_panel_sf39_test.lua - THE HANDFUL PANEL (SF-39)
--
-- The reading surface for the kneel. It renders the FROZEN SF-38 payload and
-- writes nothing, so the whole bench is: given a payload, what text appears.
--
-- The properties locked here are the SF-38 cert gates as they land on a screen:
--   PER-CLAUSE NEUTRALITY - an absent clause renders a dash. NEVER a zero. This
--     is the one that actually bites: nil-defaulted-to-zero is how a panel tells
--     a player their nitrogen is empty when the truth is that nobody measured it.
--   GRAIN HONESTY - the disease line says whether it is the knelt cell or the
--     whole field, driven by the payload's own diseaseGrain label.
--   BANDS NOT NUMBERS - readTestKit() is a hardcoded false until the kit member
--     ships, so every gated clause renders a word. A raw figure leaking onto the
--     panel would be the kit bypassing its own gate.
--   NO PHANTOM FIELDS - every clause the panel draws is a name in
--     HandfulRead.CLAUSES; the panel invents no read of its own.
--   THE MATERIAL SECTION HIDES when nothing lies under the hand, rather than
--     rendering an "unavailable" status as if it were a measurement.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialScouting.lua, src/HandfulRead.lua, src/ui/SoilHandfulDialog.lua

-- Force tr() down its fallback path so assertions read as the English the player
-- sees, not as key names. getText returning "" is exactly the "key absent" case.
g_i18n = { getText = function(_self, _key) return "" end, hasText = function() return false end }

local function el()
  local e = { text = "", visible = true }
  e.setText = function(_self, t) e.text = t or "" end
  e.setVisible = function(_self, v) e.visible = v end
  return e
end

local IDS = {
  "hfHeader", "hfNutrients", "hfPhOm", "hfGround", "hfDisease", "hfPestWeed",
  "hfCrops", "hfRotation", "hfOrganic", "hfSecMaterial", "hfMaterial", "hfFooter",
}

local function newPanel(payload)
  local self = { _payload = payload }
  for _, id in ipairs(IDS) do self[id] = el() end
  return self
end

local function render(payload)
  local p = newPanel(payload)
  SoilHandfulDialog._populate(p)
  return p
end

-- Sentinel for "override this clause to absent". A literal nil cannot do the job:
-- assigning nil to a table key removes it, so pairs() never sees the override and
-- the clause silently keeps its healthy value. That misfire is exactly how an
-- absent-clause test passes while testing nothing.
local NIL = {}

-- A full, healthy payload in the exact shape HandfulRead.assemble returns.
local function fullPayload(over)
  local p = {
    fieldId = 7,
    fromZoneCell = true,
    N = { value = 42, status = "Good" },
    P = { value = 30, status = "Fair" },
    K = { value = 12, status = "Poor" },
    pH = 6.5,
    OM = 4.2,
    compaction = 18,
    moisture = 0.47,
    diseasePressure = 60,
    diseaseGrain = "cell",
    diseaseKnown = true,
    pestPressure = 10,
    weedPressure = 55,
    lastCrop = "wheat", lastCrop2 = "barley", lastCrop3 = "canola",
    rotationStatus = "Bonus",
    rotationBonusDaysLeft = 5,
    daysSinceHarvest = 12,
    organicState = { state = 2, daysAccrued = 40, transitionDaysNeeded = 90, certified = false, breaches = 0 },
    materialWetness = { pct = 30, band = "damp" },
    materialDaysDown = { days = 3, band = "settling" },
    materialVerdict = { status = "ok", spoiled = false },
    testKitActive = false,
    clauses = HandfulRead.CLAUSES,
  }
  for k, v in pairs(over or {}) do
    if v == NIL then p[k] = nil else p[k] = v end
  end
  return p
end

local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

-- ── PER-CLAUSE NEUTRALITY: absent is a dash, never a zero ───────────────────
do
  -- Every optional clause stripped at once: one absent system must not take the
  -- panel down with it, and must not become a confident zero.
  local p = render({ fieldId = 3, clauses = HandfulRead.CLAUSES })

  T.ok("an empty payload still renders a header", has(p.hfHeader.text, "3"))
  T.ok("absent N renders a dash", has(p.hfNutrients.text, "--"))
  T.ok("absent N never renders as zero", not has(p.hfNutrients.text, ": 0"))
  T.ok("absent pH and OM render dashes", has(p.hfPhOm.text, "--"))
  T.ok("absent compaction renders a dash", has(p.hfGround.text, "--"))
  T.ok("absent moisture never renders 0%", not has(p.hfGround.text, "0%"))
  T.ok("absent crop history renders a dash", has(p.hfCrops.text, "--"))
  T.ok("absent organic state renders a dash", has(p.hfOrganic.text, "--"))
end

do
  -- The narrow case the rule exists for: SCS absent blanks moisture ONLY, and
  -- every neighbouring clause on the same row survives.
  local p = render(fullPayload({ moisture = NIL }))
  T.ok("SCS absent blanks moisture alone", has(p.hfGround.text, "--"))
  T.ok("SCS absent leaves compaction intact", has(p.hfGround.text, "Low"))
  T.ok("SCS absent leaves the nutrient row intact", has(p.hfNutrients.text, "Good"))
end

-- ── BANDS, NOT NUMBERS ──────────────────────────────────────────────────────
do
  local p = render(fullPayload())
  T.ok("N renders its band word", has(p.hfNutrients.text, "Good"))
  T.ok("P renders its band word", has(p.hfNutrients.text, "Fair"))
  T.ok("K renders its band word", has(p.hfNutrients.text, "Poor"))
  -- The kit is false, so the raw figure must not reach the screen.
  T.ok("the raw N figure never leaks while the kit is absent", not has(p.hfNutrients.text, "42"))
  T.ok("the footer explains why the readings are words", has(p.hfFooter.text, "No soil test kit"))
end

do
  -- pH bands ride SoilConstants.REPORT_COLORS; no threshold is invented here.
  local rc = SoilConstants.REPORT_COLORS
  T.ok("pH inside the good band reads Good",
    has(render(fullPayload({ pH = rc.PH_GOOD_LOW })).hfPhOm.text, "Good"))
  T.ok("pH below the fair floor reads Acidic",
    has(render(fullPayload({ pH = rc.PH_FAIR_LOW - 0.1 })).hfPhOm.text, "Acidic"))
  T.ok("pH above the fair ceiling reads Alkaline",
    has(render(fullPayload({ pH = rc.PH_FAIR_HIGH + 0.1 })).hfPhOm.text, "Alkaline"))
  T.ok("OM under the fair floor reads Poor",
    has(render(fullPayload({ OM = rc.OM_FAIR - 0.1 })).hfPhOm.text, "Poor"))
end

do
  -- Compaction reuses the cut points the shipped map layer displays against.
  T.ok("compaction under 25 reads Low",     has(render(fullPayload({ compaction = 24 })).hfGround.text, "Low"))
  T.ok("compaction at 25 reads Moderate",   has(render(fullPayload({ compaction = 25 })).hfGround.text, "Moderate"))
  T.ok("compaction at 60 reads High",       has(render(fullPayload({ compaction = 60 })).hfGround.text, "High"))
end

do
  -- Pressure tiers ride SoilConstants.DISEASE_PRESSURE, the same ladder scoutField uses.
  local dp = SoilConstants.DISEASE_PRESSURE
  T.ok("pressure below LOW reads None",     has(render(fullPayload({ pestPressure = dp.LOW - 1 })).hfPestWeed.text, "None"))
  T.ok("pressure at LOW reads Mild",        has(render(fullPayload({ pestPressure = dp.LOW })).hfPestWeed.text, "Mild"))
  T.ok("pressure at MEDIUM reads Moderate", has(render(fullPayload({ pestPressure = dp.MEDIUM })).hfPestWeed.text, "Moderate"))
  T.ok("pressure at HIGH reads Severe",     has(render(fullPayload({ pestPressure = dp.HIGH })).hfPestWeed.text, "Severe"))
end

-- ── GRAIN HONESTY ───────────────────────────────────────────────────────────
do
  T.ok("a knelt cell is labelled as this cell",
    has(render(fullPayload({ diseaseGrain = "cell" })).hfDisease.text, "this cell"))
  T.ok("field grain is labelled as the field average",
    has(render(fullPayload({ diseaseGrain = "field" })).hfDisease.text, "field average"))
  T.ok("a refined nutrient read is labelled spot",
    has(render(fullPayload({ fromZoneCell = true })).hfHeader.text, "spot"))
  T.ok("an unrefined nutrient read is labelled field average",
    has(render(fullPayload({ fromZoneCell = false })).hfHeader.text, "field average"))
end

do
  -- The knowledge gate: shownDiseasePressure is nil until scouted, and that is an
  -- answer, not a hole. Rendering it as None would sell a clean bill of health
  -- for a field nobody has looked at.
  local p = render(fullPayload({ diseasePressure = NIL }))
  T.ok("unscouted disease says so", has(p.hfDisease.text, "Unscouted"))
  T.ok("unscouted disease never reads as None", not has(p.hfDisease.text, "None"))
  T.ok("unscouted disease never reads as zero", not has(p.hfDisease.text, ": 0"))
end

-- ── THE MATERIAL SECTION HIDES WHEN THERE IS NOTHING UNDER THE HAND ─────────
do
  local shown = render(fullPayload())
  T.ok("material section shows when material lies there", shown.hfSecMaterial.visible == true)
  T.ok("material row renders its wetness band", has(shown.hfMaterial.text, "Damp"))
  T.ok("material row renders days down", has(shown.hfMaterial.text, "3"))
  T.ok("a sound verdict renders", has(shown.hfMaterial.text, "Sound"))

  local bare = render(fullPayload({
    materialWetness  = { status = "unavailable" },
    materialDaysDown = { status = "unavailable" },
    materialVerdict  = { status = "refusal", reason = "no material fill type supplied" },
  }))
  T.ok("material section hides on an absent-material payload", bare.hfSecMaterial.visible == false)
  T.ok("material row hides too", bare.hfMaterial.visible == false)
  T.ok("a refusal status is never rendered as a value", not has(bare.hfMaterial.text, "unavailable"))
end

-- ── NO PHANTOM FIELDS ───────────────────────────────────────────────────────
do
  -- Every clause the panel draws must be a name the frozen contract publishes.
  local known = {}
  for _, name in ipairs(HandfulRead.CLAUSES) do known[name] = true end
  local drawn = {
    "N", "P", "K", "pH", "OM", "compaction", "moisture", "diseasePressure",
    "pestPressure", "weedPressure", "lastCrop", "lastCrop2", "lastCrop3",
    "rotationStatus", "rotationBonusDaysLeft", "daysSinceHarvest", "organicState",
    "materialWetness", "materialDaysDown", "materialVerdict", "testKitActive",
  }
  local missing = nil
  for _, name in ipairs(drawn) do
    if not known[name] then missing = name break end
  end
  T.ok("the panel draws only clauses the frozen contract publishes", missing == nil, missing)
end

-- ── A nil payload must not crash the surface ────────────────────────────────
do
  local p = render(nil)
  T.ok("a nil payload renders a spoken refusal", has(p.hfHeader.text, "Nothing read"))
end

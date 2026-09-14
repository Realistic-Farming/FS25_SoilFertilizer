-- handful_panel_sf39_test.lua - THE HANDFUL PANEL (SF-39)
--
-- The reading surface for the kneel. It renders the FROZEN SF-38 payload and
-- writes nothing, so the whole bench is: given a payload, what appears.
--
-- The properties locked here are the SF-38 cert gates as they land on a screen:
--   PER-CLAUSE NEUTRALITY - an absent clause renders a dash. NEVER a zero. This
--     is the one that actually bites: nil-defaulted-to-zero is how a panel tells
--     a player their nitrogen is empty when the truth is that nobody measured it.
--   COLOUR IS A SECOND CHANNEL - the word always says the thing, and an absent
--     or unknown reading takes the NEUTRAL grey. A clause nobody measured must
--     never wear a severity colour, or absence reads as a verdict.
--   GRAIN HONESTY - the disease tile says whether it is the knelt cell or the
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
  local e = { text = "", visible = true, color = nil }
  e.setText = function(_self, t) e.text = t or "" end
  e.setVisible = function(_self, v) e.visible = v end
  e.setTextColor = function(_self, r, g, b, a) e.color = { r, g, b, a } end
  return e
end

local IDS = {
  "hfField", "hfGrain",
  "hfLblN", "hfValN", "hfLblP", "hfValP", "hfLblK", "hfValK",
  "hfLblPh", "hfValPh", "hfLblOm", "hfValOm",
  "hfLblComp", "hfValComp", "hfLblMoist", "hfValMoist",
  "hfLblDis", "hfValDis", "hfLblPest", "hfValPest", "hfLblWeed", "hfValWeed",
  "hfDisGrain", "hfCrops", "hfRotation", "hfOrganic",
  "hfSecMaterial", "hfLblWet", "hfValWet", "hfLblDown", "hfValDown",
  "hfLblVerdict", "hfValVerdict", "hfFooter",
}

local function render(payload)
  local p = { _payload = payload }
  for _, id in ipairs(IDS) do p[id] = el() end
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
local function sameColor(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for i = 1, 4 do if a[i] ~= b[i] then return false end end
  return true
end

-- ── PER-CLAUSE NEUTRALITY: absent is a dash, never a zero ───────────────────
do
  -- Every optional clause stripped at once: one absent system must not take the
  -- panel down with it, and must not become a confident zero.
  local p = render({ fieldId = 3, clauses = HandfulRead.CLAUSES })

  T.ok("an empty payload still names the field", has(p.hfField.text, "3"))
  T.eq("absent N renders a dash", p.hfValN.text, "--")
  T.eq("absent pH renders a dash", p.hfValPh.text, "--")
  T.eq("absent compaction renders a dash", p.hfValComp.text, "--")
  T.eq("absent moisture renders a dash, not 0%", p.hfValMoist.text, "--")
  T.ok("absent crop history renders a dash", has(p.hfCrops.text, "--"))
  T.ok("absent organic state renders a dash", has(p.hfOrganic.text, "--"))
end

do
  -- The narrow case the rule exists for: SCS absent blanks moisture ONLY, and
  -- every neighbouring clause survives.
  local p = render(fullPayload({ moisture = NIL }))
  T.eq("SCS absent blanks moisture alone", p.hfValMoist.text, "--")
  T.ok("SCS absent leaves compaction intact", has(p.hfValComp.text, "Low"))
  T.ok("SCS absent leaves the nutrient tiles intact", has(p.hfValN.text, "Good"))
end

-- ── COLOUR IS A SECOND CHANNEL, AND ABSENCE IS NOT A VERDICT ────────────────
do
  local absent  = render({ fieldId = 1 })
  local healthy = render(fullPayload())
  T.ok("an absent clause takes a colour", absent.hfValN.color ~= nil)
  T.ok("an absent clause does NOT wear the colour of a good reading",
    not sameColor(absent.hfValN.color, healthy.hfValN.color))
  T.ok("every absent clause shares one neutral colour",
    sameColor(absent.hfValN.color, absent.hfValComp.color))
end

do
  -- Good, fair and poor must be three visibly different colours, or the second
  -- channel carries no information at all.
  local p = render(fullPayload())
  T.ok("good and fair differ in colour",  not sameColor(p.hfValN.color, p.hfValP.color))
  T.ok("fair and poor differ in colour",  not sameColor(p.hfValP.color, p.hfValK.color))
  T.ok("good and poor differ in colour",  not sameColor(p.hfValN.color, p.hfValK.color))
end

-- ── BANDS, NOT NUMBERS ──────────────────────────────────────────────────────
do
  local p = render(fullPayload())
  T.eq("N renders its band word", p.hfValN.text, "Good")
  T.eq("P renders its band word", p.hfValP.text, "Fair")
  T.eq("K renders its band word", p.hfValK.text, "Poor")
  T.ok("the raw N figure never leaks while the kit is absent", not has(p.hfValN.text, "42"))
  T.ok("the footer explains why the readings are words", has(p.hfFooter.text, "No soil test kit"))
end

do
  -- pH bands ride SoilConstants.REPORT_COLORS; no threshold is invented here.
  local rc = SoilConstants.REPORT_COLORS
  T.eq("pH inside the good band reads Good",
    render(fullPayload({ pH = rc.PH_GOOD_LOW })).hfValPh.text, "Good")
  T.eq("pH below the fair floor reads Acidic",
    render(fullPayload({ pH = rc.PH_FAIR_LOW - 0.1 })).hfValPh.text, "Acidic")
  T.eq("pH above the fair ceiling reads Alkaline",
    render(fullPayload({ pH = rc.PH_FAIR_HIGH + 0.1 })).hfValPh.text, "Alkaline")
  T.eq("OM under the fair floor reads Poor",
    render(fullPayload({ OM = rc.OM_FAIR - 0.1 })).hfValOm.text, "Poor")
end

do
  -- Compaction reuses the cut points the shipped map layer displays against.
  -- Its polarity is inverted from the nutrients: LOW compaction is the GOOD one,
  -- so the colour has to follow the meaning rather than the word.
  local low  = render(fullPayload({ compaction = 24 }))
  local high = render(fullPayload({ compaction = 60 }))
  T.eq("compaction under 25 reads Low",   low.hfValComp.text, "Low")
  T.eq("compaction at 25 reads Moderate", render(fullPayload({ compaction = 25 })).hfValComp.text, "Moderate")
  T.eq("compaction at 60 reads High",     high.hfValComp.text, "High")
  T.ok("LOW compaction is coloured as the good outcome",
    sameColor(low.hfValComp.color, render(fullPayload()).hfValN.color))
  T.ok("HIGH compaction is not coloured as good",
    not sameColor(high.hfValComp.color, low.hfValComp.color))
end

do
  -- Pressure tiers ride SoilConstants.DISEASE_PRESSURE, the same ladder scoutField uses.
  local dp = SoilConstants.DISEASE_PRESSURE
  T.eq("pressure below LOW reads None",     render(fullPayload({ pestPressure = dp.LOW - 1 })).hfValPest.text, "None")
  T.eq("pressure at LOW reads Mild",        render(fullPayload({ pestPressure = dp.LOW })).hfValPest.text, "Mild")
  T.eq("pressure at MEDIUM reads Moderate", render(fullPayload({ pestPressure = dp.MEDIUM })).hfValPest.text, "Moderate")
  T.eq("pressure at HIGH reads Severe",     render(fullPayload({ pestPressure = dp.HIGH })).hfValPest.text, "Severe")
end

-- ── GRAIN HONESTY ───────────────────────────────────────────────────────────
do
  T.ok("a knelt cell is labelled as this cell",
    has(render(fullPayload({ diseaseGrain = "cell" })).hfDisGrain.text, "this cell"))
  T.ok("field grain is labelled as the field average",
    has(render(fullPayload({ diseaseGrain = "field" })).hfDisGrain.text, "field average"))
  T.ok("a refined nutrient read is labelled spot",
    has(render(fullPayload({ fromZoneCell = true })).hfGrain.text, "spot"))
  T.ok("an unrefined nutrient read is labelled field average",
    has(render(fullPayload({ fromZoneCell = false })).hfGrain.text, "field average"))
end

do
  -- The knowledge gate: shownDiseasePressure is nil until scouted, and that is an
  -- answer, not a hole. Rendering it as None would sell a clean bill of health
  -- for a field nobody has looked at - in the word AND in the colour.
  local unscouted = render(fullPayload({ diseasePressure = NIL }))
  local clean     = render(fullPayload({ diseasePressure = 0 }))
  T.eq("unscouted disease says so", unscouted.hfValDis.text, "Unscouted")
  T.eq("a genuinely clean field reads None", clean.hfValDis.text, "None")
  T.ok("unscouted is NOT painted with the green of a clean field",
    not sameColor(unscouted.hfValDis.color, clean.hfValDis.color))
end

-- ── THE MATERIAL SECTION HIDES WHEN THERE IS NOTHING UNDER THE HAND ─────────
do
  local shown = render(fullPayload())
  T.ok("material section shows when material lies there", shown.hfSecMaterial.visible == true)
  T.eq("material renders its wetness band", shown.hfValWet.text, "Damp")
  T.eq("material renders days down", shown.hfValDown.text, "3")
  T.eq("a sound verdict renders", shown.hfValVerdict.text, "Sound")

  local spoiled = render(fullPayload({ materialVerdict = { status = "ok", spoiled = true } }))
  T.eq("a spoiled verdict renders", spoiled.hfValVerdict.text, "Spoiled")
  T.ok("spoiled and sound differ in colour",
    not sameColor(spoiled.hfValVerdict.color, shown.hfValVerdict.color))

  local bare = render(fullPayload({
    materialWetness  = { status = "unavailable" },
    materialDaysDown = { status = "unavailable" },
    materialVerdict  = { status = "refusal", reason = "no material fill type supplied" },
  }))
  T.ok("material section hides on an absent-material payload", bare.hfSecMaterial.visible == false)
  T.ok("a refusal status is never rendered as a value", not has(bare.hfValWet.text, "unavailable"))
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
  T.ok("a nil payload renders a spoken refusal", has(p.hfField.text, "Nothing read"))
end

-- ── RSF-F217: THE TEST KIT SHOWS WORD AND FIGURE ─────────────────────────────
--
-- With the kit, N/P/K/pH show "<band word> <figure>": the figure is the internal
-- value through the display-only PPM_DISPLAY scale, rounded as the HUD rounds;
-- pH is one decimal. The word stays because the cut points are crop-adjusted and
-- acidic/alkaline share one colour. Every guard fails to the neutral dash.

local KIT = SoilConstants.PPM_DISPLAY
local NEUTRAL = { 0.55, 0.55, 0.55, 1 }

do
  local p = render(fullPayload({ testKitActive = true,
    N = { value = 50, status = "Good" }, P = { value = 45, status = "Fair" },
    K = { value = 40, status = "Poor" }, pH = 6.7 }))
  T.eq("kit: N is word and figure", p.hfValN.text, "Good 150 ppm")
  T.eq("kit: P is word and figure", p.hfValP.text, "Fair 27 ppm")
  T.eq("kit: K is word and figure", p.hfValK.text, "Poor 160 ppm")
  T.eq("kit: pH is word and one-decimal figure", p.hfValPh.text, "Good 6.7")
  T.ok("kit: N keeps its severity colour", p.hfValN.color ~= nil and p.hfValN.color[1] == 0.42)
  T.ok("kit: K keeps its poor colour", p.hfValK.color ~= nil and p.hfValK.color[1] == 0.90)
  T.ok("kit: pH keeps its good colour", p.hfValPh.color ~= nil and p.hfValPh.color[1] == 0.42)
  T.ok("kit: footer says exact figures", has(p.hfFooter.text, "exact figures"))
  T.eq("kit: OM is still a band", p.hfValOm.text, "Good")
end

-- The word carries meaning the figure cannot: same 120 ppm, different status per crop.
do
  local wheat = render(fullPayload({ testKitActive = true, N = { value = 40, status = "Fair" } }))
  local soy   = render(fullPayload({ testKitActive = true, N = { value = 40, status = "Good" } }))
  T.eq("kit: same figure on wheat reads Fair", wheat.hfValN.text, "Fair 120 ppm")
  T.eq("kit: same figure on soybean reads Good", soy.hfValN.text, "Good 120 ppm")
end

-- Only a strict boolean true opens the kit branch.
do
  local base = fullPayload()
  local bands = render(base)
  for _, v in ipairs({ false, 1, "true", {} }) do
    local p = render(fullPayload({ testKitActive = v }))
    T.eq("kit gate: " .. type(v) .. " keeps the band for N", p.hfValN.text, bands.hfValN.text)
    T.eq("kit gate: " .. type(v) .. " keeps the band for pH", p.hfValPh.text, bands.hfValPh.text)
    T.ok("kit gate: " .. type(v) .. " keeps the no-kit footer", has(p.hfFooter.text, "by hand"))
  end
  local absent = render(fullPayload({ testKitActive = NIL }))
  T.eq("kit gate: absent keeps the band for N", absent.hfValN.text, bands.hfValN.text)
  T.eq("kit: today's band output is byte-identical without the kit", bands.hfValN.text, "Good")
end

-- Per-tile dash for anything the kit branch cannot form; the other tiles are unaffected.
do
  local nan, inf = 0/0, math.huge
  local p = render(fullPayload({ testKitActive = true,
    N = NIL, P = { value = nan, status = "Good" }, K = { value = 30, status = "Unknown" }, pH = inf }))
  T.eq("kit dash: missing N", p.hfValN.text, "--")
  T.ok("kit dash: missing N is neutral grey", sameColor(p.hfValN.color, NEUTRAL))
  T.eq("kit dash: NaN P value", p.hfValP.text, "--")
  T.ok("kit dash: NaN P is neutral even though status says Good", sameColor(p.hfValP.color, NEUTRAL))
  T.eq("kit dash: Unknown K status", p.hfValK.text, "--")
  T.eq("kit dash: infinite pH", p.hfValPh.text, "--")
  T.ok("kit dash: infinite pH is neutral", sameColor(p.hfValPh.color, NEUTRAL))

  local q = render(fullPayload({ testKitActive = true,
    N = { status = "Good" }, P = { value = "45", status = "Fair" }, K = { value = 40 }, pH = "6.7" }))
  T.eq("kit dash: N without a value", q.hfValN.text, "--")
  T.eq("kit dash: P with a string value", q.hfValP.text, "--")
  T.eq("kit dash: K without a status", q.hfValK.text, "--")
  T.eq("kit dash: pH as a string", q.hfValPh.text, "--")
  T.eq("kit dash: NaN pH", render(fullPayload({ testKitActive = true, pH = nan })).hfValPh.text, "--")
end

-- A bad PPM factor blanks that one tile, and never falls back to a factor of 1.
do
  local saved = { N = KIT.N, P = KIT.P, K = KIT.K }
  KIT.N = 0; KIT.P = nil; KIT.K = -4
  local p = render(fullPayload({ testKitActive = true,
    N = { value = 50, status = "Good" }, P = { value = 45, status = "Fair" }, K = { value = 40, status = "Poor" } }))
  T.eq("kit factor: zero factor dashes N", p.hfValN.text, "--")
  T.eq("kit factor: missing factor dashes P", p.hfValP.text, "--")
  T.eq("kit factor: negative factor dashes K", p.hfValK.text, "--")
  T.ok("kit factor: pH is unaffected", has(p.hfValPh.text, "6.5"))
  KIT.N, KIT.P, KIT.K = saved.N, saved.P, saved.K
  local savedTable = SoilConstants.PPM_DISPLAY
  SoilConstants.PPM_DISPLAY = nil
  local q = render(fullPayload({ testKitActive = true, N = { value = 50, status = "Good" } }))
  T.eq("kit factor: missing table dashes N", q.hfValN.text, "--")
  SoilConstants.PPM_DISPLAY = savedTable
end

-- Zero is a real measurement; .5 rounds up, as the HUD rounds.
do
  local p = render(fullPayload({ testKitActive = true,
    N = { value = 0, status = "Poor" }, P = { value = 45.75, status = "Fair" }, K = { value = 0.125, status = "Poor" } }))
  T.eq("kit: a valid zero renders 0 ppm", p.hfValN.text, "Poor 0 ppm")
  T.eq("kit: 45.75 * 0.6 = 27.45 rounds to 27", p.hfValP.text, "Fair 27 ppm")
  T.eq("kit: 0.125 * 4 = 0.5 rounds up to 1", p.hfValK.text, "Poor 1 ppm")
  T.eq("kit: pH shows one decimal from a longer value",
       render(fullPayload({ testKitActive = true, pH = 6.25 })).hfValPh.text, "Good 6.3")
end

-- A translated pattern with the wrong placeholders never throws and never drops an
-- argument: the exact Lua fallback is used instead. A good pattern may reorder.
do
  local savedI18n = g_i18n
  local texts = {}
  g_i18n = { getText = function(_self, key) return texts[key] or "" end, hasText = function() return false end }

  texts.sf_handful_ppm = "%d ppm %d"           -- one placeholder too many
  texts.sf_handful_kit_tile = "%s"             -- one too few
  local ok, p = pcall(render, fullPayload({ testKitActive = true, N = { value = 50, status = "Good" } }))
  T.ok("kit i18n: a malformed pattern does not throw", ok)
  T.eq("kit i18n: malformed patterns use the exact fallbacks", ok and p.hfValN.text, "Good 150 ppm")

  texts.sf_handful_ppm = "%s ppm"              -- wrong conversion letter
  texts.sf_handful_kit_tile = "%s %s %%"       -- escaped percent is allowed
  p = render(fullPayload({ testKitActive = true, N = { value = 50, status = "Good" } }))
  T.eq("kit i18n: wrong letter falls back, escaped %% is a literal", p.hfValN.text, "Good 150 ppm %")

  texts.sf_handful_ppm = "%d ppm"
  texts.sf_handful_kit_tile = "%s (%s)"        -- a translator's reorder/decoration
  p = render(fullPayload({ testKitActive = true, N = { value = 50, status = "Good" } }))
  T.eq("kit i18n: a valid translated pattern is honoured", p.hfValN.text, "Good (150 ppm)")

  texts.sf_handful_ppm = ""                    -- empty resolves to fallback
  texts.sf_handful_kit_tile = "%d %d"          -- wrong conversions entirely
  p = render(fullPayload({ testKitActive = true, pH = 6.7 }))
  T.eq("kit i18n: pH survives a bad tile pattern", p.hfValPh.text, "Good 6.7")
  g_i18n = savedI18n
end

-- The panel reads; it never writes back into the frozen payload.
do
  local payload = fullPayload({ testKitActive = true, N = { value = 50, status = "Good" }, pH = 6.7 })
  local before = { N = payload.N.value, Ns = payload.N.status, pH = payload.pH, kit = payload.testKitActive }
  render(payload)
  T.eq("kit: payload N value untouched", payload.N.value, before.N)
  T.eq("kit: payload N status untouched", payload.N.status, before.Ns)
  T.eq("kit: payload pH untouched", payload.pH, before.pH)
  T.eq("kit: payload kit flag untouched", payload.testKitActive, before.kit)
  local n = 0
  for _ in pairs(payload) do n = n + 1 end
  local m = 0
  for _ in pairs(fullPayload({ testKitActive = true, N = { value = 50, status = "Good" }, pH = 6.7 })) do m = m + 1 end
  T.eq("kit: no key added to the payload", n, m)
end

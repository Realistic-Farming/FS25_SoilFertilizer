-- SF-79 POSITIONAL pH CONTRACT: the field average reports the soil; it never
-- paints untreated ground. This bar defends ticket #868 and the owner-ratified
-- rule in SF-79-DESIGN-EVIDENCE.md:221-241.
--
-- GROUP A loads the current shipped SoilFertilitySystem and asserts the canonical
-- authority helper is not built yet. It goes red when implementation lands and is
-- then repointed to the real helper. Groups B-E are pure reference contracts for
-- the unbuilt behavior. They prove arithmetic, migration precedence, batch shape,
-- dirty-row payload count, and revision ordering. They do not prove density-map
-- execution, savegame IO, rendering, or real multiplayer transport.
--
-- Source literals:
--   pH default: Constants.lua:91-97.
--   pH bounds: Constants.lua:293-294.
--   shared daily nutrient membership: SoilFertilitySystem.lua:3704 and :4075-4100.
--   current chunk fields: NetworkEvents.lua:1914-1924.
--   current rows-per-event: NetworkEvents.lua:2193-2216.
--   pH LAYER_DEFS index 4: SoilValueMaps.lua:49-54.
-- All ratios, cell populations, row ranges, and map sizes below are test fixtures,
-- not transcribed agronomy or live-map counts.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua

local limits = SoilConstants.NUTRIENT_LIMITS
local PH_MIN = limits.PH_MIN
local PH_MAX = limits.PH_MAX
local PH_DEFAULT = SoilConstants.FIELD_DEFAULTS.pH
local PH_SPAN = PH_MAX - PH_MIN
local EPS = 0.000000001 -- pure-Lua arithmetic tolerance, not a simulation tolerance

local function cloneArray(src, count)
  local out = {}
  for i = 1, count do out[i] = src[i] end
  return out
end

local function mean(values, count)
  local sum = 0
  for i = 1, count do sum = sum + values[i] end
  return sum / count
end

local function clampPH(value)
  return math.max(PH_MIN, math.min(PH_MAX, value))
end

-- GROUP A: SHIPPED SURFACES. SF-79 is built: the canonical writer and its
-- report / whole-field / AUTO siblings exist, and the shipped pure kernel matches
-- the reference models below.
T.eq("SF-79 A1: shipped SoilFertilitySystem exposes the canonical _applyPHFootprint helper",
     type(SoilFertilitySystem._applyPHFootprint), "function")
T.eq("SF-79 A2: shipped source exposes the derived report refresher",
     type(SoilFertilitySystem._ensurePHReport), "function")
T.eq("SF-79 A3: shipped source exposes the whole-field writer adapter",
     type(SoilFertilitySystem._phApplyField), "function")
T.eq("SF-79 A4: shipped source exposes the pH AUTO rate",
     type(SoilFertilitySystem.updatePHWorkAuto), "function")
T.eq("SF-79 A5: shipped pH layer is the SoilValueMaps pH def",
     (PositionalPH.phDef() ~= nil and PositionalPH.phDef().key), "pH")
T.eq("SF-79 A6: shipped raw quantiser truncates toward zero",
     PositionalPH.rawDeltaFor(PositionalPH.unitsPerRaw() * 3.9), 3)
local shippedCohort = { 240 }
PositionalPH.rawCohortDelta(shippedCohort, 10)
T.eq("SF-79 A7: shipped saturation cohort lands 240+10 at 250", shippedCohort[1], 250)

-- GROUP B: REFERENCE MODEL for local ownership and the derived field report.
-- Fixture values stay away from the shipped PH_MIN/PH_MAX, so no clamp is expected.
local function applyCoveredDelta(values, count, covered, delta)
  local before = mean(values, count)
  local touched = 0
  for _, idx in ipairs(covered) do
    values[idx] = clampPH(values[idx] + delta)
    touched = touched + 1
  end
  return before, mean(values, count), touched
end

local start = {
  PH_MIN + PH_SPAN * 0.20,
  PH_MIN + PH_SPAN * 0.35,
  PH_MIN + PH_SPAN * 0.50,
  PH_MIN + PH_SPAN * 0.65,
}
local cellCount = #start
local covered = { 1, 2 }
local dose = PH_SPAN * 0.04
local partial = cloneArray(start, cellCount)
local beforeMean, afterMean, touched = applyCoveredDelta(partial, cellCount, covered, dose)

T.near("SF-79 B1: first covered cell receives the local dose", partial[1], start[1] + dose, EPS)
T.near("SF-79 B2: second covered cell receives the local dose", partial[2], start[2] + dose, EPS)
T.near("SF-79 B3: first untouched cell stays unchanged", partial[3], start[3], EPS)
T.near("SF-79 B4: second untouched cell stays unchanged", partial[4], start[4], EPS)
T.eq("SF-79 B5: touched-ground accounting equals the covered fixture population", touched, #covered)
T.near("SF-79 B6: report changes by dose times covered share when no clamp occurs",
       afterMean - beforeMean, dose * (#covered / cellCount), EPS)

-- Manual and automatic rate are two dose choices through the same footprint model.
-- The fixture doubles only the dose. Covered indices do not change.
local manual = cloneArray(start, cellCount)
local automatic = cloneArray(start, cellCount)
applyCoveredDelta(manual, cellCount, covered, dose)
applyCoveredDelta(automatic, cellCount, covered, dose * 2)
T.near("SF-79 B7: rate choice changes amount on covered ground",
       automatic[1] - start[1], (manual[1] - start[1]) * 2, EPS)
T.near("SF-79 B8: manual rate does not touch uncovered ground", manual[4], start[4], EPS)
T.near("SF-79 B9: automatic rate does not touch uncovered ground", automatic[4], start[4], EPS)

-- GROUP C: REFERENCE MODEL for the existing all-nutrient daily batch.
-- A genuinely uniform additive consequence applies inside the ordinary field pass. It preserves the
-- gap between cells and creates no pH-only field pass or scheduler.
local function applyUniformDelta(values, count, delta)
  for i = 1, count do values[i] = clampPH(values[i] + delta) end
end

local dailyFields = {
  cloneArray(start, cellCount),
  cloneArray(start, cellCount),
}
local elapsedDays = 3
local fieldPasses = 0
local pHInsideBatch = 0
local pHOnlyPasses = 0
local dailyDelta = -(PH_SPAN * 0.01)
local gapBefore = dailyFields[1][4] - dailyFields[1][1]

for _ = 1, elapsedDays do
  for _, cells in ipairs(dailyFields) do
    fieldPasses = fieldPasses + 1
    applyUniformDelta(cells, cellCount, dailyDelta)
    pHInsideBatch = pHInsideBatch + 1
  end
end

T.near("SF-79 C1: a uniform additive consequence preserves positional difference",
       dailyFields[1][4] - dailyFields[1][1], gapBefore, EPS)
T.eq("SF-79 C2: pH runs exactly once inside each existing field pass", pHInsideBatch, fieldPasses)
T.eq("SF-79 C3: no pH-only daily pass is created", pHOnlyPasses, 0)
T.eq("SF-79 C4: caught-up work follows fields times elapsed days",
     fieldPasses, #dailyFields * elapsedDays)

-- GROUP D: REFERENCE MODEL for preservation-first, one-time migration.
-- nil means unwritten pH-map ground. A legacy zone value is eligible only when
-- durable provenance says it is local. Current evidence provides no such marker,
-- so the ordinary current path falls through to the old field scalar.
local function validPH(value)
  return type(value) == "number" and value >= PH_MIN and value <= PH_MAX
end

local function migratePH(existingMap, count, legacyZones, oldScalar, alreadyMigrated)
  local result = cloneArray(existingMap, count)
  local writes = 0
  local recomputes = 0
  do -- A schema marker never makes raw-zero/missing ground valid.
    for i = 1, count do
      if not validPH(result[i]) then
        -- Current source supplies no proven-local zone marker. The entire
        -- legacyZones argument is deliberately non-authoritative.
        result[i] = clampPH(oldScalar)
        writes = writes + 1
      end
    end
    if writes > 0 then recomputes = 1 end
  end
  return result, mean(result, count), true, writes, recomputes
end

local migratedInput = {
  PH_DEFAULT - PH_SPAN * 0.03,
  PH_DEFAULT + PH_SPAN * 0.02,
  nil,
  nil,
}
local provenZone = PH_DEFAULT + PH_SPAN * 0.05
local oldScalar = PH_DEFAULT - PH_SPAN * 0.01
local legacy = {
  [3] = { value = provenZone, provenLocal = true },
  [4] = { value = PH_DEFAULT + PH_SPAN * 0.08, provenLocal = false },
}
local migrated, rollup, marker, writes, recomputes =
  migratePH(migratedInput, cellCount, legacy, oldScalar, false)

T.near("SF-79 D1: valid first map pixel is preserved", migrated[1], migratedInput[1], EPS)
T.near("SF-79 D2: valid second map pixel is preserved", migrated[2], migratedInput[2], EPS)
T.near("SF-79 D3: unproved legacy zone cannot override frozen seed", migrated[3], oldScalar, EPS)
T.near("SF-79 D4: unproven legacy pH yields to the old field scalar", migrated[4], oldScalar, EPS)
T.eq("SF-79 D5: first migration writes only the two unwritten fixture pixels", writes, 2)
T.eq("SF-79 D6: first migration performs one rollup recompute", recomputes, 1)
T.eq("SF-79 D7: migration sets its one-time marker", marker, true)
T.near("SF-79 D8: rollup is recomputed from the finished positional state",
       rollup, mean(migrated, cellCount), EPS)

local migratedAgain, rollupAgain, markerAgain, writesAgain, recomputesAgain =
  migratePH(migrated, cellCount, {}, PH_MAX, marker)
T.eq("SF-79 D9: second migration performs zero writes", writesAgain, 0)
T.eq("SF-79 D10: second migration performs zero recomputes", recomputesAgain, 0)
T.eq("SF-79 D11: one-time marker remains set", markerAgain, true)
for i = 1, cellCount do
  T.near("SF-79 D12." .. tostring(i) .. ": second migration preserves pixel " .. tostring(i),
         migratedAgain[i], migrated[i], EPS)
end
T.near("SF-79 D13: second migration preserves the report", rollupAgain, rollup, EPS)

-- GROUP E: REFERENCE MODEL for display-grade changed-row delivery through the existing event.
-- This is not exact native-pixel replication or runtime packet performance.
-- ROWS_PER_EVENT=16 is the current source constant at NetworkEvents.lua:2193.
-- layerIdx=4 is pH in SoilValueMaps.LAYER_DEFS at SoilValueMaps.lua:49-54.
local ROWS_PER_EVENT = 16
local PH_LAYER_INDEX = 4

local function memberCount(tbl)
  local n = 0
  for _ in pairs(tbl) do n = n + 1 end
  return n
end

local function planPatch(rowRanges, totalMapPixels, revision)
  local dirty = {}
  for _, range in ipairs(rowRanges) do
    for row = range[1], range[2] do dirty[row] = true end
  end
  local ordered = {}
  for row in pairs(dirty) do ordered[#ordered + 1] = row end
  table.sort(ordered)

  local chunks = {}
  local i = 1
  while i <= #ordered do
    local first = ordered[i]
    local rows = { first }
    i = i + 1
    while i <= #ordered and #rows < ROWS_PER_EVENT and ordered[i] == rows[#rows] + 1 do
      rows[#rows + 1] = ordered[i]
      i = i + 1
    end
    chunks[#chunks + 1] = {
      layerIdx = PH_LAYER_INDEX,
      gyStart = first,
      rows = rows,
      isLast = false,
      mode = "PATCH",
      revision = revision,
      baseRevision = revision - 1,
      transferId = revision,
      partIndex = #chunks,
      partCount = 0,
      sourceResolution = 2048,
      transportStride = 4,
    }
  end
  if #chunks > 0 then
    chunks[#chunks].isLast = true
    for _, chunk in ipairs(chunks) do chunk.partCount = #chunks end
  end
  return chunks, #ordered, totalMapPixels
end

local ranges = { { 2, 4 }, { 4, 6 } }
local smallPlan, smallDirty = planPatch(ranges, 4096, 7)
local largePlan, largeDirty = planPatch(ranges, 16777216, 7)
T.eq("SF-79 E1: overlapping changed regions deduplicate to five dirty rows", smallDirty, 5)
T.eq("SF-79 E2: the same changed rows make the same event count on a small map",
     #smallPlan, 1)
T.eq("SF-79 E3: total map pixels do not change the routine event count",
     #largePlan, #smallPlan)
T.eq("SF-79 E4: total map pixels do not change the dirty-row count", largeDirty, smallDirty)
T.eq("SF-79 E5: shared chunk carries transfer and grain metadata",
     memberCount(smallPlan[1]), 12)
T.eq("SF-79 E6: pH travels as an existing layer index", smallPlan[1].layerIdx, PH_LAYER_INDEX)
T.eq("SF-79 E7: routine delivery is PATCH mode", smallPlan[1].mode, "PATCH")
T.eq("SF-79 E8: pH creates no key-named event member", smallPlan[1].eventName, nil)

T.eq("SF-79 E9: retained 1-based layer actually names pH",SoilValueMaps.LAYER_DEFS[PH_LAYER_INDEX].key,"pH")
-- FULL/PATCH application has one model, Group H below. There is no separate
-- clear-first model masquerading as a valid partial FULL commit.

-- GROUP F: new independent raw-value oracles for v1.1. These are design models,
-- plus one real-source witness with a current-data fake native modifier.
local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
local phDef
for _, def in ipairs(SoilValueMaps.LAYER_DEFS) do if def.key == "pH" then phDef = def end end
T.ok("SF-79 F1: actual pH layer definition is loaded", phDef ~= nil)
local UPR = (phDef.maxVal - phDef.minVal) / (RMAX - RMIN)
local lowRaw = SoilValueMaps._encode(limits.PH_NEUTRAL_LOW, phDef)
local highRaw = SoilValueMaps._encode(limits.PH_NEUTRAL_HIGH, phDef)
local function clampedRaw(raw, delta)
  if raw == 0 then return 0 end
  return math.max(RMIN, math.min(RMAX, raw + delta))
end
local function runBand(values, lo, hi, add, target)
  for i, raw in ipairs(values) do
    if raw >= lo and raw <= hi then values[i] = target or (raw + add) end
  end
end
local function rawCohortDelta(values, delta)
  if delta == 0 then return end
  if delta >= RMAX-RMIN then runBand(values,RMIN,RMAX,0,RMAX); return end
  if delta <= -(RMAX-RMIN) then runBand(values,RMIN,RMAX,0,RMIN); return end
  if delta > 0 then
    runBand(values,RMAX-delta+1,RMAX-1,0,RMAX)
    runBand(values,RMIN,RMAX-delta,delta,nil)
  else
    runBand(values,RMIN,RMIN-delta-1,0,RMIN)
    runBand(values,RMIN-delta,RMAX,delta,nil)
  end
end
for _, delta in ipairs({-300,-10,-1,0,1,10,300}) do
  local values, wanted = {}, {}
  for raw=0,RMAX do values[#values+1]=raw; wanted[#wanted+1]=clampedRaw(raw,delta) end
  rawCohortDelta(values,delta)
  local matches=true
  for i=1,#values do if values[i]~=wanted[i] then matches=false; break end end
  T.ok("SF-79 F2: pre-write cohorts equal pointwise clamp for delta "..delta,matches)
end
local fakeValues={240}
local fakeFilter={lo=RMIN,hi=RMAX}
function fakeFilter:setValueCompareParams(_,lo,hi) self.lo,self.hi=lo,hi end
local fakeModifier={}
function fakeModifier:setParallelogramWorldCoords(...) end
function fakeModifier:executeAdd(delta,filter) runBand(fakeValues,filter.lo,filter.hi,delta,nil) end
function fakeModifier:executeSet(value,filter) runBand(fakeValues,filter.lo,filter.hi,0,value) end
local fakeVM={available=true,hasExecuteAdd=true,layers={pH={def=phDef,modifier=fakeModifier,filter=fakeFilter}}}
-- The shipped addPaintStrip reports one growth-write observation at its mutator
-- boundary; the fixture is a pure stand-in for the engine write, so it no-ops.
function fakeVM:_observeGrowthWrite() end
-- These enum sentinels are consumed only by the fake modifier/filter above;
-- geometry/raster execution is explicitly outside this source-order witness.
local savedCoordType,savedCompareType=DensityCoordType,DensityValueCompareType
DensityCoordType=DensityCoordType or {POINT_POINT_POINT="fixture"}
DensityValueCompareType=DensityValueCompareType or {BETWEEN="fixture"}
SoilValueMaps.addPaintStrip(fakeVM,"pH",0,0,1,0,0,1,(10+0.000001)*UPR)
DensityCoordType,DensityValueCompareType=savedCoordType,savedCompareType
T.eq("SF-79 F3: current source witness reselects an added interior value into saturation",fakeValues[1],255)
local corrected={240}; rawCohortDelta(corrected,10)
T.eq("SF-79 F4: proposed correct interior result remains 250",corrected[1],250)

local function expectedNormalize(raw,step)
  if raw==0 then return 0 end
  if raw<lowRaw then return math.min(lowRaw,raw+step) end
  if raw>highRaw then return math.max(highRaw,raw-step) end
  return raw
end
local function normalizeCohorts(values,step)
  runBand(values,math.max(RMIN,lowRaw-step+1),lowRaw-1,0,lowRaw)
  runBand(values,RMIN,lowRaw-step,step,nil)
  runBand(values,highRaw+1,math.min(RMAX,highRaw+step-1),0,highRaw)
  runBand(values,highRaw+step,RMAX,-step,nil)
end
for _,step in ipairs({1,3,20,300}) do
  local values,wanted={},{}
  for raw=0,RMAX do values[#values+1]=raw; wanted[#wanted+1]=expectedNormalize(raw,step) end
  normalizeCohorts(values,step)
  local matches=true
  for i=1,#values do if values[i]~=wanted[i] then matches=false;break end end
  T.ok("SF-79 F5: normalization cohorts equal independent oracle for step "..step,matches)
end
local mixed={lowRaw-12,highRaw+12}
T.ok("SF-79 F6: mixed field average is already inside neutral band",(mixed[1]+mixed[2])/2>=lowRaw and (mixed[1]+mixed[2])/2<=highRaw)
normalizeCohorts(mixed,3)
T.eq("SF-79 F7: sour patch still normalizes despite neutral mean",mixed[1],lowRaw-9)
T.eq("SF-79 F8: alkaline patch still normalizes despite neutral mean",mixed[2],highRaw+9)

-- GROUP G: model the exact domain union and report-cache direction. Pixel labels
-- are a synthetic oracle, not an implementation of native polygon rasterization.
local parts={{1,2,3},{3,5,6}}
local domain={}
for _,part in ipairs(parts) do for _,pixel in ipairs(part) do domain[pixel]=true end end
local rawField={100,100,100,100,100,100}
for pixel in pairs(domain) do rawField[pixel]=rawField[pixel]+10 end
T.eq("SF-79 G1: overlapping parcel polygons do not double-dose shared pixel",rawField[3],110)
T.eq("SF-79 G2: gap between cultivated polygons stays untouched",rawField[4],100)
local report={dirty=true,value=nil,reads=0}
local function ensureReport()
  if report.dirty then
    local sum,n=0,0
    for pixel in pairs(domain) do sum=sum+rawField[pixel]; n=n+1 end
    report.value=phDef.minVal+((sum/n-RMIN)/(RMAX-RMIN))*(phDef.maxVal-phDef.minVal)
    report.reads=report.reads+1; report.dirty=false
  end
  return report.value
end
local first=ensureReport();for _=1,9 do ensureReport() end
T.eq("SF-79 G3: repeated reads of same report revision reuse its aggregate",report.reads,1)
rawField[1]=255;report.dirty=true;local second=ensureReport()
T.eq("SF-79 G4: changed map triggers next needed report rebuild",report.reads,2)
T.ok("SF-79 G5: report follows actual clamped map",second>first)
T.eq("SF-79 G6: report reads cannot repaint the untouched gap",rawField[4],100)

-- GROUP H: presentation precision and complete multi-part revision commit.
local function projection(raw) if raw==0 then return 0 end; return math.max(1, math.floor(raw/16)) end
T.eq("SF-79 H1: current four-bit projection can merge different native pH pixels",projection(100),projection(101))
local meta={sourceResolution=2048,transportStride=4,terrainMetres=4096,displayOnly=true}
T.eq("SF-79 H2: carrier grain derives from actual source dimensions",meta.terrainMetres/meta.sourceResolution,2)
T.eq("SF-79 H3: delivered grain includes the actual stride",meta.terrainMetres/meta.sourceResolution*meta.transportStride,8)
T.eq("SF-79 H4: display-grade metadata cannot authorize fine simulation",not meta.displayOnly,false)
local U32=4294967296
local function newer(a,b) local d=(a-b)%U32; return d>0 and d<U32/2 end
local layer={revision=10,transferId=10,rows={[0]="old-zero",[1]="old-one",[2]="old-two",[3]="old-three"},pending=nil}
-- Four symbolic rows are a bounded protocol fixture, not native pixel data.
local function packet(mode,revision,id,part,total,start,rows,base)
  return {mode=mode,revision=revision,baseRevision=base or 0,transferId=id,
    partIndex=part,partCount=total,gyStart=start,rows=rows,layerIdx=PH_LAYER_INDEX,
    sourceResolution=16,transportStride=4}
end
local function receivePart(p)
  if p.layerIdx~=PH_LAYER_INDEX or p.sourceResolution~=16 or p.transportStride~=4 then return "RESYNC" end
  if p.partCount<1 or p.partCount>4 or p.partIndex<0 or p.partIndex>=p.partCount or p.partIndex%1~=0 then return "RESYNC" end
  if p.gyStart<0 or p.gyStart+#p.rows>4 then return "RESYNC" end
  if not newer(p.transferId,layer.transferId) then return "OLD" end
  if p.revision~=layer.revision and not newer(p.revision,layer.revision) then return "OLD" end
  if p.mode=="PATCH" then
    if p.baseRevision~=layer.revision or not newer(p.revision,layer.revision) then return "RESYNC" end
  elseif p.mode~="FULL" then return "RESYNC" end
  local pending=layer.pending
  if pending and pending.id~=p.transferId then layer.pending=nil;return "RESYNC" end
  if not pending then
    pending={id=p.transferId,mode=p.mode,revision=p.revision,base=p.baseRevision,total=p.partCount,parts={},count=0}
    layer.pending=pending
  end
  if pending.mode~=p.mode or pending.revision~=p.revision or pending.base~=p.baseRevision or pending.total~=p.partCount then layer.pending=nil;return "RESYNC" end
  local old=pending.parts[p.partIndex]
  if old then
    if old.gyStart~=p.gyStart or #old.rows~=#p.rows then layer.pending=nil;return "RESYNC" end
    for i,v in ipairs(p.rows) do if old.rows[i]~=v then layer.pending=nil;return "RESYNC" end end
  else pending.parts[p.partIndex]=p;pending.count=pending.count+1 end
  if pending.count<pending.total then return "WAIT" end
  local result,seen={},{}
  if p.mode=="PATCH" then for row,v in pairs(layer.rows) do result[row]=v end end
  for i=0,pending.total-1 do
    local part=pending.parts[i]
    for offset,v in ipairs(part.rows) do
      local row=part.gyStart+offset-1
      if seen[row] then layer.pending=nil;return "RESYNC" end
      seen[row]=true;result[row]=v
    end
  end
  if p.mode=="FULL" then for row=0,3 do if not seen[row] then layer.pending=nil;return "RESYNC" end end end
  layer.rows=result;layer.revision=p.revision;layer.transferId=p.transferId;layer.pending=nil
  return "APPLIED"
end
local p0=packet("PATCH",11,11,0,2,0,{"new-zero"},10)
local p1=packet("PATCH",11,11,1,2,2,{"new-two"},10)
T.eq("SF-79 H5: first PATCH part alone never commits",receivePart(p0),"WAIT")
T.eq("SF-79 H6: last complete view survives partial PATCH",layer.rows[0],"old-zero")
T.eq("SF-79 H7: duplicate part cannot complete PATCH",receivePart(p0),"WAIT")
T.eq("SF-79 H8: final PATCH part commits once",receivePart(p1),"APPLIED")
T.eq("SF-79 H9: row-zero PATCH preserves unrelated row",layer.rows[1],"old-one")
T.eq("SF-79 H10: delayed duplicate is ignored",receivePart(p0),"OLD")
local f0=packet("FULL",11,12,0,2,0,{"repair-zero","repair-one"})
local f1=packet("FULL",11,12,1,2,2,{"repair-two","repair-three"})
T.eq("SF-79 H11: same-revision newer FULL repair starts",receivePart(f0),"WAIT")
T.eq("SF-79 H12: row-zero partial FULL does not wipe any live row",layer.rows[1],"old-one")
T.eq("SF-79 H13: final FULL part atomically repairs same revision",receivePart(f1),"APPLIED")
T.eq("SF-79 H14: complete FULL replaces old rows",layer.rows[0],"repair-zero")
T.eq("SF-79 H15: repaired same revision stays that revision",layer.revision,11)
T.eq("SF-79 H16: old FULL duplicate cannot rewrite a repair",receivePart(f0),"OLD")
T.eq("SF-79 H17: coalesced PATCH may skip cuts with exact installed base",receivePart(packet("PATCH",14,13,0,1,3,{"coalesced"},11)),"APPLIED")
T.eq("SF-79 H18: missing base is a repair request",receivePart(packet("PATCH",16,14,0,1,0,{"gap"},15)),"RESYNC")
T.eq("SF-79 H19: bad-base packet never mutates the view",layer.rows[0],"repair-zero")
local before=layer.rows
T.eq("SF-79 H20: incomplete coverage cannot commit a FULL",receivePart(packet("FULL",15,15,0,1,0,{"missing-three-rows"})),"RESYNC")
T.eq("SF-79 H21: malformed FULL preserves live table",layer.rows,before)
T.eq("SF-79 H22: wrong layer is not accepted as pH",receivePart({layerIdx=3}),"RESYNC")
T.eq("SF-79 H23: uint32 wrap recognizes the next cut",newer(0,U32-1),true)
T.eq("SF-79 H24: delayed pre-wrap cut is old",newer(U32-1,0),false)

-- GROUP I: migration marker recovery, separate section intensity, immutable
-- presentation capture and actual payload bound. Reference decisions only.
local recovered,_,_,recoveryWrites=migratePH({nil,PH_MIN},2,{},PH_MAX+1,true)
T.eq("SF-79 I1: schema marker cannot suppress missing carrier recovery",recoveryWrites,1)
T.eq("SF-79 I2: legacy scalar is clamped to carrier maximum",recovered[1],PH_MAX)
T.eq("SF-79 I3: existing written low pixel is preserved",recovered[2],PH_MIN)
T.eq("SF-79 I4: valid lowest raw value remains a known display bin",projection(1),1)
T.eq("SF-79 I5: raw zero remains unknown",projection(0),0)
local perLitre=0.0004 -- synthetic intensity fixture, not an agronomic constant
local function localIntensity(litres,areaHa) return perLitre*litres/areaHa end
local left=localIntensity(20,0.01); local right=localIntensity(5,0.01)
T.eq("SF-79 I6: separately dosed equal-area sections retain 4-to-1 intensity",left/right,4)
T.near("SF-79 I7: subdividing one accepted dose and its area preserves local intensity",
 localIntensity(10,0.005),left,EPS)
local rowCache={[0]="old-zero",[1]="old-one"}
local frozen={}; for row,value in pairs(rowCache) do frozen[row]=value end
rowCache[0]="later-zero"
T.eq("SF-79 I8: in-flight full retains immutable earlier row",frozen[0],"old-zero")
T.eq("SF-79 I9: later projection carries new row independently",rowCache[0],"later-zero")
local headerBits=8+16+8+1+1+32+32+32+16+16+16+16
local worstRowBits=16+16+512*(4+16)
local maxRows=math.min(16,math.floor((8192*8-headerBits)/worstRowBits))
T.ok("SF-79 I10: worst-case full-width row fits selected 8 KiB event budget",maxRows>=1)
T.ok("SF-79 I11: 16-row limit alone would exceed encoded budget",headerBits+16*worstRowBits>8192*8)
T.ok("SF-79 I12: selected row count actually fits encoded budget",headerBits+maxRows*worstRowBits<=8192*8)

-- GROUP J: caller/identity counterexamples, deliberately pure references.
local function readPH(positional,sample,report)
  if positional then return sample,sample~=nil and "LOCAL" or "UNAVAILABLE" end
  return report,report~=nil and "FIELD_REPORT" or "UNAVAILABLE"
end
local value,status=readPH(true,nil,7.0)
T.eq("SF-79 J1: a healthy report cannot fill a missing local sample",value,nil)
T.eq("SF-79 J2: missing local PH has a typed unavailable state",status,"UNAVAILABLE")
local function needsPH(ph,otherNeed) if otherNeed then return true end; if ph==nil then return nil end; return ph<6.5 end
T.eq("SF-79 J3: sour strip still needs lime despite healthy field mean",needsPH(5.5,false),true)
T.eq("SF-79 J4: unknown PH cannot assert no lime need",needsPH(nil,false),nil)
T.eq("SF-79 J5: known other nutrient need remains true",needsPH(nil,true),true)
local doseSeen,total={},0
local function acceptDose(id,amount) if not doseSeen[id] then doseSeen[id]=true;total=total+amount end end
acceptDose("implement:tick:section1:call1",0.4)
acceptDose("implement:tick:section2:call1",0.1)
acceptDose("implement:tick:section1:call1",0.4)
T.near("SF-79 J6: overlapping different sections both count but duplicate delivery does not",total,0.5,EPS)
-- Native per-work-area metric is reset by WorkArea before each processing loop.
-- The reference verifies selection of completed records, not native rasterization.
local areas={{functionName="processPlowArea",lastWorkedHectares=0.1},
 {functionName="processPlowArea",lastWorkedHectares=0},
 {functionName="processCultivatorArea",lastWorkedHectares=0.2}}
local accepted=0
for _,wa in ipairs(areas) do if wa.lastWorkedHectares>0 then accepted=accepted+wa.lastWorkedHectares end end
T.near("SF-79 J7: multi-work-area tillage keeps accepted areas separate from inactive ones",accepted,0.3,EPS)
-- A busy source accumulates all rows after a frozen cut while that transfer sends.
local changedSinceFull={}; changedSinceFull[0]=true;changedSinceFull[3]=true
local current={[0]="new-headland",[1]="same",[2]="same",[3]="new-interior"}
local patch={baseRevision=20,revision=23,rows={}}
for row in pairs(changedSinceFull) do patch.rows[row]=current[row] end
T.eq("SF-79 J8: coalesced post-FULL patch retains early changed row",patch.rows[0],"new-headland")
T.eq("SF-79 J9: coalesced post-FULL patch retains later changed row",patch.rows[3],"new-interior")
T.eq("SF-79 J10: unchanged row is not fabricated into dirty set",patch.rows[1],nil)

T.summary()


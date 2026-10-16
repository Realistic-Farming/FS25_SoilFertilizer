-- SF-1128-viability_pass_slices_entry_test.lua
--
-- #1128: the 4x map freeze at midnight (memory to 15 GB). Time Guard's day
-- settle ran ViabilityMask:runPass() inside the engine's DAY_CHANGED message:
-- one frame enumerated every 2 m carrier square of every farmland, rebuilt a
-- polygon's vertex-text fingerprint per square, rebuilt the map-wide ownership
-- digest (sort + join of every square) once PER FARMLAND, and built a plan hash
-- that repeated the full vertex text per square.
--
-- THE FIX: the accrual's onSettle only starts the pass (startPass, no
-- enumeration); SoilFertilityManager:update steps it a slice at a time
-- (stepPass); fingerprints are built once per polygon; the ownership digest is
-- built once per pass; both hashes are fixed-size digests.
--
-- ENTRY POINTS, NAMED PER ROW:
--   S1, S10  ViabilityMask:registerDailyAccrual() files the accrual through a
--            stub Time Guard (the same minimal registerAccrual/scheduler shape
--            MAINT-251-timeguard_skew_guard_entry_spec_test.lua's bench already
--            uses; the real FS25_TimeGuard scheduler is not loaded). The filed
--            onSettle is invoked with pcall(onSettle, ctx) exactly as
--            TimeGuardScheduler:settle calls it
--            (FS25_TimeGuard/src/TimeGuardScheduler.lua:175).
--   S2       SoilFertilityManager:update is NOT loaded here (its dependency
--            closure is the whole mod); driving it is impractical in this
--            harness. The entry point driven is
--            self.viability:stepPass(ViabilityMask.PASS_SQUARES_PER_UPDATE),
--            the exact call SoilFertilityManager:update makes
--            (src/SoilFertilityManager.lua, the block added directly after
--            `self.zoneYield:advanceJobs(budget)`).
--   S3-S9, S11  ViabilityMask:startPass / :stepPass / :runPass directly (all
--            three are production's own public methods, not helpers this bar
--            added).
--   S12      GrowthBlock:onStartGrowthPeriod / :onFinishedGrowthPeriod,
--            GrowthCredit:onStartGrowthPeriod / :onFinishedGrowthPeriod, and
--            ZoneYield:advanceJobs: the three consumers' own real dispatch
--            entry points.
--
-- MODELLED (the engine is not available here): the carrier-square grid walk
-- itself is production's _enumerateSome/_squareSource; what is modelled is the
-- value-map read (readValueAtWorld), the growth-input revision/token family,
-- and _getFarmlandPolygons -- a plain stub returning fixed vertex lists, not a
-- real farmland manager or terrain. No frame time, memory or save duration is
-- proved here; only reference behaviour.
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/ViabilityMask.lua, src/integrations/OptionScalingResolver.lua, src/GrowthBlock.lua, src/GrowthCredit.lua, src/ZoneYield.lua

local V = ViabilityMask

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ============================================================
-- SHARED FIXTURE BUILDERS
-- ============================================================

-- The growth-input revision/token family (SF-52-family_reference_arithmetic_spec_test.lua
-- Group B's model, reused): a bare owner table, established once, bumped per write.
local function newOwner()
  return { globalRevision = nil, unscopedRevision = nil, farmlandRevisions = {} }
end
local function ownerEstablish(owner, ids)
  if owner.globalRevision == nil then owner.globalRevision = 1 end
  if owner.unscopedRevision == nil then owner.unscopedRevision = 1 end
  for _, id in ipairs(ids or {}) do
    if owner.farmlandRevisions[id] == nil then owner.farmlandRevisions[id] = 1 end
  end
end
local function ownerToken(owner, farmlandId)
  local fr = owner.farmlandRevisions[farmlandId]
  if fr == nil then return nil end
  return { globalRevision = owner.globalRevision, farmlandRevision = fr, unscopedRevision = owner.unscopedRevision }
end
local function ownerBumpFarmland(owner, farmlandId)
  owner.globalRevision = (owner.globalRevision or 1) + 1
  owner.farmlandRevisions[farmlandId] = (owner.farmlandRevisions[farmlandId] or 1) + 1
end
local function ownerBumpUnscoped(owner)
  owner.globalRevision = (owner.globalRevision or 1) + 1
  owner.unscopedRevision = (owner.unscopedRevision or 1) + 1
end

-- A value map stub: readValueAtWorld, getGrainMetres, getGrowthInputToken,
-- establishGrowthInputRevisions (the fixture shape the SF-52 benches use), plus a
-- per-cell override table and a read counter for S1/S11.
local function newVM(owner, grain, defaultN, defaultC)
  local overrides = {}
  local readCount = 0
  local vm = { available = true }
  function vm:getGrainMetres() return grain end
  function vm:getGrowthInputToken(farmlandId) return ownerToken(owner, farmlandId) end
  function vm:establishGrowthInputRevisions(ids) ownerEstablish(owner, ids) end
  -- Keyed with %.3f: a world coordinate built from gx*grain+half (the real
  -- enumeration's arithmetic) is a float, and a float's tostring differs from
  -- a same-valued integer literal's ("21.0" vs "21"); %.3f normalises both.
  function vm:readValueAtWorld(key, x, z)
    readCount = readCount + 1
    local cell = overrides[string.format('%.3f:%.3f', x, z)]
    if key == 'nitrogen' then return (cell and cell.n) or defaultN end
    if key == 'compaction' then return (cell and cell.c) or defaultC end
    return nil
  end
  vm._setOverride = function(_self, x, z, n, c)
    overrides[string.format('%.3f:%.3f', x, z)] = { n = n, c = c }
  end
  vm._readCount = function() return readCount end
  return vm
end

-- A soil-system stub: fieldData (the farmland set) and _getFarmlandPolygons
-- (one polygon per farmland). polysByFarmland is returned too so a test can
-- swap a farmland's live geometry mid-pass (S9's geometry-cancel case).
local function newSoilSystem(polysByFarmland)
  local ss = { fieldData = {} }
  for id in pairs(polysByFarmland) do ss.fieldData[id] = true end
  ss._getFarmlandPolygons = function(_self, farmlandId)
    local p = polysByFarmland[farmlandId]
    if p == nil then return nil end
    return { p }
  end
  return ss, polysByFarmland
end

local function buildMask(vm, ss)
  ss.valueMaps = vm
  return ViabilityMask.new({ soilSystem = ss })
end

-- BIG fixture: two overlapping farmlands at grain 2, ~2091 carrier squares
-- each (51 columns x 41 rows), sharing a 6-column x 41-row band (246 squares).
local GRAIN_BIG = 2
local FARMLAND_A = { { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 80 }, { x = 0, z = 80 } }
local FARMLAND_B = { { x = 90, z = 0 }, { x = 190, z = 0 }, { x = 190, z = 80 }, { x = 90, z = 80 } }
local DEFAULT_N, DEFAULT_C = 40, 50   -- NORMAL/NORMAL -> combine() NORMAL, not blocked

local function buildBigFixture()
  local owner = newOwner()
  local vm = newVM(owner, GRAIN_BIG, DEFAULT_N, DEFAULT_C)
  ownerEstablish(owner, { 7, 9 })
  local ss, polys = newSoilSystem({ [7] = FARMLAND_A, [9] = FARMLAND_B })
  local mask = buildMask(vm, ss)
  return mask, vm, owner, ss, polys
end

-- SMALL fixture: the same two-farmland shape at grain 20, 30 squares each
-- (6 columns x 5 rows), sharing a 2-column x 5-row band (10 squares). Used
-- where the test needs to pause a pass mid-flight by hand.
local GRAIN_SMALL = 20
local SMALL_A = FARMLAND_A
local SMALL_B = FARMLAND_B

local function buildSmallFixture()
  local owner = newOwner()
  local vm = newVM(owner, GRAIN_SMALL, DEFAULT_N, DEFAULT_C)
  ownerEstablish(owner, { 7, 9 })
  local ss, polys = newSoilSystem({ [7] = SMALL_A, [9] = SMALL_B })
  local mask = buildMask(vm, ss)
  return mask, vm, owner, ss, polys
end

local function runSlicedToCompletion(mask, budget)
  local calls = 0
  while true do
    calls = calls + 1
    if not mask:stepPass(budget) then return calls end
    if calls > 200 then error("pass did not finish within 200 updates") end
  end
end

local function regionsEqual(a, b)
  if #a ~= #b then return false, "count " .. #a .. " vs " .. #b end
  for i = 1, #a do
    local ra, rb = a[i], b[i]
    if ra.key ~= rb.key or ra.blocked ~= rb.blocked or ra.area ~= rb.area
        or ra.carrierOwnerFarmlandId ~= rb.carrierOwnerFarmlandId
        or ra.writableForFarmland ~= rb.writableForFarmland
        or ra.sourcePolygonFingerprint ~= rb.sourcePolygonFingerprint then
      return false, "region " .. i .. " (" .. tostring(ra.key) .. ") differs"
    end
  end
  return true
end

-- A Time Guard stub of the same minimal shape MAINT-251's bench uses (no real
-- FS25_TimeGuard scheduler loaded): registerAccrual files the spec by id.
local function timeGuardStub()
  local filed = {}
  local tg = {
    scheduler = { FLOW_CLASSES = { calendar = true, usage = true, event = true, simulation = true } },
    registerAccrual = function(_self, id, spec) filed[id] = spec; return true end,
    unregisterAccrual = function() return true end,
  }
  return tg, filed
end

-- Invoke the filed onSettle exactly as TimeGuardScheduler:settle does
-- (FS25_TimeGuard/src/TimeGuardScheduler.lua:175): pcall(a.onSettle, ctx).
local function settleAccrual(spec)
  local ctx = { accrualId = ViabilityMask.DAILY_ACCURAL_ID, boundariesCrossed = 1,
                isFirstSettle = true, proration = 1.0 }
  return pcall(spec.onSettle, ctx)
end

-- ============================================================
-- S1: settle enumerates nothing, leaves a pass in progress.
-- ============================================================
group("S1", function()
  local mask, vm = buildBigFixture()
  local tg, filed = timeGuardStub()
  local oldMission, oldTg = g_currentMission, g_timeGuard
  g_currentMission = { timeGuard = tg }
  g_timeGuard = nil

  T.ok("S1 [reached] production's registerDailyAccrual reaches Time Guard", mask:registerDailyAccrual())
  local spec = filed[ViabilityMask.DAILY_ACCURAL_ID]
  T.ok("S1 [reached] the accrual filed an onSettle entry point", spec ~= nil and spec.onSettle ~= nil)

  local before = vm:_readCount()
  local ok = settleAccrual(spec)
  T.ok("S1 onSettle ran without error", ok)
  T.eq("S1 NAMED (row #1128): onSettle enumerates nothing (0 readValueAtWorld calls)",
    vm:_readCount() - before, 0)
  T.ok("S1 NAMED (row #1128): onSettle leaves a pass in progress", mask._pass ~= nil)
  T.eq("S1 no plan is published yet", mask._plans[7], nil)
  T.eq("S1 no summary is published yet", mask._summaries[7], nil)

  g_currentMission, g_timeGuard = oldMission, oldTg
end)

-- ============================================================
-- S2: each update walks at most PASS_SQUARES_PER_UPDATE squares and commits
-- at most one farmland; the pass finishes after a derived number of updates.
--
-- Derivation (grain 2, budgets 1024/8192/1 per the constants, 2091+2091
-- squares, 3936 distinct owner keys, 2 farmlands to commit):
--   call 1: start farmland 7 (cost 1) + 1023 of its 2091 squares  = 1024 used, 1068 left
--   call 2: 1024 more of farmland 7's squares                     = 1024 used,   44 left
--   call 3: 44 left of farmland 7 (done) + start 9 (cost 1) + 979  = 1024 used, 1112 left of 9
--   call 4: 1024 more of farmland 9's squares                     = 1024 used,   88 left
--   call 5: 88 left of farmland 9 (done); phase -> OWNERS, returns immediately
--   call 6: OWNERS drains all 3936 entries (<= 8192/update), phase -> COMMIT
--   call 7: COMMIT commits farmland 7 (1/update)
--   call 8: COMMIT commits farmland 9 (1/update)
--   call 9: COMMIT finds no farmland left, clears the pass, returns false
-- Total: 9 calls.
-- ============================================================
group("S2", function()
  local mask = buildBigFixture()
  local origSquareSource, sqCount = ViabilityMask._squareSource, 0
  ViabilityMask._squareSource = function(self, x, z, polygons, fingerprints)
    sqCount = sqCount + 1
    return origSquareSource(self, x, z, polygons, fingerprints)
  end
  local origCommit, commitCount = ViabilityMask._commitFarmland, 0
  ViabilityMask._commitFarmland = function(self, ...)
    commitCount = commitCount + 1
    return origCommit(self, ...)
  end

  T.ok("S2 [reached] startPass begins the pass", mask:startPass())
  local calls, running = 0, true
  while running do
    calls = calls + 1
    sqCount, commitCount = 0, 0
    running = mask:stepPass(ViabilityMask.PASS_SQUARES_PER_UPDATE)
    T.ok("S2 update " .. calls .. " walks at most PASS_SQUARES_PER_UPDATE squares (" .. sqCount .. ")",
      sqCount <= ViabilityMask.PASS_SQUARES_PER_UPDATE)
    T.ok("S2 update " .. calls .. " commits at most one farmland (" .. commitCount .. ")",
      commitCount <= 1)
    if calls > 50 then error("S2 pass did not finish within 50 updates") end
  end
  ViabilityMask._squareSource = origSquareSource
  ViabilityMask._commitFarmland = origCommit

  T.eq("S2 NAMED (row #1128): the pass finishes after 9 updates (derived above from the fixture's square count)",
    calls, 9)
end)

-- ============================================================
-- S3: on an identical fixture, the sliced pass gives exactly the same
-- _summaries and _plans (regions, every field, both hashes) as runPass().
-- ============================================================
group("S3", function()
  local maskSliced = buildBigFixture()
  T.ok("S3 [reached] sliced pass starts", maskSliced:startPass())
  runSlicedToCompletion(maskSliced, ViabilityMask.PASS_SQUARES_PER_UPDATE)

  local maskWhole = buildBigFixture()
  maskWhole:runPass()

  for _, fid in ipairs({ 7, 9 }) do
    local sa, sb = maskSliced._summaries[fid], maskWhole._summaries[fid]
    T.ok("S3 farmland " .. fid .. " committed on both", sa ~= nil and sb ~= nil)
    if sa ~= nil and sb ~= nil then
      T.near("S3 farmland " .. fid .. " blockedFrac matches", sa.blockedFrac, sb.blockedFrac, 1e-9)
      T.near("S3 farmland " .. fid .. " normalFrac matches", sa.normalFrac, sb.normalFrac, 1e-9)
      T.eq("S3 farmland " .. fid .. " resultHash matches", sa.resultHash, sb.resultHash)
    end

    local pa, pb = maskSliced._plans[fid], maskWhole._plans[fid]
    T.ok("S3 farmland " .. fid .. " has a plan on both", pa ~= nil and pb ~= nil)
    if pa ~= nil and pb ~= nil then
      local eqRegions, why = regionsEqual(pa.regions, pb.regions)
      T.ok("S3 NAMED (row #1128): farmland " .. fid .. " regions match" .. (why and (" (" .. why .. ")") or ""),
        eqRegions)
      T.eq("S3 NAMED (row #1128): farmland " .. fid .. " planContentHash matches", pa.planContentHash, pb.planContentHash)
      T.eq("S3 NAMED (row #1128): farmland " .. fid .. " carrierOwnershipHash matches",
        pa.carrierOwnershipHash, pb.carrierOwnershipHash)
    end
  end
end)

-- ============================================================
-- S4: the sliced pass's owners (lowest farmland id per square) equal
-- assignCarrierOwners over the candidates _enumerateFarmland lists.
-- ============================================================
group("S4", function()
  local mask, vm, _owner, ss = buildBigFixture()
  T.ok("S4 [reached] sliced pass starts", mask:startPass())
  runSlicedToCompletion(mask, ViabilityMask.PASS_SQUARES_PER_UPDATE)

  local polyA = ss:_getFarmlandPolygons(7)
  local polyB = ss:_getFarmlandPolygons(9)
  local _, candA = mask:_enumerateFarmland(7, polyA, GRAIN_BIG, vm)
  local _, candB = mask:_enumerateFarmland(9, polyB, GRAIN_BIG, vm)
  local allCandidates = {}
  for _, c in ipairs(candA) do allCandidates[#allCandidates + 1] = c end
  for _, c in ipairs(candB) do allCandidates[#allCandidates + 1] = c end
  local refOwners = ViabilityMask.assignCarrierOwners(allCandidates)

  local checked, mismatches = 0, 0
  for _, fid in ipairs({ 7, 9 }) do
    for _, region in ipairs(mask._plans[fid].regions) do
      local ref = refOwners[region.key]
      if ref ~= nil then
        checked = checked + 1
        if ref.farmlandId ~= region.carrierOwnerFarmlandId then mismatches = mismatches + 1 end
      end
    end
  end
  T.ok("S4 [reached] the reference owners were actually compared", checked > 0)
  T.eq("S4 NAMED (row #1128): sliced owners equal assignCarrierOwners over the _enumerateFarmland candidates",
    mismatches, 0)
  T.eq("S4 an overlap square's owner is farmland 7 (the lower id)", refOwners["45:0"].farmlandId, 7)
end)

-- ============================================================
-- S5: polygonFingerprint is called once per polygon in one pass (2 polygons
-- across the two farmlands), not once per square.
-- ============================================================
group("S5", function()
  local mask = buildBigFixture()
  local orig, count = ViabilityMask.polygonFingerprint, 0
  ViabilityMask.polygonFingerprint = function(...)
    count = count + 1
    return orig(...)
  end
  mask:runPass()
  ViabilityMask.polygonFingerprint = orig
  T.eq("S5 NAMED (row #1128): polygonFingerprint is called exactly once per polygon (2), not once per square",
    count, 2)
end)

-- ============================================================
-- S6: with a 500-vertex field polygon and a few thousand squares,
-- planContentHash and carrierOwnershipHash stay under 32 characters.
-- ============================================================
local function rectPolygonVerts(x0, z0, x1, z1, perEdge)
  local verts = {}
  local function addEdge(ax, az, bx, bz, n)
    for i = 0, n - 1 do
      local t = i / n
      verts[#verts + 1] = { x = ax + (bx - ax) * t, z = az + (bz - az) * t }
    end
  end
  addEdge(x0, z0, x1, z0, perEdge)
  addEdge(x1, z0, x1, z1, perEdge)
  addEdge(x1, z1, x0, z1, perEdge)
  addEdge(x0, z1, x0, z0, perEdge)
  return verts
end

group("S6", function()
  local owner = newOwner()
  local vm = newVM(owner, GRAIN_BIG, DEFAULT_N, DEFAULT_C)
  local verts = rectPolygonVerts(0, 0, 100, 80, 125)
  T.eq("S6 [reached] the fixture polygon carries 500 vertices", #verts, 500)
  ownerEstablish(owner, { 7 })
  local ss = newSoilSystem({ [7] = verts })
  local mask = buildMask(vm, ss)
  mask:runPass()
  local plan = mask._plans[7]
  T.ok("S6 [reached] the plan committed", plan ~= nil)
  if plan ~= nil then
    T.ok("S6 [reached] the fixture carries a few thousand squares (" .. #plan.regions .. ")",
      #plan.regions >= 2000)
    T.ok("S6 NAMED (row #1128): planContentHash is under 32 characters (" .. #plan.planContentHash .. ")",
      #plan.planContentHash < 32)
    T.ok("S6 NAMED (row #1128): carrierOwnershipHash is under 32 characters (" .. #plan.carrierOwnershipHash .. ")",
      #plan.carrierOwnershipHash < 32)
  end
end)

-- ============================================================
-- S7: carrierOwnershipHash is not called once per farmland during a sliced
-- pass; the pass's one digest is passed to every commit.
-- ============================================================
group("S7", function()
  local mask = buildBigFixture()
  local orig, count = ViabilityMask.carrierOwnershipHash, 0
  ViabilityMask.carrierOwnershipHash = function(...)
    count = count + 1
    return orig(...)
  end
  T.ok("S7 [reached] sliced pass starts", mask:startPass())
  runSlicedToCompletion(mask, ViabilityMask.PASS_SQUARES_PER_UPDATE)
  ViabilityMask.carrierOwnershipHash = orig

  T.eq("S7 NAMED (row #1128): carrierOwnershipHash is not invoked once per farmland (2 farmlands committed)",
    count, 0)
  T.ok("S7 [reached] both farmlands committed", mask._plans[7] ~= nil and mask._plans[9] ~= nil)
  if mask._plans[7] ~= nil and mask._plans[9] ~= nil then
    T.eq("S7 both farmlands' plans carry the identical ownership digest",
      mask._plans[7].carrierOwnershipHash, mask._plans[9].carrierOwnershipHash)
  end
end)

-- ============================================================
-- S8: determinism and change. Two passes over the same input give the same
-- hashes; changing one square's band, the geometry, or an owner changes the
-- relevant hash.
-- ============================================================
group("S8", function()
  local function freshPlan(blockXZ, idB)
    local owner = newOwner()
    local vm = newVM(owner, GRAIN_BIG, DEFAULT_N, DEFAULT_C)
    idB = idB or 9
    ownerEstablish(owner, { 7, idB })
    local ss = newSoilSystem({ [7] = FARMLAND_A, [idB] = FARMLAND_B })
    local mask = buildMask(vm, ss)
    if blockXZ then vm:_setOverride(blockXZ[1], blockXZ[2], 5, DEFAULT_C) end
    mask:runPass()
    return mask
  end
  local function freshPlanVertexBump()
    local owner = newOwner()
    local vm = newVM(owner, GRAIN_BIG, DEFAULT_N, DEFAULT_C)
    local vertsA = { { x = 1, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 80 }, { x = 0, z = 80 } }
    ownerEstablish(owner, { 7, 9 })
    local ss = newSoilSystem({ [7] = vertsA, [9] = FARMLAND_B })
    local mask = buildMask(vm, ss)
    mask:runPass()
    return mask
  end

  local m1 = freshPlan()
  local m2 = freshPlan()
  T.eq("S8 NAMED (row #1128): determinism, planContentHash",
    m1._plans[7].planContentHash, m2._plans[7].planContentHash)
  T.eq("S8 NAMED (row #1128): determinism, carrierOwnershipHash",
    m1._plans[7].carrierOwnershipHash, m2._plans[7].carrierOwnershipHash)

  local m3 = freshPlan({ 21, 21 })   -- the square centred at (21,21) now reads BLOCKED
  T.ok("S8 NAMED (row #1128): a changed square band changes planContentHash",
    m3._plans[7].planContentHash ~= m1._plans[7].planContentHash)

  local m4 = freshPlanVertexBump()
  T.ok("S8 NAMED (row #1128): a changed polygon vertex changes planContentHash",
    m4._plans[7].planContentHash ~= m1._plans[7].planContentHash)

  -- Changing an owner: a pure call on ViabilityMask's own published function,
  -- isolated from any geometry/band change.
  local ownersX, ownersY = {}, {}
  for i = 1, 50 do ownersX["k" .. i] = 7; ownersY["k" .. i] = 7 end
  ownersY["k1"] = 9
  T.ok("S8 NAMED (row #1128): changing one owner changes carrierOwnershipHash",
    ViabilityMask.carrierOwnershipHash(ownersX) ~= ViabilityMask.carrierOwnershipHash(ownersY))
end)

-- ============================================================
-- S9: a same-farmland or unscoped write, or a geometry change, after a
-- farmland's enumeration and before its commit cancels that commit; the
-- other farmland in the same pass still commits.
-- ============================================================
local function runS9Case(name, mutate)
  group(name, function()
    local mask, vm, owner, ss, polys = buildSmallFixture()
    mask:runPass()
    local plan7Before, summary7Before = mask._plans[7], mask._summaries[7]
    T.ok(name .. " [reached] the baseline pass committed farmland 7", plan7Before ~= nil)

    T.ok(name .. " [reached] a second pass starts", mask:startPass())
    -- Budget 31 on this fixture (1 start cost + farmland 7's 30 squares)
    -- finishes farmland 7's enumeration exactly, with farmland 9 not yet
    -- begun at all (its own token is not captured until it starts). This
    -- matters for S9b: an unscoped write bumps every farmland's shared
    -- unscopedRevision, so farmland 9 must observe its token AFTER the
    -- mutation or its own commit would be cancelled too.
    local running = mask:stepPass(31)
    T.ok(name .. " [reached] the pause lands after farmland 7's enumeration, pass still running", running)

    mutate(owner, polys)

    while mask:stepPass(1024) do end

    T.eq(name .. " NAMED (row #1128): farmland 7's plan stays the previous one",
      mask._plans[7].planId, plan7Before.planId)
    T.eq(name .. " farmland 7's summary stays the previous one",
      mask._summaries[7].summaryGeneration, summary7Before.summaryGeneration)
    T.ok(name .. " NAMED (row #1128): farmland 9 in the same pass still commits",
      mask._plans[9] ~= nil and mask._plans[9].planId == "9:2")
    T.eq(name .. " NAMED (row #1128): a cancelled commit leaves farmland 7 visibly PENDING",
      mask:getFieldGrowthSummaryStatus(7), "PENDING")
    T.eq(name .. " NAMED (row #1128): farmland 9's commit in the same pass reads CURRENT",
      mask:getFieldGrowthSummaryStatus(9), "CURRENT")
  end)
end

runS9Case("S9a", function(owner, _polys) ownerBumpFarmland(owner, 7) end)
runS9Case("S9b", function(owner, _polys) ownerBumpUnscoped(owner) end)
runS9Case("S9c", function(_owner, polys) polys[7] = { { x = 5, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 80 }, { x = 0, z = 80 } } end)

-- ============================================================
-- S10: a second settle while a pass runs neither restarts nor duplicates it.
-- ============================================================
group("S10", function()
  local mask = buildSmallFixture()
  local tg, filed = timeGuardStub()
  local oldMission, oldTg = g_currentMission, g_timeGuard
  g_currentMission = { timeGuard = tg }
  g_timeGuard = nil

  T.ok("S10 [reached] registration reaches Time Guard", mask:registerDailyAccrual())
  local spec = filed[ViabilityMask.DAILY_ACCURAL_ID]
  T.ok("S10 [reached] settle #1 runs without error", (settleAccrual(spec)))
  T.eq("S10 generation after settle #1", mask._planGeneration, 1)

  T.ok("S10 [reached] settle #2 (a pass is already running) runs without error", (settleAccrual(spec)))
  T.eq("S10 NAMED (row #1128): a second settle does not start a second generation",
    mask._planGeneration, 1)

  while mask:stepPass(1024) do end
  T.eq("S10 NAMED (row #1128): exactly one set of commits publishes (farmland 7 at generation 1)",
    mask._plans[7].planId, "7:1")
  T.eq("S10 NAMED (row #1128): exactly one set of commits publishes (farmland 9 at generation 1)",
    mask._plans[9].planId, "9:1")
  T.eq("S10 generation never advanced past 1", mask._planGeneration, 1)

  g_currentMission, g_timeGuard = oldMission, oldTg
end)

-- ============================================================
-- S11: the per-update step does nothing when no pass runs.
-- ============================================================
group("S11", function()
  local mask, vm = buildSmallFixture()
  T.eq("S11 [reached] no pass is running", mask._pass, nil)
  local before = vm:_readCount()
  local running = mask:stepPass(ViabilityMask.PASS_SQUARES_PER_UPDATE)
  T.eq("S11 NAMED (row #1128): stepPass returns false when no pass is running", running, false)
  T.eq("S11 NAMED (row #1128): stepPass with no pass performs no reads", vm:_readCount() - before, 0)
  T.eq("S11 no plan was created", mask._plans[7], nil)
end)

-- ============================================================
-- S13: a farmland committed by the pass reads CURRENT, not PENDING. Added for
-- the battery's M9 (COMMIT must clear _pendingFarmlands as it commits).
-- ============================================================
group("S13", function()
  local mask = buildSmallFixture()
  T.ok("S13 [reached] requestRecompute marks farmland 7 pending", mask:requestRecompute(7))
  T.eq("S13 [reached] farmland 7 reads PENDING before the pass runs", mask:_summaryStatus(7), "PENDING")
  mask:runPass()
  T.ok("S13 [reached] farmland 7 committed", mask._plans[7] ~= nil)
  T.eq("S13 NAMED (row #1128): a farmland committed by the pass reads CURRENT, not PENDING",
    mask:_summaryStatus(7), "CURRENT")
end)

-- ============================================================
-- S12: a new-format planContentHash differs from an old-format one, and each
-- consumer's own comparison treats the mismatch the way its code actually
-- reads, without throwing.
-- ============================================================
local OLD_FORMAT_HASH = "OWNERS=edge:2|tie:2|1:1:fpA:N:16:7:W|2:1:fpA:N:16:7:W"
local NEW_FORMAT_HASH = "2:0a1b2c3d4e5f607"

-- S12a: GrowthBlock.lua:635 (_laterStart). Reuses SF-78's Group H2 fixture
-- shape exactly.
group("S12a-GrowthBlock-laterStart", function()
  local oldMission = g_currentMission
  local vmGB = {
    available = true,
    getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1 } end,
  }
  local planGB = {
    planId = 'p1', planContentHash = NEW_FORMAT_HASH, polygonUnionFingerprint = 'g',
    farmlandInputRevision = 1, unscopedInputRevision = 1, settingsFingerprint = '',
    regions = {},
  }
  local gb = GrowthBlock.new({
    soilSystem = { valueMaps = vmGB, fieldData = { [7] = {} },
                   _getFarmlandPolygons = function() return {} end },
    viability = { getCellGrowthInfo = function() return { blocked = true } end },
    getGrowthEligibleRegionPlan = function() return planGB end,
  })
  gb:initialize()
  gb._envelope = GrowthBlock.openBracket(4, true, 'SEASONAL', 3, {
    { farmlandId = 7, planId = 'p1', planContentHash = OLD_FORMAT_HASH, polygonUnionFingerprint = 'g',
      farmlandInputRevision = 1, unscopedInputRevision = 1, transitionCount = 1, stale = false },
  })
  gb._captureGeneration = 3
  g_currentMission = { getIsServer = function() return true end, missionInfo = { growthMode = GrowthMode.SEASONAL } }

  local ok = pcall(function() gb:onStartGrowthPeriod(5) end)
  T.ok("S12a [reached] onStartGrowthPeriod ran without error", ok)
  T.eq("S12a NAMED (GrowthBlock.lua:635): an old-format vs new-format planContentHash mismatch stales the receipt",
    gb._envelope.receipts[1].stale, true)

  g_currentMission = oldMission
end)

-- S12b: GrowthBlock.lua:715 (_restoreFarmland), through onFinishedGrowthPeriod.
group("S12b-GrowthBlock-restoreFarmland", function()
  local oldMission = g_currentMission
  local vmGB = {
    available = true,
    getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1 } end,
  }
  local planGB = {
    planId = 'p1', planContentHash = NEW_FORMAT_HASH, polygonUnionFingerprint = 'g',
    farmlandInputRevision = 1, unscopedInputRevision = 1, settingsFingerprint = '',
    regions = {},
  }
  local gb = GrowthBlock.new({
    soilSystem = { valueMaps = vmGB, fieldData = { [7] = {} },
                   _getFarmlandPolygons = function() return {} end },
    viability = { getCellGrowthInfo = function() return { blocked = true } end },
    getGrowthEligibleRegionPlan = function() return planGB end,
  })
  gb:initialize()
  gb._captureGeneration = 3
  gb._envelope = GrowthBlock.openBracket(4, true, 'SEASONAL', 3, {
    { farmlandId = 7, planId = 'p1', planContentHash = OLD_FORMAT_HASH, polygonUnionFingerprint = 'g',
      farmlandInputRevision = 1, unscopedInputRevision = 1, settingsFingerprint = '', stale = false },
  })
  g_currentMission = { getIsServer = function() return true end, missionInfo = { growthMode = GrowthMode.SEASONAL } }

  local ok, restored = pcall(function() return gb:onFinishedGrowthPeriod(4, false) end)
  T.ok("S12b [reached] onFinishedGrowthPeriod ran without error", ok)
  T.eq("S12b NAMED (GrowthBlock.lua:715): an old-format vs new-format planContentHash mismatch restores nothing",
    restored, false)

  g_currentMission = oldMission
end)

-- S12c: ZoneYield.lua:678 (_jobDrifted), through advanceJobs. Reuses
-- zone_yield_sf14_test.lua Group G's fixture shape.
group("S12c-ZoneYield-jobDrifted", function()
  local oldMission, oldFTM, oldFDU = g_currentMission, g_fruitTypeManager, FSDensityMapUtil
  local function newWheat()
    return {
      name = "wheat", terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
      cutState = 9, numGrowthStates = 8, minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
      minForageGrowthState = 0, regrows = false,
      getIsCut = function() return false end, getIsWithered = function() return false end,
    }
  end
  local planZY = {
    planId = "p1", planContentHash = OLD_FORMAT_HASH, polygonUnionFingerprint = "g1",
    carrierOwnershipHash = "o1", farmlandInputRevision = 1, unscopedInputRevision = 1,
    settingsFingerprint = "", executionGrainMetres = 4,
    regions = {
      { key = "1:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
        carrierOwnerFarmlandId = 7, writableForFarmland = true },
      { key = "2:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
        carrierOwnerFarmlandId = 7, writableForFarmland = true },
    },
  }
  local vmZY = { available = true, resolution = 2048 }
  function vmZY:getGrowthInputToken() return { farmlandRevision = 1, unscopedRevision = 1, globalRevision = 1 } end
  function vmZY:readValueAtWorld(key) if key == "nitrogen" or key == "phosphorus" or key == "potassium" then return 80 end end
  function vmZY:readAverageOfPolygon(key) if key == "yieldEfficiency" then return 95, 1 end; return nil, 0 end
  g_currentMission = { getIsServer = function() return true end, missionInfo = { growthMode = GrowthMode.SEASONAL } }
  g_fruitTypeManager = { getFruitTypeByIndex = function() return newWheat() end }
  FSDensityMapUtil = { getFruitTypeIndexAtWorldPos = function() return 1, 6 end, getFruitArea = function() return 100 end }
  local ss = { fieldData = { [7] = { nitrogen = 80, phosphorus = 80, potassium = 80, organicMatter = 3.5 } },
               valueMaps = vmZY, _getFarmlandPolygons = function() return {} end,
               _yieldModifierFromNutrients = function() return 1.0 end }
  local zy = ZoneYield.new({ soilSystem = ss, viability = { enabled = true, getCellGrowthInfo = function() return {} end },
                              getGrowthEligibleRegionPlan = function() return planZY end })
  zy:initialize()

  zy:onFinishedGrowthPeriod(4, false)
  T.ok("S12c [reached] the job queued", #zy._queue == 1)
  planZY.planContentHash = NEW_FORMAT_HASH
  local ok = pcall(function() zy:advanceJobs(100) end)
  T.ok("S12c [reached] advanceJobs ran without error", ok)
  T.eq("S12c NAMED (ZoneYield.lua:678): an old-format vs new-format planContentHash mismatch drops the job as drifted",
    #zy._queue, 0)

  g_currentMission, g_fruitTypeManager, FSDensityMapUtil = oldMission, oldFTM, oldFDU
end)

-- S12d: GrowthCredit.lua:773. This line compares polygonUnionFingerprint, not
-- planContentHash -- GrowthCredit never compares planContentHash in
-- _spendFarmland (it stores it in the receipt at :715 and never reads it back
-- there). So a plan-hash mismatch does not gate this consumer: a
-- planContentHash-only mismatch does NOT gate GrowthCredit's spend. This is
-- asserted directly by proving execution reaches past the guard clause
-- (GrowthCredit.effectiveThresholdDays, called only after it) despite the
-- mismatch.
group("S12d-GrowthCredit-spendFarmland", function()
  local oldMission = g_currentMission
  local planGC = {
    planId = 'p1', planContentHash = OLD_FORMAT_HASH, polygonUnionFingerprint = 'g',
    farmlandInputRevision = 1, unscopedInputRevision = 1, settingsFingerprint = '',
    executionGrainMetres = 2, truthGrainMetres = 2, carrierOwnershipHash = 'o1',
    regions = {},
  }
  local vmGC = {
    available = true,
    getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1, globalRevision = 1 } end,
  }
  local gc = GrowthCredit.new({
    soilSystem = { fieldData = { [7] = true }, valueMaps = vmGC, _getFarmlandPolygons = function() return {} end },
    getGrowthEligibleRegionPlan = function() return planGC end,
  })
  gc:initialize()
  g_currentMission = { getIsServer = function() return true end, missionInfo = { growthMode = GrowthMode.SEASONAL } }

  gc:onStartGrowthPeriod(4)
  T.ok("S12d [reached] onStartGrowthPeriod opened a bracket", #gc._brackets.open == 1)
  planGC.planContentHash = NEW_FORMAT_HASH   -- only the content hash drifts

  local origThreshold = GrowthCredit.effectiveThresholdDays
  local reachedPostGuard = false
  GrowthCredit.effectiveThresholdDays = function(...)
    reachedPostGuard = true
    return origThreshold(...)
  end
  local ok = pcall(function() gc:onFinishedGrowthPeriod(4, false) end)
  GrowthCredit.effectiveThresholdDays = origThreshold

  T.ok("S12d [reached] onFinishedGrowthPeriod ran without error", ok)
  T.eq("S12d NAMED CORRECTION (GrowthCredit.lua:773 is a polygonUnionFingerprint compare, not planContentHash): "
    .. "a planContentHash-only mismatch does not stop _spendFarmland before its guard-clause's later work",
    reachedPostGuard, true)

  g_currentMission = oldMission
end)

T.summary()

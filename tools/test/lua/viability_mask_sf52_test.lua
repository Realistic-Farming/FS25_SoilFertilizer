-- viability_mask_sf52_test.lua
-- SF-52 v1 THE VIABILITY MASK: the executable bar for the three-band
-- classifier and the published contract.
--
-- SCOPE IS v1, per Arissani's split ruling. The engine write (step 5) is NOT
-- built and is not tested here; what IS tested is everything three other rows
-- are waiting on: the bands, the combination rule, the area-fraction summary,
-- and the getter family's shape.
--
-- THE INVARIANT THAT MATTERS MOST: an unreadable input is NOT a block.
-- "We do not know" rendered as "this ground is dead" would stop growth on a
-- field for a reason nobody could see or explain.
--!load: src/utils/Logger.lua, src/ViabilityMask.lua

local V = ViabilityMask

-- 1. NITROGEN BANDS, at and around every boundary.
do
  T.eq('n.wellBelow',   V.bandNitrogen(0),    V.BAND_BLOCKED)
  T.eq('n.justBelow',   V.bandNitrogen(19.9), V.BAND_BLOCKED)
  T.eq('n.atThreshold', V.bandNitrogen(20),   V.BAND_NORMAL)     -- not below
  T.eq('n.mid',         V.bandNitrogen(40),   V.BAND_NORMAL)
  T.eq('n.atExcellent', V.bandNitrogen(60),   V.BAND_NORMAL)     -- not above
  T.eq('n.aboveExcellent', V.bandNitrogen(60.1), V.BAND_EXCELLENT)
  T.eq('n.high',        V.bandNitrogen(100),  V.BAND_EXCELLENT)
end

-- 2. COMPACTION BANDS. Higher is WORSE, so the comparisons invert.
do
  T.eq('c.clean',       V.bandCompaction(0),    V.BAND_EXCELLENT)
  T.eq('c.justUnder',   V.bandCompaction(29.9), V.BAND_EXCELLENT)
  T.eq('c.atExcellent', V.bandCompaction(30),   V.BAND_NORMAL)   -- not below
  T.eq('c.mid',         V.bandCompaction(50),   V.BAND_NORMAL)
  T.eq('c.atBlocked',   V.bandCompaction(70),   V.BAND_NORMAL)   -- not above
  T.eq('c.justOver',    V.bandCompaction(70.1), V.BAND_BLOCKED)
  T.eq('c.crushed',     V.bandCompaction(100),  V.BAND_BLOCKED)
end

-- 3. AN UNREADABLE INPUT IS NOT A BLOCK. This is the invariant, so it is
--    asserted for every band and for the combination.
do
  T.eq('unknown.nitrogenNil',   V.bandNitrogen(nil),   nil)
  T.eq('unknown.nitrogenText',  V.bandNitrogen('40'),  nil)
  T.eq('unknown.compactionNil', V.bandCompaction(nil), nil)
  T.eq('unknown.allNil', V.combine({ n = nil, compaction = nil, moisture = nil }), nil)
  T.eq('unknown.emptyTable', V.combine({}), nil)
  T.eq('unknown.nilTable', V.combine(nil), nil)
end

-- 4. MOISTURE IS INERT IN v1, ON PURPOSE, AND THIS TEST GUARDS THAT.
--    The brief's source for the window (FruitTypeDesc.min/maxWaterLitersPerSqm)
--    is STANDING WATER IN LITRES PER SQM, certified at the decompile against
--    RiceFieldUpdateTask:performPerlinNoiseDestruction. SCS moisture is a 0..1
--    fraction. Comparing them would classify every crop with a window as
--    permanently BLOCKED and stop its growth forever, silently.
--    If somebody wires this band up, they must change this test deliberately.
do
  T.eq('moisture.inertDry',  V.bandMoisture(0.0), nil)
  T.eq('moisture.inertWet',  V.bandMoisture(1.0), nil)
  T.eq('moisture.inertMid',  V.bandMoisture(0.5), nil)
  T.eq('moisture.inertNil',  V.bandMoisture(nil), nil)
  -- And it must not drag a field into BLOCKED by itself.
  T.eq('moisture.doesNotBlock',
       V.combine({ n = V.BAND_NORMAL, compaction = V.BAND_NORMAL, moisture = V.bandMoisture(0.0) }),
       V.BAND_NORMAL)
end

-- 5. THE COMBINATION RULE: any BLOCKED wins; EXCELLENT only when nothing is
--    blocked; a nil band abstains rather than voting.
do
  local B, N, E = V.BAND_BLOCKED, V.BAND_NORMAL, V.BAND_EXCELLENT
  T.eq('combine.oneBlocked',    V.combine({ n = B, compaction = E }), B)
  T.eq('combine.blockedBeatsExcellent', V.combine({ n = E, compaction = B }), B)
  T.eq('combine.allNormal',     V.combine({ n = N, compaction = N }), N)
  T.eq('combine.oneExcellent',  V.combine({ n = E, compaction = N }), E)
  T.eq('combine.allExcellent',  V.combine({ n = E, compaction = E }), E)
  T.eq('combine.nilAbstains',   V.combine({ n = E, compaction = nil }), E)
  T.eq('combine.nilDoesNotBlock', V.combine({ n = N, compaction = nil }), N)
end

-- 6. THE AREA-FRACTION SUMMARY, which is SCS-020's whole contract.
do
  local B, N, E = V.BAND_BLOCKED, V.BAND_NORMAL, V.BAND_EXCELLENT

  local all = V.summariseSamples({ B, B, B, B })
  T.near('summary.allBlocked', all.blockedFrac, 1.0, 1e-9)
  T.near('summary.allBlockedNoneExcellent', all.excellentFrac, 0.0, 1e-9)

  local none = V.summariseSamples({ N, N, N, N })
  T.near('summary.noneBlocked', none.blockedFrac, 0.0, 1e-9)

  local mixed = V.summariseSamples({ B, N, E, N, B, N, E, N })
  T.near('summary.mixedBlocked', mixed.blockedFrac, 0.25, 1e-9)
  T.near('summary.mixedExcellent', mixed.excellentFrac, 0.25, 1e-9)
  T.eq('summary.sampleCount', mixed.samples, 8)

  -- Fractions are fractions: never negative, never over 1, and the two
  -- together can never exceed the whole field.
  T.ok('summary.inRange', mixed.blockedFrac >= 0 and mixed.blockedFrac <= 1)
  T.ok('summary.sumBounded', mixed.blockedFrac + mixed.excellentFrac <= 1 + 1e-9)

  -- nil bands (unknown ground) count toward the denominator but neither band.
  local withUnknown = V.summariseSamples({ B, nil, N, E })
  T.ok('summary.unknownHandled', withUnknown ~= nil)

  -- No samples means no answer, not a zeroed answer: a field we could not read
  -- is not a field that is 0% blocked.
  T.eq('summary.emptyIsNil', V.summariseSamples({}), nil)
  T.eq('summary.nilIsNil', V.summariseSamples(nil), nil)
end

-- 7. THE PUBLISHED GETTERS' SHAPE. Three rows bind to this, so the keys are
--    part of the contract and not an implementation detail.
do
  local mask = V.new({ soilSystem = nil })
  mask.isInitialized = true

  -- No value maps available: the getter must refuse quietly, never throw
  -- across the mod boundary and never invent a reading.
  T.eq('getter.noMapsIsNil', mask:getCellGrowthInfo(1, 0, 0), nil)
  T.eq('getter.noSummaryIsNil', mask:getFieldGrowthSummary(1), nil)
  T.eq('getter.nilFieldIsNil', mask:getFieldGrowthSummary(nil), nil)

  -- The summary serves what the pass computed, and only the two published keys.
  mask._summaries[7] = { blockedFrac = 0.3, excellentFrac = 0.1, samples = 40 }
  local s = mask:getFieldGrowthSummary(7)
  T.near('getter.summaryBlocked', s.blockedFrac, 0.3, 1e-9)
  T.near('getter.summaryExcellent', s.excellentFrac, 0.1, 1e-9)

  -- Unbuilt siblings read neutral, never zero. Zero is a measurement.
  T.eq('getter.creditNilUntilSF53', mask:_readCredit(7, 0, 0), nil)
  T.eq('getter.capturedNilUntilSF14', mask:_readCapturedEfficiency(7, 0, 0), nil)
end

-- 8. THE MASK ENABLE is default-on (Tyson's ruling) and gates the getters.
do
  local mask = V.new({ soilSystem = nil })
  T.eq('enable.defaultOn', mask.enabled, true)

  mask._summaries[3] = { blockedFrac = 0.5, excellentFrac = 0.0, samples = 10 }
  T.ok('enable.servesWhenOn', mask:getFieldGrowthSummary(3) ~= nil)

  mask:setEnabled(false)
  T.eq('enable.offRefusesSummary', mask:getFieldGrowthSummary(3), nil)
  T.eq('enable.offRefusesCell', mask:getCellGrowthInfo(3, 0, 0), nil)
  T.eq('enable.offRunsNoPass', mask:runPass(), 0)

  mask:setEnabled(true)
  T.ok('enable.backOn', mask:getFieldGrowthSummary(3) ~= nil)
end

-- 9. THE DIAL FAMILY IS ONE GROUPED DECLARATION with the brief's neutral
--    defaults. Locked here so a later edit is a deliberate act, not a drift.
do
  T.eq('dial.nBlocked',   V.N_BLOCKED_BELOW, 20.0)
  T.eq('dial.nExcellent', V.N_EXCELLENT_ABOVE, 60.0)
  T.eq('dial.cBlocked',   V.COMPACTION_BLOCKED_ABOVE, 70.0)
  T.eq('dial.cExcellent', V.COMPACTION_EXCELLENT_BELOW, 30.0)
  T.ok('dial.nOrdered', V.N_BLOCKED_BELOW < V.N_EXCELLENT_ABOVE)
  T.ok('dial.cOrdered', V.COMPACTION_EXCELLENT_BELOW < V.COMPACTION_BLOCKED_ABOVE)
end

-- 10. v1 MAKES NO ENGINE CALL. The whole split rests on this, so it is asserted
--     rather than trusted: no reference to the blocked lever exists anywhere on
--     the module.
do
  T.eq('v1.noSetGrowthMask', rawget(V, 'setGrowthMask'), nil)
  T.eq('v1.noResetGrowthMask', rawget(V, 'resetGrowthMask'), nil)
  T.eq('v1.noWriteMethod', rawget(V, 'writeMask'), nil)
end


-- 11. THE CROSS-MOD SURFACE. Two of the three consumers live in OTHER mods and
--     can only reach us through g_currentMission.soilFertilityManager, so the
--     contract is delegated onto the manager rather than left on the internal
--     `viability` field. Binding to that field would let a refactor here rename
--     the contract out from under three mods at once.
do
  -- A stand-in manager carrying only the delegate shape.
  local mgr = { viability = V.new({ soilSystem = nil }) }
  mgr.getCellGrowthInfo = function(self, fieldId, x, z)
    local v = self.viability
    if v == nil or type(v.getCellGrowthInfo) ~= 'function' then return nil end
    local ok, info = pcall(function() return v:getCellGrowthInfo(fieldId, x, z) end)
    if not ok then return nil end
    return info
  end
  mgr.getFieldGrowthSummary = function(self, fieldId)
    local v = self.viability
    if v == nil or type(v.getFieldGrowthSummary) ~= 'function' then return nil end
    local ok, s = pcall(function() return v:getFieldGrowthSummary(fieldId) end)
    if not ok then return nil end
    return s
  end

  mgr.viability._summaries[11] = { blockedFrac = 0.4, excellentFrac = 0.2, samples = 25 }
  local s = mgr:getFieldGrowthSummary(11)
  T.near('bridge.summaryReaches', s.blockedFrac, 0.4, 1e-9)

  -- Absent subsystem must be nil, never a throw across the boundary.
  local empty = { viability = nil }
  empty.getFieldGrowthSummary = mgr.getFieldGrowthSummary
  empty.getCellGrowthInfo = mgr.getCellGrowthInfo
  T.eq('bridge.noSubsystemSummary', empty:getFieldGrowthSummary(11), nil)
  T.eq('bridge.noSubsystemCell', empty:getCellGrowthInfo(11, 0, 0), nil)

  -- A subsystem that throws is swallowed into nil, not propagated.
  local angry = { viability = { getFieldGrowthSummary = function() error('boom') end } }
  angry.getFieldGrowthSummary = mgr.getFieldGrowthSummary
  T.eq('bridge.throwBecomesNil', angry:getFieldGrowthSummary(11), nil)
end

T.summary()

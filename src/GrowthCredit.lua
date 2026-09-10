-- ============================================================
-- GrowthCredit.lua  (SF-53, One Ground conformance)
--
-- THE REWARD HALF OF THE SF-2M MODULATION FAMILY. Ground held in
-- excellent condition long enough ripens one growth step ahead of
-- the field's own clock, on the real crop, in patches at the SF-52
-- provider's execution grain.
--
-- WHAT CHANGED IN THE ONE GROUND CONFORMANCE (SF-53-FIX amendment):
--   The retired first-polygon 8 m / 600-point adaptive lattice and the
--   ephemeral per-field Lua bank are gone. The bank now lives in two
--   server-only file-backed layers inside the current SoilValueMaps
--   carrier (growthCreditDays + growthCreditFruit), keyed by the same
--   world-origin-aligned carrier grid the SF-52 plan enumerates, and the
--   daily walk iterates the SF-52 eligible-region plan per farmland.
--   A manager-owned START/FINISHED growth dispatch feeds ordered
--   brackets with an immutable target period; a drained stable bracket
--   re-enumerates provider-owned regions and spends only verified
--   post-state cells. Small metadata rides the existing soilData XML
--   and the optional StateLedger mirror; the dense cell truth is the
--   two GRLE files. No fifth growth map, no network bank, no client
--   authority. Native fruit-plane writes, polygon clipping, engine sync,
--   real save bytes and frame time remain in-game proof (release LOCKED).
-- ============================================================

GrowthCredit = GrowthCredit or {}
local GrowthCredit_mt = Class(GrowthCredit)

-- Time Guard accrual. Priority 97 lands one behind the foundation's 96
-- (ViabilityMask), so the ground has settled and the dead have been counted
-- before anyone earns a reward.
GrowthCredit.DAILY_ACCURAL_ID       = 'SF53_growthCredit'
GrowthCredit.DAILY_ACCURAL_PRIORITY = 97

-- The credit threshold declaration (dial = agronomy, base 2 growth periods,
-- neutral 2, clamped 1..3). Resolved through the vendored
-- OptionScalingResolver.readProfile / resolve contract (SDS v2.6).
GrowthCredit.THRESHOLD_DECLARATION = {
    dial      = "agronomy",
    base      = 2,
    neutral   = 2,
    clampMin  = 1,
    clampMax  = 3,
}

-- Bank contract limits (SDS units table; invariant of the 8-bit pack).
GrowthCredit.CREDIT_DAYS_MAX = 84     -- three periods at 28 days
GrowthCredit.APPLIED_BIT     = 128    -- high bit of the credit byte
GrowthCredit.FRUIT_MAX       = 63     -- engine fruit index limit (six bits)

-- Pair-classification outcomes (brief 3.1).
GrowthCredit.PAIR_FRESH        = 'FRESH'
GrowthCredit.PAIR_COMPLETE     = 'COMPLETE'
GrowthCredit.PAIR_INVALID      = 'PAIR_INVALID'

-- Bracket close outcomes (brief 3.6 / Group E model).
GrowthCredit.CLOSE_MISSING        = 'MISSING'
GrowthCredit.CLOSE_PENDING        = 'CLOSED_PENDING'
GrowthCredit.CLOSE_DISABLED       = 'CLOSED_DISABLED'
GrowthCredit.CLOSE_LOCKED         = 'CLOSED_LOCKED'
GrowthCredit.CLOSE_STALE          = 'CLOSED_STALE'
GrowthCredit.CLOSE_SPEND          = 'SPEND'

function GrowthCredit.new(manager)
    local self = setmetatable({}, GrowthCredit_mt)
    self.manager = manager
    self.isInitialized = false
    self._tgAccrualRegistered = false
    self._fallbackCursorDay   = nil
    self._bankPairState       = GrowthCredit.PAIR_FRESH
    self._bankGeneration      = 0
    self._bankAvailable       = false
    -- farmlandId -> per-farmland metadata (see loadMetadata / _refreshMetadata).
    self._metadata = {}
    -- Ordered open growth brackets (never saved; derived on reload).
    self._brackets = { nextSequence = 1, open = {} }
    -- Tracked farmland set (the keys of soilSystem.fieldData are authoritative;
    -- a receipt farmland is the SF-52 plan's own farmland id).
    self._farmlands = {}
    -- Settings fingerprint (SF-53 adds no setting; empty string is the SF-52
    -- neutral, kept so the witness contract has a real key).
    self._settingsFingerprint = ''
    self._daysPerPeriod = 1
    -- farmlandId -> true while a restored bank cell still awaits current-session
    -- validation (fruit roster + membership). Set on load, cleared by the first
    -- accrual pass that validates. While set, a farmland may earn at most the one
    -- observed excellent day, never a retroactive multi-day award across reload
    -- (brief 3.2/3.4: "no retroactive multi-day witness crosses reload").
    self._pendingValidation = {}
    return self
end

function GrowthCredit:initialize()
    self.isInitialized = true
end

-- ============================================================
-- PURE BANK KERNEL (the fixed contract; driven directly by the bar).
--
-- These statics mirror the SDS v2.6 reference models exactly so the offline
-- bar guards the shipped arithmetic, not a private copy of it.
-- ============================================================

--- Pack a credit byte: low seven bits hold bank days 0..84, the high bit holds
--- the appliedThisCrop witness. Returns nil for an out-of-contract day count.
--- @return number|nil packed 0..212 (days + applied*128)
function GrowthCredit.packCredit(days, applied)
    days = type(days) == 'number' and days or 0
    if days < 0 or days > GrowthCredit.CREDIT_DAYS_MAX then return nil end
    return days + (applied and GrowthCredit.APPLIED_BIT or 0)
end

--- Unpack a credit byte into (days 0..84, applied). Refuses a value outside the
--- stored range (0..212: 84 days plus the high bit).
--- @return number|nil days
--- @return boolean|nil applied
function GrowthCredit.unpackCredit(value)
    if type(value) ~= 'number' or value < 0 or value > GrowthCredit.CREDIT_DAYS_MAX + GrowthCredit.APPLIED_BIT then
        return nil, nil
    end
    local applied = value >= GrowthCredit.APPLIED_BIT
    return value % GrowthCredit.APPLIED_BIT, applied
end

--- The excellence test per the brief's two presets (unchanged semantics; casual
--- = at least one excellent band and none blocked, everything else = at least
--- two known voters and every voter excellent).
function GrowthCredit.isExcellent(bands, casual)
    if bands == nil then return false end
    if casual then
        return ViabilityMask.combine(bands) == ViabilityMask.BAND_EXCELLENT
    end
    local voters, allExcellent = 0, true
    for _, b in pairs(bands) do
        if b ~= nil then
            voters = voters + 1
            if b ~= ViabilityMask.BAND_EXCELLENT then allExcellent = false end
        end
    end
    return voters >= 2 and allExcellent
end

--- The resolved threshold in days: OptionScaling periods rounded, then scaled by
--- days per period. Absent or switched-off profile is neutral (brief 3.5).
--- @return number periods
--- @return number days
function GrowthCredit.effectiveThresholdDays(profile, daysPerPeriod)
    local declaration = GrowthCredit.THRESHOLD_DECLARATION
    local periods = 2
    if OptionScalingResolver ~= nil and type(OptionScalingResolver.resolve) == 'function' then
        local ok, resolved = pcall(OptionScalingResolver.resolve, declaration, profile)
        if ok and type(resolved) == 'number' then periods = resolved end
    end
    periods = math.max(1, math.floor(periods + 0.5))
    local dpp = (type(daysPerPeriod) == 'number' and daysPerPeriod >= 1) and daysPerPeriod or 1
    return periods, periods * dpp
end

--- Evidence-bounded skipped-day award: only a fully unchanged witness may earn
--- every crossed day; any changed or missing witness awards at most the one
--- observed excellent day; a non-excellent current cell earns none (brief 3.4).
--- @return number daysToAward
function GrowthCredit.witnessDays(crossed, sameFruit, sameInput, sameGeometry,
    sameSettings, excellent)
    if not excellent then return 0 end
    if sameFruit and sameInput and sameGeometry and sameSettings then
        return math.max(0, crossed or 0)
    end
    return 1
end

--- Classify the two-layer bank after layer + metadata load (brief 3.1).
--- @param days  { exists = bool, loaded = bool, resolution = number }
--- @param fruit { exists = bool, loaded = bool, resolution = number }
--- @param metadataClaimsBank boolean
--- @param expectedResolution number
--- @return string FRESH|COMPLETE|PAIR_INVALID
function GrowthCredit.classifyPair(days, fruit, metadataClaimsBank, expectedResolution)
    local neitherExists = not days.exists and not fruit.exists
    if neitherExists and not metadataClaimsBank then return GrowthCredit.PAIR_FRESH end
    local complete = days.exists and fruit.exists
        and days.loaded and fruit.loaded
        and days.resolution == expectedResolution
        and fruit.resolution == expectedResolution
    if complete then return GrowthCredit.PAIR_COMPLETE end
    return GrowthCredit.PAIR_INVALID
end

--- Run-length encode a row of sparse cells (Group C model: the worst-case bound
--- for a dense 4096-square carrier serialized as runs is one run per coherent
--- row). GrowthCredit does not store per-cell runs in XML (brief 3.2); this is
--- the reference bound used by the bar and the save-design's reasoning.
function GrowthCredit.encodeRuns(cells)
    local ordered = {}
    for _, c in ipairs(cells or {}) do
        ordered[#ordered + 1] = {
            px = c.px, pz = c.pz, creditDays = c.creditDays, fruitIndex = c.fruitIndex,
        }
    end
    table.sort(ordered, function(a, b)
        if a.pz ~= b.pz then return a.pz < b.pz end
        return a.px < b.px
    end)
    local runs = {}
    for _, c in ipairs(ordered) do
        local last = runs[#runs]
        if last ~= nil and last.pz == c.pz
            and last.pxStart + last.length == c.px
            and last.creditDays == c.creditDays
            and last.fruitIndex == c.fruitIndex then
            last.length = last.length + 1
        else
            runs[#runs + 1] = {
                pz = c.pz, pxStart = c.px, length = 1,
                creditDays = c.creditDays, fruitIndex = c.fruitIndex,
            }
        end
    end
    return runs
end

--- Open one ordered bracket for a transition (brief 3.6). Seasonal derives the
--- immutable next period with a fixed 12-wrap; the returned bracket never reads
--- live environment.currentPeriod after START.
--- @return table bracket
function GrowthCredit.openBracket(queue, transitionPeriod, gateLive, growthMode, bankGeneration, receipts)
    local b = {
        sequence       = queue.nextSequence,
        transitionPeriod = transitionPeriod,
        targetPeriod   = (growthMode == 'DAILY') and (transitionPeriod % 12 + 1) or (transitionPeriod % 12 + 1),
        gateLiveAtStart = gateLive,
        growthMode     = growthMode,
        bankGeneration = bankGeneration,
        receipts       = receipts or {},
    }
    queue.nextSequence = queue.nextSequence + 1
    queue.open[#queue.open + 1] = b
    return b
end

--- Close the oldest bracket matching a finished transition period. Returns the
--- bracket and one of CLOSE_*: MISSING / CLOSED_PENDING / CLOSED_DISABLED /
--- CLOSED_LOCKED / CLOSED_STALE / SPEND (drained, gate live at START and now,
--- unchanged bank generation).
function GrowthCredit.closeBracket(queue, period, hasPendingGrowth, gateLiveNow, currentBankGeneration)
    local index = nil
    for i, b in ipairs(queue.open) do
        if b.transitionPeriod == period then index = i; break end
    end
    if index == nil then return nil, GrowthCredit.CLOSE_MISSING end
    local b = table.remove(queue.open, index)
    if hasPendingGrowth then return b, GrowthCredit.CLOSE_PENDING end
    if b.growthMode == 'DISABLED' then return b, GrowthCredit.CLOSE_DISABLED end
    if not b.gateLiveAtStart or not gateLiveNow then return b, GrowthCredit.CLOSE_LOCKED end
    if b.bankGeneration ~= currentBankGeneration then return b, GrowthCredit.CLOSE_STALE end
    return b, GrowthCredit.CLOSE_SPEND
end

--- Post-write result owns the credit reset (brief 3.7 / Group G): only a cell the
--- engine reports at exactly the target state under the SAME fruit resets its
--- bank-day bits (appliedThisCrop is set, fruit retained). Returns
--- reset, retained over the caller's cell list, mutating each cell.creditDays.
function GrowthCredit.verifyPostWrite(cells, actual)
    local reset, retained = 0, 0
    for _, cell in ipairs(cells or {}) do
        local observed = actual and actual[cell.key]
        if observed ~= nil and observed.fruitIndex == cell.fruitIndex
            and observed.state == cell.targetState then
            cell.creditDays = 0
            reset = reset + 1
        else
            retained = retained + 1
        end
    end
    return reset, retained
end

--- A ready cell outside an active first-START hold may spend; a captured-blocked
--- cell (SF-78 active) cannot spend in this queued batch (brief 3.6 step 7).
function GrowthCredit.maySpendCredit(capturedAtFirstStart, ready)
    return ready == true and capturedAtFirstStart ~= true
end

-- ============================================================
-- INPUTS (read-only access to the family's own data)
-- ============================================================

function GrowthCredit:_viability()
    local v = self.manager and self.manager.viability
    if v ~= nil and type(v.getCellGrowthInfo) == 'function' then return v end
    return nil
end

function GrowthCredit:_valueMaps()
    local soilSystem = self.manager and self.manager.soilSystem
    local vm = soilSystem and soilSystem.valueMaps
    if vm ~= nil and vm.available then return vm end
    return nil
end

function GrowthCredit:_soilSystem()
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and type(ss._getFarmlandPolygons) == 'function' then return ss end
    return nil
end

--- The SF-52 provider's immutable complete plan for a farmland, or nil.
function GrowthCredit:_plan(farmlandId)
    local m = self.manager
    if m == nil or type(m.getGrowthEligibleRegionPlan) ~= 'function' then return nil end
    local ok, plan = pcall(function() return m:getGrowthEligibleRegionPlan(farmlandId) end)
    if not ok then return nil end
    return plan
end

--- The current farmland+unscoped observation token, or nil.
function GrowthCredit:_token(farmlandId)
    local vm = self:_valueMaps()
    if vm == nil or type(vm.getGrowthInputToken) ~= 'function' then return nil end
    local ok, token = pcall(function() return vm:getGrowthInputToken(farmlandId) end)
    if not ok then return nil end
    return token
end

--- In-game day coordinate from Time Guard context, else the host fallback.
--- Never environment.currentDay (brief 3.7).
function GrowthCredit:_monotonicDay()
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg ~= nil and type(tg.getContext) == 'function' then
        local ok, ctx = pcall(function() return tg:getContext() end)
        if ok and type(ctx) == 'table' and type(ctx.monotonicDay) == 'number' then
            return ctx.monotonicDay
        end
    end
    if type(self._fallbackCursorDay) == 'number' then return self._fallbackCursorDay end
    return nil
end

--- The farmlands currently tracked by the soil system (keys of fieldData are the
--- authoritative SF-52 pass set).
function GrowthCredit:_currentFarmlandIds()
    local ss = self:_soilSystem()
    local ids = {}
    if ss ~= nil and ss.fieldData ~= nil then
        for farmlandId in pairs(ss.fieldData) do ids[#ids + 1] = farmlandId end
    end
    return ids
end

-- ============================================================
-- THE PAIRED BANK LAYERS (brief 3.1)
-- ============================================================

--- Read one logical bank cell at a world point. Returns the packed credit byte
--- and the fruit index, or nil when either half is absent/invalid.
function GrowthCredit:_readPair(vm, x, z)
    local credit = vm:readValueAtWorld('growthCreditDays', x, z)
    local fruit  = vm:readValueAtWorld('growthCreditFruit', x, z)
    if credit == nil or credit <= 0 or fruit == nil or fruit <= 0 then return nil end
    local days, applied = GrowthCredit.unpackCredit(credit)
    if days == nil then return nil end
    return credit, fruit, days, applied
end

--- Write one logical bank cell. Days 0..84 (packed with the applied bit), fruit
--- 1..63. Any invalid or zero-intent write clears BOTH halves.
function GrowthCredit:_writePair(vm, x, z, days, applied, fruit, radius)
    if fruit == nil or fruit <= 0 or fruit > GrowthCredit.FRUIT_MAX
        or days == nil or days < 0 or days > GrowthCredit.CREDIT_DAYS_MAX then
        self:_clearPair(vm, x, z, radius)
        return false
    end
    local packed = GrowthCredit.packCredit(days, applied)
    if packed == nil then
        self:_clearPair(vm, x, z, radius)
        return false
    end
    local ok1, ok2 = pcall(function() vm:writeValueAtWorld('growthCreditDays', x, z, packed, radius) end)
    local okf = pcall(function() vm:writeValueAtWorld('growthCreditFruit', x, z, fruit, radius) end)
    -- Post-read both halves; a one-sided or invalid result clears both.
    if not ok1 or not okf or self:_readPair(vm, x, z) == nil then
        self:_clearPair(vm, x, z, radius)
        return false
    end
    return true
end

--- Clear both halves of one logical bank cell (raw-zero absent; the carrier's
--- linear 0..254 encode maps semantic 0 to raw 1, which reads back 0 and is
--- treated as absent by _readPair, so a write of 0 to both is the clear).
function GrowthCredit:_clearPair(vm, x, z, radius)
    local r = radius or 1.5
    pcall(function() vm:writeValueAtWorld('growthCreditDays', x, z, 0, r) end)
    pcall(function() vm:writeValueAtWorld('growthCreditFruit', x, z, 0, r) end)
end

--- The bank's availability gate (brief 3.2/3.8): a PAIR_INVALID state clears both
--- layers and all metadata before any validation, accrual or save. Called after
--- load and after a metadata/geometry mismatch is detected.
function GrowthCredit:_classifyBank()
    local vm = self:_valueMaps()
    if vm == nil then
        self._bankPairState = GrowthCredit.PAIR_INVALID
        self._bankAvailable = false
        return self._bankPairState
    end
    local daysEntry  = vm.getLayerEntry and vm:getLayerEntry('growthCreditDays') or nil
    local fruitEntry = vm.getLayerEntry and vm:getLayerEntry('growthCreditFruit') or nil
    local expected = vm.resolution or 0
    local function probe(entry)
        if entry == nil then return { exists = false, loaded = false, resolution = 0 } end
        return {
            exists   = entry.loaded == true,
            loaded   = entry.loaded == true,
            resolution = (vm.resolution or 0),
        }
    end
    -- File existence is read from disk at load; the layer entry's `loaded` flag is
    -- the honest signal of restore. On a fresh save neither file existed and the
    -- maps were created blank, so loaded == false; a metadata claim then decides.
    local days = { exists = false, loaded = false, resolution = 0 }
    local fruit = { exists = false, loaded = false, resolution = 0 }
    if daysEntry and daysEntry.loaded then days = { exists = true, loaded = true, resolution = expected } end
    if fruitEntry and fruitEntry.loaded then fruit = { exists = true, loaded = true, resolution = expected } end

    local claimsBank = false
    for _, meta in pairs(self._metadata) do
        if meta ~= nil and (meta.migrationMarker ~= nil or meta.fruitRosterFingerprint ~= nil) then
            claimsBank = true
        end
    end

    local state = GrowthCredit.classifyPair(days, fruit, claimsBank, expected)
    self._bankPairState = state
    if state == GrowthCredit.PAIR_INVALID then
        -- PAIR_INVALID clears both layers and all metadata before availability.
        pcall(function() vm:clearLayer('growthCreditDays') end)
        pcall(function() vm:clearLayer('growthCreditFruit') end)
        self._metadata = {}
        self._bankAvailable = false
    elseif state == GrowthCredit.PAIR_COMPLETE or state == GrowthCredit.PAIR_FRESH then
        self._bankAvailable = true
    end
    return state
end

-- ============================================================
-- THE DAILY ACCRUAL (the bookkeeper, brief 3.3/3.4)
-- ============================================================

--- Register with Time Guard first (true-return semantics); the daily pass runs on
--- the simulation settle. runDailyPass is also the fallback cadence entry.
function GrowthCredit:runDailyPass(ctx)
    if not self.isInitialized then return 0 end
    if not self:isLive() then return 0 end
    local daysPerPeriod = (ctx ~= nil and type(ctx.daysPerPeriod) == 'number' and ctx.daysPerPeriod >= 1)
        and ctx.daysPerPeriod or nil
    if daysPerPeriod ~= nil then self._daysPerPeriod = daysPerPeriod end
    local day = self:_monotonicDay()
    if day == nil then return 0 end
    local vm = self:_valueMaps()
    if vm == nil then return 0 end

    self:_classifyBank()
    if not self._bankAvailable then return 0 end

    local passed = 0
    for _, farmlandId in ipairs(self:_currentFarmlandIds()) do
        if self:_accrueFarmland(farmlandId, vm, day) then passed = passed + 1 end
    end
    return passed
end

--- Accrue one farmland: validate the complete current SF-52 plan and tokens,
--- then walk every stable plan region owned by this receipt farmland. Each
--- eligible excellent cell accrues one day, capped at the resolved threshold;
--- fruit identity binds before the first positive increment and a crop change
--- clears the old pair. One complete farmland pass publishes one bank
--- generation.
function GrowthCredit:_accrueFarmland(farmlandId, vm, day)
    local plan = self:_plan(farmlandId)
    if plan == nil or type(plan.regions) ~= 'table' or #plan.regions == 0 then return false end
    local token = self:_token(farmlandId)
    if token == nil then return false end
    if plan.farmlandInputRevision ~= token.farmlandRevision
        or plan.unscopedInputRevision ~= token.unscopedRevision then return false end

    -- Farmland geometry must still match the plan that generated these regions.
    local ss = self:_soilSystem()
    local polygons = ss and type(ss._getFarmlandPolygons) == 'function'
        and ss:_getFarmlandPolygons(farmlandId) or nil
    if polygons == nil then return false end
    local fingerprint = ViabilityMask.polygonUnionFingerprint(polygons)
    if fingerprint ~= plan.polygonUnionFingerprint then return false end

    -- Settings fingerprint unchanged (SF-53 adds no setting; neutral empty).
    local meta = self._metadata[farmlandId] or {}
    local lastDay = meta.lastAccruedMonotonicDay
    local crossed = 1
    if type(lastDay) == 'number' and lastDay >= 0 and day > lastDay then crossed = day - lastDay end

    -- EVIDENCE-BOUNDED CATCH-UP (brief 3.4). Every crossed day may be awarded
    -- only when the farmland-level witness is UNCHANGED since the last accrual:
    -- stored farmland input revision, unscoped revision, polygon-union
    -- fingerprint and settings fingerprint must all equal today's. Any change or
    -- missing stored witness caps the whole pass at the one observed excellent
    -- day. (The per-cell fruit identity is checked again below.) A reloaded bank
    -- carries no session revisions, so it is inherently capped here as well.
    local witnessSame = (type(meta.farmlandInputRevision) == 'number')
        and meta.farmlandInputRevision == token.farmlandRevision
        and meta.unscopedInputRevision == token.unscopedRevision
        and meta.polygonUnionFingerprint == fingerprint
        and meta.settingsFingerprint == self._settingsFingerprint
    if not witnessSame then crossed = math.min(crossed, 1) end

    -- Restored-bank validation on the first in-session pass. A fruit-roster or
    -- carrier mismatch clears BOTH layers and this farmland's metadata (numeric
    -- identity may have moved). The cap above already bounds a reload to the one
    -- observed day; this pass then resolves pending validation.
    if self._pendingValidation[farmlandId] then
        local currentRoster = self:_fruitRosterFingerprint()
        if currentRoster ~= '' and meta.fruitRosterFingerprint ~= nil
            and currentRoster ~= meta.fruitRosterFingerprint then
            pcall(function() vm:clearLayer('growthCreditDays') end)
            pcall(function() vm:clearLayer('growthCreditFruit') end)
            self._metadata[farmlandId] = nil
            self._pendingValidation[farmlandId] = nil
            return false
        end
        crossed = math.min(crossed, 1)
    end
    local casual = self:_isCasualPreset()
    local _, threshold = GrowthCredit.effectiveThresholdDays(self:_readProfile(), self._daysPerPeriod)

    local grain = plan.executionGrainMetres or plan.truthGrainMetres
    if type(grain) ~= 'number' or grain <= 0 then return false end
    local radius = grain * 0.5

    local committedAny = false
    for _, region in ipairs(plan.regions) do
        -- Only squares this farmland may write (carrier ownership partition).
        if region.writableForFarmland == true and region.blocked ~= true then
            local gx, gz = self:_decodeKey(region.key)
            if gx ~= nil then
                local cx = gx * grain + grain * 0.5
                local cz = gz * grain + grain * 0.5
                if self:_accrueCell(farmlandId, vm, cx, cz, crossed, casual, threshold, day, radius) then
                    committedAny = true
                end
            end
        end
    end

    -- Ordinary day accrual does NOT advance the bank generation: a drained
    -- FINISHED bracket must see the same generation it captured at START (model
    -- E9), and daily day-capping accrual is not a material bank change. Only a
    -- spend that writes or a full clear advances it (see _spendFarmland and
    -- _classifyBank). The bracket's CLOSED_STALE guard therefore means "the bank
    -- was reset or already spent while the bracket was open", never "days passed".
    -- A complete farmland pass (whether or not any cell happened to be excellent
    -- this day) resolves the restored-bank pending validation: membership and
    -- fruit identity have now been checked against current truth.
    self._pendingValidation[farmlandId] = nil
    -- Track the last accrued day regardless of cell outcomes (a normal day still
    -- advances the cursor; a changed-witness day is awarded at most one, above).
    -- The witnessed revisions/fingerprint/settings are stored so the NEXT accrual
    -- can prove whether the soil, geometry and settings were unchanged across the
    -- gap (the evidence-bounded catch-up contract, brief 3.4).
    self._metadata[farmlandId] = {
        schema = 1,
        fruitRosterFingerprint = self:_fruitRosterFingerprint(),
        terrainResolution = vm.resolution or 0,
        truthGrainMetres = (type(vm.getGrainMetres) == 'function') and vm:getGrainMetres() or nil,
        migrationMarker = meta.migrationMarker,
        polygonUnionFingerprint = fingerprint,
        farmlandInputRevision = token.farmlandRevision,
        unscopedInputRevision = token.unscopedRevision,
        settingsFingerprint = self._settingsFingerprint,
        lastAccruedMonotonicDay = day,
    }
    return committedAny
end

--- Accrue one carrier square. Reads current fruit identity + state and the SF-52
--- point condition fresh; rejects unknown, bare, cut, withered, blocked or
--- non-excellent cells. Identity binds before the first increment; a changed crop
--- clears the old pair before the new one earns. Catch-up is evidence bounded.
function GrowthCredit:_accrueCell(farmlandId, vm, cx, cz, crossed, casual, threshold, day, radius)
    -- Fruit identity + state, fresh.
    local state, fruitIndex = self:_readCellState(cx, cz)
    if state == nil or fruitIndex == nil then return false end
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return false end
    if fruitDesc:getIsCut(state) or fruitDesc:getIsWithered(state) then return false end
    if state == fruitDesc.cutState or state >= fruitDesc.maxHarvestingGrowthState then return false end

    -- SF-52 point condition, fresh.
    local info = self:_viability() and self:_viability():getCellGrowthInfo(farmlandId, cx, cz)
    if info == nil or info.blocked then return false end
    if not GrowthCredit.isExcellent(info.bands, casual) then return false end
    -- A non-excellent current cell earns none; evidence bounding happens below.

    -- Bank read. A stored fruit that differs clears the old pair (crop change).
    local credit, storedFruit, storedDays, storedApplied = self:_readPair(vm, cx, cz)
    if storedFruit ~= nil and storedFruit ~= fruitIndex then
        self:_clearPair(vm, cx, cz, radius)
        credit, storedFruit, storedDays, storedApplied = nil, nil, 0, false
    end

    -- Evidence-bounded award: the farmland-level witness was folded into
    -- `crossed` above (capped to 1 when any soil/geometry/settings coordinate
    -- moved). At the cell, only the FRUIT identity witness remains: an unchanged
    -- fruit may earn every crossed day; a fruit change clears the pair first and
    -- the new crop earns only the one observed day; a fresh (never-banked) cell
    -- earns only the observed day, never a retroactive gap (brief 3.3/3.4).
    local award
    if storedFruit == nil or storedFruit ~= fruitIndex then
        award = 1
    else
        award = GrowthCredit.witnessDays(crossed, true, true, true, true, true)
    end
    if award <= 0 then return false end

    local nextDays = (storedDays or 0) + award
    if nextDays > threshold then nextDays = threshold end
    if nextDays > GrowthCredit.CREDIT_DAYS_MAX then nextDays = GrowthCredit.CREDIT_DAYS_MAX end
    return self:_writePair(vm, cx, cz, nextDays, storedApplied == true, fruitIndex, radius)
end

function GrowthCredit:_decodeKey(key)
    if type(key) ~= 'string' then return nil end
    local gx, gz = key:match("^(-?%d+):(-?%d+)$")
    if not gx then return nil end
    return tonumber(gx), tonumber(gz)
end

function GrowthCredit:_isCasualPreset()
    local s = self.manager and self.manager.settings
    if s == nil or s.difficulty == nil then return false end
    local easy = SoilConstants and SoilConstants.DIFFICULTY and SoilConstants.DIFFICULTY.EASY
    return easy ~= nil and s.difficulty == easy
end

--- The current Option-Scaling profile through the vendored readProfile contract.
function GrowthCredit:_readProfile()
    if OptionScalingResolver == nil or type(OptionScalingResolver.readProfile) ~= 'function' then
        return nil
    end
    local sh = (g_currentMission ~= nil and g_currentMission.settingsHub) or nil
    if sh == nil then return nil end
    local ok, profile = pcall(OptionScalingResolver.readProfile, OptionScalingResolver, sh)
    if not ok then return nil end
    return profile
end

--- Server test that tolerates a bench mission without getIsServer (nil-safe; a
--- mission that cannot answer is treated as not-server, matching the siblings).
function GrowthCredit:_isServer()
    local mission = g_currentMission
    if mission ~= nil and type(mission.getIsServer) == 'function' then
        local ok, isServer = pcall(function() return mission:getIsServer() end)
        if ok then return isServer == true end
        return false
    end
    return false
end

--- A deterministic roster fingerprint for the current fruit-type set, so a loaded
--- bank whose numeric fruit identity may have moved is cleared (brief 3.2).
function GrowthCredit:_fruitRosterFingerprint()
    local ftm = g_fruitTypeManager
    if ftm == nil or type(ftm.getFruitTypes) ~= 'function' then
        -- No roster API on the bench: fall back to a stable empty fingerprint so a
        -- save/load round trip does not clear the bank purely because the roster
        -- could not be read at that moment.
        return ''
    end
    local ok, names = pcall(function()
        local out = {}
        local fruits = ftm:getFruitTypes()
        for _, ft in ipairs(fruits or {}) do
            if type(ft) == 'table' and ft.name then out[#out + 1] = ft.name end
        end
        table.sort(out)
        return out
    end)
    if not ok then return '' end
    return table.concat(names or {}, '|')
end

-- ============================================================
-- THE PERIOD HAND (the bell, brief 3.6/3.7)
-- ============================================================

--- START delivery from the manager's single growth dispatch. Opens one ordered
--- bracket carrying each current complete farmland receipt; never copies the
--- eligible-key population.
function GrowthCredit:onStartGrowthPeriod(transitionPeriod)
    if not self:_isServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    local mission = g_currentMission
    local growthMode = mission and mission.missionInfo and mission.missionInfo.growthMode
    local modeName = (growthMode == GrowthMode.SEASONAL) and 'SEASONAL'
        or (growthMode == GrowthMode.DAILY) and 'DAILY' or 'DISABLED'

    local receipts = {}
    for _, farmlandId in ipairs(self:_currentFarmlandIds()) do
        local plan = self:_plan(farmlandId)
        local token = self:_token(farmlandId)
        if plan ~= nil and token ~= nil then
            receipts[#receipts + 1] = {
                farmlandId = farmlandId,
                planId = plan.planId,
                planContentHash = plan.planContentHash,
                polygonUnionFingerprint = plan.polygonUnionFingerprint,
                farmlandInputRevision = plan.farmlandInputRevision or token.farmlandRevision,
                unscopedInputRevision = plan.unscopedInputRevision or token.unscopedRevision,
                settingsFingerprint = plan.settingsFingerprint or '',
                bankGeneration = self._bankGeneration,
                carrierOwnershipHash = plan.carrierOwnershipHash,
            }
        end
    end
    GrowthCredit.openBracket(self._brackets, transitionPeriod or 1, true, modeName,
        self._bankGeneration, receipts)
    return true
end

--- FINISHED delivery from the manager's single growth dispatch. Matches the
--- oldest open bracket for the finished period and closes it on EVERY path
--- (brief 3.6: "close the matched bracket on every path"): pending growth closes
--- without spend, disabled growth rings but never rewards, a mid-bracket gate
--- change or a changed bank generation suppresses spend, and only a drained,
--- stable bracket re-enumerates provider-owned regions and spends
--- threshold-banked cells outside SF-78's active first-START capture.
function GrowthCredit:onFinishedGrowthPeriod(finishedPeriod, hasPendingGrowth)
    if not self:_isServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    local pending = (hasPendingGrowth == true)

    local bracket, outcome = GrowthCredit.closeBracket(self._brackets,
        finishedPeriod or 1, pending, true, self._bankGeneration)
    if bracket == nil or outcome ~= GrowthCredit.CLOSE_SPEND then return outcome end
    local wroteAny = self:_spendBracket(bracket)
    return wroteAny
end

--- Spend one drained stable bracket: for each farmland receipt, re-enumerate the
--- provider-owned regions, select threshold-banked cells outside the hold
--- capture, read current state fresh, derive the immutable target, bucket by
--- (fruitIndex, sourceState, targetState), stroke one filtered executeSet per
--- bucket, then re-read every submitted cell and reset only the verified ones.
function GrowthCredit:_spendBracket(bracket)
    local vm = self:_valueMaps()
    if vm == nil then return false end
    local wroteAny = false
    for _, receipt in ipairs(bracket.receipts or {}) do
        if self:_spendFarmland(receipt, vm, bracket) then wroteAny = true end
    end
    return wroteAny
end

function GrowthCredit:_spendFarmland(receipt, vm, bracket)
    local farmlandId = receipt.farmlandId
    local plan = self:_plan(farmlandId)
    if plan == nil or plan.planId ~= receipt.planId then return false end
    local token = self:_token(farmlandId)
    if token == nil then return false end
    if plan.farmlandInputRevision ~= receipt.farmlandInputRevision
        or plan.unscopedInputRevision ~= receipt.unscopedInputRevision
        or plan.polygonUnionFingerprint ~= receipt.polygonUnionFingerprint
        or plan.settingsFingerprint ~= receipt.settingsFingerprint
        or self._bankGeneration ~= receipt.bankGeneration then
        return false
    end

    local grain = plan.executionGrainMetres or plan.truthGrainMetres
    if type(grain) ~= 'number' or grain <= 0 then return false end
    local radius = grain * 0.5

    -- Re-enumerate provider-owned regions and select threshold-banked cells.
    local _, threshold = GrowthCredit.effectiveThresholdDays(self:_readProfile(), self._daysPerPeriod)
    local candidates = {}
    for _, region in ipairs(plan.regions) do
        if region.writableForFarmland == true and region.blocked ~= true then
            local gx, gz = self:_decodeKey(region.key)
            if gx ~= nil then
                local cx = gx * grain + grain * 0.5
                local cz = gz * grain + grain * 0.5
                local cell = self:_spendCandidate(farmlandId, vm, cx, cz, threshold, radius,
                    receipt, plan, token, bracket)
                if cell ~= nil then candidates[#candidates + 1] = cell end
            end
        end
    end
    if #candidates == 0 then return false end

    -- Bucket survivors by (fruitIndex, sourceState, targetState).
    local buckets = {}
    for _, c in ipairs(candidates) do
        local key = c.fruitIndex .. "|" .. c.current .. "|" .. c.target
        local b = buckets[key]
        if b == nil then
            b = { fruitIndex = c.fruitIndex, current = c.current, target = c.target,
                  cells = {}, plan = plan }
            buckets[key] = b
        end
        b.cells[#b.cells + 1] = {
            gx = c.gx, gz = c.gz, key = c.key,
            fruitIndex = c.fruitIndex, targetState = c.target,
            creditDays = c.creditDays,
        }
    end

    local anyWritten = false
    for _, b in pairs(buckets) do
        local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(b.fruitIndex)
        if fruitDesc ~= nil and fruitDesc.terrainDataPlaneId ~= nil then
            local written = self:_strokeBucket(b, fruitDesc, grain)
            if written then
                -- Post-write: re-read every submitted cell; reset only verified ones.
                local actual = {}
                for _, cc in ipairs(b.cells) do
                    local cx = cc.gx * grain + grain * 0.5
                    local cz = cc.gz * grain + grain * 0.5
                    local st, fi = self:_readCellState(cx, cz)
                    actual[cc.key] = { fruitIndex = fi, state = st }
                end
                local reset, _ = GrowthCredit.verifyPostWrite(b.cells, actual)
                for _, cc in ipairs(b.cells) do
                    if cc.creditDays == 0 then
                        -- Clear the bank-day bits, set appliedThisCrop, retain fruit.
                        self:_writePair(vm, cc.gx * grain + grain * 0.5, cc.gz * grain + grain * 0.5,
                            0, true, b.fruitIndex, radius)
                    end
                end
                if reset > 0 then anyWritten = true end
            end
        end
    end
    if anyWritten then self._bankGeneration = self._bankGeneration + 1 end
    return anyWritten
end

--- One spend candidate: a threshold-banked, current, provider-owned, hold-eligible
--- cell whose current fruit/state/SF-52 condition pass the guards. Holds carry a
--- capturedAtFirstStart marker so SF-78's active capture cannot spend here.
function GrowthCredit:_spendCandidate(farmlandId, vm, cx, cz, threshold, radius,
    receipt, plan, token, bracket)
    local credit, storedFruit, storedDays, storedApplied = self:_readPair(vm, cx, cz)
    if credit == nil then return nil end
    if storedDays == nil or storedDays < threshold then return nil end

    -- Re-read current fruit identity and source state.
    local state, fruitIndex = self:_readCellState(cx, cz)
    if state == nil or fruitIndex == nil then return nil end
    if fruitIndex ~= storedFruit then return nil end
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return nil end
    if fruitDesc:getIsCut(state) or fruitDesc:getIsWithered(state) then return nil end
    if state == fruitDesc.cutState or state >= fruitDesc.maxHarvestingGrowthState then return nil end

    -- Re-read SF-52 condition: blocked or unavailable ground cannot spend.
    local info = self:_viability() and self:_viability():getCellGrowthInfo(farmlandId, cx, cz)
    if info == nil or info.blocked then return nil end

    -- Immutable target from the bracket's mapping; no mapping falls back to +1.
    local target = self:_engineTarget(fruitIndex, state, fruitDesc, bracket)
    if target == nil or target <= state then return nil end

    -- Hold exclusion: a receipt captured at SF-78's first START cannot spend now.
    if GrowthCredit.maySpendCredit(receipt.capturedAtFirstStart == true, true) == false then
        return nil
    end
    return {
        key = self:_regionKeyAt(cx, cz, plan), gx = self:_gx(cx, plan), gz = self:_gz(cz, plan),
        fruitIndex = fruitIndex, current = state, target = target, creditDays = storedDays,
    }
end

-- World -> carrier grid helpers at a plan's execution grain.
function GrowthCredit:_gx(x, plan) local g = plan.executionGrainMetres or plan.truthGrainMetres; if not g or g <= 0 then return nil end; return math.floor(x / g) end
function GrowthCredit:_gz(z, plan) local g = plan.executionGrainMetres or plan.truthGrainMetres; if not g or g <= 0 then return nil end; return math.floor(z / g) end
function GrowthCredit:_regionKeyAt(x, z, plan)
    local gx, gz = self:_gx(x, plan), self:_gz(z, plan)
    if gx == nil or gz == nil then return nil end
    return gx .. ':' .. gz
end

-- The engine's per-cell get: FSDensityMapUtil.getFruitTypeIndexAtWorldPos returns
-- (fruitTypeIndex, growthState) in one call.
function GrowthCredit:_readCellState(x, z)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= 'function' then
        return nil, nil
    end
    local ok, fruitIndex, state = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok or fruitIndex == nil or state == nil then return nil, nil end
    return state, fruitIndex
end

--- The engine-true next state. Seasonal uses the bracket's immutable target
--- period growthMapping; daily uses the non-seasonal mapping; no data steps by
--- one; a mapping that does not advance returns nil (a hold, never a step back).
function GrowthCredit:_engineTarget(fruitIndex, state, fruitDesc, bracket)
    if fruitDesc == nil then return nil end
    local mission = g_currentMission
    local growthMode = mission and mission.missionInfo and mission.missionInfo.growthMode
    local target = nil
    if growthMode == GrowthMode.SEASONAL then
        local gd = fruitDesc:getSeasonalGrowthData()
        local p = gd and gd.periods and gd.periods[bracket and bracket.targetPeriod]
        if p ~= nil and p.growthMapping ~= nil then target = p.growthMapping[state] end
    elseif growthMode == GrowthMode.DAILY then
        local gd = fruitDesc:getNonSeasonalGrowthData()
        if gd ~= nil and gd.growthMapping ~= nil then target = gd.growthMapping[state] end
    end
    if target == nil then target = state + 1 end
    if type(target) ~= "number" or target <= state then return nil end
    return target
end

-- ============================================================
-- THE WRITE HAND (the family machine; fruit-plane executeSet)
-- ============================================================

--- Group 4-connected stable carrier cells into exact rings (world-aligned grid
--- at the plan grain) and stroke one filtered executeSet per bucket.
function GrowthCredit:_strokeBucket(bucket, fruitDesc, grain)
    local ok, err = pcall(function()
        local rings = self:_bucketRings(bucket.cells, grain)
        if rings == nil or #rings == 0 then return end

        local modifier = DensityMapModifier.new(
            fruitDesc.terrainDataPlaneId, fruitDesc.startStateChannel, fruitDesc.numStateChannels, g_terrainNode)
        local filter = DensityMapFilter.new(modifier)
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, bucket.current, bucket.current)

        local multi = DensityMapMultiModifier.new()
        for _, ring in ipairs(rings) do
            if #ring >= 3 then
                modifier:clearPolygonPoints()
                for _, pt in ipairs(ring) do
                    modifier:addPolygonPointWorldCoords(pt.x, pt.z)
                end
                multi:addExecuteSet(bucket.target, modifier, filter)
            end
        end
        multi:execute()
    end)
    if not ok then
        SoilLogger.error("[SF-53] field growth credit write failed: %s", tostring(err))
    end
    return ok
end

--- Group a list of {gx=, gz=} cells into contiguous 4-connected regions and build
--- each region's outline ring(s) on the world-origin carrier grid. Ring corner i
--- of a region cell sits at (gx*grain, gz*grain).
function GrowthCredit:_bucketRings(cells, grain)
    local set = {}
    for _, c in ipairs(cells) do set[c.gx .. "," .. c.gz] = c end
    local regions = {}
    local visited = {}
    for _, c in ipairs(cells) do
        local key = c.gx .. "," .. c.gz
        if not visited[key] then
            local region = {}
            local queue = { c }
            visited[key] = true
            local head = 1
            while head <= #queue do
                local cur = queue[head]
                head = head + 1
                region[#region + 1] = cur
                for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
                    local nk = (cur.gx + d[1]) .. "," .. (cur.gz + d[2])
                    if set[nk] and not visited[nk] then
                        visited[nk] = true
                        queue[#queue + 1] = set[nk]
                    end
                end
            end
            regions[#regions + 1] = region
        end
    end

    local rings = {}
    for _, region in ipairs(regions) do
        local rset = {}
        for _, c in ipairs(region) do rset[c.gx .. "," .. c.gz] = true end

        local function hasCell(nx, nz) return rset[nx .. "," .. nz] ~= nil end
        local function cornerKey(x, z) return x .. "," .. z end

        local nextEdge = {}
        for _, c in ipairs(region) do
            local gx, gz = c.gx, c.gz
            if not hasCell(gx, gz - 1) then nextEdge[cornerKey(gx, gz)] = cornerKey(gx + 1, gz) end
            if not hasCell(gx + 1, gz) then nextEdge[cornerKey(gx + 1, gz)] = cornerKey(gx + 1, gz + 1) end
            if not hasCell(gx, gz + 1) then nextEdge[cornerKey(gx + 1, gz + 1)] = cornerKey(gx, gz + 1) end
            if not hasCell(gx - 1, gz) then nextEdge[cornerKey(gx, gz + 1)] = cornerKey(gx, gz) end
        end

        local used = {}
        local keys = {}
        for k in pairs(nextEdge) do keys[#keys + 1] = k end
        for _, startKey in ipairs(keys) do
            if not used[startKey] then
                local ring = {}
                local k = startKey
                local steps = 0
                while k and not used[k] and steps <= 4096 do
                    used[k] = true
                    local x, z = k:match("^(-?%d+),(-?%d+)$")
                    if x then
                        ring[#ring + 1] = {
                            x = tonumber(x) * grain,
                            z = tonumber(z) * grain,
                        }
                    end
                    k = nextEdge[k]
                    steps = steps + 1
                    if k == startKey then break end
                end
                if #ring >= 3 then rings[#rings + 1] = ring end
            end
        end
    end
    return rings
end

-- ============================================================
-- THE PUBLISHED WITNESS (brief 3.9 / the SF-54 surface)
-- ============================================================

--- Server credit plus witness at a world position. Returns (creditDays, witness)
--- or nil. Client, stale, partial or mismatched reads return nil. The witness is
--- the matching record for SF-54's in-mod assembler and for any sibling read.
function GrowthCredit:readCreditAt(fieldId, x, z)
    if not self.isInitialized then return nil end
    if not self:_isServer() then return nil end
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local plan = self:_plan(fieldId)
    if plan == nil then return nil end
    local token = self:_token(fieldId)
    if token == nil then return nil end

    -- Point must be covered by this farmland's current plan region and owned by
    -- it (the carrier-ownership boundary: a square another farmland owns is not
    -- this farmland's receipt, even when the plan lists it).
    local covered = false
    local carrierOwner = nil
    local grain = plan.executionGrainMetres or plan.truthGrainMetres
    if type(grain) ~= 'number' or grain <= 0 then return nil end
    local key = math.floor(x / grain) .. ':' .. math.floor(z / grain)
    for _, region in ipairs(plan.regions) do
        if region.key == key then covered = true; carrierOwner = region.carrierOwnerFarmlandId; break end
    end
    if not covered then return nil end
    if carrierOwner ~= nil and carrierOwner ~= fieldId then return nil end

    local credit, storedFruit, storedDays, storedApplied = self:_readPair(vm, x, z)
    if credit == nil then return nil end

    -- Current fruit identity must match the banked identity.
    local state, fruitIndex = self:_readCellState(x, z)
    if state == nil or fruitIndex == nil or fruitIndex ~= storedFruit then return nil end

    -- Currentness: farmland and unscoped revisions must match the plan.
    local current = (plan.farmlandInputRevision == token.farmlandRevision
        and plan.unscopedInputRevision == token.unscopedRevision)
    if not current then return nil end

    local _, threshold = GrowthCredit.effectiveThresholdDays(self:_readProfile(), self._daysPerPeriod)
    local banked = storedDays >= threshold
    local capturedAtFirstStart = false
    local deferredByHold = banked and capturedAtFirstStart == true

    local witness = {
        farmlandId = fieldId,
        polygonUnionFingerprint = plan.polygonUnionFingerprint,
        coversPoint = true,
        siblingGeneration = self._bankGeneration,
        current = true,
        fruitIndex = storedFruit,
        creditDays = storedDays,
        appliedThisCrop = storedApplied == true,
        thresholdDays = threshold,
        banked = banked,
        ready = banked and not deferredByHold,
        deferredByHold = deferredByHold,
    }
    return storedDays, witness
end

--- SF-54's growth-surface witness assembler: the matching record for the in-mod
--- assembler, or nil. Computed (deferredByHold) never stored.
function GrowthCredit:getGrowthSurfaceWitness(fieldId, x, z)
    local credit, witness = self:readCreditAt(fieldId, x, z)
    if witness == nil then return nil end
    return witness
end

-- ============================================================
-- SAVE / RELOAD / TEARDOWN (brief 3.8)
-- ============================================================

--- Persist the small metadata under soilData.growthCredit. The dense cell truth
--- is the two GRLE files written by SoilValueMaps; no per-cell list enters XML.
function GrowthCredit:saveToXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then return end
    setXMLInt(xmlFile, key .. "#schema", 1)
    local idx = 0
    for farmlandId, meta in pairs(self._metadata or {}) do
        if meta ~= nil then
            local entryKey = string.format("%s.farmland(%d)", key, idx)
            setXMLInt(xmlFile, entryKey .. "#id", farmlandId)
            setXMLString(xmlFile, entryKey .. "#fruitRoster", meta.fruitRosterFingerprint or '')
            setXMLInt(xmlFile, entryKey .. "#resolution", meta.terrainResolution or 0)
            setXMLFloat(xmlFile, entryKey .. "#grain", meta.truthGrainMetres or 0)
            setXMLString(xmlFile, entryKey .. "#geometry", meta.polygonUnionFingerprint or '')
            setXMLInt(xmlFile, entryKey .. "#lastDay", meta.lastAccruedMonotonicDay or 0)
            setXMLString(xmlFile, entryKey .. "#settings", meta.settingsFingerprint or '')
            setXMLString(xmlFile, entryKey .. "#migration", meta.migrationMarker or '')
            idx = idx + 1
        end
    end
    setXMLInt(xmlFile, key .. "#count", idx)
end

--- Restore the small metadata (called after the GRLE pair restored; the bank stays
--- PENDING_VALIDATION until current-session membership/fruit validation).
function GrowthCredit:loadFromXMLFile(xmlFile, key)
    self._metadata = {}
    self._pendingValidation = {}
    if xmlFile == nil or key == nil then return end
    local count = getXMLInt(xmlFile, key .. "#count") or 0
    for i = 0, count - 1 do
        local entryKey = string.format("%s.farmland(%d)", key, i)
        local id = getXMLInt(xmlFile, entryKey .. "#id")
        if id ~= nil then
            self._metadata[id] = {
                schema = 1,
                fruitRosterFingerprint = getXMLString(xmlFile, entryKey .. "#fruitRoster") or '',
                terrainResolution = getXMLInt(xmlFile, entryKey .. "#resolution") or 0,
                truthGrainMetres = getXMLFloat(xmlFile, entryKey .. "#grain") or 0,
                polygonUnionFingerprint = getXMLString(xmlFile, entryKey .. "#geometry") or '',
                lastAccruedMonotonicDay = getXMLInt(xmlFile, entryKey .. "#lastDay") or 0,
                settingsFingerprint = getXMLString(xmlFile, entryKey .. "#settings") or '',
                migrationMarker = getXMLString(xmlFile, entryKey .. "#migration") or '',
            }
            -- Restored cells stay PENDING_VALIDATION until current-session
            -- membership and fruit identity match (brief 3.2).
            self._pendingValidation[id] = true
        end
    end
    self:_classifyBank()
end

--- StateLedger mirror table (the same normalized metadata).
function GrowthCredit:getStateTable()
    return {
        schema = 1,
        bankGeneration = self._bankGeneration,
        farmlands = self._metadata,
    }
end

--- Apply a StateLedger metadata block.
function GrowthCredit:applyStateTable(data)
    self._metadata = {}
    self._pendingValidation = {}
    if type(data) ~= 'table' then self:_classifyBank(); return end
    if type(data.farmlands) == 'table' then
        for id, meta in pairs(data.farmlands) do
            if type(meta) == 'table' then
                self._metadata[id] = meta
                -- Restored cells stay PENDING_VALIDATION until current-session
                -- membership and fruit identity match (brief 3.2).
                self._pendingValidation[id] = true
            end
        end
    end
    self._bankGeneration = (type(data.bankGeneration) == 'number' and data.bankGeneration) or 0
    self:_classifyBank()
end

--- Host monotonic-day fallback feed, used when Time Guard is absent (brief 3.7).
function GrowthCredit:setCurrentMonotonicDay(day)
    if type(day) == 'number' then self._fallbackCursorDay = day end
end

function GrowthCredit:register()
    return self:registerDailyAccrual()
end

--- Register the daily bookkeeper with Time Guard (simulation flow). Registration
--- succeeds only on a LITERAL true return (brief 3.4). Absent, incompatible or
--- refusing Time Guard activates the host currentMonotonicDay fallback instead.
function GrowthCredit:registerDailyAccrual()
    if self._tgAccrualRegistered then return true end
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.registerAccrual) ~= 'function' then return false end

    -- Version-skew guard: an older Time Guard silently coerces an unknown
    -- flowClass to calendar, which would run this on a clock it never meant.
    if tg.flowClasses ~= nil and tg.flowClasses.simulation ~= true then
        return false
    end

    local registered = false
    local ok = pcall(function()
        registered = tg:registerAccrual(GrowthCredit.DAILY_ACCURAL_ID, {
            cadence = 'day',
            flowClass = 'simulation',
            firstPeriodPolicy = 'skip',
            priority = GrowthCredit.DAILY_ACCURAL_PRIORITY,
            onSettle = function(ctx) self:runDailyPass(ctx) end,
        })
    end)
    if ok and registered == true then
        self._tgAccrualRegistered = true
        return true
    end
    return false
end

--- The family's live gate: the release gate must be open AND the mask enabled.
--- FAIL-OPEN on the release gate (nil settings on the bench means live); the
--- mask switch is a real toggle and gates hard.
function GrowthCredit:isLive()
    local vm = self:_viability()
    if vm ~= nil and vm.enabled == false then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == 'function' then
        return ReleaseGate.isSystemLive("growth_modulation")
    end
    return true
end

function GrowthCredit:delete()
    self.isInitialized = false
    -- Unregister the Time Guard accrual when supported (brief 3.8).
    if self._tgAccrualRegistered then
        local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
        if tg ~= nil and type(tg.unregisterAccrual) == 'function' then
            pcall(function() tg:unregisterAccrual(GrowthCredit.DAILY_ACCURAL_ID) end)
        end
        self._tgAccrualRegistered = false
    end
    -- Invalidate the fallback cursor, clear plans/brackets/witness/accessors.
    self._fallbackCursorDay = nil
    self._brackets = { nextSequence = 1, open = {} }
    self._metadata = {}
    self._pendingValidation = {}
    self._bankAvailable = false
    -- No bank-clearing density write on delete.
end

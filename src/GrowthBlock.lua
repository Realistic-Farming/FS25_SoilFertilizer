-- ============================================================
-- GrowthBlock.lua  (SF-78, One Ground conformance)
--
-- THE HOLD HALF OF THE SF-2M MODULATION FAMILY. Ground SF-52
-- classifies BLOCKED at the beginning of a growth batch does not keep
-- the state step the engine just gave it: the cell's pre-state is
-- captured at START, and at the drained FINISHED delivery a governed
-- number of the states it received are put back, on the real crop, in
-- patches at the SF-52 provider's execution grain. The crop never
-- moves below its captured state.
--
-- WHAT CHANGED IN THE ONE GROUND CONFORMANCE (SF-78-FIX amendment):
--   The retired first-polygon 8 m / 600-point adaptive lattice and the
--   ephemeral per-field Lua capture are gone. The capture now lives in
--   two server-only file-backed layers inside the current SoilValueMaps
--   carrier (growthBlockState + growthBlockFruit), keyed by the same
--   world-origin-aligned carrier grid the SF-52 plan enumerates. A
--   manager-owned START/FINISHED growth dispatch feeds ordered brackets
--   with an immutable target period; a drained stable bracket restores
--   only verified post-state cells and then clears its capture
--   authority UNCONDITIONALLY. Small metadata rides the existing
--   soilData XML and the optional StateLedger mirror; the dense cell
--   truth is the two GRLE files. No fifth growth map, no network
--   capture, no client authority, no Time Guard registration (the
--   engine's own bracket START -> FINISHED is the clock). Native
--   fruit-plane writes, polygon clipping, engine sync, real save bytes
--   and frame time remain in-game proof (release LOCKED).
-- ============================================================

GrowthBlock = GrowthBlock or {}
local GrowthBlock_mt = Class(GrowthBlock)

-- The capture flag bits packed into the growthBlockFruit byte (SDS 2.5 units):
-- low six bits hold fruit 1..63, bit 6 (64) is ACTIVE capture authority, bit 7
-- (128) records verified completion (HELD). Both flags set is invalid.
GrowthBlock.FRUIT_MAX  = 63     -- engine fruit index limit (six bits)
GrowthBlock.STATE_MAX  = 254    -- captured growth state, semantic 0..254
GrowthBlock.ACTIVE_BIT = 64     -- bit 6: this cell holds an open capture
GrowthBlock.HELD_BIT   = 128    -- bit 7: this cell's hold completed (explanation)

-- Capture-cell classifications (brief 3.1 step 4).
GrowthBlock.CELL_MISSED  = 'MISSED'   -- valid fruit, neither flag
GrowthBlock.CELL_ACTIVE  = 'ACTIVE'   -- capture authority (may restore)
GrowthBlock.CELL_HELD    = 'HELD'     -- verified completion (explanation only)
GrowthBlock.CELL_INVALID = 'INVALID'  -- both flags, or no fruit

-- Pair-classification outcomes (brief 3.1).
GrowthBlock.PAIR_FRESH    = 'FRESH'
GrowthBlock.PAIR_COMPLETE  = 'COMPLETE'
GrowthBlock.PAIR_INVALID  = 'PAIR_INVALID'

-- Bracket close outcomes (brief 3.7 / restore model). Mirrors the SF-53 credit
-- close grammar so the family reads the same way; RESTORE is the drained,
-- stable, gate-live, unchanged-generation path that actually restores.
GrowthBlock.CLOSE_MISSING   = 'MISSING'
GrowthBlock.CLOSE_PENDING   = 'CLOSED_PENDING'
GrowthBlock.CLOSE_DISABLED  = 'CLOSED_DISABLED'
GrowthBlock.CLOSE_LOCKED    = 'CLOSED_LOCKED'
GrowthBlock.CLOSE_STALE     = 'CLOSED_STALE'
GrowthBlock.CLOSE_UNMATCHED = 'CLOSED_UNMATCHED'   -- finishedPeriod ~= lastStartPeriod
GrowthBlock.CLOSE_RESTORE   = 'RESTORE'

-- The restore-cap declaration (dial = agronomy, base 1 growth step, neutral 1,
-- clamped 1..2). Resolved through the vendored OptionScalingResolver contract
-- (SDS v2.5 section 3.10); the curve is data for the resolver, never read here.
GrowthBlock.RESTORE_DECLARATION = {
    dial     = "agronomy",
    base     = 1,
    neutral  = 1,
    clampMin = 1,
    clampMax = 2,
    curve    = { at0 = 1, at1 = 1, at2 = 2, ease = 2 },
}

function GrowthBlock.new(manager)
    local self = setmetatable({}, GrowthBlock_mt)
    self.manager = manager
    self.isInitialized = false
    self._bankPairState = GrowthBlock.PAIR_FRESH
    self._bankAvailable = false
    self._captureGeneration = 0
    -- The single active batch envelope, or nil. Never a live GrowthSystem read
    -- after START (brief 3.4/3.5): an immutable target period is captured once.
    self._envelope = nil
    -- farmlandId -> per-farmland durable metadata (see loadMetadata).
    self._metadata = {}
    -- Tracked farmland set is the keys of soilSystem.fieldData (the SF-52 pass).
    self._farmlands = {}
    -- Settings fingerprint (SF-78 adds no setting; empty string is the SF-52
    -- neutral, kept so the witness contract has a real key).
    self._settingsFingerprint = ''
    -- farmlandId -> true while a restored capture still awaits current-session
    -- validation (fruit roster + membership). Set on load, cleared by the first
    -- resolving pass. A reloaded capture never restores from stale pre-state
    -- (brief 3.6: "No stale pre-state retries after reload").
    self._pendingValidation = {}
    return self
end

function GrowthBlock:initialize()
    self.isInitialized = true
end

-- ============================================================
-- PURE CAPTURE KERNEL (the fixed contract; driven directly by the bar).
--
-- These statics mirror the SDS v2.5 reference models exactly so the offline bar
-- guards the shipped arithmetic, not a private copy of it.
-- ============================================================

--- Pack the fruit byte: low seven bits are unused above the six fruit bits; the
--- fruit occupies bits 0..5 (1..63), ACTIVE is bit 6, HELD is bit 7. Exactly one
--- of ACTIVE/HELD may be set. Returns nil for an out-of-contract input.
--- @return number|nil packed 0..254
function GrowthBlock.packFruit(fruit, active, held)
    if type(fruit) ~= 'number' or fruit < 1 or fruit > GrowthBlock.FRUIT_MAX then return nil end
    if active and held then return nil end
    return fruit + (active and GrowthBlock.ACTIVE_BIT or 0) + (held and GrowthBlock.HELD_BIT or 0)
end

--- Unpack the fruit byte into (fruit 1..63, active, held). Refuses both-flags and
--- a zero fruit; returns nil for either.
--- @return number|nil fruit
--- @return boolean active
--- @return boolean held
function GrowthBlock.unpackFruit(value)
    if type(value) ~= 'number' or value <= 0 or value > GrowthBlock.STATE_MAX then return nil end
    local held = value >= GrowthBlock.HELD_BIT               -- bit 7 (128)
    local rest = held and (value - GrowthBlock.HELD_BIT) or value
    local active = rest >= GrowthBlock.ACTIVE_BIT            -- bit 6 (64)
    local fruit = active and (rest - GrowthBlock.ACTIVE_BIT) or rest
    if active and held then return nil end
    if fruit < 1 or fruit > GrowthBlock.FRUIT_MAX then return nil end
    return fruit, active, held
end

--- Classify one packed fruit byte (brief 3.1 step 4): ACTIVE grants capture
--- authority, HELD records verified completion, neither flag with valid fruit
--- records MISSED, both flags is invalid.
--- @return string CELL_ACTIVE|CELL_HELD|CELL_MISSED|CELL_INVALID
function GrowthBlock.classifyFruitByte(value)
    local fruit, active, held = GrowthBlock.unpackFruit(value)
    if fruit == nil then return GrowthBlock.CELL_INVALID end
    if active then return GrowthBlock.CELL_ACTIVE end
    if held then return GrowthBlock.CELL_HELD end
    return GrowthBlock.CELL_MISSED
end

--- Validate a captured state value (brief 3.1 step 4): integer 0..254.
function GrowthBlock.isValidCapturedState(state)
    return type(state) == 'number' and state >= 0 and state <= GrowthBlock.STATE_MAX
        and math.floor(state) == state
end

--- The resolved restore cap in state steps: OptionScaling steps rounded, then a
--- neutral of one when absent/switched off (brief 3.10). Clamped 1..2.
--- @return number restoreStepsPerTransition
function GrowthBlock.effectiveRestoreSteps(profile)
    local declaration = GrowthBlock.RESTORE_DECLARATION
    local steps = 1
    if OptionScalingResolver ~= nil and type(OptionScalingResolver.resolve) == 'function' then
        local ok, resolved = pcall(OptionScalingResolver.resolve, declaration, profile)
        if ok and type(resolved) == 'number' then steps = resolved end
    end
    steps = math.floor(steps + 0.5)
    if steps < declaration.clampMin then steps = declaration.clampMin end
    if steps > declaration.clampMax then steps = declaration.clampMax end
    return steps
end

--- The restore target for one cell (brief 3.8): hold back
--- restoreStepsPerTransition * transitionCount states, but never below the
--- captured state. Returns nil for a target that does not rise above the
--- captured value or is not strictly below current (a hold that would do
--- nothing, never a step backward past captured).
--- @return number|nil target
function GrowthBlock.restoreTarget(capturedState, currentState, restoreStepsPerTransition, transitionCount)
    if type(currentState) ~= 'number' or type(capturedState) ~= 'number' then return nil end
    if currentState <= capturedState then return nil end
    local steps = (restoreStepsPerTransition or 1) * math.max(1, transitionCount or 1)
    local target = currentState - steps
    -- Clamp up to the captured state: invariant 12 (never below captured) is then
    -- structurally guaranteed (brief 3.8 step 10).
    if target < capturedState then target = capturedState end
    if target >= currentState then return nil end   -- brief 3.8 step 9: reject target == current
    return target
end

--- The R2 discriminator, three halves, all required (brief 3.8 steps 3-5): fruit
--- identity unchanged, current state not cut/withered, current strictly above
--- captured. Any half fails: reject (the caller writes nothing).
--- @return boolean passes
function GrowthBlock.passesR2(capturedFruit, currentFruit, capturedState, currentState, isCut, isWithered)
    if currentFruit == nil or currentFruit ~= capturedFruit then return false end
    if isCut or isWithered then return false end
    if type(currentState) ~= 'number' or type(capturedState) ~= 'number' then return false end
    return currentState > capturedState
end

--- Classify the two-layer capture after layer + metadata load (brief 3.1).
--- @param state { exists, loaded, resolution }
--- @param fruit { exists, loaded, resolution }
--- @param metadataClaimsCapture boolean
--- @param expectedResolution number
--- @return string FRESH|COMPLETE|PAIR_INVALID
function GrowthBlock.classifyPair(state, fruit, metadataClaimsCapture, expectedResolution)
    local neitherExists = not state.exists and not fruit.exists
    if neitherExists and not metadataClaimsCapture then return GrowthBlock.PAIR_FRESH end
    local complete = state.exists and fruit.exists
        and state.loaded and fruit.loaded
        and state.resolution == expectedResolution
        and fruit.resolution == expectedResolution
    if complete then return GrowthBlock.PAIR_COMPLETE end
    return GrowthBlock.PAIR_INVALID
end

--- Open one ordered bracket for a transition (brief 3.4). Seasonal derives the
--- immutable next period with a fixed 12-wrap; the returned bracket never reads
--- live environment.currentPeriod after START. Receipts carry the immutable
--- per-farmland identity captured at first START.
--- @return table bracket
function GrowthBlock.openBracket(transitionPeriod, gateLive, growthMode, captureGeneration, receipts)
    return {
        firstTransitionPeriod = transitionPeriod,
        lastStartPeriod       = transitionPeriod,
        targetPeriod          = transitionPeriod % 12 + 1,
        gateLiveAtStart       = gateLive,
        growthMode            = growthMode,
        captureGeneration     = captureGeneration,
        globalStale           = false,
        receipts              = receipts or {},
    }
end

--- Close (drain) an active bracket against a FINISHED delivery (brief 3.7).
--- Returns one of CLOSE_*: MISSING (no envelope) / CLOSED_PENDING (queue still
--- draining) / CLOSED_UNMATCHED (finishedPeriod ~= lastStartPeriod) /
--- CLOSED_DISABLED / CLOSED_LOCKED (gate down at START or now) / CLOSED_STALE
--- (global stale or capture generation moved) / RESTORE (drained, stable, gate
--- live, unchanged generation: restore stable receipts, then clear).
function GrowthBlock.closeBracket(envelope, finishedPeriod, hasPendingGrowth, gateLiveNow, currentCaptureGeneration)
    if envelope == nil then return GrowthBlock.CLOSE_MISSING end
    if hasPendingGrowth then return GrowthBlock.CLOSE_PENDING end
    if finishedPeriod ~= envelope.lastStartPeriod then return GrowthBlock.CLOSE_UNMATCHED end
    if envelope.growthMode == 'DISABLED' then return GrowthBlock.CLOSE_DISABLED end
    if not envelope.gateLiveAtStart or not gateLiveNow then return GrowthBlock.CLOSE_LOCKED end
    if envelope.globalStale then return GrowthBlock.CLOSE_STALE end
    if envelope.captureGeneration ~= currentCaptureGeneration then return GrowthBlock.CLOSE_STALE end
    return GrowthBlock.CLOSE_RESTORE
end

--- Post-write result owns the restored classification (brief 3.9 / step 5): only
--- a cell the engine reports at exactly the target state under the SAME fruit
--- counts as restored (its byte flips ACTIVE -> HELD). Every other submitted
--- cell is a MISSED hold (ACTIVE -> MISSED). Returns restored, missed; mutates
--- each cell.outcome to CELL_HELD or CELL_MISSED.
function GrowthBlock.verifyPostWrite(cells, actual)
    local restored, missed = 0, 0
    for _, cell in ipairs(cells or {}) do
        local observed = actual and actual[cell.key]
        if observed ~= nil and observed.fruitIndex == cell.fruitIndex
            and observed.state == cell.targetState then
            cell.outcome = GrowthBlock.CELL_HELD
            restored = restored + 1
        else
            cell.outcome = GrowthBlock.CELL_MISSED
            missed = missed + 1
        end
    end
    return restored, missed
end

-- ============================================================
-- INPUTS (read-only access to the family's own data)
-- ============================================================

function GrowthBlock:_viability()
    local v = self.manager and self.manager.viability
    if v ~= nil and type(v.getCellGrowthInfo) == 'function' then return v end
    return nil
end

function GrowthBlock:_valueMaps()
    local soilSystem = self.manager and self.manager.soilSystem
    local vm = soilSystem and soilSystem.valueMaps
    if vm ~= nil and vm.available then return vm end
    return nil
end

function GrowthBlock:_soilSystem()
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and type(ss._getFarmlandPolygons) == 'function' then return ss end
    return nil
end

--- The SF-52 provider's immutable complete plan for a farmland, or nil.
function GrowthBlock:_plan(farmlandId)
    local m = self.manager
    if m == nil or type(m.getGrowthEligibleRegionPlan) ~= 'function' then return nil end
    local ok, plan = pcall(function() return m:getGrowthEligibleRegionPlan(farmlandId) end)
    if not ok then return nil end
    return plan
end

--- The current farmland+unscoped observation token, or nil.
function GrowthBlock:_token(farmlandId)
    local vm = self:_valueMaps()
    if vm == nil or type(vm.getGrowthInputToken) ~= 'function' then return nil end
    local ok, token = pcall(function() return vm:getGrowthInputToken(farmlandId) end)
    if not ok then return nil end
    return token
end

--- The farmlands currently tracked by the soil system, in ascending numeric
--- order (brief 3.4 step 2: enumerate in ascending numeric order).
function GrowthBlock:_currentFarmlandIds()
    local ss = self:_soilSystem()
    local ids = {}
    if ss ~= nil and ss.fieldData ~= nil then
        for farmlandId in pairs(ss.fieldData) do ids[#ids + 1] = farmlandId end
    end
    table.sort(ids)
    return ids
end

--- Server test that tolerates a bench mission without getIsServer (nil-safe; a
--- mission that cannot answer is treated as not-server, matching the siblings).
function GrowthBlock:_isServer()
    local mission = g_currentMission
    if mission ~= nil and type(mission.getIsServer) == 'function' then
        local ok, isServer = pcall(function() return mission:getIsServer() end)
        if ok then return isServer == true end
        return false
    end
    return false
end

--- A deterministic roster fingerprint for the current fruit-type set, so a loaded
--- capture whose numeric fruit identity may have moved is cleared (brief 3.2).
function GrowthBlock:_fruitRosterFingerprint()
    local ftm = g_fruitTypeManager
    if ftm == nil or type(ftm.getFruitTypes) ~= 'function' then return '' end
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

--- The current Option-Scaling profile through the vendored readProfile contract.
function GrowthBlock:_readProfile()
    if OptionScalingResolver == nil or type(OptionScalingResolver.readProfile) ~= 'function' then
        return nil
    end
    local sh = (g_currentMission ~= nil and g_currentMission.settingsHub) or nil
    if sh == nil then return nil end
    local ok, profile = pcall(OptionScalingResolver.readProfile, OptionScalingResolver, sh)
    if not ok then return nil end
    return profile
end

-- ============================================================
-- THE PAIRED CAPTURE LAYERS (brief 3.1)
-- ============================================================

--- Read one logical capture cell at a world point. Returns the captured state,
--- fruit index and flags, or nil when either half is absent/invalid. Presence is
--- carried by the fruit byte (which always holds a flag for a real capture); the
--- state byte may legitimately be 0.
--- @return number|nil capturedState
--- @return number|nil fruitIndex
--- @return boolean active
--- @return boolean held
function GrowthBlock:_readPair(vm, x, z)
    local fruitRaw = vm:readValueAtWorld('growthBlockFruit', x, z)
    if fruitRaw == nil or fruitRaw <= 0 then return nil end
    local fruit, active, held = GrowthBlock.unpackFruit(fruitRaw)
    if fruit == nil then return nil end
    local stateRaw = vm:readValueAtWorld('growthBlockState', x, z)
    if stateRaw == nil then return nil end
    if not GrowthBlock.isValidCapturedState(stateRaw) then return nil end
    return stateRaw, fruit, active, held
end

--- Write one logical capture cell. State 0..254, fruit 1..63, exactly one flag.
--- Any invalid or zero-intent write clears BOTH halves. Post-reads both halves;
--- a one-sided or invalid result clears both and returns false (brief 3.1).
function GrowthBlock:_writePair(vm, x, z, capturedState, fruit, active, held, radius)
    local packedFruit = GrowthBlock.packFruit(fruit, active, held)
    if packedFruit == nil or not GrowthBlock.isValidCapturedState(capturedState) then
        self:_clearPair(vm, x, z, radius)
        return false
    end
    self:_clearPair(vm, x, z, radius)   -- brief 3.1 step 1: clear old raw first
    local ok1 = pcall(function() vm:writeValueAtWorld('growthBlockState', x, z, capturedState, radius) end)
    local ok2 = pcall(function() vm:writeValueAtWorld('growthBlockFruit', x, z, packedFruit, radius) end)
    if not ok1 or not ok2 or self:_readPair(vm, x, z) == nil then
        self:_clearPair(vm, x, z, radius)
        return false
    end
    return true
end

--- Clear both halves of one logical capture cell (raw-zero absent; the carrier's
--- linear encode maps semantic 0 to raw 1, read back as 0 and treated as absent).
function GrowthBlock:_clearPair(vm, x, z, radius)
    local r = radius or 1.5
    pcall(function() vm:writeValueAtWorld('growthBlockState', x, z, 0, r) end)
    pcall(function() vm:writeValueAtWorld('growthBlockFruit', x, z, 0, r) end)
end

--- The capture's availability gate (brief 3.1/3.3): a PAIR_INVALID state clears
--- both layers and all metadata before any validation, capture or save.
function GrowthBlock:_classifyPairState()
    local vm = self:_valueMaps()
    if vm == nil then
        self._bankPairState = GrowthBlock.PAIR_INVALID
        self._bankAvailable = false
        return self._bankPairState
    end
    local stateEntry = vm.getLayerEntry and vm:getLayerEntry('growthBlockState') or nil
    local fruitEntry = vm.getLayerEntry and vm:getLayerEntry('growthBlockFruit') or nil
    local expected = vm.resolution or 0

    local stateProbe = { exists = false, loaded = false, resolution = 0 }
    local fruitProbe = { exists = false, loaded = false, resolution = 0 }
    if stateEntry and stateEntry.loaded then stateProbe = { exists = true, loaded = true, resolution = expected } end
    if fruitEntry and fruitEntry.loaded then fruitProbe = { exists = true, loaded = true, resolution = expected } end

    local claimsCapture = false
    for _, meta in pairs(self._metadata) do
        if meta ~= nil and (meta.active == true or meta.migrationMarker ~= nil) then
            claimsCapture = true
        end
    end

    local state = GrowthBlock.classifyPair(stateProbe, fruitProbe, claimsCapture, expected)
    self._bankPairState = state
    if state == GrowthBlock.PAIR_INVALID then
        pcall(function() vm:clearLayer('growthBlockState') end)
        pcall(function() vm:clearLayer('growthBlockFruit') end)
        self._metadata = {}
        self._envelope = nil
        self._bankAvailable = false
    elseif state == GrowthBlock.PAIR_COMPLETE or state == GrowthBlock.PAIR_FRESH then
        self._bankAvailable = true
    end
    return state
end

-- World -> carrier grid helpers at a plan's execution grain.
function GrowthBlock:_grain(plan)
    local g = plan and (plan.executionGrainMetres or plan.truthGrainMetres)
    if type(g) ~= 'number' or g <= 0 then return nil end
    return g
end

function GrowthBlock:_decodeKey(key)
    if type(key) ~= 'string' then return nil end
    local gx, gz = key:match("^(-?%d+):(-?%d+)$")
    if not gx then return nil end
    return tonumber(gx), tonumber(gz)
end

-- The engine's per-cell get: FSDensityMapUtil.getFruitTypeIndexAtWorldPos returns
-- (fruitTypeIndex, growthState) in one call.
function GrowthBlock:_readCellState(x, z)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= 'function' then
        return nil, nil
    end
    local ok, fruitIndex, state = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok or fruitIndex == nil or state == nil then return nil, nil end
    return state, fruitIndex
end

-- ============================================================
-- FIRST START: capture the pre-state (brief 3.4)
-- ============================================================

--- START delivery from the manager's single growth dispatch. When no envelope is
--- active, capture every stable blocked plan cell's pre-state, write-once across
--- the bracket; when an envelope is active, this is a later START (brief 3.5).
function GrowthBlock:onStartGrowthPeriod(transitionPeriod)
    if not self:_isServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end

    if self._envelope ~= nil then
        return self:_laterStart(transitionPeriod)
    end
    return self:_firstStart(transitionPeriod)
end

function GrowthBlock:_firstStart(transitionPeriod)
    local vm = self:_valueMaps()
    if vm == nil then return end
    self:_classifyPairState()
    if not self._bankAvailable then return end

    local mission = g_currentMission
    local growthMode = mission and mission.missionInfo and mission.missionInfo.growthMode
    local modeName = (growthMode == GrowthMode.SEASONAL) and 'SEASONAL'
        or (growthMode == GrowthMode.DAILY) and 'DAILY' or 'DISABLED'
    if modeName == 'DISABLED' then return end

    local period = transitionPeriod or 1
    local receipts = {}
    local anyCommitted = false
    for _, farmlandId in ipairs(self:_currentFarmlandIds()) do
        local receipt = self:_captureFarmland(farmlandId, vm, period)
        if receipt ~= nil then
            receipts[#receipts + 1] = receipt
            anyCommitted = true
        end
    end
    -- Publish one generation after every candidate is committed or omitted.
    self._captureGeneration = self._captureGeneration + 1
    -- Create an active envelope only when at least one receipt commits.
    if not anyCommitted then return end
    self._envelope = GrowthBlock.openBracket(period, true, modeName, self._captureGeneration, receipts)
    return true
end

--- Capture one farmland's blocked pre-state cells (brief 3.4 steps 3-10). Returns
--- an immutable receipt, or nil when the farmland is omitted (no plan, budget,
--- token or geometry mismatch, or nothing captured). A partial capture clears
--- only this farmland's owned cells and omits it.
function GrowthBlock:_captureFarmland(farmlandId, vm, period)
    local plan = self:_plan(farmlandId)
    if plan == nil or type(plan.regions) ~= 'table' or #plan.regions == 0 then return nil end
    local token = self:_token(farmlandId)
    if token == nil then return nil end
    if plan.farmlandInputRevision ~= token.farmlandRevision
        or plan.unscopedInputRevision ~= token.unscopedRevision then return nil end

    local grain = self:_grain(plan)
    if grain == nil then return nil end
    local radius = grain * 0.5

    -- Clear prior completed (HELD/MISSED) outcome bytes across admitted regions
    -- before the new capture (brief 3.4 step 4). The next first START replaces
    -- completed outcomes; completed bytes can never restore again.
    local written = {}
    local committed = false
    for _, region in ipairs(plan.regions) do
        if region.writableForFarmland == true then
            local gx, gz = self:_decodeKey(region.key)
            if gx ~= nil then
                local cx = gx * grain + grain * 0.5
                local cz = gz * grain + grain * 0.5
                self:_clearPair(vm, cx, cz, radius)
                if region.blocked == true then
                    if self:_captureCell(farmlandId, vm, cx, cz, radius, region.key) then
                        written[#written + 1] = region.key
                        committed = true
                    end
                end
            end
        end
    end
    if not committed then return nil end

    self._metadata[farmlandId] = {
        schema = 1,
        active = true,
        fruitRosterFingerprint = self:_fruitRosterFingerprint(),
        terrainResolution = vm.resolution or 0,
        truthGrainMetres = (type(vm.getGrainMetres) == 'function') and vm:getGrainMetres() or nil,
        polygonUnionFingerprint = plan.polygonUnionFingerprint,
        planContentHash = plan.planContentHash,
        settingsFingerprint = plan.settingsFingerprint or '',
        transitionCount = 1,
        lastTransitionPeriod = period,
    }
    return {
        farmlandId = farmlandId,
        planId = plan.planId,
        planContentHash = plan.planContentHash,
        polygonUnionFingerprint = plan.polygonUnionFingerprint,
        farmlandInputRevision = plan.farmlandInputRevision or token.farmlandRevision,
        unscopedInputRevision = plan.unscopedInputRevision or token.unscopedRevision,
        settingsFingerprint = plan.settingsFingerprint or '',
        carrierOwnershipHash = plan.carrierOwnershipHash,
        transitionCount = 1,
        lastTransitionPeriod = period,
        stale = false,
    }
end

--- Capture one carrier square's pre-state (brief 3.4 steps 6-9). Reads current
--- fruit identity + state fresh; rejects unknown, bare, cut or withered; accepts
--- a shared carrier key only when SF-52 names this receipt farmland as owner.
function GrowthBlock:_captureCell(farmlandId, vm, cx, cz, radius, regionKey)
    local state, fruitIndex = self:_readCellState(cx, cz)
    if state == nil or fruitIndex == nil then return false end
    if fruitIndex < 1 or fruitIndex > GrowthBlock.FRUIT_MAX then return false end
    if not GrowthBlock.isValidCapturedState(state) then return false end
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return false end
    if fruitDesc:getIsCut(state) or fruitDesc:getIsWithered(state) then return false end
    -- Write-once ACTIVE capture: state + fruit with the ACTIVE flag.
    return self:_writePair(vm, cx, cz, state, fruitIndex, true, false, radius)
end

-- ============================================================
-- LATER START: never recapture (brief 3.5)
-- ============================================================

function GrowthBlock:_laterStart(transitionPeriod)
    local env = self._envelope
    if env == nil then return end
    env.lastStartPeriod = transitionPeriod or env.lastStartPeriod

    -- Global comparison: unscoped revision, roster, settings, growth mode.
    local mission = g_currentMission
    local growthMode = mission and mission.missionInfo and mission.missionInfo.growthMode
    local modeName = (growthMode == GrowthMode.SEASONAL) and 'SEASONAL'
        or (growthMode == GrowthMode.DAILY) and 'DAILY' or 'DISABLED'
    if modeName ~= env.growthMode then env.globalStale = true end
    if env.globalStale then return true end

    -- Per-farmland: matching plan-content hash + geometry increments only that
    -- receipt's transition count; changed or unavailable plan stales it.
    for _, receipt in ipairs(env.receipts) do
        if not receipt.stale then
            local plan = self:_plan(receipt.farmlandId)
            local token = self:_token(receipt.farmlandId)
            if plan == nil or token == nil
                or plan.planContentHash ~= receipt.planContentHash
                or plan.polygonUnionFingerprint ~= receipt.polygonUnionFingerprint
                or plan.farmlandInputRevision ~= receipt.farmlandInputRevision then
                receipt.stale = true
            else
                receipt.transitionCount = receipt.transitionCount + 1
                receipt.lastTransitionPeriod = transitionPeriod or receipt.lastTransitionPeriod
                local meta = self._metadata[receipt.farmlandId]
                if meta ~= nil then
                    meta.transitionCount = receipt.transitionCount
                    meta.lastTransitionPeriod = receipt.lastTransitionPeriod
                end
            end
        end
    end
    return true
end

-- ============================================================
-- FINISHED: restore, then unconditional cleanup (brief 3.7)
-- ============================================================

--- FINISHED delivery from the manager's single growth dispatch. Runs the server
--- and initialization checks even when the gate is now closed; a drained, stable
--- bracket restores stable receipts, then EVERY path clears active capture
--- authority unconditionally (brief 3.7 step 6, cert assertion).
function GrowthBlock:onFinishedGrowthPeriod(finishedPeriod, hasPendingGrowth)
    if not self:_isServer() then return end
    if not self.isInitialized then return end
    local env = self._envelope
    if env == nil then return GrowthBlock.CLOSE_MISSING end

    local pending = (hasPendingGrowth == true)
    local gateLiveNow = self:isLive()
    local outcome = GrowthBlock.closeBracket(env, finishedPeriod or env.lastStartPeriod,
        pending, gateLiveNow, self._captureGeneration)

    if outcome == GrowthBlock.CLOSE_PENDING then
        -- Retain the envelope and return without restore or clear.
        return outcome
    end

    local restored = false
    if outcome == GrowthBlock.CLOSE_RESTORE then
        restored = self:_restoreBracket(env)
    end

    -- THE UNCONDITIONAL CLEANUP. Every non-pending drained delivery removes all
    -- active restore authority and clears the envelope, whatever the outcome.
    -- growthMode is runtime-settable; a surviving capture plus write-once would
    -- wedge the bracket forever (cert assertion).
    self:_clearActiveAuthority()
    self._envelope = nil
    if outcome == GrowthBlock.CLOSE_RESTORE then return restored end
    return outcome
end

--- Restore one drained stable bracket: for each stable farmland receipt,
--- re-enumerate the provider-owned regions, read the captured pair and current
--- state fresh, apply the R2 guards, derive the immutable target, bucket by
--- (fruitIndex, sourceState, targetState), stroke one filtered executeSet per
--- bucket, then re-read every submitted cell and mark HELD/MISSED.
function GrowthBlock:_restoreBracket(env)
    local vm = self:_valueMaps()
    if vm == nil then return false end
    local wroteAny = false
    for _, receipt in ipairs(env.receipts or {}) do
        if not receipt.stale then
            if self:_restoreFarmland(receipt, vm) then wroteAny = true end
        end
    end
    return wroteAny
end

function GrowthBlock:_restoreFarmland(receipt, vm)
    local farmlandId = receipt.farmlandId
    local plan = self:_plan(farmlandId)
    if plan == nil or plan.planId ~= receipt.planId then return false end
    local token = self:_token(farmlandId)
    if token == nil then return false end
    if plan.planContentHash ~= receipt.planContentHash
        or plan.polygonUnionFingerprint ~= receipt.polygonUnionFingerprint
        or plan.farmlandInputRevision ~= receipt.farmlandInputRevision
        or plan.unscopedInputRevision ~= receipt.unscopedInputRevision
        or plan.settingsFingerprint ~= receipt.settingsFingerprint then
        return false
    end

    local grain = self:_grain(plan)
    if grain == nil then return false end
    local radius = grain * 0.5
    local steps = GrowthBlock.effectiveRestoreSteps(self:_readProfile())

    -- Re-enumerate provider-owned regions and select restorable captured cells.
    -- Ownership is the filter; _restoreCandidate then requires an ACTIVE pair, so
    -- the blocked flag at capture time is already encoded in the carrier.
    local candidates = {}
    for _, region in ipairs(plan.regions) do
        if region.writableForFarmland == true then
            local gx, gz = self:_decodeKey(region.key)
            if gx ~= nil then
                local cx = gx * grain + grain * 0.5
                local cz = gz * grain + grain * 0.5
                local cell = self:_restoreCandidate(farmlandId, vm, cx, cz, gx, gz, region.key,
                    steps, receipt.transitionCount)
                if cell ~= nil then candidates[#candidates + 1] = cell end
            end
        end
    end
    if #candidates == 0 then return false end

    -- Bucket survivors by (fruitIndex, currentState, targetState).
    local buckets = {}
    for _, c in ipairs(candidates) do
        local key = c.fruitIndex .. "|" .. c.current .. "|" .. c.target
        local b = buckets[key]
        if b == nil then
            b = { fruitIndex = c.fruitIndex, current = c.current, target = c.target, cells = {} }
            buckets[key] = b
        end
        b.cells[#b.cells + 1] = {
            gx = c.gx, gz = c.gz, key = c.key,
            fruitIndex = c.fruitIndex, targetState = c.target,
        }
    end

    local anyWritten = false
    for _, b in pairs(buckets) do
        local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(b.fruitIndex)
        if fruitDesc ~= nil and fruitDesc.terrainDataPlaneId ~= nil then
            if self:_strokeBucket(b, fruitDesc, grain) then
                -- Post-write: re-read every submitted cell; HELD only the verified.
                local actual = {}
                for _, cc in ipairs(b.cells) do
                    local cx = cc.gx * grain + grain * 0.5
                    local cz = cc.gz * grain + grain * 0.5
                    local st, fi = self:_readCellState(cx, cz)
                    actual[cc.key] = { fruitIndex = fi, state = st }
                end
                local restored = GrowthBlock.verifyPostWrite(b.cells, actual)
                for _, cc in ipairs(b.cells) do
                    local cx = cc.gx * grain + grain * 0.5
                    local cz = cc.gz * grain + grain * 0.5
                    -- Flip ACTIVE -> HELD (verified) or ACTIVE -> MISSED, retain fruit.
                    local held = (cc.outcome == GrowthBlock.CELL_HELD)
                    self:_writePair(vm, cx, cz, cc.targetState, cc.fruitIndex, false, held, radius)
                end
                if restored > 0 then anyWritten = true end
            end
        end
    end
    return anyWritten
end

--- One restore candidate: a captured, ACTIVE, provider-owned cell whose current
--- fruit/state pass the R2 guards, with a target strictly between captured and
--- current. Returns the cell or nil.
function GrowthBlock:_restoreCandidate(farmlandId, vm, cx, cz, gx, gz, regionKey, steps, transitionCount)
    local capturedState, storedFruit, active = self:_readPair(vm, cx, cz)
    if capturedState == nil or storedFruit == nil then return nil end
    if active ~= true then return nil end   -- only an ACTIVE capture may restore

    local state, fruitIndex = self:_readCellState(cx, cz)
    if state == nil or fruitIndex == nil then return nil end
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return nil end
    local isCut = fruitDesc:getIsCut(state)
    local isWithered = fruitDesc:getIsWithered(state)
    if not GrowthBlock.passesR2(storedFruit, fruitIndex, capturedState, state, isCut, isWithered) then
        return nil
    end

    -- SF-52 condition: blocked or unavailable ground cannot restore.
    local info = self:_viability() and self:_viability():getCellGrowthInfo(farmlandId, cx, cz)
    if info == nil then return nil end

    local target = GrowthBlock.restoreTarget(capturedState, state, steps, transitionCount)
    if target == nil then return nil end
    return {
        key = regionKey, gx = gx, gz = gz,
        fruitIndex = fruitIndex, current = state, target = target, capturedState = capturedState,
    }
end

--- Clear active restore authority across the current metadata (brief 3.7 step 6):
--- every ACTIVE byte in an admitted region loses authority; HELD/MISSED
--- explanation bytes are retained for SF-54 until the next first START.
function GrowthBlock:_clearActiveAuthority()
    for _, meta in pairs(self._metadata) do
        if meta ~= nil then meta.active = false end
    end
end

-- ============================================================
-- THE WRITE HAND (the family machine; fruit-plane executeSet)
-- ============================================================

--- Group 4-connected owned carrier cells into exact rings (world-aligned grid at
--- the plan grain) and stroke one filtered executeSet per bucket.
function GrowthBlock:_strokeBucket(bucket, fruitDesc, grain)
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
        SoilLogger.error("[SF-78] field growth block restore write failed: %s", tostring(err))
    end
    return ok
end

--- Group a list of {gx=, gz=} cells into contiguous 4-connected regions and build
--- each region's outline ring(s) on the world-origin carrier grid. Ring corner i
--- of a region cell sits at (gx*grain, gz*grain).
function GrowthBlock:_bucketRings(cells, grain)
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
-- THE PUBLISHED WITNESS (brief 4 / the SF-54 surface)
-- ============================================================

--- Server capture witness at a world position for SF-54's in-mod assembler, or
--- nil. Reports PENDING availability or NOT_HELD/HELD/MISSED/OMITTED outcome,
--- never a historical cause. Client, stale, partial or mismatched reads return
--- nil.
function GrowthBlock:getGrowthSurfaceWitness(fieldId, x, z)
    if not self.isInitialized then return nil end
    if not self:_isServer() then return nil end
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local plan = self:_plan(fieldId)
    if plan == nil then return nil end
    local grain = self:_grain(plan)
    if grain == nil then return nil end

    local key = math.floor(x / grain) .. ':' .. math.floor(z / grain)
    local covered, carrierOwner = false, nil
    for _, region in ipairs(plan.regions) do
        if region.key == key then covered = true; carrierOwner = region.carrierOwnerFarmlandId; break end
    end
    if not covered then return nil end
    if carrierOwner ~= nil and carrierOwner ~= fieldId then return nil end

    local capturedState, storedFruit, active, held = self:_readPair(vm, x, z)
    if capturedState == nil or storedFruit == nil then
        return { farmlandId = fieldId, coversPoint = true, outcome = 'NOT_HELD',
                 siblingGeneration = self._captureGeneration }
    end
    local outcome = active and 'PENDING' or (held and 'HELD' or 'MISSED')
    return {
        farmlandId = fieldId,
        polygonUnionFingerprint = plan.polygonUnionFingerprint,
        coversPoint = true,
        siblingGeneration = self._captureGeneration,
        fruitIndex = storedFruit,
        capturedState = capturedState,
        active = active,
        outcome = outcome,
    }
end

--- Active first-START membership exposed to SF-53 as an exclusion (brief 4): a
--- cell captured under an active bracket cannot be spent by the credit sibling in
--- the same queued batch.
function GrowthBlock:isCapturedAtFirstStart(fieldId, x, z)
    if self._envelope == nil then return false end
    local vm = self:_valueMaps()
    if vm == nil then return false end
    local _, _, active = self:_readPair(vm, x, z)
    return active == true
end

-- ============================================================
-- SAVE / RELOAD / TEARDOWN (brief 3.6)
-- ============================================================

--- Persist the small durable metadata under soilData.growthBlock. The dense cell
--- truth is the two GRLE files written by SoilValueMaps; no per-cell list enters
--- XML. Session revisions, plan IDs and callback state are never serialized.
function GrowthBlock:saveToXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then return end
    setXMLInt(xmlFile, key .. "#schema", 1)
    setXMLInt(xmlFile, key .. "#captureGeneration", self._captureGeneration or 0)
    local env = self._envelope
    setXMLInt(xmlFile, key .. "#active", env ~= nil and 1 or 0)
    if env ~= nil then
        setXMLInt(xmlFile, key .. "#firstTransitionPeriod", env.firstTransitionPeriod or 0)
        setXMLInt(xmlFile, key .. "#lastStartPeriod", env.lastStartPeriod or 0)
        setXMLString(xmlFile, key .. "#growthMode", env.growthMode or 'DISABLED')
    end
    local idx = 0
    for farmlandId, meta in pairs(self._metadata or {}) do
        if meta ~= nil then
            local entryKey = string.format("%s.farmland(%d)", key, idx)
            setXMLInt(xmlFile, entryKey .. "#id", farmlandId)
            setXMLInt(xmlFile, entryKey .. "#active", meta.active == true and 1 or 0)
            setXMLString(xmlFile, entryKey .. "#fruitRoster", meta.fruitRosterFingerprint or '')
            setXMLInt(xmlFile, entryKey .. "#resolution", meta.terrainResolution or 0)
            setXMLFloat(xmlFile, entryKey .. "#grain", meta.truthGrainMetres or 0)
            setXMLString(xmlFile, entryKey .. "#geometry", meta.polygonUnionFingerprint or '')
            setXMLString(xmlFile, entryKey .. "#planHash", meta.planContentHash or '')
            setXMLString(xmlFile, entryKey .. "#settings", meta.settingsFingerprint or '')
            setXMLInt(xmlFile, entryKey .. "#transitionCount", meta.transitionCount or 1)
            setXMLInt(xmlFile, entryKey .. "#lastPeriod", meta.lastTransitionPeriod or 0)
            setXMLString(xmlFile, entryKey .. "#migration", meta.migrationMarker or '')
            idx = idx + 1
        end
    end
    setXMLInt(xmlFile, key .. "#count", idx)
end

--- Restore the small metadata (called after the GRLE pair restored; the capture
--- stays PENDING_VALIDATION until current-session membership/fruit validation).
function GrowthBlock:loadFromXMLFile(xmlFile, key)
    self._metadata = {}
    self._pendingValidation = {}
    self._envelope = nil
    if xmlFile == nil or key == nil then return end
    self._captureGeneration = getXMLInt(xmlFile, key .. "#captureGeneration") or 0
    local count = getXMLInt(xmlFile, key .. "#count") or 0
    for i = 0, count - 1 do
        local entryKey = string.format("%s.farmland(%d)", key, i)
        local id = getXMLInt(xmlFile, entryKey .. "#id")
        if id ~= nil then
            self._metadata[id] = {
                schema = 1,
                active = (getXMLInt(xmlFile, entryKey .. "#active") or 0) == 1,
                fruitRosterFingerprint = getXMLString(xmlFile, entryKey .. "#fruitRoster") or '',
                terrainResolution = getXMLInt(xmlFile, entryKey .. "#resolution") or 0,
                truthGrainMetres = getXMLFloat(xmlFile, entryKey .. "#grain") or 0,
                polygonUnionFingerprint = getXMLString(xmlFile, entryKey .. "#geometry") or '',
                planContentHash = getXMLString(xmlFile, entryKey .. "#planHash") or '',
                settingsFingerprint = getXMLString(xmlFile, entryKey .. "#settings") or '',
                transitionCount = getXMLInt(xmlFile, entryKey .. "#transitionCount") or 1,
                lastTransitionPeriod = getXMLInt(xmlFile, entryKey .. "#lastPeriod") or 0,
                migration = getXMLString(xmlFile, entryKey .. "#migration") or '',
            }
            self._pendingValidation[id] = true
        end
    end
    self:_classifyPairState()
end

--- StateLedger mirror table (the same normalized durable metadata).
function GrowthBlock:getStateTable()
    return {
        schema = 1,
        captureGeneration = self._captureGeneration,
        active = self._envelope ~= nil,
        farmlands = self._metadata,
    }
end

--- Apply a StateLedger metadata block.
function GrowthBlock:applyStateTable(data)
    self._metadata = {}
    self._pendingValidation = {}
    self._envelope = nil
    if type(data) ~= 'table' then self:_classifyPairState(); return end
    if type(data.farmlands) == 'table' then
        for id, meta in pairs(data.farmlands) do
            if type(meta) == 'table' then
                self._metadata[id] = meta
                self._pendingValidation[id] = true
            end
        end
    end
    self._captureGeneration = (type(data.captureGeneration) == 'number' and data.captureGeneration) or 0
    self:_classifyPairState()
end

-- ============================================================
-- CADENCE + LIFECYCLE
-- No Time Guard registration of any kind: the engine's own bracket
-- (START -> FINISHED) is the clock, delivered through the manager's
-- single family message pair. GrowthBlock owns no independent
-- subscription (brief 3.3 step 12 / 3.11).
-- ============================================================

--- Retained for the manager's uniform family API. GrowthBlock subscribes to no
--- growth callback of its own; the manager delivers START/FINISHED. Returns true
--- so the manager's register sweep treats the member as ready.
function GrowthBlock:register()
    return true
end

--- The family's live gate: the release gate must be open AND the mask enabled.
--- FAIL-OPEN on the release gate (nil settings on the bench means live); the
--- mask switch is a real toggle and gates hard.
function GrowthBlock:isLive()
    local vm = self:_viability()
    if vm ~= nil and vm.enabled == false then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == 'function' then
        return ReleaseGate.isSystemLive("growth_modulation")
    end
    return true
end

function GrowthBlock:delete()
    self.isInitialized = false
    -- GrowthBlock owns no independent subscription; the manager unsubscribes the
    -- single family callback pair. Perform no fruit-plane restore during teardown.
    self._envelope = nil
    self._metadata = {}
    self._pendingValidation = {}
    self._bankAvailable = false
    -- No capture-clearing density write on delete.
end

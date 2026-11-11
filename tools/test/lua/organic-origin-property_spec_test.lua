-- organic-origin-property_spec_test.lua
--
-- Build brief: organic-origin-property-BUILD-BRIEF.md. Soil registers
-- `harvestOrganicOriginV1` with StockGuard's SG-1 as a STORED, birth = true
-- property (src/OrganicOriginProperty.lua).
--
-- ISOLATION-LEVEL BENCH, not a production entry-point battery (unlike the
-- SG2-4c3 GroundConditionProperty bench, which wires through
-- SoilFertilitySystem.new/initialize). This property needs no ground layers,
-- no coordinator and no day cursors, so the rows exercise the module
-- directly: a recorder of StockGuard's mission handle for registration, and
-- the spec's own callbacks called with dots exactly as SGOperations.lua
-- calls them. The field comes from the birth's own place, which StockGuard's
-- capture names in the cut's evidence (FS25_StockGuard #75); the TRANSFORM rows
-- hand that evidence in as SG-1's settle context carries it. What is NOT proved
-- here: StockGuard's own reading of the place (its SG2-3a and SG2-5c group V
-- bars) or a live harvest in game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/hooks/HookManager.lua, src/OrganicOriginProperty.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function countWarn(pattern)
    local n = 0
    for _, w in ipairs(WARN) do if w:find(pattern, 1, true) then n = n + 1 end end
    return n
end

local OOP = OrganicOriginProperty

-- ── A recorder of StockGuard's mission handle ───────────────────────────────
-- Mirrors the SG2-4c3 bench's recorder: a dot-called closure that keeps every
-- argument registerProperty/unregisterOwner are given and answers as the
-- registry does (SGRegistry.lua:139-163 and :295-303): a lease, or nil and a
-- reason.
local function recorder(refuse)
    local r = { registers = {}, unregisters = {}, handle = {}, lease = nil }
    r.handle.registerProperty = function(...)
        local args = { n = select("#", ...), ... }
        r.registers[#r.registers + 1] = args
        if refuse ~= nil then return nil, refuse end
        r.lease = { leaseId = "1:" .. #r.registers, kind = "property", ownerId = args[1], live = true }
        return r.lease
    end
    r.handle.unregisterOwner = function(...)
        local args = { n = select("#", ...), ... }
        r.unregisters[#r.unregisters + 1] = args
        if type(args[1]) == "table" then args[1].live = false end
        return true
    end
    return r
end

local W = {}
local function world(opts)
    opts = opts or {}
    WARN, INFO = {}, {}
    local rec = nil
    if not opts.noStockGuard then rec = recorder(opts.refuse) end
    -- Not `opts.client and nil or {}`: the and/or idiom drops a nil "then" branch
    -- and falls through to the "else", which would make this always {}.
    if opts.client then g_server = nil else g_server = {} end
    g_currentMission = {
        stockGuard = rec ~= nil and rec.handle or nil,
        controlledVehicle = opts.vehicle,
    }
    g_SoilFertilityManager = opts.organic ~= nil and { organic = opts.organic } or nil
    local hm = HookManager.new()
    hm.getFieldIdAtWorldPosition = opts.fieldIdFn or function() return nil end
    -- Same and/or trap: opts.noHookManager and nil always falls through to hm.
    local hookManagerArg = hm
    if opts.noHookManager then hookManagerArg = nil end
    local prop = OOP.new(hookManagerArg)
    W.rec, W.prop, W.hm = rec, prop, hm
    return prop
end
local function spec() return W.rec.registers[1][2] end

local function brief(rec)
    if rec == nil then return "nil" end
    local p = rec.payload or {}
    return table.concat({ tostring(rec.knowledge), tostring(p.fraction),
        tostring(rec.knownAmount) .. "of" .. tostring(rec.basisAmount), tostring(rec.amountUnit) }, "/")
end

-- SG-1's inputs to combine: a portion (SGOperations.lua interpretDestination's
-- contributions) and a destination snapshot, each carrying the record by
-- property id.
local function rec(fraction, litres, knowledge)
    return { propertyId = OOP.PROPERTY_ID, schemaVersion = 1, producerId = "soil", propertyRevision = 0,
             knowledge = knowledge or "KNOWN", knownAmount = litres, basisAmount = litres, amountUnit = "LITRE",
             payload = { fraction = fraction } }
end
local function portion(litres, r) return { amount = litres, unit = "LITRE", properties = { [OOP.PROPERTY_ID] = r } } end
local function dest(litres, r) return { observedAmount = litres, amountUnit = "LITRE", properties = { [OOP.PROPERTY_ID] = r } } end
local OPCTX = { operationId = "op1", operationKind = "BIRTH" }

group("REG", function()
    local alone = world({ noStockGuard = true })
    local ok, why = alone:register(g_currentMission)
    T.eq("REG0 StockGuard absent is a no-op: not registered, no warning",
        tostring(ok) .. "/" .. tostring(why) .. "/" .. tostring(alone:isRegistered()) .. "/" .. countWarn("[OrganicOrigin]"),
        "false/STOCKGUARD_ABSENT/false/0")

    local prop = world()
    local firstRec = W.rec   -- captured now: later world() calls in this group reassign W.rec
    local okR, whyR = prop:register(g_currentMission)
    T.ok("REG1 with StockGuard's handle, register succeeds", okR and prop:isRegistered())
    local r = firstRec.registers
    T.eq("REG2 one registerProperty call, with exactly two arguments, for harvestOrganicOriginV1",
        #r .. "/" .. tostring(r[1] and r[1].n) .. "/" .. tostring(r[1] and r[1][1]), "1/2/harvestOrganicOriginV1")
    local s = r[1][2]
    T.eq("REG3 the spec's literal fields: schema 1, producer soil, STORED, birth = true",
        table.concat({ tostring(s.schemaVersion), tostring(s.producerId), tostring(s.residency), tostring(s.birth) }, "/"),
        "1/soil/STORED/true")
    local fns = {}
    for _, k in ipairs({ "validate", "combine", "transform", "disclosure" }) do fns[#fns + 1] = k .. "=" .. type(s[k]) end
    T.eq("REG4 every callback SGRegistry:registerProperty requires is a function",
        table.concat(fns, " "), "validate=function combine=function transform=function disclosure=function")
    T.eq("REG5 no resolveResident/getResidentRevision - STORED, not OWNER_RESOLVED",
        tostring(s.resolveResident) .. "/" .. tostring(s.getResidentRevision), "nil/nil")
    local again, whyAgain = prop:register(g_currentMission)
    T.eq("REG6 a second register is a no-op: no second call to StockGuard",
        tostring(again) .. "/" .. tostring(whyAgain) .. "/" .. #firstRec.registers, "true/ALREADY_REGISTERED/1")
    T.ok("REG7 the lease kept is the one the handle returned", prop.lease == firstRec.lease and prop.handle == firstRec.handle)

    -- Withdraw checks run now, against firstRec, before any later world() call in this
    -- group reassigns the shared W.rec to a different recorder.
    prop:withdraw("unload")
    T.eq("REG10 withdraw unregisters with the lease, exactly once",
        #firstRec.unregisters .. "/" .. tostring(firstRec.unregisters[1] and firstRec.unregisters[1][1] == firstRec.lease) .. "/" .. tostring(prop:isRegistered()),
        "1/true/false")
    local okW2 = prop:withdraw("unload again")
    T.eq("REG11 a second withdraw is a no-op", tostring(okW2) .. "/" .. #firstRec.unregisters, "false/1")

    local refused = world({ refuse = "DUPLICATE_OWNER" })
    local okRef, whyRef = refused:register(g_currentMission)
    T.eq("REG8 a refused registration: not registered, one warning naming the reason",
        tostring(okRef) .. "/" .. tostring(whyRef) .. "/" .. tostring(refused:isRegistered()) .. "/" .. countWarn("DUPLICATE_OWNER"),
        "false/DUPLICATE_OWNER/false/1")

    local client = world({ client = true })
    local okC, whyC = client:register(g_currentMission)
    T.eq("REG9 a pure client never registers", tostring(okC) .. "/" .. tostring(whyC), "false/NOT_SERVER")
end)

group("VAL", function()
    world()
    local v = OOP.validate
    local good = rec(0.5, 30)
    local other = rec(0.5, 30); other.propertyId = "soil.other"
    local badKnowledge = rec(0.5, 30); badKnowledge.knowledge = "MAYBE"
    local lowOOR = rec(-0.1, 30)
    local highOOR = rec(1.1, 30)
    local unknownOk = rec(0, 30, "UNKNOWN")
    local function verdict(r) local ok, why = v(r) return tostring(ok) .. ":" .. tostring(why) end
    T.eq("VAL1 a record of this property validates; another id, a bad knowledge tag and a fraction outside [0,1] do not",
        table.concat({ verdict(good), verdict(other), verdict(badKnowledge), verdict(lowOOR), verdict(highOOR) }, "/"),
        "true:nil/false:IDENTITY/false:KNOWLEDGE/false:FRACTION/false:FRACTION")
    T.eq("VAL2 an UNKNOWN record with a well-formed payload still validates", verdict(unknownOk), "true:nil")
    T.eq("VAL3 not a table at all is refused", verdict(nil), "false:NOT_TABLE")
end)

group("COMBINE", function()
    local prop = world()
    prop:register(g_currentMission)
    local combine = spec().combine
    -- Matches OrganicCertification:getFarmOrganicFraction's own blend: frac =
    -- (total*oldFrac + amount*isOrganic) / (total+amount), generalized to N parts.
    local c1 = combine(OPCTX, { portion(30, rec(1, 30)), portion(10, rec(0, 10)) }, nil)
    T.eq("C1 30L certified + 10L conventional: weighted average is 0.75",
        brief(c1), "KNOWN/0.75/40of40/LITRE")
    local c2 = combine(OPCTX, { portion(20, rec(0.5, 20)) }, dest(20, rec(0, 20)))
    T.eq("C2 the destination's own existing load joins the blend: (20*0 + 20*0.5)/40 = 0.25",
        brief(c2), "KNOWN/0.25/40of40/LITRE")
    T.eq("C3 a portion with no record at all contributes no litres: the known part alone decides it",
        brief(combine(OPCTX, { portion(30, rec(1, 30)), { amount = 10, unit = "LITRE", properties = {} } }, nil)),
        "KNOWN/1/30of30/LITRE")
    T.eq("C4 a zero-litre portion imports nothing",
        brief(combine(OPCTX, { portion(30, rec(0.6, 30)), { amount = 0, unit = "LITRE", properties = {} } }, nil)),
        "KNOWN/0.6/30of30/LITRE")
    T.eq("C5 an UNKNOWN-knowledge portion carries no litres into a continuous blend",
        brief(combine(OPCTX, { portion(30, rec(1, 30)), portion(10, rec(0, 10, "UNKNOWN")) }, nil)),
        "KNOWN/1/30of30/LITRE")
    local none, why = combine(OPCTX, { { amount = 0, unit = "LITRE", properties = {} } }, nil)
    T.eq("C6 no material at all: nil, NO_MATERIAL", tostring(none) .. "/" .. tostring(why), "nil/NO_MATERIAL")
    T.eq("C7 every result above validates", tostring(spec().validate(c1)) .. "/" .. tostring(spec().validate(c2)), "true/true")
end)

group("TRANSFORM", function()
    -- The birth's place, as StockGuard's capture names it in the cut's own evidence
    -- (FS25_StockGuard #75): context.report.outcomeEvidence.vehiclePosition.
    local function ctxAt(x, z, path)
        return { operationId = "op1", operationKind = "BIRTH",
                 report = { outcomeEvidence = { nativePath = path or "COMBINE_CUT", vehiclePosition = { x = x, y = 2, z = z, vehicleId = "vehicle:header" } } } }
    end
    local OUT = { { amount = 25, unit = "LITRE" } }
    local certified = { getFieldOrganicState = function(_self, fieldId) return { certified = fieldId == 42 } end }
    -- Field 42 east of x = 100, field 7 west of it; every lookup is recorded with the place it was given.
    local asked = {}
    local function fieldAt(_hm, x, z)
        asked[#asked + 1] = tostring(x) .. "," .. tostring(z)
        if type(x) ~= "number" then return nil end
        return x > 100 and 42 or 7
    end

    local prop = world({ fieldIdFn = fieldAt, organic = certified })
    asked = {}
    local t1 = prop:transform(ctxAt(137.5, -12.75), {}, OUT)
    T.eq("T1 the cut's place is on a certified field: fraction 1, KNOWN, and the field lookup was given exactly that place",
        brief(t1) .. "|" .. table.concat(asked, ";"), "KNOWN/1/25of25/LITRE|137.5,-12.75")

    asked = {}
    local t2 = prop:transform(ctxAt(10, 208.25, "GROUND_MOWER_CUT"), {}, OUT)
    T.eq("T2 the Mower's cut on a conventional field: fraction 0, KNOWN", brief(t2) .. "|" .. table.concat(asked, ";"), "KNOWN/0/25of25/LITRE|10,208.25")

    local untracked = world({ fieldIdFn = fieldAt })
    local t3 = untracked:transform(ctxAt(137.5, -12.75), {}, OUT)
    T.eq("T3 StockGuard present but OrganicCertification unreachable: defaults to conventional (0), never a guessed 1",
        brief(t3), "KNOWN/0/25of25/LITRE")

    -- No place, no field: honestly UNKNOWN, and the lookup is never asked to guess.
    asked = {}
    local older = { operationId = "op1", operationKind = "BIRTH", report = { outcomeEvidence = { nativePath = "COMBINE_CUT" } } }
    local t4 = prop:transform(older, {}, OUT)
    local t5 = prop:transform({ operationId = "op1", operationKind = "BIRTH" }, {}, OUT)
    local t5b = prop:transform(nil, {}, OUT)
    T.eq("T4 the evidence names no place (a StockGuard older than #75), no report at all, or no context: UNKNOWN each time, and no field lookup",
        brief(t4) .. "|" .. brief(t5) .. "|" .. brief(t5b) .. "|" .. #asked, "UNKNOWN/0/0of25/LITRE|UNKNOWN/0/0of25/LITRE|UNKNOWN/0/0of25/LITRE|0")
    local t6a = prop:transform(ctxAt(0 / 0, 5), {}, OUT)
    local t6b = prop:transform(ctxAt(137.5, math.huge), {}, OUT)
    local t6c = prop:transform({ report = { outcomeEvidence = { vehiclePosition = { x = "137.5", z = 5 } } } }, {}, OUT)
    T.eq("T5 a place that is not a finite x and z (NaN, infinite, a string) is no place: UNKNOWN, no field lookup",
        brief(t6a) .. "|" .. brief(t6b) .. "|" .. brief(t6c) .. "|" .. #asked, "UNKNOWN/0/0of25/LITRE|UNKNOWN/0/0of25/LITRE|UNKNOWN/0/0of25/LITRE|0")

    local outside = world({ fieldIdFn = function() return nil end, organic = certified })
    T.eq("T6 a place outside every field: UNKNOWN", brief(outside:transform(ctxAt(137.5, -12.75), {}, OUT)), "UNKNOWN/0/0of25/LITRE")

    -- A player's vehicle is never read: the place in the evidence is the only source.
    local playerCombine = { spec_combine = {}, rootNode = { x = 500, z = 0 } }
    local seated = world({ vehicle = playerCombine, fieldIdFn = fieldAt, organic = certified })
    g_localPlayer = { getCurrentVehicle = function() return playerCombine end }
    asked = {}
    local t7a = seated:transform(older, {}, OUT)
    local t7b = seated:transform(ctxAt(10, 0), {}, OUT)
    g_localPlayer = nil
    T.eq("T7 a player sitting in a combine on a certified field changes nothing: with no place in the evidence the birth is UNKNOWN, with a place on field 7 it is field 7's 0",
        brief(t7a) .. "|" .. brief(t7b) .. "|" .. table.concat(asked, ";"), "UNKNOWN/0/0of25/LITRE|KNOWN/0/25of25/LITRE|10,0")
    T.eq("T8 the acting-vehicle stand-in is gone from the module", tostring(OOP.resolveActingVehicle), "nil")

    local noHm = world({ noHookManager = true, organic = certified })
    T.eq("T9 no hook manager wired: UNKNOWN", brief(noHm:transform(ctxAt(137.5, -12.75), {}, OUT)), "UNKNOWN/0/0of25/LITRE")

    -- Through the registered spec, called with dots as SGOperations calls it.
    local reg = world({ fieldIdFn = fieldAt, organic = certified })
    reg:register(g_currentMission)
    local t10 = spec().transform(ctxAt(137.5, -12.75), {}, OUT)
    T.eq("T10 the registered spec's transform reads the same place", brief(t10), "KNOWN/1/25of25/LITRE")

    T.eq("T11 every result above validates",
        table.concat({ tostring(OOP.validate(t1)), tostring(OOP.validate(t2)), tostring(OOP.validate(t3)), tostring(OOP.validate(t4)), tostring(OOP.validate(t10)) }, "/"),
        "true/true/true/true/true")
end)

group("DISCLOSURE", function()
    local prop = world()
    prop:register(g_currentMission)
    T.eq("D1 disclosure gives a player view nothing", spec().disclosure({ purpose = "PLAYER_VIEW" }, rec(1, 30)), nil)
end)

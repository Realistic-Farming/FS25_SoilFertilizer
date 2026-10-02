-- SG2-5d-soil_collected_read_spec_test.lua
--
-- SG2-5 slice 5d-soil (SG-2 v2.3 :344, GCC :106 read through :129 and RSF-F211 :56; Bob's G2
-- ruling as amended 2026-10-02, and his G3 ruling): Soil's half of the leased collection read.
--   * a pickup by a collection machine (a Baler or a ForageWagon) captures a COLLECTED snapshot of
--     its source cells on delivery, before Soil projects it: the litres read at admit, the
--     condition nothing has changed since (GroundConditionAdmission); a drop, another primitive
--     or a pickup over bare ground captures none;
--   * the pickup's delivery result names it (result.collection: snapshotRef, basis, revision, the
--     litres each cell lost);
--   * the published groundCondition.readCollectedCondition(snapshotRef, receiptRef) runs Soil's
--     collected reader on that snapshot, resolving the producer's sealed allocation through
--     StockGuard's readCollectionReceipt;
--   * soil.groundCondition's payload carries an optional collected account (F211 :46), which
--     combine adds by carrier litres (GroundConditionProperty).
--
-- THE ENTRY-POINT BAR IS GROUP E. StockGuard's path, in production's order: the published table
-- bound as SGSoilCondition.receiver binds it (StockGuard 26c9d1b, :72-87: the revision through
-- SoilFertilityManager.getCapabilities, the calls through the manager's groundCondition, which
-- activateSoilSystem sets, SoilFertilityManager.lua:457); admit for a Baler, the engine's own line
-- pickup (DensityMapHeightUtil.tipToGroundAroundLine, the engine model's port), deliver, close; then
-- the published read with a receipt. Soil's MaterialWetness is the real module, armed with the
-- family in production's order (the RSF-F211-s6 world). StockGuard's producer is a RECORDER of its
-- handle (5d is unbuilt): it seals an allocation from the delivery's collection by F211 :76's rule
-- and answers readCollectionReceipt, keeping every argument. Nothing hand-writes Soil's snapshot.
--
-- NOT RUN, and why:
--   - MaterialWetness:readCollectedCondition's own refusals beyond the ones the published path adds
--     here: RSF-F211-s6-readers pins them.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialWetness.lua, src/HayBet.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/GroundConditionProperty.lua, src/SoilFertilityManager.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG25DS_BENCH()
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

local FT = ENGINE.FT
local GR = FT.GRASS_WINDROW
local A = GroundConditionAdmission
local MW = MaterialWetness
local GP = GroundConditionProperty

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── the world: production's system, the family armed in production's order (RSF-F211-s6) ──
local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local function world(today)
    HEIGHT.pixels = {}
    g_densityMapHeightManager.valid = true
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {} },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
    }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function() return nil end
    sys.materialDown.ageAppliedThroughDay = today
    local armedWet = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    local armedHay = sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    return (armedWet and armedHay and a and b and c) == true
end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return ENGINE.layerGet(W.age, gx, gz) .. "/" .. ENGINE.layerGet(W.wet, gx, gz) end
--- Windrowed grass on the strip x 0..8, z 0..2: 16 pixels at 50 L. Cell (8,8) holds x 0..4,
--- cell (9,8) holds x 4..8 (4 m grain, origin -32).
local function grass() HEIGHT.fill(GR, 0, 0, 8, 2, 50) end

--- The published table, as StockGuard binds it (header).
local function sfm()
    return { soilSystem = W.sys, getCapabilities = SoilFertilityManager.getCapabilities,
             groundCondition = W.sys.groundConditionAdmission.groundCondition }
end
local function gc()
    local m = sfm()
    local caps = m:getCapabilities()
    if type(caps.groundCondition) ~= "table" or caps.groundCondition.admissionRevision ~= 2 then return nil end
    return m.groundCondition
end
local BALER = { isServer = true, uniqueId = "sg-baler", spec_baler = {} }
local SHOVEL = { isServer = true, uniqueId = "sg-shovel" }
local function lineFP(sx, sz, ex, ez, ft, inner, radius)
    return { schemaVersion = 1, kind = "LINE", sx = sx, sz = sz, ex = ex, ez = ez, fillTypeIndex = ft, innerRadius = inner, radius = radius }
end
--- admit, the engine's line, deliver, close: StockGuard's bracket.
local function bracket(vehicle, delta, sx, sz, ex, ez, inner, radius)
    local t = gc()
    local lease = t.admitPrimitive(lineFP(sx, sz, ex, ez, GR, inner, radius), A.KIND_TIP_LINE, vehicle, "area1")
    if lease.status ~= "ADMITTED" then return lease, nil, nil end
    local okN, litres, off = pcall(DensityMapHeightUtil.tipToGroundAroundLine, vehicle, delta, GR, sx, 0, sz, ex, 0, ez, inner, radius, 0, false, nil)
    local out = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = okN, fillTypeIndex = GR,
        deltaRequested = delta, litresReturned = okN and litres or nil, lineOffset = okN and off or nil })
    t.closePrimitive(lease.leaseToken)
    return lease, out, okN and litres or nil
end
local function pickup(vehicle) return bracket(vehicle, -math.huge, 0, 1, 8, 1, 1, nil) end

-- ── StockGuard's producer, a recorder of its handle ──────────────────────────
-- It seals by F211 :76: the batch's produced carrier W, the accepted A, each source q_i = A *
-- r_i / R (the final remainder on the last part) and the raw retained equivalent r_i * A / W.
local SG = {}
local function sealFrom(collection, A_, W_)
    local R = 0
    for _, p in ipairs(collection.parts) do R = R + p.raw end
    local parts, claim, sum = {}, {}, 0
    for i, p in ipairs(collection.parts) do
        local q = (i < #collection.parts) and A_ * p.raw / R or (A_ - sum)
        sum = sum + q
        parts[i] = { id = p.id, carrierLitres = q, rawLitres = p.raw * A_ / W_ }
        claim[i] = { id = p.id, q = q }
    end
    local sealed = { sealed = true, snapshotId = collection.snapshotRef, acceptedCarrierLitres = A_, parts = parts }
    local receipt = { snapshotId = collection.snapshotRef, basis = collection.basis, revision = collection.revision, total = A_, parts = claim }
    return sealed, receipt
end
local function stockGuardOn(sealed)
    SG = { calls = {}, sealed = sealed }
    g_currentMission.stockGuard = {
        readCollectionReceipt = function(...)
            SG.calls[#SG.calls + 1] = { n = select("#", ...), receipt = (...) }
            return SG.sealed
        end,
    }
end
local function covText(c)
    return table.concat({ tostring(c.status), tostring(c.reason), num(c.carrierLitres), num(c.knownCarrierLitres),
        num(c.unknownCarrierLitres), num(c.refusedCarrierLitres), num(c.pct) }, "/")
end
local function copyTable(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
--- The published read, answered through pcall so a raise is a row's answer, not a crash.
local function readVia(fn, ...)
    local ok, r = pcall(fn, ...)
    if not ok then return { reason = "raised" } end
    return r
end
local function read(ref, receipt) return readVia(gc().readCollectedCondition, ref, receipt) end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    T.ok("E0 [world] the family arms in production's order", world(100) == true)
    T.eq("E0b StockGuard binds the published table at revision 2, and it carries readCollectedCondition",
        tostring(gc() ~= nil) .. "/" .. type(gc().readCollectedCondition), "true/function")
    grass()
    setCell(8, 8, 3, 120)
    setCell(9, 8, 5, 180)
    local pct1, pct2 = MW.rawToPct(120), MW.rawToPct(180)
    local lease, out, picked = pickup(BALER)
    local col = out and out.collection or nil
    local parts = col and col.parts or {}
    T.eq("E1 [entry point] a Baler's leased pickup names its collection: the COLLECTED snapshot, its revision, and the litres each cell lost (summing to the pickup)",
        tostring(lease.status) .. "/" .. tostring(col and col.basis) .. "/" .. tostring(col and type(col.revision) == "table") .. "/" .. #parts .. "/"
            .. tostring(parts[1] and parts[1].id) .. ":" .. num(parts[1] and parts[1].raw) .. "/" .. tostring(parts[2] and parts[2].id) .. ":" .. num(parts[2] and parts[2].raw)
            .. "/" .. num(picked),
        "ADMITTED/" .. MW.BASIS.COLLECTED .. "/true/2/8:8:400/9:8:400/-800")
    T.eq("E1b the source cells were cleared by the pickup's projection", condition(8, 8) .. " " .. condition(9, 8), "0/0 0/0")
    -- StockGuard's seal: the Baler took 800 L (W) and the chamber accepted 400 (A).
    local sealed, receipt = sealFrom(col, 400, 800)
    stockGuardOn(sealed)
    local cov = read(col.snapshotRef, receipt)
    T.eq("E2 NAMED: the published read resolves the producer's seal through StockGuard's readCollectionReceipt, once, with the receipt itself",
        #SG.calls .. "/" .. tostring(SG.calls[1] and SG.calls[1].n) .. "/" .. tostring(SG.calls[1] and SG.calls[1].receipt == receipt), "1/1/true")
    T.eq("E3 NAMED: the coverage is the sources' condition captured BEFORE the pickup cleared them: all 400 L known, pct the litre-weighted mean",
        covText(cov), "ok/COMPLETE_KNOWN_COVERAGE/400/400/0/0/" .. num((200 * pct1 + 200 * pct2) / 400))
    local lowered = copyTable(receipt)
    lowered.total = 300
    T.eq("E4 a receipt whose caller total is lowered cannot pass the sealed 400",
        tostring(read(col.snapshotRef, lowered).reason), "CALLER_ACCEPTANCE_MISMATCH")
    local forged = copyTable(receipt)
    forged.revision = copyTable(receipt.revision)
    forged.revision.changeCounter = forged.revision.changeCounter + 1
    T.eq("E5 a receipt whose source stamp is not the capture's is UNAVAILABLE", tostring(read(col.snapshotRef, forged).reason), "REVISION_MISMATCH")
    -- The collection's revision is the caller's copy: writing to it cannot move Soil's capture.
    local kept = copyTable(receipt)
    kept.revision = copyTable(col.revision)
    col.revision.changeCounter = col.revision.changeCounter + 7
    T.eq("E5b the collection's revision is a copy: a caller writing to it does not move the capture's stamp",
        tostring(read(col.snapshotRef, kept).reason), "COMPLETE_KNOWN_COVERAGE")
    col.revision.changeCounter = col.revision.changeCounter - 7 -- the stand-in seal's receipt shares it
    T.eq("E6 an unknown snapshot reference is UNAVAILABLE, answered in the coverage shape",
        covText(read("COLLECTED_NATIVE_VOLUME_V1#999", receipt)), "unavailable/SNAPSHOT_UNKNOWN/0/0/0/0/nil")
    g_currentMission.stockGuard = nil
    T.eq("E7 without StockGuard the reader resolves against Soil's own seals, and Soil sealed none of this: UNAVAILABLE",
        tostring(read(col.snapshotRef, receipt).reason), "PRODUCER_SEAL_MISSING")
    T.eq("E8 a colon call is refused rather than read", tostring(readVia(gc().readCollectedCondition, gc(), col.snapshotRef, receipt).reason), A.REFUSE_COLON_CALL)

    world(100)
    grass()
    local okS, _, outS = pcall(pickup, SHOVEL)
    T.eq("E9 a pickup by a vehicle that is not a collection machine names no collection",
        tostring(okS) .. "/" .. tostring(outS and outS.reason) .. "/" .. tostring(outS and outS.collection), "true/OK/nil")
    local _, outD = bracket(BALER, 800, 0, 6.5, 8, 6.5, 0.5, 1)
    T.eq("E10 a drop names no collection", tostring(outD and outD.collection), "nil")
    world(100)
    grass()
    local _, outF = pickup({ isServer = true, uniqueId = "sg-wagon", spec_forageWagon = {} })
    local partsF = outF and outF.collection and outF.collection.parts or {}
    T.eq("E9b a ForageWagon's pickup names its collection as the Baler's does (ForageWagon.lua:147-160)",
        tostring(outF and outF.collection and outF.collection.basis) .. "/" .. #partsF, MW.BASIS.COLLECTED .. "/2")

    world(100)
    grass()
    local held = gc().readCollectedCondition
    W.sys.groundConditionAdmission:standDown("bench")
    T.eq("E11 a reference kept past a stand-down answers SOIL_NOT_ARMED", tostring(readVia(held, "x", {}).reason), A.REFUSE_NOT_ARMED)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PARTS: WHAT THE PICKUP TOOK, IN THE SEAL'S CANONICAL ORDER
-- ══════════════════════════════════════════════════════════════════════════
local function partIds(col)
    local ids = {}
    for _, p in ipairs(col and col.parts or {}) do ids[#ids + 1] = p.id end
    return table.concat(ids, ",")
end
group("P", function()
    -- Cell (8,7) holds grass at z -4..-3: inside the envelope (reach 2 around z 1), outside the
    -- line's inner radius, so it is captured but the pickup leaves it.
    world(100)
    grass()
    HEIGHT.fill(GR, 0, -4, 4, -3, 50)
    local _, out = pickup(BALER)
    local col = out and out.collection or nil
    local snap = col and W.sys.groundConditionAdmission.collected[col.snapshotRef] or nil
    T.eq("P1 a cell the snapshot captured but the pickup did not lower is no part of the collection",
        tostring(snap ~= nil and snap.parts["8:7"] ~= nil) .. "/" .. partIds(col) .. "/" .. condition(8, 7), "true/8:8,9:8/0/0")
    local snapIds = {}
    for id in pairs(snap and snap.parts or {}) do snapIds[#snapIds + 1] = id end
    table.sort(snapIds)
    T.eq("P1b the snapshot names the sources only: of the envelope's cells (x -2..10, z -1..3), those holding the type",
        table.concat(snapIds, ","), "8:7,8:8,9:8")
    -- Grass across cells gx 9 (x 4..8) and gx 10 (x 8..12): by id "10:8" sorts before "9:8".
    world(100)
    HEIGHT.fill(GR, 4, 0, 12, 2, 50)
    local _, out2 = bracket(BALER, -math.huge, 4, 1, 12, 1, 1, nil)
    T.eq("P2 the parts arrive in the seal's canonical order, by id (MaterialWetness:sealAllocation), so the producer's final remainder lands on the last",
        partIds(out2 and out2.collection), "10:8,9:8")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE SNAPSHOTS ARE A BOUNDED, TRANSIENT BINDING
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local keep = A.MAX_COLLECTED
    A.MAX_COLLECTED = 2
    world(100)
    local refs = {}
    for i = 1, 3 do
        grass()
        local _, out = pickup(BALER)
        refs[i] = out and out.collection and out.collection.snapshotRef or nil
    end
    local adm = W.sys.groundConditionAdmission
    T.eq("B1 past the bound the oldest snapshot leaves first; the newer stay",
        tostring(adm.collected[refs[1]] == nil) .. "/" .. tostring(adm.collected[refs[2]] ~= nil) .. "/" .. tostring(adm.collected[refs[3]] ~= nil), "true/true/true")
    A.MAX_COLLECTED = keep

    adm:standDown("bench")
    T.eq("B2 a stand-down drops every snapshot", tostring(next(adm.collected)) .. "/" .. #adm.collectedOrder, "nil/0")
    world(100)
    grass()
    pickup(BALER)
    adm = W.sys.groundConditionAdmission
    local held = #adm.collectedOrder
    adm:arm(W.sys.groundConditionCoordinator, W.sys.groundConditionCells)
    T.eq("B3 a re-arm starts with no snapshot", held .. "/" .. tostring(next(adm.collected)) .. "/" .. #adm.collectedOrder, "1/nil/0")
    world(100)
    grass()
    adm = W.sys.groundConditionAdmission
    local lease = gc().admitPrimitive({ schemaVersion = 1, kind = "LINE", sx = 0, sz = 1, ex = 8, ez = 1, fillTypeIndex = GR, innerRadius = 1 },
        A.KIND_SMOOTH_LINE, BALER, "area1")
    local captured = #adm.collectedOrder
    if lease.leaseToken ~= nil then gc().closePrimitive(lease.leaseToken) end
    T.eq("B4 a collection machine's other line primitive (a smooth) captures no snapshot: only its pickup line is a collection",
        tostring(lease.status) .. "/" .. captured, "ADMITTED/0")
    world(100)
    adm = W.sys.groundConditionAdmission
    local wagon = { isServer = true, uniqueId = "sg-wagon", spec_forageWagon = {} }
    -- Grass already lies under the drop (cells (8,9) and (9,9)), so a capture would have sources.
    HEIGHT.fill(GR, 0, 5, 8, 6, 50)
    local leaseD, outD = bracket(wagon, 800, 0, 6.5, 8, 6.5, 0.5, 1)
    T.eq("B5 a collection machine's drop (a ForageWagon tipping to the ground) captures no snapshot",
        tostring(leaseD.status) .. "/" .. tostring(outD and outD.reason) .. "/" .. #adm.collectedOrder, "ADMITTED/OK/0")
    world(100)
    adm = W.sys.groundConditionAdmission
    local leaseB, outB = pickup(BALER)
    T.eq("B6 a pickup over bare ground captures no snapshot and names no collection",
        tostring(leaseB.status) .. "/" .. tostring(outB and outB.reason) .. "/" .. #adm.collectedOrder .. "/" .. tostring(outB and outB.collection), "ADMITTED/OK/0/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE COLLECTED ACCOUNT IN soil.groundCondition (G3)
-- ══════════════════════════════════════════════════════════════════════════
local function acct(c, k, u, r, w) return { carrierLitres = c, knownCarrierLitres = k, unknownCarrierLitres = u, refusedCarrierLitres = r, knownWeightedPctSum = w } end
local function rec(ageRaw, wetRaw, litres, account, knowledge)
    return { propertyId = "soil.groundCondition", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = knowledge or "KNOWN",
             knownAmount = litres, basisAmount = litres, amountUnit = "LITRE", payload = { ageRaw = ageRaw, wetnessRaw = wetRaw, ageDay = 100, account = account } }
end
local function portion(litres, r) return { amount = litres, unit = "LITRE", properties = { ["soil.groundCondition"] = r } } end
local function accText(a) if a == nil then return "none" end return table.concat({ num(a.carrierLitres), num(a.knownCarrierLitres), num(a.unknownCarrierLitres), num(a.refusedCarrierLitres), num(a.knownWeightedPctSum) }, "/") end
group("C", function()
    world(100)
    local prop = GP.new()
    prop.coordinator = W.sys.groundConditionCoordinator
    local v = GP.validate
    local function verdict(r)
        local okCall, ok, why = pcall(v, r)
        if not okCall then return "raised" end
        return tostring(ok) .. ":" .. tostring(why)
    end
    T.eq("C1 an account is validated: well formed passes; its parts not summing to the carrier, a pct sum past 100 per known litre, or a negative field do not",
        table.concat({ verdict(rec(5, 60, 60, acct(60, 40, 15, 5, 2400))), verdict(rec(5, 60, 60, acct(60, 40, 10, 5, 2400))),
            verdict(rec(5, 60, 60, acct(60, 40, 15, 5, 4100))), verdict(rec(5, 60, 60, acct(60, -1, 56, 5, 0))) }, " "),
        "true:nil false:ACCOUNT_SUM false:ACCOUNT_PCT false:ACCOUNT")
    T.eq("C1b a missing field, a NaN or an infinite field, or an account that is not a table is refused, not raised on",
        table.concat({ verdict(rec(5, 60, 60, acct(60, 40, 15, 5, nil))), verdict(rec(5, 60, 60, acct(0 / 0, 40, 15, 5, 0))),
            verdict(rec(5, 60, 60, acct(math.huge, 40, 15, 5, 0))), verdict(rec(5, 60, 60, 60)) }, " "),
        "false:ACCOUNT false:ACCOUNT false:ACCOUNT false:ACCOUNT")
    T.eq("C1c a rounding-level difference in the sum or the pct bound is tolerated (scaled accounts carry float error)",
        verdict(rec(5, 60, 60, acct(0.3, 0.1, 0.2, 0, 0))) .. " " .. verdict(rec(5, 60, 60, acct(0.3, 0.3, 0, 0, 30.000000000000004))),
        "true:nil true:nil")
    -- SG-1 scales a portion's coverage, never its payload: each record's account is of 60 L.
    local c2 = prop:combine({}, { portion(30, rec(5, 60, 30, acct(60, 60, 0, 0, 3600))), portion(10, rec(3, 40, 10, acct(60, 30, 30, 0, 1500))) }, nil)
    T.eq("C2 NAMED: accounts are scaled to each part's litres and added by carrier litres", accText(c2 and c2.payload.account), "40/35/5/0/2050")
    local c3 = prop:combine({}, { portion(30, rec(5, 60, 30, acct(60, 60, 0, 0, 3600))), portion(10, rec(3, 40, 10, nil)) }, nil)
    T.eq("C3 a part without an account adds its litres as unknown carrier", accText(c3 and c3.payload.account), "40/30/10/0/1800")
    local c4 = prop:combine({}, { portion(30, rec(5, 60, 30, nil)), portion(10, rec(3, 40, 10, nil)) }, nil)
    T.eq("C4 with no account among the parts there is none to carry", accText(c4 and c4.payload.account), "none")
    local withdrawn = rec(5, 60, 10, acct(60, 60, 0, 0, 3600), "UNAVAILABLE")
    local c5 = prop:combine({}, { portion(30, rec(5, 60, 30, acct(60, 60, 0, 0, 3600))), portion(10, withdrawn) }, nil)
    T.eq("C5 a record SG-1 qualified is not read for its account either: its litres are unknown", accText(c5 and c5.payload.account), "40/30/10/0/1800")
    local d = prop:combine({}, { portion(10, rec(3, 40, 10, nil)) }, { observedAmount = 20, amountUnit = "LITRE", properties = { ["soil.groundCondition"] = rec(4, 90, 20, acct(20, 20, 0, 0, 1800)) } })
    T.eq("C6 the destination's own account joins the sum", accText(d and d.payload.account), "30/20/10/0/1800")
    T.eq("C7 every combined record above validates", tostring(v(c2)) .. "/" .. tostring(v(c3)) .. "/" .. tostring(v(d)), "true/true/true")
    local t = prop:transform({}, {}, { { amount = 25, unit = "LITRE" } })
    T.eq("C8 a conversion carries no account", accText(t.payload.account), "none")
    local function combined(r2)
        local ok, out = pcall(prop.combine, prop, {}, { portion(30, rec(5, 60, 30, acct(60, 60, 0, 0, 3600))), portion(10, r2) }, nil)
        if not ok then return "raised" end
        return accText(out and out.payload.account)
    end
    T.eq("C9 a part whose account is of zero litres adds its litres as unknown rather than dividing by zero",
        combined(rec(3, 40, 10, acct(0, 0, 0, 0, 0))), "40/30/10/0/1800")
    T.eq("C10 a part whose account is malformed adds its litres as unknown rather than its figures",
        combined(rec(3, 40, 10, acct(60, 40, 10, 5, 2400))), "40/30/10/0/1800")
    local unknownRec = rec(0, 24, 10, acct(60, 0, 50, 10, 0), "UNKNOWN")
    T.eq("C11 an UNKNOWN record's account is read: an account is its own statement of what is known (componentsOf's two states)",
        tostring(v(unknownRec)) .. "/" .. combined(unknownRec), "true/40/30/8.3333/1.6667/1800")
end)
end
SG25DS_BENCH()

-- RSF-F196-density_refusal_test.lua - the refusal at the start append and at the
-- external-fill charge, driven through the REAL installed hooks on an engine model.
--
-- Slice 1's bar established identity (the catalogue and the one resolver) and the
-- refusal written at registration. This bar drives the two consumers the engine
-- reaches FIRST, in the order it reaches them:
--   R3a  Sprayer.getExternalFill, called from inside native onStartWorkAreaProcessing
--        (Sprayer.lua:889), BEFORE native's final assignment. The mod's wrapper is
--        propagated onto type tables and live instances by Hook 9, and this bar
--        installs and propagates it the way the mod does.
--   R2   the density refusal, the LAST append on onStartWorkAreaProcessing, after
--        native's final assignment (Sprayer.lua:926-931 in our tree) and after every
--        append the mod already installs.
-- The three consumers inside the end hook (R3b AI-1, R3c the residual snap, R3d the
-- secondary enumeration) live in a 700-line function and are benched separately on
-- the F226d fixture.
--
-- THE ENGINE MODEL, and what it is faithful to:
--   nativeOnStart      writes the six work-area fields from the tank the way
--                      Sprayer.lua:926-931 does; it calls getExternalFill first, at
--                      the point native does, so R3a's UNKNOWN,0 lands in the same
--                      fields R2 then reads.
--   nativePaint        Sprayer.processSprayerArea gates on sprayFillLevel > 0
--                      (Sprayer.lua:320). Painting is the observable consequence.
--   nativeDrain        Sprayer.onEndWorkAreaProcessing drains by usage (:942).
-- It is NOT faithful to the density map, the stream, or money beyond the one
-- addMoney call, and does not claim to be.
--
-- Locked here:
--   REFUSED IS NOTHING   a refused driving product paints nothing, drains nothing,
--                        charges nothing, and sprayVehicle and the tank are untouched.
--   VALID IS UNCHANGED   a valid custom product behaves exactly as before.
--   ON EVERY PEER        the refusal runs with isServer false. This is the clause
--                        that was easy to get wrong: clients paint, and a refusal
--                        folded into the server-only rate multiplier leaves them
--                        painting a product the server refused.
--   LAST APPEND          an append installed BEFORE R2 that re-arms usage is undone
--                        by R2, which is what "last" buys.
--   THE NURSE TANK       an attached source's refused product is refused through
--                        the direct candidate, the post-native sprayFillType, even
--                        while the local unit is empty.
--   THE LATE JOIN        a peer whose unit is empty but whose native
--                        lastValidFillType names a refused product refuses without
--                        any private stamp or transmitted verdict.
--   NO STAMP             _soilLastCustomFillType is never written, and a stale one
--                        planted on the vehicle changes nothing.
--   NO FABRICATED PRICE  a custom product with no price returns UNKNOWN,0 and is
--                        NOT delegated to native, whose cascade would pick FERTILIZER.
--   STAND-DOWN           settings.enabled false leaves everything alone.
--   TOLD ONCE            the farmer is notified once per product per manager, and
--                        the technical reason is logged at the existing throttle.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = {
    Sprayer = Sprayer, Utils = Utils, FillType = FillType, ToolType = ToolType,
    MoneyType = MoneyType, UIHelper = UIHelper, g_i18n = g_i18n,
    g_fillTypeManager = g_fillTypeManager, g_currentMission = g_currentMission,
    g_SoilFertilityManager = g_SoilFertilityManager, g_farmManager = g_farmManager,
    g_sprayTypeManager = g_sprayTypeManager, g_vehicleTypeManager = g_vehicleTypeManager,
}

-- The engine's own wrappers (utils/Utils.lua:380-393): the appended form discards
-- the old function's returns, and either form returns newFunc when there is
-- nothing to wrap.
Utils = {
    appendedFunction = function(oldFunc, newFunc)
        return oldFunc ~= nil and function(...) oldFunc(...) newFunc(...) end or newFunc
    end,
    prependedFunction = function(oldFunc, newFunc)
        return oldFunc ~= nil and function(...) newFunc(...) oldFunc(...) end or newFunc
    end,
}
MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1 }
ToolType = ToolType or { UNDEFINED = 0 }
UIHelper = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }
FillType = { UNKNOWN = 0, FERTILIZER = 1, LIQUIDFERTILIZER = 2, LIQUIDMANURE = 3, DIGESTATE = 4, MANURE = 5, HERBICIDE = 6,
             UREA = 31, GYPSUM = 32, POTASH = 33 }
local NAMES = { [31] = "UREA", [32] = "GYPSUM", [33] = "POTASH", [1] = "FERTILIZER", [2] = "LIQUIDFERTILIZER" }
g_fillTypeManager = {
    getFillTypeByIndex = function(_, i) return NAMES[i] and { name = NAMES[i], index = i, title = NAMES[i] } or nil end,
    getFillTypeIndexByName = function(_, n) for i, name in pairs(NAMES) do if name == n then return i end end return nil end,
    getFillTypeByName = function(_, n) for i, name in pairs(NAMES) do if name == n then return { name = n, index = i } end end return nil end,
}
g_sprayTypeManager = { getSprayTypeByFillTypeIndex = function() return { litersPerSecond = 0.01 } end }
g_farmManager = { updateFarmStats = function() end }
g_vehicleTypeManager = { types = {} }
g_i18n = { hasText = function() return false end, getText = function(_, k) return k end }

-- ── world ────────────────────────────────────────────────────────────────────
local money, notices, warnings = {}, {}, {}
local function newWorld(opts)
    opts = opts or {}
    money, notices, warnings = {}, {}, {}
    g_currentMission = {
        time = opts.time or 1000,
        missionInfo = { helperBuyFertilizer = opts.buy ~= false, helperSlurrySource = 1, helperManureSource = 1 },
        addMoney = function(_, amount, farmId, kind) money[#money + 1] = { amount = amount, farmId = farmId, kind = kind } end,
        vehicleSystem = { vehicles = {} },
    }
    local soilSys = { showNotification = function(_, title, body) notices[#notices + 1] = { title = title, body = body } end }
    g_SoilFertilityManager = { settings = { enabled = opts.enabled ~= false, showNotifications = true }, soilSystem = soilSys }
    -- Dot-called in production (SoilLogger.warning(fmt, ...)), so no self slot: the
    -- first draft stubbed it as a colon-call and silently swallowed the format string.
    SoilLogger.warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
    local hm = HookManager.new()
    hm.customProductIndices = { [FillType.UREA] = true, [FillType.GYPSUM] = true, [FillType.POTASH] = true }
    hm.refusedProducts = { [FillType.GYPSUM] = "density" }
    hm.customFillTypePrices = opts.prices or { [FillType.UREA] = 2.0, [FillType.GYPSUM] = 1.5 }
    return hm
end

-- ── the engine model ────────────────────────────────────────────────────────
local nativeCalls
local function nativeGetExternalFill(self, fillType, dt)
    nativeCalls = nativeCalls + 1
    -- vanilla's cascade, the #205 shape: an UNKNOWN request becomes FERTILIZER
    if fillType == FillType.UNKNOWN then return FillType.FERTILIZER, 10 end
    return fillType, 10
end

--- Sprayer.lua:855-931, the parts the refusal touches. sourceType/sourceLevel model an
--- attached nurse tank (sprayVehicle ~= self); otherwise the local unit drives.
local function nativeOnStart(self, dt)
    local spec = self.spec_sprayer
    local wap = spec.workAreaParameters
    local fui = self:getSprayerFillUnitIndex()
    local sprayVehicle, sprayFui, sprayType, level = self, fui, self:getFillUnitFillType(fui), self:getFillUnitFillLevel(fui)
    if self._source then
        sprayVehicle, sprayFui, sprayType, level = self._source, 1, self._source.fillType, self._source.level
    end
    local externalType, externalUsage = sprayType, level
    if level <= 0 and not self._source then
        -- empty: native asks getExternalFill, the point R3a is reached (Sprayer.lua:889)
        externalType, externalUsage = self:getExternalFill(FillType.UNKNOWN, dt)
        sprayVehicle = nil
    end
    local usage = externalUsage > 0 and 0.5 or 0
    wap.sprayFillType = externalType
    wap.sprayFillLevel = externalUsage
    wap.usage = usage
    wap.usagePerMin = usage / dt * 1000 * 60
    wap.sprayVehicle = sprayVehicle
    wap.sprayVehicleFillUnitIndex = sprayFui
end
--- Sprayer.processSprayerArea, :314-320: no paint below the gate.
local function nativePaint(self)
    if self.spec_sprayer.workAreaParameters.sprayFillLevel <= 0 then return 0 end
    self._painted = (self._painted or 0) + 1
    return 1
end
--- Sprayer.onEndWorkAreaProcessing, :938-942: drain by usage.
local function nativeDrain(self)
    local u = self.spec_sprayer.workAreaParameters.usage
    if u and u > 0 and not self._source then self._tank.level = self._tank.level - u end
end

local function newSprayer(opts)
    opts = opts or {}
    local v = { isServer = opts.isServer ~= false, id = 7, lastSpeed = 0.003, _tank = { type = opts.tankType or FillType.UREA, level = opts.level or 100, lastValid = opts.lastValid } }
    v._source = opts.source
    v.getSprayerFillUnitIndex = function() return 1 end
    v.getFillUnitFillType = function(self) return self._tank.type end
    v.getFillUnitFillLevel = function(self) return self._tank.level end
    v.getFillUnitLastValidFillType = function(self) return self._tank.lastValid or self._tank.type end
    v.getFillUnitAllowsFillType = function() return true end
    v.getActiveFarm = function() return 1 end
    v.getLastTouchedFarmlandFarmId = function() return 1 end
    v.getActiveSprayType = function() return nil end
    v.getExternalFill = nativeGetExternalFill   -- the instance copy Hook 9 must replace
    v.spec_sprayer = { usageScale = { workingWidth = 12, default = 1 },
                       workAreaParameters = { sprayFillType = FillType.UNKNOWN, sprayFillLevel = 0, usage = 0, usagePerMin = 0 } }
    -- LIVE from birth. Hook 9's propagation replaces the instance copy of
    -- getExternalFill only on vehicles the mission lists, so a sprayer built after
    -- propagation, or never listed, silently keeps native and every R3a case then
    -- exercises the wrong function while reading as a clean pass. The first draft of
    -- this file did exactly that in one block and not in another.
    g_currentMission.vehicleSystem.vehicles = { v }
    return v
end

--- Install the real hooks the way the mod does. `preArm` installs an append AHEAD of
--- R2 that re-arms usage, to prove "last append" is load-bearing.
local function install(hm, opts)
    opts = opts or {}
    nativeCalls = 0
    Sprayer = { getExternalFill = nativeGetExternalFill, onStartWorkAreaProcessing = nativeOnStart,
                processSprayerArea = nativePaint, onEndWorkAreaProcessing = nativeDrain }
    -- newSprayer has already listed the vehicle, so propagation below reaches it.
    HookManager.installExternalFillHook(hm)
    HookManager.propagateExternalFillHookToLiveVehicles(hm)
    if opts.preArm then
        Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(Sprayer.onStartWorkAreaProcessing,
            function(self) self.spec_sprayer.workAreaParameters.usage = 99 end)
    end
    HookManager.installDensityRefusalHook(hm)
end

local function frame(v, dt)
    Sprayer.onStartWorkAreaProcessing(v, dt or 16)
    local painted = Sprayer.processSprayerArea(v)
    Sprayer.onEndWorkAreaProcessing(v, dt or 16, true)
    return painted
end
local function wap(v) return v.spec_sprayer.workAreaParameters end

-- ── VALID IS UNCHANGED ───────────────────────────────────────────────────────
do
    local hm = newWorld(); local v = newSprayer({ tankType = FillType.UREA, level = 100 }); install(hm)
    g_currentMission.vehicleSystem.vehicles = { v }
    local painted = frame(v)
    T.eq("R2 A1: a valid custom product paints", painted, 1)
    T.eq("R2 A2: its dose is intact", wap(v).usage, 0.5)
    T.eq("R2 A3: it drains", v._tank.level, 99.5)
    T.eq("R2 A4: sprayVehicle is the machine itself", wap(v).sprayVehicle, v)
    T.eq("R2 A5: nothing was refused, so no notice", #notices, 0)
end

-- ── REFUSED IS NOTHING ───────────────────────────────────────────────────────
do
    local hm = newWorld(); local v = newSprayer({ tankType = FillType.GYPSUM, level = 100 }); install(hm)
    local painted = frame(v)
    T.eq("R2 B1: a refused driving product paints nothing", painted, 0)
    T.eq("R2 B2: sprayFillLevel zeroed", wap(v).sprayFillLevel, 0)
    T.eq("R2 B3: usage zeroed", wap(v).usage, 0)
    T.eq("R2 B4: usagePerMin zeroed", wap(v).usagePerMin, 0)
    T.eq("R2 B5: it drains nothing", v._tank.level, 100)
    T.eq("R2 B6: sprayVehicle is untouched (still the machine)", wap(v).sprayVehicle, v)
    T.eq("R2 B7: the product name still stands in sprayFillType, so a reader can see what was refused", wap(v).sprayFillType, FillType.GYPSUM)
    T.eq("R2 B8: no money moved", #money, 0)
end

-- ── ON EVERY PEER ────────────────────────────────────────────────────────────
do
    local hm = newWorld(); local v = newSprayer({ tankType = FillType.GYPSUM, level = 100, isServer = false }); install(hm)
    local painted = frame(v)
    T.eq("R2 C1: a CLIENT refuses too: nothing painted", painted, 0)
    T.eq("R2 C2: client dose zeroed", wap(v).usage, 0)
    local hm2 = newWorld(); local v2 = newSprayer({ tankType = FillType.UREA, level = 100, isServer = false }); install(hm2)
    T.eq("R2 C3: and a client with a valid product still paints", frame(v2), 1)
end

-- ── LAST APPEND ──────────────────────────────────────────────────────────────
do
    local hm = newWorld(); local v = newSprayer({ tankType = FillType.GYPSUM, level = 100 }); install(hm, { preArm = true })
    frame(v)
    T.eq("R2 D1: an earlier append that re-arms usage to 99 is undone by R2 running last", wap(v).usage, 0)
    local hm2 = newWorld(); local v2 = newSprayer({ tankType = FillType.UREA, level = 100 }); install(hm2, { preArm = true })
    frame(v2)
    T.eq("R2 D2: for a valid product the earlier append's value survives, R2 touched nothing", wap(v2).usage, 99)
end

-- ── THE NURSE TANK ───────────────────────────────────────────────────────────
do
    local hm = newWorld()
    local source = { fillType = FillType.GYPSUM, level = 500 }
    local v = newSprayer({ tankType = FillType.UNKNOWN, level = 0, source = source }); install(hm)
    local painted = frame(v)
    T.eq("R2 E1: an attached source's refused product is refused via the direct candidate", painted, 0)
    T.eq("R2 E2: with the local unit empty, so the tank steps could not have found it", v._tank.type, FillType.UNKNOWN)
    T.eq("R2 E3: sprayVehicle still names the source, untouched", wap(v).sprayVehicle, source)
    local hm2 = newWorld(); local src2 = { fillType = FillType.UREA, level = 500 }
    local v2 = newSprayer({ tankType = FillType.UNKNOWN, level = 0, source = src2 }); install(hm2)
    T.eq("R2 E4: a valid product from an attached source paints", frame(v2), 1)
end

-- ── THE LATE JOIN ────────────────────────────────────────────────────────────
do
    -- A client whose unit is empty and whose native lastValidFillType names the refused
    -- product. That field is what FillUnit syncs in its own stream (FillUnit.lua:482,
    -- :541), so this is the joined peer's whole knowledge of the product.
    local hm = newWorld({ buy = false })
    local v = newSprayer({ tankType = FillType.UNKNOWN, level = 0, lastValid = FillType.GYPSUM, isServer = false }); install(hm)
    frame(v)
    T.eq("R2 F1: with buy off, native leaves the dose empty and R2 has nothing to do", wap(v).usage, 0)
    T.eq("R2 F2: the resolver reaches the refused product through lastValidFillType alone",
         hm:resolveCustomProductIntent(v, FillType.UNKNOWN), FillType.GYPSUM)
    T.eq("R2 F3: and it is refused", hm:isRefusedProduct(hm:resolveCustomProductIntent(v, nil)), true)
end

-- ── R3a: THE EXTERNAL-FILL CHARGE ────────────────────────────────────────────
do
    -- Empty tank, buy on, refused product remembered: the first consumer the engine
    -- reaches. R3a must answer UNKNOWN,0 from its own reading and move no money.
    local hm = newWorld({ buy = true })
    local v = newSprayer({ tankType = FillType.UNKNOWN, level = 0, lastValid = FillType.GYPSUM }); install(hm)
    g_currentMission.vehicleSystem.vehicles = { v }
    HookManager.propagateExternalFillHookToLiveVehicles(hm)
    local ft, usage = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("R3a G1: a refused product returns UNKNOWN", ft, FillType.UNKNOWN)
    T.eq("R3a G2: and zero usage", usage, 0)
    T.eq("R3a G3: no money moved", #money, 0)
    T.eq("R3a G4: native was NOT delegated to (its cascade would have picked FERTILIZER)", nativeCalls, 0)
    -- V12c: the instance carries the layer's wrapper around ITS OWN predecessor, one
    -- per predecessor rather than the class closure copied everywhere.
    T.eq("R3a G5: the propagated instance copy IS an owned-layer wrapper", hm:isOwnedLayerWrapper(v.getExternalFill), true)
end
do
    -- Same shape with a valid product: the existing charge is preserved.
    local hm = newWorld({ buy = true })
    local v = newSprayer({ tankType = FillType.UNKNOWN, level = 0, lastValid = FillType.UREA }); install(hm)
    local ft, usage = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("R3a H1: a valid product returns itself", ft, FillType.UREA)
    T.ok("R3a H2: with a positive usage", usage > 0)
    T.eq("R3a H3: and one charge", #money, 1)
    -- Guarded so a failed H3 fails this row by name instead of crashing the file: a
    -- kill that arrives as a load error names nothing.
    local charged = money[1] and money[1].amount or 0
    T.ok("R3a H4: at 1.5x the price, the existing premium", charged < 0 and math.abs(charged + usage * 2.0 * 1.5) < 1e-9)
    T.eq("R3a H5: native not delegated to", nativeCalls, 0)
end
do
    -- NO FABRICATED PRICE: a custom product with no price entry.
    local hm = newWorld({ buy = true, prices = { [FillType.GYPSUM] = 1.5 } })   -- UREA unpriced
    local v = newSprayer({ tankType = FillType.UREA, level = 0, lastValid = FillType.UREA }); install(hm)
    local ft, usage = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("R3a I1: an unpriced custom product returns UNKNOWN", ft, FillType.UNKNOWN)
    T.eq("R3a I2: zero usage", usage, 0)
    T.eq("R3a I3: no money, and no charge at a made-up 1.0", #money, 0)
    T.eq("R3a I4: and NOT native, whose cascade would have sold FERTILIZER for a UREA tank", nativeCalls, 0)
end
do
    -- A vanilla product: native owns it entirely.
    local hm = newWorld({ buy = true })
    local v = newSprayer({ tankType = FillType.LIQUIDFERTILIZER, level = 0, lastValid = FillType.LIQUIDFERTILIZER }); install(hm)
    local ft = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("R3a J1: a vanilla tank is delegated to native", nativeCalls, 1)
    T.eq("R3a J2: and native's answer stands", ft, FillType.FERTILIZER)
end

-- ── NO STAMP ─────────────────────────────────────────────────────────────────
do
    local hm = newWorld({ buy = true })
    local v = newSprayer({ tankType = FillType.UNKNOWN, level = 0, lastValid = FillType.UREA }); install(hm)
    v._soilLastCustomFillType = FillType.GYPSUM   -- a stale stamp from an older build
    local ft = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("R1b K1: a planted stamp naming a refused product changes nothing; the engine's lastValid wins", ft, FillType.UREA)
    frame(v)
    T.eq("R1b K2: the stamp is never written by the hooks", v._soilLastCustomFillType, FillType.GYPSUM)
end

-- ── STAND-DOWN ───────────────────────────────────────────────────────────────
do
    local hm = newWorld({ enabled = false }); local v = newSprayer({ tankType = FillType.GYPSUM, level = 100 }); install(hm)
    local painted = frame(v)
    T.eq("R2 L1: with the mod stood down, a refused product is left entirely alone and paints", painted, 1)
    T.eq("R2 L2: its dose is untouched", wap(v).usage, 0.5)
end

-- ── TOLD ONCE ────────────────────────────────────────────────────────────────
do
    local hm = newWorld(); local v = newSprayer({ tankType = FillType.GYPSUM, level = 100 }); install(hm)
    frame(v); frame(v); frame(v)
    T.eq("V18 M1: the farmer is told once per product across three refused frames", #notices, 1)
    T.eq("V18 M2: with the existing title", notices[1].title, "Soil Update")
    T.ok("V18 M3: the body names the product", notices[1].body:find("GYPSUM", 1, true) ~= nil)
    T.ok("V18 M4: and points at Drain Vehicle", notices[1].body:find("Drain Vehicle", 1, true) ~= nil)
    T.eq("V18 M5: the technical reason is logged once at the throttle, not three times", #warnings, 1)
    T.ok("V18 M6: and the log carries the reason", warnings[1]:find("density", 1, true) ~= nil)
    g_currentMission.time = g_currentMission.time + 5000
    frame(v)
    T.eq("V18 M7: after the throttle window the log repeats, the notice does not", #warnings, 2)
    T.eq("V18 M8: still one notice", #notices, 1)
    local v2 = newSprayer({ tankType = FillType.POTASH, level = 100 })
    hm.refusedProducts[FillType.POTASH] = "density"
    frame(v2)
    T.eq("V18 M9: a second refused product gets its own notice", #notices, 2)
end

for k, val in pairs(saved) do _G[k] = val end

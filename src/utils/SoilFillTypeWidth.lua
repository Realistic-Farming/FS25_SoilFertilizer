-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Fill type index width floor
-- =========================================================
-- Raises the engine's fill-type index width so players on large maps do not need
-- FillType Extender installed alongside this mod. FTE exists because the 255
-- default is a real ceiling that real maps reach.
--
-- TWO CLAIMS THAT LOOK ALIKE AND ARE NOT THE SAME CLAIM. They were conflated for
-- most of an evening and it cost hours, so both are written down here.
--
--   1. "SoilFertilizer's fill type warnings are caused by the 255 cap, and FTE
--      prevents them." FALSE. The warnings fired with FTE loaded AND with FTE
--      disabled, roughly 27 seconds before gameplay even started. They were the
--      deferred-init defect, fixed in #970. Nothing in this file touches them.
--
--   2. "Some large maps genuinely exceed 255 fill types, so players there need
--      FTE today." TRUE, and it is the entire reason this file exists. Known
--      cases: Null Creek, Witcombe, No Creek. Measured case: a tester's River
--      Bend session carried at least 513 registered fill types, confirmed from
--      the live engine registry rather than from a count of mod declarations.
--
-- Only claim 1 was false. Absorbing FTE is justified by claim 2 alone and needs
-- no reference to our own warnings.
--
-- WHY A FUNCTION RATHER THAN THREE INLINE LINES IN main.lua: so the bench can
-- drive the real guard instead of a copy of it. The call site stays at top-level
-- file scope in main.lua, which is what the timing requires; this file only gives
-- that call something addressable to test.
--
-- WHY A FUNCTION RATHER THAN THREE INLINE LINES IN main.lua: so the bench can
-- drive the real guard instead of a copy of it. The call site stays at top-level
-- file scope in main.lua, which is what the timing requires; this file only gives
-- that call something addressable to test.
-- =========================================================

SoilFillTypeWidth = SoilFillTypeWidth or {}

--- The floor this mod guarantees. 10 bits, a cap of 1023 fill types.
---
--- DELIBERATELY ABOVE FillType Extender's 9, and that choice is the point of the
--- change rather than an incidental detail. Two independent reasons agree on 10:
---
--- 1. MEASURED, and cited so it can be re-run rather than trusted. A 9-bit floor
---    caps at 511, and a tester's River Bend session carries at least 513 live
---    fill types. Source: the log delivered through Discord at
---    C:\Users\tison\.claude\channels\discord\inbox\1790024913586-1551700977298706484.txt
---    line 3083 "snapshotted 491 base prices" (a COUNT) and line 6229
---    "seeded buffer for fillType 513" (the highest INDEX). Beware that 491 also
---    appears as an index at :6207; the count is :3083 and nothing else. This log
---    is from one machine and is not reproducible from any log on ours, where the
---    equivalent figures are 474 and 495.
---
--- 2. UNMEASURED, and it survives if that log is ever lost. StockGuard's own
---    source-cited record puts Realistic Livestock at 10. Sitting exactly there
---    means a session with both mods has one agreed floor rather than two
---    competing ones, and the ADAPTERS registry gains no new shape.
---
--- Matching FTE's 9 would have shipped the shape of the capability without
--- reaching the cases that motivated it.
---
--- A player dropping FTE still sees no regression, because 10 is strictly above 9
--- and this only ever raises. At 10 we match Realistic Livestock exactly, which is
--- also the value StockGuard already records for it.
SoilFillTypeWidth.FLOOR_BITS = 10

--- Raise FillTypeManager.SEND_NUM_BITS to the floor, never lower it.
---
--- ONLY EVER RAISES, and that is mandatory rather than stylistic. Realistic
--- Livestock raises this same constant to 10 at its own file load, so an
--- unconditional assignment would truncate a width another mod had already
--- established whenever that mod sourced first. The symptom would be a
--- multiplayer desync on someone else's server, not anything visible locally.
---
--- Reads the current width from the manager AT CALL TIME rather than capturing it,
--- because the value is a shared global that other mods write during sourcing; a
--- captured copy would decide against a width that no longer exists.
---
---@param manager table|nil defaults to the engine's FillTypeManager; injectable for tests
---@return boolean raised true only when this call changed the width
---@return number|nil width the width in force after this call, nil if unreadable
function SoilFillTypeWidth.applyFloor(manager)
    if manager == nil then manager = FillTypeManager end
    if type(manager) ~= "table" then return false, nil end

    local current = manager.SEND_NUM_BITS
    if type(current) ~= "number" then return false, nil end

    if current >= SoilFillTypeWidth.FLOOR_BITS then
        return false, current
    end

    manager.SEND_NUM_BITS = SoilFillTypeWidth.FLOOR_BITS
    return true, SoilFillTypeWidth.FLOOR_BITS
end

--- Largest fill type index the engine will accept at a given width.
--- Mirrors FillTypeManager.lua:204, `2 ^ SEND_NUM_BITS - 1`, recomputed there on
--- every addFillType call rather than cached, which is why raising the width
--- before any registration is enough and raising it afterwards would not be.
---@param bits number
---@return number
function SoilFillTypeWidth.maxFillTypes(bits)
    return 2 ^ bits - 1
end

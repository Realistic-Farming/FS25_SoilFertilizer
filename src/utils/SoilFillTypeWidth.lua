-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Fill type index width floor
-- =========================================================
-- Raises the engine's fill-type index width so players do not need FillType
-- Extender installed alongside this mod. FTE does exactly this and nothing else
-- of consequence, so absorbing it means adopting its floor, not copying its file.
--
-- THIS IS NOT A FIX FOR OUR FILL TYPE ERRORS. The belief that those errors were a
-- 255-cap problem FTE was saving us from was tested and is FALSE: FTE was loaded
-- and active at width 9 while this mod emitted them, and the engine's own cap
-- error (FillTypeManager.lua:206) appears zero times across six sessions. The real
-- cause was the deferred-init defect fixed in #970. Written here because the
-- presence of this file is exactly what would invite someone to re-derive the
-- wrong version in a month.
--
-- WHY A FUNCTION RATHER THAN THREE INLINE LINES IN main.lua: so the bench can
-- drive the real guard instead of a copy of it. The call site stays at top-level
-- file scope in main.lua, which is what the timing requires; this file only gives
-- that call something addressable to test.
-- =========================================================

SoilFillTypeWidth = SoilFillTypeWidth or {}

--- The floor this mod guarantees. 9 bits is FillType Extender's value, and
--- matching it exactly is the point: a player who drops FTE must see no change.
SoilFillTypeWidth.FLOOR_BITS = 9

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

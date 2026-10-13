-- =========================================================
-- FS25 Soil & Fertilizer - GROUND TIP GATE (RSF-F227)
-- =========================================================
-- The Lua-side wrapper over DensityMapHeightUtil.getCanTipToGround that the
-- legacy height-type injection in main.lua installs when the engine did not
-- register the mod's solid fill types itself.
--
-- WHY A WRAPPER EXISTS: the injected height types are added to the manager's
-- Lua tables after the engine built its own picture, so a belt-and-braces Lua
-- answer keeps discharge eligibility honest for them. It must not answer for
-- anything else.
--
-- WHAT IT ASKS: exactly what the engine body asks (DensityMapHeightUtil.lua:26-37).
-- Manager not valid -> false. Height type known -> that type's own canBeTipped,
-- coerced to a boolean. No height type -> whatever was installed before us.
-- It never answers a bare true, and it never adds a nil-manager gate the engine
-- does not have.
--
-- LIFETIME: installed ONCE per process, so a later mission never chains a second
-- wrapper on top of the first. A runtime flag decides whether the wrapper is
-- doing anything: loadedMission enables it only when the Lua injection ran,
-- unload disables it. Disabled means "delegate to the captured predecessor",
-- so a mission without injection, or a later mod's hook stacked on top of ours,
-- sees the predecessor's answers untouched. The wrapper is never removed:
-- reloadDlcsAndMods re-sources this file on a normal game path, so an identity
-- test against the live function could never match and removal is not safe.
-- SG6's joined mode drives the same flag from its side via disable().
-- =========================================================

GroundTipGate = GroundTipGate or {}

local _installed    = false   -- the wrapper is the live DensityMapHeightUtil.getCanTipToGround
local _legacyActive = false   -- the wrapper applies its gates; false means pure delegation
local _origGetCan   = nil     -- whatever callable was live when we installed

local function wrapper(fillTypeIndex)
    if not _legacyActive then
        return _origGetCan(fillTypeIndex)
    end
    local mgr = g_densityMapHeightManager
    if not mgr:getIsValid() then
        return false
    end
    local ht = mgr.fillTypeIndexToHeightType and mgr.fillTypeIndexToHeightType[fillTypeIndex]
    if ht ~= nil then
        return ht.canBeTipped and true or false
    end
    return _origGetCan(fillTypeIndex)
end

--- Install the wrapper once per process. Safe to call every mission.
---@return boolean installedNow  true only on the call that actually installed it
function GroundTipGate.install()
    if _installed then return false end
    if DensityMapHeightUtil == nil or type(DensityMapHeightUtil.getCanTipToGround) ~= "function" then
        return false
    end
    _origGetCan = DensityMapHeightUtil.getCanTipToGround
    DensityMapHeightUtil.getCanTipToGround = wrapper
    _installed = true
    return true
end

--- Turn the gates on for this mission. No-op unless the wrapper is installed.
---@return boolean active
function GroundTipGate.enable()
    if _installed then _legacyActive = true end
    return _legacyActive
end

--- Turn the gates off (unload, or SG6 joined mode). The wrapper stays installed
--- and delegates to its predecessor.
function GroundTipGate.disable()
    _legacyActive = false
end

function GroundTipGate.isInstalled() return _installed end
function GroundTipGate.isActive()    return _legacyActive end

--- The wrapper function object, so a test can prove the live callable is ours
--- and that a second mission does not chain another.
function GroundTipGate.getWrapper() return wrapper end

--- Test-only: forget the process state so one bench can play several processes.
function GroundTipGate._resetForTests()
    _installed, _legacyActive, _origGetCan = false, false, nil
end

-- =========================================================
-- FS25 Realistic Soil & Fertilizer - SettingsHub bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_SettingsHub. Safe if SettingsHub is not
-- installed (register() just no-ops). Purpose: let the FarmTablet
-- System Settings app list Soil & Fertilizer's settings.
--
-- This mod already has a single source of truth for its settings --
-- SettingsSchema.definitions (config/SettingsSchema.lua) -- so instead
-- of hand-listing every field like the other bridges, this one walks
-- the schema directly. def.localOnly maps 1:1 onto SettingsHub's
-- adminOnly=false (both mean "per-player, not server-authoritative"),
-- so the scope split here is exactly the one SoilSettingsUI already
-- enforces, nothing new invented.
--
-- Real editing still goes through SoilSettingsUI / SoilNetworkEvents
-- exactly as before -- this bridge only mirrors current values into
-- SettingsHub and applies edits made *through* SettingsHub the same
-- minimal way requestSettingChange() does for the localOnly branch:
-- set, validate, save. It does not attempt to replicate the admin
-- network-sync path (SoilNetworkEvents_RequestSettingChange) since
-- FarmTablet's System Settings app is read-only for now.
-- =========================================================

SoilSettingsHubBridge = {}

-- FarmTablet's System Settings app renders the label string as-is (no l10n
-- lookup on its end), so resolve each setting's human-readable name here from
-- its "<uiId>_short" key, falling back to the raw id if it is not translated.
local function resolveLabel(schemaDef)
    local base = schemaDef.uiId or schemaDef.id
    if g_i18n ~= nil and g_i18n.hasText ~= nil then
        local key = base .. "_short"
        if g_i18n:hasText(key) then
            return g_i18n:getText(key)
        end
    end
    return base
end

local function applyChange(key, value)
    local mgr = g_SoilFertilityManager
    if mgr == nil or mgr.settings == nil then return end

    local validated = SettingsSchema.validate(key, value)
    if validated == nil then return end

    mgr.settings[key] = validated
    mgr.settings:save()

    if mgr.settingsUI and mgr.settingsUI.refreshUI then
        mgr.settingsUI:refreshUI()
    end
end

function SoilSettingsHubBridge.register(mgr)
    -- The reliable cross-mod handle is g_currentMission.settingsHub (the same one
    -- FarmTablet reads). The bare g_settingsHub global is only visible inside
    -- SettingsHub's own mod environment, so it reads back nil from here; prefer the
    -- mission reference and only fall back to the global.
    local hub = (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
    if hub == nil then
        SoilLogger.info("SettingsHub not detected; skipping tablet registration")
        return
    end
    if mgr == nil or mgr.settings == nil then return end

    local defs = {}
    for _, schemaDef in ipairs(SettingsSchema.definitions) do
        local shType
        if schemaDef.type == "boolean" then
            shType = "bool"
        elseif schemaDef.type == "number" then
            shType = "int"
        end

        if shType ~= nil then
            defs[#defs + 1] = {
                id        = schemaDef.id,
                type      = shType,
                default   = mgr.settings[schemaDef.id],
                adminOnly = not schemaDef.localOnly,
                min       = schemaDef.min,
                max       = schemaDef.max,
                label     = resolveLabel(schemaDef),
            }
        end
    end

    local ok, err = pcall(function()
        hub:registerModule("SoilFertilizer", {
            adminSettings = defs,
            onChange      = function(key, value, playerId) applyChange(key, value) end,
        })
    end)

    if ok then
        SoilLogger.info("Registered with SettingsHub (%d setting(s))", #defs)
    else
        SoilLogger.warning("SettingsHub registration failed: %s", tostring(err))
    end
end

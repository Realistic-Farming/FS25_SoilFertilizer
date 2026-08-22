-- =========================================================
-- FS25 Soil & Fertilizer - Release Gate Dialog
-- =========================================================
-- Shows the release-gate status (which systems are STABLE vs experimental-LOCKED)
-- as a drawn dialog. Same status text as the SoilRelease console command, built
-- as dynamic TextElements in a BoxLayout (version-dialog pattern).
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilReleaseDialog
SoilReleaseDialog = SoilReleaseDialog or {}
local SoilReleaseDialog_mt = Class(SoilReleaseDialog, ScreenElement)

local SF_RLS_MOD_NAME = (SoilFertilizerModName or g_currentModName)
local SF_RLS_MOD_DIR  = (SoilFertilizerModDirectory or g_currentModDirectory)

SoilReleaseDialog.INSTANCE = nil

-- ── i18n helper (version-dialog pattern) ──────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_RLS_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Constructor ───────────────────────────────────────────

function SoilReleaseDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilReleaseDialog_mt)
    self._contentLineEls = {}
    return self
end

function SoilReleaseDialog.register(modDirectory)
    if SoilReleaseDialog.INSTANCE ~= nil then return end

    SF_RLS_MOD_DIR = modDirectory
    local xmlPath = modDirectory .. "xml/gui/SoilReleaseDialog.xml"

    SoilReleaseDialog.INSTANCE = SoilReleaseDialog.new()
    SoilLogger.info("SoilReleaseDialog: registering from %s", xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(xmlPath, "SoilReleaseDialog", SoilReleaseDialog.INSTANCE)
    end)

    if not ok then
        SoilLogger.error("SoilReleaseDialog: loadGui failed: %s", tostring(err))
        SoilReleaseDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilReleaseDialog: registered successfully")
    end
end

function SoilReleaseDialog.show()
    if SoilReleaseDialog.INSTANCE == nil then
        SoilReleaseDialog.register(SF_RLS_MOD_DIR)
    end
    if SoilReleaseDialog.INSTANCE == nil then return end
    g_gui:showDialog("SoilReleaseDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilReleaseDialog:onGuiSetupFinished()
    SoilReleaseDialog:superClass().onGuiSetupFinished(self)

    self._elTitle     = self:getDescendantById("sfRls_title")
    self._elContentBox = self:getDescendantById("sfRls_contentBox")
end

function SoilReleaseDialog:onOpen()
    SoilReleaseDialog:superClass().onOpen(self)

    if self._elTitle then
        self._elTitle:setText(tr("sf_release_dialog_title", "Release Gate"))
    end

    self:_buildContent()
end

function SoilReleaseDialog:onClose()
    SoilReleaseDialog:superClass().onClose(self)
    self:_clearContent()
end

-- ── Content builder ───────────────────────────────────────

-- Split a multiline string into lines without losing empty ones.
local function splitLines(text)
    local out = {}
    if not text then return out end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    return out
end

-- Build one TextElement per line of the release-gate status, into the BoxLayout.
function SoilReleaseDialog:_buildContent()
    if not self._elContentBox then return end

    local profileSection = g_gui:getProfile("sfRls_section")
    local profileHeader  = g_gui:getProfile("sfRls_header")
    local profileBody    = g_gui:getProfile("sfRls_body")
    if not profileBody then
        SoilLogger.warning("SoilReleaseDialog: profile 'sfRls_body' not found")
        return
    end

    -- Same status text the SoilRelease console command prints.
    local s = g_SoilFertilityManager and g_SoilFertilityManager.settings
    local optIn = s and s.allowsExperimentalSystems and s:allowsExperimentalSystems()
    local status = ReleaseGate and ReleaseGate.status(optIn) or "Release gate not loaded"

    for _, line in ipairs(splitLines(status)) do
        local profile = profileBody
        if line:match("^===") then
            profile = profileSection or profileBody
        elseif line:match("^%s+%[") then
            profile = profileBody
        elseif line:match("^%s+Not yet") or line:match("^%s+Experimental") or line:match("^%s+All experimental") then
            profile = profileHeader or profileBody
        end

        local el = TextElement.new()
        el:loadProfile(profile, true)
        el:setText(line)
        self._elContentBox:addElement(el)
        el:onGuiSetupFinished()
        table.insert(self._contentLineEls, el)
    end

    self._elContentBox:invalidateLayout()
end

function SoilReleaseDialog:_clearContent()
    for _, el in ipairs(self._contentLineEls) do
        if self._elContentBox then
            self._elContentBox:removeElement(el)
        end
    end
    self._contentLineEls = {}
end

-- ── Button ────────────────────────────────────────────────

function SoilReleaseDialog:onClickOk()
    g_gui:closeDialogByName("SoilReleaseDialog")
end

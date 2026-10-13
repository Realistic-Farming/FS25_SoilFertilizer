-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Constants Tuning Editor
-- =========================================================
-- Admin-only panel for fine-tuning simulation constants.
-- Open from the Admin page of the Settings Panel.
-- Supports presets, per-parameter steppers, reset to defaults,
-- full server sync, and save-on-change.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilTuningPanel
SoilTuningPanel = SoilTuningPanel or {}
local SoilTuningPanel_mt = Class(SoilTuningPanel)

local SF_TUN_MOD_NAME = (SoilFertilizerModName or g_currentModName)

-- ── Panel geometry (matches SoilSettingsPanel for visual consistency) ─────
local PW     = 0.60
local PH     = 0.74
local PX     = (1 - PW) / 2
local PY     = (1 - PH) / 2
local TB_H   = 0.052
local IB_H   = 0.046
local PAD    = 0.018
local CX     = PX + PAD
local CW     = PW - PAD * 2
local CY_BOT = PY + IB_H + 0.010
local CY_TOP = PY + PH - TB_H - 0.008
local CH     = CY_TOP - CY_BOT

-- ── Amber accent (distinguishes from green settings / red admin) ───────────
local ACCENT = { 0.95, 0.65, 0.10 }

-- ── Text sizes ────────────────────────────────────────────────────────────
local TS_TITLE = 0.018
local TS_BODY  = 0.015
local TS_SMALL = 0.013
local TS_TINY  = 0.011

-- ── Colors ────────────────────────────────────────────────────────────────
local C = {
    bg        = { 0.05, 0.06, 0.09, 0.97 },
    title_bg  = { 0.07, 0.09, 0.13, 1.00 },
    info_bg   = { 0.04, 0.05, 0.08, 1.00 },
    shadow    = { 0.00, 0.00, 0.00, 0.45 },
    divider   = { 0.20, 0.22, 0.28, 0.55 },
    row_alt   = { 1.00, 1.00, 1.00, 0.025 },
    amber     = { 0.95, 0.65, 0.10, 1.00 },
    amber_dim = { 0.55, 0.38, 0.06, 1.00 },
    amber_mod = { 0.98, 0.88, 0.22, 1.00 },
    white     = { 1.00, 1.00, 1.00, 1.00 },
    dim       = { 0.55, 0.55, 0.60, 1.00 },
    green_mod = { 0.30, 0.90, 0.40, 1.00 },
    red       = { 0.88, 0.25, 0.25, 1.00 },
    red_bg    = { 0.22, 0.06, 0.06, 0.85 },
    red_hov   = { 0.40, 0.10, 0.10, 0.92 },
    off_bg    = { 0.10, 0.11, 0.15, 0.85 },
    btn_bg    = { 0.08, 0.12, 0.18, 0.90 },
    btn_hov   = { 0.14, 0.20, 0.32, 0.95 },
    step_hov  = { 0.28, 0.18, 0.06, 0.90 },
    sec_bg    = { 0.06, 0.08, 0.12, 0.90 },
    lock_text = { 0.65, 0.50, 0.20, 1.00 },
}

-- ── Row geometry ──────────────────────────────────────────────────────────
local ROW_H     = 0.038
local SEC_H     = 0.026
local STEP_W    = 0.028   -- < and > button width
local VAL_W     = 0.078   -- value display width
local DOT_AREA  = 0.065   -- 5-dot indicator width
local DOT_SZ    = 0.005

-- ── Preset bar ────────────────────────────────────────────────────────────
local PRESET_H  = 0.048
local RESET_H   = 0.028

-- ── Content definition ────────────────────────────────────────────────────
-- lut: key into SoilConstants.TUNING; fmt: string.format pattern for the LUT value
local TUNING_SECTIONS = {
    {
        header = "FIELD STARTING VALUES",
        items  = {
            { id = "tuningDefaultN",  label = "Nitrogen (N)",       lut = "DEFAULT_N",  fmt = "%.0f pts" },
            { id = "tuningDefaultP",  label = "Phosphorus (P)",     lut = "DEFAULT_P",  fmt = "%.0f pts" },
            { id = "tuningDefaultK",  label = "Potassium (K)",      lut = "DEFAULT_K",  fmt = "%.0f pts" },
            { id = "tuningDefaultPH", label = "Soil pH",            lut = "DEFAULT_PH", fmt = "%.1f" },
            { id = "tuningDefaultOM", label = "Organic Matter (%)", lut = "DEFAULT_OM", fmt = "%.1f %%" },
        },
    },
    {
        header = "NUTRIENT & SOIL RATES",
        items  = {
            { id = "tuningNutrientDepletion",    label = "Nutrient Depletion Rate", lut = "RATE_MULT", fmt = "x%.2f" },
            { id = "tuningFertilizerEfficiency", label = "Fertilizer Efficiency",   lut = "RATE_MULT", fmt = "x%.2f" },
        },
    },
    {
        header = "WEATHER & CLIMATE",
        items  = {
            { id = "tuningRainLeaching",     label = "Rain Leaching",    lut = "ZERO_MULT", fmt = "x%.2f" },
            { id = "tuningSeasonalStrength", label = "Seasonal Effects", lut = "ZERO_MULT", fmt = "x%.2f" },
            { id = "tuningFallowRecovery",   label = "Fallow Recovery",  lut = "ZERO_MULT", fmt = "x%.2f" },
        },
    },
    {
        header = "CROP STRESS SYSTEMS",
        items  = {
            { id = "tuningPestGrowth",      label = "Pest Growth Rate",    lut = "ZERO_MULT", fmt = "x%.2f" },
            { id = "tuningDiseaseGrowth",   label = "Disease Growth Rate", lut = "ZERO_MULT", fmt = "x%.2f" },
            { id = "tuningCompactionRate",  label = "Compaction Buildup",  lut = "ZERO_MULT", fmt = "x%.2f" },
            { id = "tuningCompactionDecay", label = "Compaction Decay",    lut = "ZERO_MULT", fmt = "x%.2f" },
        },
    },
}

-- ── Presets ───────────────────────────────────────────────────────────────
local PRESETS = {
    {
        label = "EASY",
        desc  = "High starts, slow stress",
        col   = { 0.25, 0.78, 0.35, 1.0 },
        values = {
            tuningDefaultN = 4, tuningDefaultP = 4, tuningDefaultK = 4,
            tuningDefaultPH = 3, tuningDefaultOM = 4,
            tuningNutrientDepletion = 2, tuningFertilizerEfficiency = 4,
            tuningRainLeaching = 1, tuningSeasonalStrength = 2,
            tuningPestGrowth = 1, tuningDiseaseGrowth = 1,
            tuningFallowRecovery = 4, tuningCompactionDecay = 4, tuningCompactionRate = 2,
        },
    },
    {
        label = "BALANCED",
        desc  = "Default simulation",
        col   = { 0.95, 0.65, 0.10, 1.0 },
        values = {
            tuningDefaultN = 3, tuningDefaultP = 3, tuningDefaultK = 3,
            tuningDefaultPH = 3, tuningDefaultOM = 3,
            tuningNutrientDepletion = 3, tuningFertilizerEfficiency = 3,
            tuningRainLeaching = 3, tuningSeasonalStrength = 3,
            tuningPestGrowth = 3, tuningDiseaseGrowth = 3,
            tuningFallowRecovery = 3, tuningCompactionDecay = 3, tuningCompactionRate = 3,
        },
    },
    {
        label = "HARDCORE",
        desc  = "Low starts, rapid stress",
        col   = { 0.90, 0.30, 0.30, 1.0 },
        values = {
            tuningDefaultN = 2, tuningDefaultP = 2, tuningDefaultK = 2,
            tuningDefaultPH = 3, tuningDefaultOM = 2,
            tuningNutrientDepletion = 4, tuningFertilizerEfficiency = 2,
            tuningRainLeaching = 4, tuningSeasonalStrength = 4,
            tuningPestGrowth = 4, tuningDiseaseGrowth = 4,
            tuningFallowRecovery = 2, tuningCompactionDecay = 2, tuningCompactionRate = 4,
        },
    },
    {
        label = "NO STRESS",
        desc  = "Disable all stress systems",
        col   = { 0.55, 0.72, 0.95, 1.0 },
        values = {
            tuningDefaultN = 3, tuningDefaultP = 3, tuningDefaultK = 3,
            tuningDefaultPH = 3, tuningDefaultOM = 3,
            tuningNutrientDepletion = 3, tuningFertilizerEfficiency = 3,
            tuningRainLeaching = 1, tuningSeasonalStrength = 1,
            tuningPestGrowth = 1, tuningDiseaseGrowth = 1,
            tuningFallowRecovery = 3, tuningCompactionDecay = 3, tuningCompactionRate = 1,
        },
    },
}

-- ── Constructor ───────────────────────────────────────────────────────────
function SoilTuningPanel.new(settings)
    local self = setmetatable({}, SoilTuningPanel_mt)
    self.settings     = settings
    self.fillOverlay  = nil
    self.isVisible    = false
    self.initialized  = false
    self.scrollPx     = 0
    self.mouseX       = 0
    self.mouseY       = 0
    self._clickRects  = {}
    self.savedCamRotX = nil
    self.savedCamRotY = nil
    self.savedCamRotZ = nil
    return self
end

function SoilTuningPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    self.initialized = true
    SoilLogger.info("[SoilTuningPanel] Initialized")
end

function SoilTuningPanel:delete()
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Visibility ────────────────────────────────────────────────────────────
function SoilTuningPanel:open()
    -- Bypass tool: Simple difficulty only. Hard choke point so any trigger honors the
    -- gate (matches SoilCropTuningPanel:open).
    if self.settings and not self.settings:allowsBypassTools() then
        SoilLogger.info("[SoilTuningPanel] Open blocked: bypass tools are Simple-difficulty only")
        return
    end
    if not self.initialized then self:initialize() end
    self.isVisible = true
    self.scrollPx  = 0
    -- Freeze camera (same pattern as SoilSettingsPanel)
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if getCamera and getRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            local ok2, rx, ry, rz = pcall(getRotation, cam)
            if ok2 then
                self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = rx, ry, rz
            end
        end
    end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    SoilLogger.debug("[SoilTuningPanel] Opened")
end

function SoilTuningPanel:close()
    self.isVisible = false
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
    SoilLogger.debug("[SoilTuningPanel] Closed")
end

function SoilTuningPanel:isOpen()
    return self.isVisible
end

function SoilTuningPanel:update()
    if not self.isVisible then return end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    if self.savedCamRotX ~= nil and getCamera and setRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            pcall(setRotation, cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
        end
    end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        self:close()
    end
end

-- ── Admin helpers ─────────────────────────────────────────────────────────
function SoilTuningPanel:isAdmin()
    return SoilUtils.isPlayerAdmin()
end

function SoilTuningPanel:requestChange(id, value)
    if not self:isAdmin() then return end
    if SoilNetworkEvents_RequestSettingChange then
        SoilNetworkEvents_RequestSettingChange(id, value)
    else
        self.settings[id] = value
        self.settings:save()
    end
end

function SoilTuningPanel:getLutValue(lutKey, idx)
    local lut = SoilConstants.TUNING and SoilConstants.TUNING[lutKey]
    if lut then return lut[idx] or lut[3] end
    return 1.0
end

-- ── Drawing helpers ───────────────────────────────────────────────────────
function SoilTuningPanel:drawRect(x, y, w, h, col, alpha)
    if not self.fillOverlay then return end
    local a = alpha or col[4] or 1.0
    setOverlayColor(self.fillOverlay, col[1], col[2], col[3], a)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

function SoilTuningPanel:drawText(x, y, size, text, col, align, bold)
    setTextColor(col[1], col[2], col[3], col[4] or 1.0)
    setTextBold(bold == true)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, text)
end

function SoilTuningPanel:registerClick(id, x, y, w, h, data)
    table.insert(self._clickRects, { id = id, x = x, y = y, w = w, h = h, data = data })
end

function SoilTuningPanel:hitTest(rx, ry, rw, rh, mx, my)
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

function SoilTuningPanel:_contentHeight()
    local h = 0
    for _, sec in ipairs(TUNING_SECTIONS) do
        h = h + SEC_H
        h = h + #sec.items * ROW_H
    end
    return h
end

-- ── Main draw ─────────────────────────────────────────────────────────────
function SoilTuningPanel:draw()
    if not self.isVisible then return end
    if not self.fillOverlay then self:initialize() end
    if not self.fillOverlay then return end

    self._clickRects = {}

    -- Drop shadow
    self:drawRect(PX + 0.005, PY - 0.005, PW, PH, C.shadow)

    -- Background
    self:drawRect(PX, PY, PW, PH, C.bg)

    -- Amber border (all 4 sides)
    self:drawRect(PX,             PY + PH - 0.002, PW,    0.002, C.amber)
    self:drawRect(PX,             PY,              PW,    0.002, C.amber)
    self:drawRect(PX,             PY,              0.002, PH,    C.amber)
    self:drawRect(PX + PW - 0.002, PY,             0.002, PH,    C.amber)

    -- ── Title bar ────────────────────────────────────────────────────────
    self:drawRect(PX, PY + PH - TB_H, PW, TB_H, C.title_bg)
    self:drawRect(PX, PY + PH - TB_H, 0.004, TB_H, C.amber)
    self:drawText(PX + 0.018, PY + PH - TB_H + TB_H * 0.33, TS_TITLE,
        "CONSTANTS TUNING EDITOR", C.amber, RenderText.ALIGN_LEFT, true)
    self:drawText(PX + PW - 0.018, PY + PH - TB_H + TB_H * 0.33, TS_SMALL,
        "ADMIN ONLY", C.amber_dim, RenderText.ALIGN_RIGHT, false)

    -- Close [X]
    local closeW = 0.034
    local closeH = TB_H - 0.012
    local closeX = PX + PW - closeW - 0.008
    local closeY = PY + PH - TB_H + 0.006
    local closeHov = self:hitTest(closeX, closeY, closeW, closeH, self.mouseX, self.mouseY)
    self:drawRect(closeX, closeY, closeW, closeH,
        closeHov and { 0.45, 0.10, 0.10, 0.85 } or { 0.18, 0.08, 0.08, 0.65 })
    self:drawText(closeX + closeW * 0.5, closeY + closeH * 0.22, TS_BODY,
        "X", C.white, RenderText.ALIGN_CENTER, true)
    self:registerClick("tp_close", closeX, closeY, closeW, closeH)

    -- ── Bottom bar ───────────────────────────────────────────────────────
    self:drawRect(PX, PY, PW, IB_H, C.info_bg)
    self:drawRect(PX, PY + IB_H, PW, 0.001, C.divider)
    self:drawText(CX, PY + IB_H * 0.38, TS_TINY,
        "Changes sync to all players  |  Starting Values only apply to newly-created fields",
        C.dim, RenderText.ALIGN_LEFT, false)

    -- Back button
    local backW = 0.125
    local backH = IB_H - 0.012
    local backX = PX + PW - backW - 0.010
    local backY = PY + 0.006
    local backHov = self:hitTest(backX, backY, backW, backH, self.mouseX, self.mouseY)
    self:drawRect(backX, backY, backW, backH, backHov and C.btn_hov or C.btn_bg)
    self:drawRect(backX, backY, 0.003, backH, C.amber_dim)
    self:drawText(backX + backW * 0.5, backY + backH * 0.22, TS_SMALL,
        "< BACK TO SETTINGS", backHov and C.white or C.amber, RenderText.ALIGN_CENTER, true)
    self:registerClick("tp_back", backX, backY, backW, backH)

    local isAdmin = self:isAdmin()

    if not isAdmin then
        self:drawText(CX + CW * 0.5, CY_BOT + CH * 0.52, TS_BODY,
            "Administrator access required.", C.lock_text, RenderText.ALIGN_CENTER, false)
        self:drawText(CX + CW * 0.5, CY_BOT + CH * 0.47, TS_SMALL,
            "Only server admins can edit simulation constants.", C.dim, RenderText.ALIGN_CENTER, false)
        return
    end

    -- ── Preset row ───────────────────────────────────────────────────────
    local presetY = CY_TOP - PRESET_H
    local presetW = (CW - 0.003 * 3) / 4
    for i, preset in ipairs(PRESETS) do
        local px    = CX + (i - 1) * (presetW + 0.003)
        local phov  = self:hitTest(px, presetY, presetW, PRESET_H - 0.004, self.mouseX, self.mouseY)
        local pcol  = phov and C.btn_hov or C.btn_bg
        self:drawRect(px, presetY, presetW, PRESET_H - 0.004, pcol)
        -- Colored accent bar at top of each preset button
        self:drawRect(px, presetY + PRESET_H - 0.008, presetW, 0.004, preset.col)
        self:drawText(px + presetW * 0.5, presetY + (PRESET_H - 0.004) * 0.52, TS_SMALL,
            preset.label, preset.col, RenderText.ALIGN_CENTER, true)
        self:drawText(px + presetW * 0.5, presetY + (PRESET_H - 0.004) * 0.16, TS_TINY,
            preset.desc, C.dim, RenderText.ALIGN_CENTER, false)
        self:registerClick("tp_preset_" .. i, px, presetY, presetW, PRESET_H - 0.004, { idx = i })
    end
    self:drawRect(CX, presetY - 0.005, CW, 0.001, C.divider)

    -- ── Reset All button ─────────────────────────────────────────────────
    local resetY = presetY - 0.005 - RESET_H
    local resetW = 0.145
    local resetX = CX + CW - resetW
    local resetHov = self:hitTest(resetX, resetY, resetW, RESET_H, self.mouseX, self.mouseY)
    self:drawRect(resetX, resetY, resetW, RESET_H, resetHov and C.red_hov or C.red_bg)
    self:drawRect(resetX, resetY, 0.003, RESET_H, C.red)
    self:drawText(resetX + resetW * 0.5, resetY + RESET_H * 0.22, TS_SMALL,
        "! RESET ALL TO DEFAULTS", resetHov and C.white or C.red, RenderText.ALIGN_CENTER, true)
    self:registerClick("tp_reset_all", resetX, resetY, resetW, RESET_H)
    self:drawText(CX, resetY + RESET_H * 0.30, TS_TINY,
        "Defaults = Balanced preset (all x1.0 / base values)", C.dim, RenderText.ALIGN_LEFT, false)

    self:drawRect(CX, resetY - 0.005, CW, 0.001, C.divider)

    -- ── Scroll area bounds ───────────────────────────────────────────────
    local scrollTop = resetY - 0.005
    local scrollH   = scrollTop - CY_BOT
    local totalH    = self:_contentHeight()
    local maxScroll = math.max(0, totalH - scrollH)
    if self.scrollPx > maxScroll then self.scrollPx = maxScroll end

    -- Scrollbar (right gutter)
    local SB_W = 0.006
    local SB_X = PX + PW - SB_W - 0.004
    if maxScroll > 0 then
        local thumbH = math.max(0.030, (scrollH / totalH) * scrollH)
        local thumbRatio = (maxScroll > 0) and (self.scrollPx / maxScroll) or 0
        local thumbY = (CY_BOT + scrollH - thumbH) - thumbRatio * (scrollH - thumbH)
        self:drawRect(SB_X, CY_BOT, SB_W, scrollH, { 0.12, 0.12, 0.15, 0.50 })
        self:drawRect(SB_X, thumbY, SB_W, thumbH, { ACCENT[1], ACCENT[2], ACCENT[3], 0.75 })
    end

    local contentW = CW - SB_W - 0.010

    -- ── Scrollable parameter rows ─────────────────────────────────────────
    local curY   = scrollTop + self.scrollPx
    local rowIdx = 0

    for _, sec in ipairs(TUNING_SECTIONS) do
        local secY = curY - SEC_H
        curY = secY
        if secY + SEC_H >= CY_BOT and secY <= scrollTop then
            self:drawRect(CX, secY, contentW, SEC_H, C.sec_bg)
            self:drawRect(CX, secY, 0.003, SEC_H, C.amber)
            self:drawText(CX + 0.010, secY + SEC_H * 0.25, TS_SMALL,
                sec.header, { ACCENT[1], ACCENT[2], ACCENT[3], 1.0 },
                RenderText.ALIGN_LEFT, true)
        end

        for _, item in ipairs(sec.items) do
            local itemY = curY - ROW_H
            curY = itemY

            -- Skip rows outside the scroll viewport
            if itemY + ROW_H < CY_BOT or itemY > scrollTop then
                -- (continue)
            else
                rowIdx = rowIdx + 1

                -- Current value and modification status
                local idx      = (self.settings and self.settings[item.id]) or 3
                local isModified = (idx ~= 3)
                local lutVal   = self:getLutValue(item.lut, idx)
                local valStr   = string.format(item.fmt, lutVal)

                -- Alternating row background
                if rowIdx % 2 == 0 then
                    self:drawRect(CX, itemY, contentW, ROW_H, C.row_alt)
                end

                -- Left accent strip: amber if modified from default, subtle if default
                local stripCol = isModified and C.amber or { 0.25, 0.27, 0.32, 0.40 }
                self:drawRect(CX, itemY, 0.003, ROW_H, stripCol)

                -- Parameter label
                local labelCol = isModified and C.amber_mod or C.white
                self:drawText(CX + 0.012, itemY + ROW_H * 0.55, TS_BODY,
                    item.label, labelCol, RenderText.ALIGN_LEFT, isModified)

                -- Right edge layout: [dots] [<] [value] [>]
                local rightEdge = CX + contentW - 0.006
                local plusX     = rightEdge - STEP_W
                local valX      = plusX - VAL_W - 0.002
                local minusX    = valX - STEP_W - 0.004
                local dotsX     = minusX - DOT_AREA - 0.006

                -- 5-dot step indicator
                for d = 1, 5 do
                    local spacing = DOT_AREA / 5
                    local dotX = dotsX + (d - 1) * spacing + (spacing - DOT_SZ) * 0.5
                    local dotY = itemY + (ROW_H - DOT_SZ) * 0.5
                    local dotCol = (d <= idx) and C.amber or C.dim
                    self:drawRect(dotX, dotY, DOT_SZ, DOT_SZ, dotCol)
                end

                -- [<] button
                local mHov = self:hitTest(minusX, itemY + 0.004, STEP_W, ROW_H - 0.008, self.mouseX, self.mouseY)
                self:drawRect(minusX, itemY + 0.004, STEP_W, ROW_H - 0.008,
                    mHov and C.step_hov or C.off_bg)
                self:drawText(minusX + STEP_W * 0.5, itemY + (ROW_H - 0.008) * 0.5 - 0.005,
                    TS_BODY, "<", C.white, RenderText.ALIGN_CENTER, true)

                -- Value display
                local valCol = isModified and C.amber_mod or C.white
                self:drawRect(valX, itemY + 0.004, VAL_W, ROW_H - 0.008, { 0.10, 0.11, 0.15, 0.90 })
                self:drawText(valX + VAL_W * 0.5, itemY + (ROW_H - 0.008) * 0.5 - 0.005,
                    TS_BODY, valStr, valCol, RenderText.ALIGN_CENTER, true)

                -- [>] button
                local pHov = self:hitTest(plusX, itemY + 0.004, STEP_W, ROW_H - 0.008, self.mouseX, self.mouseY)
                self:drawRect(plusX, itemY + 0.004, STEP_W, ROW_H - 0.008,
                    pHov and C.step_hov or C.off_bg)
                self:drawText(plusX + STEP_W * 0.5, itemY + (ROW_H - 0.008) * 0.5 - 0.005,
                    TS_BODY, ">", C.white, RenderText.ALIGN_CENTER, true)

                -- Register click targets
                self:registerClick("tp_dec_" .. item.id,
                    minusX, itemY + 0.004, STEP_W, ROW_H - 0.008, { id = item.id, step = -1 })
                self:registerClick("tp_inc_" .. item.id,
                    plusX,  itemY + 0.004, STEP_W, ROW_H - 0.008, { id = item.id, step =  1 })
            end
        end
    end

    -- Clip boundary lines
    self:drawRect(CX, scrollTop, contentW, 0.001, C.divider)
    self:drawRect(CX, CY_BOT,   contentW, 0.001, C.divider)
end

-- ── Mouse event handler ───────────────────────────────────────────────────
function SoilTuningPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.isVisible then return false end
    if eventUsed then return false end

    self.mouseX = posX
    self.mouseY = posY

    -- Scroll wheel
    if button == Input.MOUSE_BUTTON_WHEEL_UP then
        self.scrollPx = math.max(0, self.scrollPx - 0.036)
        return true
    elseif button == Input.MOUSE_BUTTON_WHEEL_DOWN then
        local scrollTop = (CY_TOP - PRESET_H - 0.005 - RESET_H - 0.005)
        local scrollH   = scrollTop - CY_BOT
        local totalH    = self:_contentHeight()
        local maxScroll = math.max(0, totalH - scrollH)
        self.scrollPx   = math.min(maxScroll, self.scrollPx + 0.036)
        return true
    end

    if not isDown or button ~= Input.MOUSE_BUTTON_LEFT then return false end

    for _, rect in ipairs(self._clickRects) do
        if self:hitTest(rect.x, rect.y, rect.w, rect.h, posX, posY) then
            self:_handleClick(rect.id, rect.data)
            return true
        end
    end

    return false
end

-- ── Click handler ─────────────────────────────────────────────────────────
function SoilTuningPanel:_handleClick(id, data)
    if id == "tp_close" then
        self:close()

    elseif id == "tp_back" then
        self:close()
        -- Re-open settings panel at the admin page
        if g_SoilFertilityManager and g_SoilFertilityManager.settingsPanel then
            local sp = g_SoilFertilityManager.settingsPanel
            sp:open()
            sp.page = "admin"
        end

    elseif id == "tp_reset_all" then
        for _, sec in ipairs(TUNING_SECTIONS) do
            for _, item in ipairs(sec.items) do
                self:requestChange(item.id, 3)
            end
        end
        self:_showMsg("All tuning constants reset to defaults.")

    elseif id:sub(1, 10) == "tp_preset_" then
        local presetIdx = data and data.idx
        local preset    = presetIdx and PRESETS[presetIdx]
        if preset then
            for settingId, value in pairs(preset.values) do
                self:requestChange(settingId, value)
            end
            self:_showMsg("Preset applied: " .. preset.label)
        end

    elseif id:sub(1, 7) == "tp_dec_" or id:sub(1, 7) == "tp_inc_" then
        local settingId = data and data.id
        local step      = data and data.step
        if settingId and step then
            local current = (self.settings and self.settings[settingId]) or 3
            local newVal  = math.max(1, math.min(5, current + step))
            self:requestChange(settingId, newVal)
        end
    end
end

function SoilTuningPanel:_showMsg(msg)
    if g_currentMission and g_currentMission.hud and
       g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(msg, 3500)
    end
end

SoilLogger.info("SoilTuningPanel loaded")

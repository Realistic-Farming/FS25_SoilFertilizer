-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Crop Tuning Editor
-- =========================================================
-- Admin/host panel for adjusting per-crop N/P/K requirements (issue #717).
-- Opened from the Admin page of the Settings Panel, styled to match the
-- Constants Tuning Editor. Edits the live SoilConstants.CROP_EXTRACTION
-- table through SoilCropTuning and persists to the player-editable
-- soilCropTuning.xml. New crops are added by hand-editing that XML or via
-- the SoilAddCrop console command.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilCropTuningPanel
SoilCropTuningPanel = {}
local SoilCropTuningPanel_mt = Class(SoilCropTuningPanel)

-- Geometry / colors mirror SoilTuningPanel for a consistent look.
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

local ACCENT = { 0.95, 0.65, 0.10 }
local TS_TITLE = 0.018
local TS_BODY  = 0.015
local TS_SMALL = 0.013
local TS_TINY  = 0.011

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
    red       = { 0.88, 0.25, 0.25, 1.00 },
    red_bg    = { 0.22, 0.06, 0.06, 0.85 },
    red_hov   = { 0.40, 0.10, 0.10, 0.92 },
    off_bg    = { 0.10, 0.11, 0.15, 0.85 },
    btn_bg    = { 0.08, 0.12, 0.18, 0.90 },
    btn_hov   = { 0.14, 0.20, 0.32, 0.95 },
    step_hov  = { 0.28, 0.18, 0.06, 0.90 },
    sec_bg    = { 0.06, 0.08, 0.12, 0.90 },
    lock_text = { 0.65, 0.50, 0.20, 1.00 },
    custom    = { 0.40, 0.80, 0.95, 1.00 },
}

local ROW_H  = 0.036
local SEC_H  = 0.030
local STEP_W = 0.028
local VAL_W  = 0.070
local RESET_H = 0.028
local STEP    = 0.05          -- nutrient increment per click
local NUTRIENTS = { "N", "P", "K" }
local NUTRIENT_LABEL = { N = "Nitrogen (N)", P = "Phosphorus (P)", K = "Potassium (K)" }

function SoilCropTuningPanel.new(settings, cropTuning)
    local self = setmetatable({}, SoilCropTuningPanel_mt)
    self.settings    = settings
    self.cropTuning  = cropTuning
    self.fillOverlay = nil
    self.isVisible   = false
    self.initialized = false
    self.scrollPx    = 0
    self.mouseX      = 0
    self.mouseY      = 0
    self._clickRects = {}
    return self
end

function SoilCropTuningPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    self.initialized = true
    SoilLogger.info("[SoilCropTuningPanel] Initialized")
end

function SoilCropTuningPanel:delete()
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

function SoilCropTuningPanel:open()
    if not self.initialized then self:initialize() end
    self.isVisible = true
    self.scrollPx  = 0
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
end

function SoilCropTuningPanel:close()
    self.isVisible = false
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
end

function SoilCropTuningPanel:isOpen()
    return self.isVisible
end

function SoilCropTuningPanel:update()
    if not self.isVisible then return end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        self:close()
    end
end

-- Crop tuning changes the server-side simulation table, so only the host /
-- single-player can edit. Non-host peers see the values read-only.
function SoilCropTuningPanel:canEdit()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

-- ── Draw helpers ────────────────────────────────────────────────────────────
function SoilCropTuningPanel:drawRect(x, y, w, h, col, alpha)
    if not self.fillOverlay then return end
    setOverlayColor(self.fillOverlay, col[1], col[2], col[3], alpha or col[4] or 1.0)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

function SoilCropTuningPanel:drawText(x, y, size, text, col, align, bold)
    setTextColor(col[1], col[2], col[3], col[4] or 1.0)
    setTextBold(bold == true)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, text)
end

function SoilCropTuningPanel:registerClick(id, x, y, w, h, data)
    table.insert(self._clickRects, { id = id, x = x, y = y, w = w, h = h, data = data })
end

function SoilCropTuningPanel:hitTest(rx, ry, rw, rh, mx, my)
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

function SoilCropTuningPanel:_contentHeight()
    local crops = self.cropTuning and self.cropTuning:getCropNames() or {}
    return #crops * (SEC_H + #NUTRIENTS * ROW_H)
end

-- ── Main draw ─────────────────────────────────────────────────────────────
function SoilCropTuningPanel:draw()
    if not self.isVisible then return end
    if not self.fillOverlay then self:initialize() end
    if not self.fillOverlay then return end
    self._clickRects = {}

    self:drawRect(PX + 0.005, PY - 0.005, PW, PH, C.shadow)
    self:drawRect(PX, PY, PW, PH, C.bg)
    self:drawRect(PX, PY + PH - 0.002, PW, 0.002, C.amber)
    self:drawRect(PX, PY, PW, 0.002, C.amber)
    self:drawRect(PX, PY, 0.002, PH, C.amber)
    self:drawRect(PX + PW - 0.002, PY, 0.002, PH, C.amber)

    -- Title bar
    self:drawRect(PX, PY + PH - TB_H, PW, TB_H, C.title_bg)
    self:drawRect(PX, PY + PH - TB_H, 0.004, TB_H, C.amber)
    self:drawText(PX + 0.018, PY + PH - TB_H + TB_H * 0.33, TS_TITLE,
        "CROP TUNING EDITOR", C.amber, RenderText.ALIGN_LEFT, true)
    self:drawText(PX + PW - 0.018, PY + PH - TB_H + TB_H * 0.33, TS_SMALL,
        self:canEdit() and "HOST ONLY" or "READ ONLY", C.amber_dim, RenderText.ALIGN_RIGHT, false)

    -- Close [X]
    local closeW, closeH = 0.034, TB_H - 0.012
    local closeX, closeY = PX + PW - closeW - 0.008, PY + PH - TB_H + 0.006
    local closeHov = self:hitTest(closeX, closeY, closeW, closeH, self.mouseX, self.mouseY)
    self:drawRect(closeX, closeY, closeW, closeH,
        closeHov and { 0.45, 0.10, 0.10, 0.85 } or { 0.18, 0.08, 0.08, 0.65 })
    self:drawText(closeX + closeW * 0.5, closeY + closeH * 0.22, TS_BODY, "X", C.white, RenderText.ALIGN_CENTER, true)
    self:registerClick("cp_close", closeX, closeY, closeW, closeH)

    -- Bottom bar + back
    self:drawRect(PX, PY, PW, IB_H, C.info_bg)
    self:drawRect(PX, PY + IB_H, PW, 0.001, C.divider)
    self:drawText(CX, PY + IB_H * 0.38, TS_TINY,
        "Per-crop N/P/K depletion  |  Add crops by editing soilCropTuning.xml or SoilAddCrop",
        C.dim, RenderText.ALIGN_LEFT, false)

    local backW, backH = 0.125, IB_H - 0.012
    local backX, backY = PX + PW - backW - 0.010, PY + 0.006
    local backHov = self:hitTest(backX, backY, backW, backH, self.mouseX, self.mouseY)
    self:drawRect(backX, backY, backW, backH, backHov and C.btn_hov or C.btn_bg)
    self:drawRect(backX, backY, 0.003, backH, C.amber_dim)
    self:drawText(backX + backW * 0.5, backY + backH * 0.22, TS_SMALL,
        "< BACK TO SETTINGS", backHov and C.white or C.amber, RenderText.ALIGN_CENTER, true)
    self:registerClick("cp_back", backX, backY, backW, backH)

    -- Reset All
    local resetY = CY_TOP - RESET_H
    local resetW = 0.170
    local resetX = CX + CW - resetW
    local resetHov = self:hitTest(resetX, resetY, resetW, RESET_H, self.mouseX, self.mouseY)
    self:drawRect(resetX, resetY, resetW, RESET_H, resetHov and C.red_hov or C.red_bg)
    self:drawRect(resetX, resetY, 0.003, RESET_H, C.red)
    self:drawText(resetX + resetW * 0.5, resetY + RESET_H * 0.22, TS_SMALL,
        "! RESET ALL CROPS", resetHov and C.white or C.red, RenderText.ALIGN_CENTER, true)
    if self:canEdit() then
        self:registerClick("cp_reset_all", resetX, resetY, resetW, RESET_H)
    end
    self:drawText(CX, resetY + RESET_H * 0.30, TS_TINY,
        "Restores every crop to its shipped values (drops custom crops)", C.dim, RenderText.ALIGN_LEFT, false)
    self:drawRect(CX, resetY - 0.005, CW, 0.001, C.divider)

    local scrollTop = resetY - 0.005
    local scrollH   = scrollTop - CY_BOT
    local totalH    = self:_contentHeight()
    local maxScroll = math.max(0, totalH - scrollH)
    if self.scrollPx > maxScroll then self.scrollPx = maxScroll end

    -- Scrollbar
    local SB_W = 0.006
    local SB_X = PX + PW - SB_W - 0.004
    if maxScroll > 0 then
        local thumbH = math.max(0.030, (scrollH / totalH) * scrollH)
        local thumbRatio = self.scrollPx / maxScroll
        local thumbY = (CY_BOT + scrollH - thumbH) - thumbRatio * (scrollH - thumbH)
        self:drawRect(SB_X, CY_BOT, SB_W, scrollH, { 0.12, 0.12, 0.15, 0.50 })
        self:drawRect(SB_X, thumbY, SB_W, thumbH, { ACCENT[1], ACCENT[2], ACCENT[3], 0.75 })
    end

    local contentW = CW - SB_W - 0.010
    local canEdit  = self:canEdit()
    local crops    = self.cropTuning and self.cropTuning:getCropNames() or {}
    local curY     = scrollTop + self.scrollPx
    local rowIdx   = 0

    for _, crop in ipairs(crops) do
        local rates = self.cropTuning:getRates(crop)
        local isCustom = self.cropTuning:isCustom(crop)

        -- Section header = crop name
        local secY = curY - SEC_H
        curY = secY
        if secY + SEC_H >= CY_BOT and secY <= scrollTop then
            self:drawRect(CX, secY, contentW, SEC_H, C.sec_bg)
            self:drawRect(CX, secY, 0.003, SEC_H, isCustom and C.custom or C.amber)
            self:drawText(CX + 0.010, secY + SEC_H * 0.28, TS_SMALL,
                crop:upper(), isCustom and C.custom or ACCENT, RenderText.ALIGN_LEFT, true)
            if isCustom then
                self:drawText(CX + 0.010 + 0.13, secY + SEC_H * 0.30, TS_TINY,
                    "custom", C.custom, RenderText.ALIGN_LEFT, false)
            end
            -- Per-crop reset button
            if canEdit then
                local rW, rH = 0.052, SEC_H - 0.010
                local rX = CX + contentW - rW - 0.006
                local rY = secY + 0.005
                local rHov = self:hitTest(rX, rY, rW, rH, self.mouseX, self.mouseY)
                self:drawRect(rX, rY, rW, rH, rHov and C.step_hov or C.off_bg)
                self:drawText(rX + rW * 0.5, rY + rH * 0.16, TS_TINY,
                    isCustom and "remove" or "reset", rHov and C.white or C.dim, RenderText.ALIGN_CENTER, false)
                self:registerClick("cp_resetcrop_" .. crop, rX, rY, rW, rH, { crop = crop })
            end
        end

        -- N / P / K rows
        for _, key in ipairs(NUTRIENTS) do
            local itemY = curY - ROW_H
            curY = itemY
            if itemY + ROW_H >= CY_BOT and itemY <= scrollTop then
                rowIdx = rowIdx + 1
                if rowIdx % 2 == 0 then
                    self:drawRect(CX, itemY, contentW, ROW_H, C.row_alt)
                end
                local def = SoilCropTuning.DEFAULTS[crop]
                local isMod = def == nil or math.abs((rates[key] or 0) - (def[key] or 0)) > 1e-6
                self:drawRect(CX, itemY, 0.003, ROW_H, isMod and C.amber or { 0.25, 0.27, 0.32, 0.40 })
                self:drawText(CX + 0.018, itemY + ROW_H * 0.52, TS_BODY,
                    NUTRIENT_LABEL[key], isMod and C.amber_mod or C.white, RenderText.ALIGN_LEFT, isMod)

                local rightEdge = CX + contentW - 0.006
                local plusX  = rightEdge - STEP_W
                local valX   = plusX - VAL_W - 0.002
                local minusX = valX - STEP_W - 0.004
                local valStr = string.format("%.2f", rates[key] or 0)

                if canEdit then
                    local mHov = self:hitTest(minusX, itemY + 0.004, STEP_W, ROW_H - 0.008, self.mouseX, self.mouseY)
                    self:drawRect(minusX, itemY + 0.004, STEP_W, ROW_H - 0.008, mHov and C.step_hov or C.off_bg)
                    self:drawText(minusX + STEP_W * 0.5, itemY + (ROW_H - 0.008) * 0.5 - 0.005, TS_BODY, "<", C.white, RenderText.ALIGN_CENTER, true)
                    self:registerClick("cp_dec_" .. crop .. "_" .. key, minusX, itemY + 0.004, STEP_W, ROW_H - 0.008, { crop = crop, key = key, step = -STEP })
                end

                self:drawRect(valX, itemY + 0.004, VAL_W, ROW_H - 0.008, { 0.10, 0.11, 0.15, 0.90 })
                self:drawText(valX + VAL_W * 0.5, itemY + (ROW_H - 0.008) * 0.5 - 0.005, TS_BODY,
                    valStr, isMod and C.amber_mod or C.white, RenderText.ALIGN_CENTER, true)

                if canEdit then
                    local pHov = self:hitTest(plusX, itemY + 0.004, STEP_W, ROW_H - 0.008, self.mouseX, self.mouseY)
                    self:drawRect(plusX, itemY + 0.004, STEP_W, ROW_H - 0.008, pHov and C.step_hov or C.off_bg)
                    self:drawText(plusX + STEP_W * 0.5, itemY + (ROW_H - 0.008) * 0.5 - 0.005, TS_BODY, ">", C.white, RenderText.ALIGN_CENTER, true)
                    self:registerClick("cp_inc_" .. crop .. "_" .. key, plusX, itemY + 0.004, STEP_W, ROW_H - 0.008, { crop = crop, key = key, step = STEP })
                end
            end
        end
    end

    self:drawRect(CX, scrollTop, contentW, 0.001, C.divider)
    self:drawRect(CX, CY_BOT, contentW, 0.001, C.divider)
end

-- ── Input ─────────────────────────────────────────────────────────────────
function SoilCropTuningPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.isVisible then return false end
    if eventUsed then return false end
    self.mouseX, self.mouseY = posX, posY

    if button == Input.MOUSE_BUTTON_WHEEL_UP then
        self.scrollPx = math.max(0, self.scrollPx - 0.036)
        return true
    elseif button == Input.MOUSE_BUTTON_WHEEL_DOWN then
        local scrollTop = CY_TOP - RESET_H - 0.005
        local maxScroll = math.max(0, self:_contentHeight() - (scrollTop - CY_BOT))
        self.scrollPx = math.min(maxScroll, self.scrollPx + 0.036)
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

function SoilCropTuningPanel:_handleClick(id, data)
    if id == "cp_close" then
        self:close()

    elseif id == "cp_back" then
        self:close()
        if g_SoilFertilityManager and g_SoilFertilityManager.settingsPanel then
            local sp = g_SoilFertilityManager.settingsPanel
            sp:open()
            sp.page = "admin"
        end

    elseif id == "cp_reset_all" then
        if self.cropTuning then
            self.cropTuning:resetAll()
            self:_showMsg("All crops reset to shipped values.")
        end

    elseif id:sub(1, 13) == "cp_resetcrop_" then
        local crop = data and data.crop
        if crop and self.cropTuning then
            self.cropTuning:removeCrop(crop)
        end

    elseif id:sub(1, 7) == "cp_dec_" or id:sub(1, 7) == "cp_inc_" then
        local crop, key, step = data and data.crop, data and data.key, data and data.step
        if crop and key and step and self.cropTuning then
            local rates = self.cropTuning:getRates(crop)
            if rates then
                self.cropTuning:setNutrient(crop, key, (rates[key] or 0) + step)
            end
        end
    end
end

function SoilCropTuningPanel:_showMsg(msg)
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(msg, 3500)
    end
end

SoilLogger.info("SoilCropTuningPanel loaded")

-- MAINT-194-admin_label_font_glyph_test.lua: MAINTENANCE row 194, the settings panel's
-- admin button drew "⚙ ADMIN". FS25's text font has no U+2699 (gear): the game logged
-- "Character '9881' not found in texture font" (Tyson's 2026-10-01 log) and drew a blank.
-- The label is now plain "ADMIN".
--
-- TEXT BAR FROM THE ENTRY POINT. The panel is made by the real SoilSettingsPanel.new (as
-- SoilFertilityManager does, :314), opened by the real toggle (what the SF_OPEN_SETTINGS
-- input, onOpenSettingsInput, calls) and drawn by the real draw (what the MasterHUD bridge
-- and the manager call each frame). Every string the panel hands renderText is recorded.
--
--   L0  [reached] the panel opens on its landing page and draws
--   L1  the admin button's label is drawn as plain "ADMIN"
--   L2  no string the landing page draws carries a character from the symbol blocks the
--       suite sweep found no base-game text using (Miscellaneous Technical, Geometric
--       Shapes, Miscellaneous Symbols, Dingbats, and the emoji planes); the base game's
--       own English texts do use arrows (U+2190, U+2192), so those blocks are not listed
--
-- Two-sided: on development a83ec6e6, L1 and L2 fail.
-- No battery: a non-logic change (one drawn string).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/utils/SoilUtils.lua, src/utils/SoilL10n.lua, src/ui/SoilSettingsPanel.lua

-- Engine render calls: sinks that keep every string drawn.
local drawn = {}
RenderText = RenderText or { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
function setTextColor() end
function setTextBold() end
function setTextAlignment() end
function setOverlayColor() end
function renderOverlay() end
function getTextWidth() return 0.01 end
function getTextHeight() return 0.01 end
function renderText(_x, _y, _size, text) drawn[#drawn + 1] = tostring(text) end

local function lacking(cp)
  return (cp >= 0x2300 and cp <= 0x23FF)      -- Miscellaneous Technical (U+23F8 and kin)
      or (cp >= 0x25A0 and cp <= 0x25FF)      -- Geometric Shapes
      or (cp >= 0x2600 and cp <= 0x26FF)      -- Miscellaneous Symbols (U+2699 gear, U+26FD fuel pump)
      or (cp >= 0x2700 and cp <= 0x27BF)      -- Dingbats
      or cp >= 0x1F000                        -- emoji planes
end
local function badGlyphs()
  local out = {}
  for _, s in ipairs(drawn) do
    local ok = pcall(function()
      for _, cp in utf8.codes(s) do
        if lacking(cp) then out[#out + 1] = string.format("U+%04X in %q", cp, s) end
      end
    end)
    if not ok then out[#out + 1] = "invalid UTF-8 in " .. string.format("%q", s) end
  end
  return table.concat(out, "; ")
end

local panel = SoilSettingsPanel.new({ enabled = true })
panel:toggle()
drawn = {}
local ok, err = pcall(panel.draw, panel)

local adminLabel = nil
for _, s in ipairs(drawn) do
  if s:find("ADMIN", 1, true) then adminLabel = s end
end

T.ok("L0 [reached: the real new and toggle open the panel on its landing page, and draw renders it] " .. tostring(err),
     ok and panel:isOpen() and panel.page == "landing" and #drawn > 0)
T.eq("L1 NAMED: the admin button's label is plain ADMIN", adminLabel, "ADMIN")
T.eq("L2 NAMED: no landing-page string carries a glyph from the blocks the font lacks", badGlyphs(), "")

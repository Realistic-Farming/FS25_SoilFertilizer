-- SG10-051-map_frame_model.lua
--
-- The engine under the map frame's mouse chain, MODELED so a bar can start from
-- production's own entry point rather than from the handler.
--
-- SoilMapHooks installs itself by wrapping InGameMenuMapFrame.mouseEvent through
-- Utils.overwrittenFunction (SoilMapHooks.lua:461-507, installed at :658). The wrapper
-- runs every registered handler BEFORE the engine's own mouseEvent, which is exactly why
-- the click leak travels this path: the frame does not have to be visible for the handler
-- to see the event. A bar that calls SoilMapHooks.handleMouseEvent directly never crosses
-- that wrapper and so cannot see the defect in its real shape.
--
-- Loaded BEFORE src/hooks/SoilMapHooks.lua so the install block finds a frame to wrap.

--- The engine's own leaf behaviour. GuiElement:mouseEvent (gui/GuiElement.lua:502) walks its
--- children and hands back whether the event was consumed; with no children that is eventUsed
--- unchanged. The counter is how a bar proves the chain reached the engine at all.
InGameMenuMapFrame = InGameMenuMapFrame or {}
InGameMenuMapFrame.engineMouseCalls = 0

function InGameMenuMapFrame.mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    InGameMenuMapFrame.engineMouseCalls = InGameMenuMapFrame.engineMouseCalls + 1
    return eventUsed == true
end

--- Utils as the engine defines it, only the two the install block uses.
Utils = Utils or {}

--- newFunc receives (self, superFunc, ...) and decides whether to call on.
function Utils.overwrittenFunction(oldFunc, newFunc)
    return function(...)
        return newFunc(select(1, ...), oldFunc, select(2, ...))
    end
end

--- Both run; the appended one cannot suppress the original.
function Utils.appendedFunction(oldFunc, newFunc)
    return function(...)
        if oldFunc ~= nil then oldFunc(...) end
        return newFunc(...)
    end
end

--- Reset between cases so a count means "this case".
function InGameMenuMapFrame.resetModel()
    InGameMenuMapFrame.engineMouseCalls = 0
end

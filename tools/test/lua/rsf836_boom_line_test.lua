-- rsf836_boom_line_test.lua - RSF-836 THE TRUE BOOM LINE.
--   paintBoomStrip took its line off the ends of the cell sweep array, whose last
--   element is ALWAYS the vehicle root and whose extent is a world-axis projection,
--   so it painted one tip to the middle of the machine, halved and foreshortened by
--   the heading cosine. This bar proves the endpoint derivation restores the real
--   boom length at 0, 30 and 45 degrees on the MAIN path and the FALLBACK path
--   separately, that an inactive VWW section is excluded (partial width), and that
--   the old array-end read was the RED case.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

-- ── Engine transform mocks: a consistent yaw-only world. The vehicle frame's
-- local X is the lateral axis, the engine's own working-width convention.
local FRAME_OX, FRAME_OZ = 1000, 2000
local _yaw = 0

local function setYaw(theta) _yaw = theta end
local function yawC() return math.cos(_yaw), math.sin(_yaw) end

function localToWorld(_node, lx, _ly, lz)
  local c, s = yawC()
  return FRAME_OX + lx * c - lz * s, 0, FRAME_OZ + lx * s + lz * c
end
function getWorldTranslation(node)
  return node.wx, node.wy or 0, node.wz
end
function localToLocal(node, _frame, _x, _y, _z)
  -- (0,0,0) in the node's frame is the node's origin; express it in the frame's
  -- local coordinates (the frame sits at the world origin in this mock).
  local c, s = yawC()
  local dx = node.wx - FRAME_OX
  local dz = node.wz - FRAME_OZ
  return dx * c + dz * s, 0, -dx * s + dz * c
end
function getWorldRotation(_node) return 0, _yaw, 0 end

local function mkNode(lx, lz)
  local c, s = yawC()
  return { wx = FRAME_OX + lx * c - lz * s, wy = 0, wz = FRAME_OZ + lx * s + lz * c }
end

local function spanLen(line)
  if not line then return 0 end
  local dx = line.bx - line.ax
  local dz = line.bz - line.az
  return math.sqrt(dx * dx + dz * dz)
end

local hm = HookManager.new()

-- ══════════════════════════════════════════════════════════
-- MAIN PATH: THE PAINTED LINE IS THE REAL BOOM AT ANY HEADING
-- A 36.6 m boom laid along the frame's local X, driven at 0 / 30 / 45 degrees.
-- ══════════════════════════════════════════════════════════

for _, theta in ipairs({ 0, math.rad(30), math.rad(45) }) do
  setYaw(theta)
  local half = 18.3
  local veh = {
    rootNode = mkNode(0, 0),
    components = { { node = mkNode(0, 0) } },
    spec_workArea = { workAreas = {
      { start = mkNode(-half, 0), width = mkNode(half, 0), height = mkNode(0, 2) },
    } },
  }
  local line = hm:getBoomLineEndpoints(veh, veh.rootNode.wx, veh.rootNode.wz)
  T.near("main path: painted length = real boom at " .. tostring(math.deg(theta)) .. " deg",
    spanLen(line), 36.6, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- THE RED CASE: THE OLD ARRAY-END READ WAS FORESHORTENED
-- getBoomCellPositions returns the world-axis-aligned sweep with the root appended;
-- its ends spanned (boom x cos heading) / 2, the exact striping the reporter proved.
-- ══════════════════════════════════════════════════════════

setYaw(math.rad(30))
do
  local half = 18.3
  local veh = {
    rootNode = mkNode(0, 0),
    components = { { node = mkNode(0, 0) } },
    spec_workArea = { workAreas = {
      { start = mkNode(-half, 0), width = mkNode(half, 0), height = mkNode(0, 2) },
    } },
  }
  local old = hm:getBoomCellPositions(veh, veh.rootNode.wx, veh.rootNode.wz)
  T.ok("red case: the old cell sweep exists", old ~= nil)
  if old and #old >= 2 then
    local ox = old[1].x - old[#old].x
    local oz = old[1].z - old[#old].z
    local oldSpan = math.sqrt(ox * ox + oz * oz)
    T.near("red case: the old line was halved and foreshortened (cos 30 / 2)",
      oldSpan, 36.6 * math.cos(math.rad(30)) / 2, 1e-3)
  end
  local line = hm:getBoomLineEndpoints(veh, veh.rootNode.wx, veh.rootNode.wz)
  T.near("red case: the true line is the full boom where the old one was not",
    spanLen(line), 36.6, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- FALLBACK PATH: THE WORKING WIDTH, LAID ON THE FRAME'S LOCAL X
-- A broadcast spreader with no spanning work-area nodes derives its line from the
-- working width, carried in the vehicle's real orientation, not a world axis.
-- ══════════════════════════════════════════════════════════

setYaw(math.rad(30))
do
  local bc = {
    rootNode = mkNode(0, 0),
    components = { { node = mkNode(0, 0) } },
    spec_sprayer = { usageScale = { workingWidth = 24 } },
    -- no spec_workArea and no VWW: zero collected nodes, so the fallback fires
  }
  local line = hm:getBoomLineEndpoints(bc, bc.rootNode.wx, bc.rootNode.wz)
  T.near("fallback path: the line is the working width, laid on local X", spanLen(line), 24, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- PARTIAL WIDTH: AN INACTIVE VWW SECTION DOES NOT EXTEND THE LINE
-- The inactive section's node sits at the full tip whether or not it is spraying;
-- including it would credit cells that were never covered (#475/#476).
-- ══════════════════════════════════════════════════════════

setYaw(0)
do
  local veh = {
    rootNode = mkNode(0, 0),
    components = { { node = mkNode(0, 0) } },
    spec_variableWorkWidth = { sections = {
      { isActive = true,  maxWidthNode = mkNode(-9, 0) },
      { isActive = false, maxWidthNode = mkNode(9, 0) },   -- further out, INACTIVE
      { isActive = true,  maxWidthNode = mkNode(-3, 0) },
    } },
  }
  local line = hm:getBoomLineEndpoints(veh, veh.rootNode.wx, veh.rootNode.wz)
  T.near("partial width: the line spans the active tips only", spanLen(line), 6, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- paintBoomStrip CONSUMES THE TRUE LINE (end to end through the painter)
-- The stored anchor after a paint is the true boom line, not the array ends.
-- ══════════════════════════════════════════════════════════

setYaw(math.rad(30))
do
  local painted = {}
  local soilSys = setmetatable({
    fieldData = { [1] = {} },
    vmAvailable = function() return true end,
    valueMaps = {
      addPaintStrip = function(_m, layer, _sx, _sz, _wx, _wz, _hx, _hz, _delta)
        painted[#painted + 1] = layer
      end,
    },
  }, { __index = SoilFertilitySystem })
  g_currentMission.time = 5000

  local half = 18.3
  local veh = {
    rootNode = mkNode(0, 0),
    components = { { node = mkNode(0, 0) } },
    spec_workArea = { workAreas = {
      { start = mkNode(-half, 0), width = mkNode(half, 0), height = mkNode(0, 2) },
    } },
  }
  local line = hm:getBoomLineEndpoints(veh, veh.rootNode.wx, veh.rootNode.wz)

  -- An axis-aligned cell array (the OLD boomPoints shape) passed alongside the
  -- true line must NOT be what the painter measures.
  local oldArray = { { x = FRAME_OX - 10, z = FRAME_OZ }, { x = FRAME_OX, z = FRAME_OZ } }
  soilSys.fieldData[1]._sprayDose = { time = 5000, area = 40, dN = 10, dP = 0, dK = 0, dPH = 0, dOM = 0 }
  soilSys:paintBoomStrip(1, oldArray, "UREA", line)
  local stored = soilSys.fieldData[1]._vmLastBoomLine
  T.ok("paintBoomStrip painted through the true line", #painted >= 1)
  T.near("paintBoomStrip stored the true boom line as the anchor",
    spanLen(stored), 36.6, 1e-6)

  -- RED, without the line: the painter falls back to the array ends and stores the
  -- foreshortened span (the defect this fix exists to end).
  soilSys.fieldData[1]._vmLastBoomLine = nil
  soilSys.fieldData[1]._sprayDose = { time = 5000, area = 40, dN = 10, dP = 0, dK = 0, dPH = 0, dOM = 0 }
  soilSys:paintBoomStrip(1, oldArray, "UREA", nil)
  local storedRed = soilSys.fieldData[1]._vmLastBoomLine
  T.ok("red case: without the line the anchor is the foreshortened array span",
    storedRed ~= nil and spanLen(storedRed) < 36.6)
end

T.summary()

-- RSF-F227-ground_tip_lifetime_spec_test.lua - the ground-tip wrapper's gates and lifetime.
--
-- Runs the real GroundTipGate wrapper against stubs for the engine predicate and the
-- height manager. Proves the two engine gates (manager validity, the type's own
-- canBeTipped), pure delegation while the flag is off, one wrapper per process, and
-- the install/enable/disable lifetime that main.lua drives from loadedMission and
-- unload. The main.lua call sites themselves are read, not executed: main.lua sources
-- the whole mod and cannot load under the bench.
--
--!load: src/hooks/GroundTipGate.lua

local origCalls = {}
local function origGetCan(idx) origCalls[#origCalls + 1] = idx; return idx == 99 end

local function freshProcess()
  GroundTipGate._resetForTests()
  origCalls = {}
  DensityMapHeightUtil = { getCanTipToGround = origGetCan }
  g_densityMapHeightManager = {
    _valid = true,
    getIsValid = function(self) return self._valid end,
    fillTypeIndexToHeightType = {
      [1] = { canBeTipped = true },
      [2] = { canBeTipped = false },
      [3] = {},                        -- field missing: engine coerces to false
    },
  }
end

-- ── Gates, flag on ───────────────────────────────────────────────────────────
do
  freshProcess()
  T.eq("install: first call installs", GroundTipGate.install(), true)
  T.ok("install: the live callable is our wrapper",
       DensityMapHeightUtil.getCanTipToGround == GroundTipGate.getWrapper())
  T.eq("flag: false right after install", GroundTipGate.isActive(), false)
  GroundTipGate.enable()
  T.eq("flag: true after enable", GroundTipGate.isActive(), true)

  local can = DensityMapHeightUtil.getCanTipToGround
  T.eq("on: permitted type answers true", can(1), true)
  T.eq("on: forbidden type answers false", can(2), false)
  T.eq("on: missing canBeTipped answers false, not nil", can(3), false)
  T.eq("on: unknown type delegates to the predecessor", can(99), true)
  T.eq("on: unknown type delegates (negative)", can(42), false)
  T.eq("on: the predecessor saw only the unknown types", #origCalls, 2)

  g_densityMapHeightManager._valid = false
  T.eq("on: invalid manager answers false for a permitted type", can(1), false)
  T.eq("on: invalid manager answers false for an unknown type", can(99), false)
  T.eq("on: invalid manager never reaches the predecessor", #origCalls, 2)
end

-- ── Flag off: exactly the predecessor ────────────────────────────────────────
do
  freshProcess()
  GroundTipGate.install()
  local can = DensityMapHeightUtil.getCanTipToGround
  g_densityMapHeightManager._valid = false   -- would gate if the flag were on
  T.eq("off: permitted type is the predecessor's answer", can(1), false)
  T.eq("off: unknown 99 is the predecessor's answer", can(99), true)
  T.eq("off: every call reached the predecessor", #origCalls, 2)
  GroundTipGate.enable()
  GroundTipGate.disable()
  T.eq("off again after disable", can(1), false)
  T.eq("off again: predecessor reached", #origCalls, 3)
end

-- ── Lifetime across missions in one process ──────────────────────────────────
do
  freshProcess()
  T.eq("lifetime: flag declared false", GroundTipGate.isActive(), false)
  T.eq("lifetime: enable before install is a no-op", GroundTipGate.enable(), false)

  -- Mission 1: Lua injection ran (registered > 0), as loadedMission does it.
  local installedNow = GroundTipGate.install()
  GroundTipGate.enable()
  local firstWrapper = DensityMapHeightUtil.getCanTipToGround
  T.eq("mission 1: installed now", installedNow, true)
  T.eq("mission 1: active", GroundTipGate.isActive(), true)

  -- unload, first statement, even if the manager teardown throws afterwards.
  local ok = pcall(function()
    GroundTipGate.disable()
    error("sfm:delete blew up")
  end)
  T.eq("unload: the throw happened after the disable", ok, false)
  T.eq("unload: flag false", GroundTipGate.isActive(), false)
  T.eq("unload: wrapper still installed", GroundTipGate.isInstalled(), true)
  T.ok("unload: live callable untouched", DensityMapHeightUtil.getCanTipToGround == firstWrapper)

  -- Mission 2: injection ran again -> enable without reinstalling.
  T.eq("mission 2: install is a no-op", GroundTipGate.install(), false)
  GroundTipGate.enable()
  T.eq("mission 2: active again", GroundTipGate.isActive(), true)
  T.ok("mission 2: same function object, no chaining",
       DensityMapHeightUtil.getCanTipToGround == firstWrapper)

  -- Mission 3: engine registered the types itself (registered == 0): main.lua
  -- calls neither install nor enable, so the flag stays where unload left it.
  GroundTipGate.disable()
  T.eq("mission 3: stays inert when injection did not run", GroundTipGate.isActive(), false)
  T.eq("mission 3: unknown type still delegates", DensityMapHeightUtil.getCanTipToGround(99), true)
end

-- ── A foreign hook stacked on top survives our unload ────────────────────────
do
  freshProcess()
  GroundTipGate.install()
  GroundTipGate.enable()
  local ours = DensityMapHeightUtil.getCanTipToGround
  local foreignCalls = 0
  local foreign = function(idx)
    foreignCalls = foreignCalls + 1
    if idx == 7 then return true end
    return ours(idx)
  end
  DensityMapHeightUtil.getCanTipToGround = foreign

  GroundTipGate.disable()   -- our unload
  T.ok("foreign: the live callable is still the foreign hook",
       DensityMapHeightUtil.getCanTipToGround == foreign)
  T.eq("foreign: its own answer stands", DensityMapHeightUtil.getCanTipToGround(7), true)
  T.eq("foreign: through us, disabled, to the predecessor", DensityMapHeightUtil.getCanTipToGround(99), true)
  T.eq("foreign: a permitted type is now the predecessor's answer, not ours",
       DensityMapHeightUtil.getCanTipToGround(1), false)
  T.eq("foreign: the foreign hook ran every time", foreignCalls, 3)

  -- Next mission re-enables through the stack.
  GroundTipGate.install()
  GroundTipGate.enable()
  T.eq("foreign: re-enabled, our gate answers again beneath the foreign hook",
       DensityMapHeightUtil.getCanTipToGround(1), true)
end

-- ── Install refuses when the engine util is absent ───────────────────────────
do
  GroundTipGate._resetForTests()
  DensityMapHeightUtil = nil
  T.eq("absent util: install returns false", GroundTipGate.install(), false)
  T.eq("absent util: enable stays false", GroundTipGate.enable(), false)
end

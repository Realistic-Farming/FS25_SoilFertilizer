-- RSF-F190-barn_privacy_spec_test.lua - own-farm dog barn-warning privacy (RSF-F190
-- Implementation brief v1.0, certified; over #1054; Bob's intake
-- Desk Office/Drafts/BOB-INTAKE-RSF-F190-BARN-PRIVACY-2026-10-03.md).
--
-- The barn warning belongs only to the actual local player's current farm. Detection may
-- keep an internal cache of every farm it scans; the HUD and the getter follow the local
-- actor only.
--
-- THE ENTRY-POINT BAR IS GROUP E. No Soil bench can execute all of src/main.lua (it sources
-- every module), so this bar executes main.lua's OWN dog statements, read from its text
-- (--!text) at their three sites and run in the mission's order: the construction in
-- loadedMission, the call in the FSBaseMission.update append, the release in unload. A
-- moved or changed site fails row E0. The world is two farms, each with a doghouse in
-- g_currentMission.doghouses (the shape PlaceableDoghouse registers), a barn each in the
-- placeable roster, only farm 2's sick in the provider's 1.4 shape the reader reads,
-- g_farmManager:getFarms(), g_localPlayer and a recording HUD; the MessageCenter is modelled
-- on MessageCenter.lua:27-68 and its publish (callback(target, ...)). Nothing writes a
-- warning, a key or a binding by hand.
--
-- Groups:
--   E  the entry-point bar: a listen host on farm 1, farm 2's sick barn, then the farm switch
--   D  the defects the brief names, each two-sided against development aaf0feaf
--   M  the mixed crop and barn cache (brief section 6)
--   T  topologies, the getter's purity, the update-time context check, another player's
--      switch, and the release at unload
--
--!load: src/SpatialScouting.lua, src/LivestockWarningReader.lua, src/DogEarlyWarning.lua
--!text: src/main.lua

local MAIN = ((SOURCE_TEXT and SOURCE_TEXT["src/main.lua"]) or ""):gsub("\r\n", "\n")

--- One production site of main.lua, from `first` through `last`, or nil when absent.
local function site(first, last)
  local i = MAIN:find(first, 1, true)
  if i == nil then return nil, 0 end
  local j = MAIN:find(last, i, true)
  if j == nil then return nil, 0 end
  local n, from = 0, 1
  while true do
    local k = MAIN:find(first, from, true)
    if k == nil then break end
    n, from = n + 1, k + 1
  end
  return MAIN:sub(i, j + #last - 1), n
end
local BUILD, nBuild = site("if DogEarlyWarning ~= nil and sfm.soilSystem ~= nil then", "mission.dogEarlyWarning = dogWarning\n    end")
local TICK, nTick = site("if dogWarning ~= nil then dogWarning:update(dt) end", "dogWarning:update(dt) end")
local RELEASE, nRelease = site("if dogWarning ~= nil and dogWarning.delete ~= nil then", "pcall(dogWarning.delete, dogWarning) end")

--- Run one main.lua site in an environment over the real globals; returns that environment.
local function run(code, env)
  setmetatable(env, { __index = _G })
  local f = assert(load(code, "=src/main.lua", "t", env))
  f()
  return env
end

-- ── MessageCenter, modelled on MessageCenter.lua:27-68 and its publish ──────────
MessageType = MessageType or {}
MessageType.PLAYER_FARM_CHANGED = MessageType.PLAYER_FARM_CHANGED or "PLAYER_FARM_CHANGED"
local MC = { subscribers = {} }
function MC:subscribe(messageType, callback, callbackTarget, argument)
  self.subscribers[messageType] = self.subscribers[messageType] or {}
  table.insert(self.subscribers[messageType], { callback = callback, callbackTarget = callbackTarget, argument = argument })
end
function MC:unsubscribe(messageType, callbackTarget, callback)
  local subs = self.subscribers[messageType]
  if subs == nil then return end
  for i = #subs, 1, -1 do
    local info = subs[i]
    if info.callbackTarget == callbackTarget and (callback == nil or info.callback == callback) then table.remove(subs, i) end
  end
  if #subs == 0 then self.subscribers[messageType] = nil end
end
function MC:publish(messageType, ...)
  for _, info in ipairs(self.subscribers[messageType] or {}) do
    if info.callbackTarget == nil then
      if info.argument == nil then info.callback(...) else info.callback(info.argument, ...) end
    elseif info.argument == nil then
      info.callback(info.callbackTarget, ...)
    else
      info.callback(info.callbackTarget, info.argument, ...)
    end
  end
end
local function subscriberCount(target)
  local n = 0
  for _, info in ipairs(MC.subscribers[MessageType.PLAYER_FARM_CHANGED] or {}) do
    if info.callbackTarget == target then n = n + 1 end
  end
  return n
end

-- ── the provider's 1.4 shapes the reader reads (as the reader's own bench builds them) ──
local function srec(state) return { type = "x", state = state, isCarrier = false } end
local function gate14(self)
  if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled or self.diseases == nil then return false end
  for _, d in ipairs(self.diseases) do if d.state == "INFECTIOUS" then return true end end
  return false
end
local function animal(sick) return { diseases = sick and { srec("INFECTIOUS") } or {}, getHasAnyDisease = gate14 } end
--- A husbandry placeable: its farm, its id (nil = getUniqueId throws), sick or not.
local function barn(farm, id, sick)
  local herd = { animal(sick) }
  local p = { spec_husbandryAnimals = { clusterSystem = { getAnimals = function() return herd end } }, _farm = farm }
  p.getOwnerFarmId = function(self) return self._farm end
  p.getUniqueId = function() if id == nil then error("no id") end return id end
  p.herd = herd
  return p
end

-- ── the world ──────────────────────────────────────────────────────────────────
local shown
local function barnToasts()
  local n = 0
  for _, s in ipairs(shown) do if s.msg:find("at Barn", 1, true) then n = n + 1 end end
  return n
end
local function cropToasts()
  local n = 0
  for _, s in ipairs(shown) do if s.msg:find("with Field", 1, true) then n = n + 1 end end
  return n
end
--- Two farms, a doghouse each, farm 1's barn healthy and farm 2's sick (opts override), the
--- dog built by main.lua's own construction statement.
local function world(opts)
  opts = opts or {}
  shown = {}
  local W = { cropInfo = {}, fieldOwner = {} }
  if opts.client then g_server = nil else g_server = {} end
  g_diseaseManager = { diseasesEnabled = true }
  W.dh1 = { getOwnerFarmId = function() return 1 end }
  W.dh2 = { getOwnerFarmId = function() return 2 end }
  W.barn1 = barn(1, "BARN-ONE", opts.ownSick == true)
  W.barn2 = barn(2, "BARN-TWO", opts.foreignSick ~= false)
  W.placeables = { W.barn1, W.barn2 }
  for _, p in ipairs(opts.extra or {}) do W.placeables[#W.placeables + 1] = p end
  W.fields = {}
  W.soil = { getFieldInfo = function(_s, fid) return W.cropInfo[fid] end }
  W.mission = {
    doghouses = { [W.dh1] = true, [W.dh2] = true },
    placeableSystem = { placeables = W.placeables },
    fieldManager = { getFields = function() if W.fieldsThrow then error("no field manager") end return W.fields end },
    hud = { showBlinkingWarning = function(_s, msg, ms) shown[#shown + 1] = { msg = msg, ms = ms } end },
  }
  g_currentMission = W.mission
  g_farmManager = { getFarms = function() return { { farmId = 1 }, { farmId = 2 } } end }
  g_farmlandManager = { getFarmlandOwner = function(_s, fid) return W.fieldOwner[fid] end }
  g_i18n = nil
  MC.subscribers = {}
  g_messageCenter = MC
  if opts.player == false then g_localPlayer = nil else g_localPlayer = { farmId = opts.farm or 1 } end
  local env = run(BUILD or "error('main.lua construction site not found')", { sfm = { soilSystem = W.soil }, mission = W.mission })
  W.dog = env.dogWarning
  return W
end
--- One frame of FSBaseMission.update's dog call, through main.lua's own statement.
local function tick(W, dt) run(TICK or "error('main.lua update site not found')", { dogWarning = W.dog, dt = dt }) end
local function scan(W) tick(W, 60000) end
local function ids(list)
  local out = {}
  for _, r in ipairs(list or {}) do out[#out + 1] = tostring(r.fieldId) .. "_" .. tostring(r.type) end
  table.sort(out)
  return table.concat(out, ",")
end
local function keys(W, farm)
  local out = {}
  for k in pairs(W.dog.notifiedFields[farm] or {}) do out[#out + 1] = k end
  table.sort(out)
  return table.concat(out, ",")
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A LISTEN HOST ON FARM 1, FARM 2'S SICK BARN
-- ══════════════════════════════════════════════════════════════════════════
do
  T.eq("E0 [reached] main.lua's construction and update sites, each found once", nBuild .. "/" .. nTick, "1/1")
  local W = world()
  T.eq("E0b [reached] the dog is built by main.lua's own statement and published on the mission",
    tostring(W.dog ~= nil and W.mission.dogEarlyWarning == W.dog), "true")
  T.eq("E0c NAMED: the dog subscribes its own target to PLAYER_FARM_CHANGED, once", subscriberCount(W.dog), 1)
  tick(W, 59999)
  T.eq("E0d under the 60 s cadence nothing is read", #shown, 0)
  tick(W, 1)
  T.eq("E1 NAMED [entry point]: farm 2's sick barn sends no toast to farm 1's player", barnToasts(), 0)
  T.eq("E2 NAMED: on this machine getWarnings(2) is empty and getWarnings(1) has no farm 2 row",
    #W.dog:getWarnings(2) .. "/" .. ids(W.dog:getWarnings(1)), "0/")
  g_localPlayer.farmId = 2
  MC:publish(MessageType.PLAYER_FARM_CHANGED, g_localPlayer)
  scan(W)
  T.eq("E3 NAMED: after the local player's switch to farm 2, the next scan toasts farm 2's own barn once",
    barnToasts() .. "/" .. tostring(shown[1] and shown[1].msg), "1/Your dog senses something wrong at Barn BARN-TWO.")
  MC:publish(MessageType.PLAYER_FARM_CHANGED, g_localPlayer)   -- one switch can publish twice (PlayerSwitchedFarmEvent)
  scan(W)
  T.eq("E4 NAMED: a second publish of the same switch changes nothing: no second toast, the key kept",
    barnToasts() .. "/" .. keys(W, 2), "1/BARN-TWO_livestock")
  T.eq("E5 farm 2's own getter lists its barn, as fresh copies", ids(W.dog:getWarnings(2)), "BARN-TWO_livestock")
end

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE DEFECTS THE BRIEF NAMES (two-sided against development aaf0feaf)
-- ══════════════════════════════════════════════════════════════════════════
do
  -- The getter (DogEarlyWarning.lua:217-219 at the trunk): a fresh list of fresh rows, no binding.
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  scan(W)
  local a = W.dog:getWarnings(1)
  local rowsBefore = ids(a)
  if a[1] then a[1].fieldId = "CORRUPT" end
  a[#a + 1] = { fieldId = "INJECTED", type = "livestock" }
  T.eq("E2b NAMED: a request for another farm never gets the context farm's own rows", #W.dog:getWarnings(2), 0)
  T.eq("D1 NAMED: the getter's rows and list are detached copies and carry no binding",
    rowsBefore .. "/" .. ids(W.dog:getWarnings(1)) .. "/" .. tostring(W.dog:getWarnings(1)[1] and W.dog:getWarnings(1)[1]._binding),
    "BARN-ONE_livestock/BARN-ONE_livestock/nil")
end
do
  -- A missing HUD (:188 at the trunk marks the key before the call).
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  W.mission.hud = nil
  scan(W)
  local k = keys(W, 1)
  W.mission.hud = { showBlinkingWarning = function(_s, msg, ms) shown[#shown + 1] = { msg = msg, ms = ms } end }
  scan(W)
  T.eq("D2 NAMED: a missing HUD does not consume the barn key; the next scan with a HUD toasts once", k .. "/" .. barnToasts(), "/1")
  -- A HUD that throws.
  W = world({ farm = 1, ownSick = true, foreignSick = false })
  W.mission.hud = { showBlinkingWarning = function() error("hud down") end }
  scan(W)
  k = keys(W, 1)
  W.mission.hud = { showBlinkingWarning = function(_s, msg, ms) shown[#shown + 1] = { msg = msg, ms = ms } end }
  scan(W)
  T.eq("D3 NAMED: a HUD call that throws does not consume the barn key; the next scan toasts once", k .. "/" .. barnToasts(), "/1")
end
do
  -- Dog loss (:108-111 at the trunk returns without pruning).
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  scan(W)
  local first = barnToasts()
  W.mission.doghouses[W.dh1] = nil
  scan(W)
  local lost = keys(W, 1) .. "|" .. #W.dog:getWarnings(1)
  W.mission.doghouses[W.dh1] = true
  scan(W)
  T.eq("D4 NAMED: losing the dog clears the barn key and the rows; the regained dog warns again",
    first .. "/" .. lost .. "/" .. barnToasts(), "1/|0/2")
  W.mission.doghouses[W.dh1] = nil
  local between = #W.dog:getWarnings(1)
  W.mission.doghouses[W.dh1] = true
  T.eq("D4b NAMED: a dog lost between scans: the getter re-reads it and returns nothing, and nothing returns once it is back",
    between .. "/" .. #W.dog:getWarnings(1), "0/1")
end
do
  -- A nil field list (:118 at the trunk returns before the barn walk).
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  W.fields = nil
  scan(W)
  T.eq("D5 NAMED: an unavailable crop field list does not skip the barn walk: the own sick barn toasts",
    barnToasts() .. "/" .. ids(W.dog:getWarnings(1)), "1/BARN-ONE_livestock")
end
do
  -- Between scans: a transfer, then a pending deletion, then removal from the roster.
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  scan(W)
  W.barn1._farm = 2
  local transferred = #W.dog:getWarnings(1)
  W.barn1._farm = 1
  W.barn1.getIsBeingDeleted = function() return true end
  local deleting = #W.dog:getWarnings(1)
  W.barn1.getIsBeingDeleted = nil
  table.remove(W.placeables, 1)
  local removed = #W.dog:getWarnings(1)
  T.eq("D6 NAMED: a barn transferred, pending deletion or removed between scans is not returned", transferred .. "/" .. deleting .. "/" .. removed, "0/0/0")
  T.eq("D6b the getter filtering it changed no key", keys(W, 1), "BARN-ONE_livestock")
end

-- ══════════════════════════════════════════════════════════════════════════
-- M. THE MIXED CROP AND BARN CACHE
-- ══════════════════════════════════════════════════════════════════════════
do
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  W.fields = { { farmland = { id = 44 } } }
  W.fieldOwner[44] = 1
  W.cropInfo[44] = { activeDisease = "late_blight" }
  scan(W)
  T.eq("M0 [reached] a sick field and a sick barn: one crop and one barn toast, both keys", cropToasts() .. "/" .. barnToasts() .. "/" .. keys(W, 1), "1/1/44_crop,BARN-ONE_livestock")
  -- A crop walk that throws after partial work is unavailable: prior crop row and key stay.
  W.fields = { { farmland = { id = 44 } }, setmetatable({}, { __index = function() error("mid-walk") end }) }
  scan(W)
  T.eq("M1 NAMED: a crop walk that throws mid-way keeps the crop row and key and sends no crop toast; the barn slice still runs",
    cropToasts() .. "/" .. keys(W, 1) .. "/" .. ids(W.dog:getWarnings(1)), "1/44_crop,BARN-ONE_livestock/44_crop,BARN-ONE_livestock")
  -- A completed empty walk drops the crop key; a real recurrence warns again.
  W.fields = { { farmland = { id = 44 } } }
  W.cropInfo[44] = nil
  scan(W)
  local cleared = keys(W, 1)
  W.cropInfo[44] = { activeDisease = "late_blight" }
  scan(W)
  T.eq("M2 NAMED: a completed empty crop walk drops the crop key, and the recurrence warns again",
    cleared .. "/" .. cropToasts(), "BARN-ONE_livestock/2")
  W.fieldOwner[44] = 2
  local transferred = ids(W.dog:getWarnings(1))
  W.fieldOwner[44] = 1
  T.eq("M4 NAMED: a field transferred between scans is not returned (the CD-15 crop membership check)", transferred, "BARN-ONE_livestock")
  g_localPlayer.farmId = 2
  MC:publish(MessageType.PLAYER_FARM_CHANGED, g_localPlayer)
  T.eq("M5 NAMED: a farm switch clears farm 1's barn rows and key and keeps its crop row and crop key",
    keys(W, 1) .. "/" .. ids(W.dog.warnings[1]), "44_crop/44_crop")
  g_localPlayer.farmId = 1
end
do
  -- An unavailable crop walk keeps the crop keys even with no crop row to carry them: the dog's loss
  -- drops the farm's rows (the crop owner's existing early return) and keeps its crop key.
  local W = world({ farm = 1, foreignSick = false })
  W.fields = { { farmland = { id = 44 } } }
  W.fieldOwner[44] = 1
  W.cropInfo[44] = { activeDisease = "late_blight" }
  scan(W)
  W.mission.doghouses[W.dh1] = nil
  scan(W)
  W.mission.doghouses[W.dh1] = true
  W.fields = nil
  scan(W)
  local kept = keys(W, 1)
  W.fields = { { farmland = { id = 44 } } }
  scan(W)
  T.eq("M6 NAMED: an unavailable crop walk sends no crop toast and prunes no crop key, so the still-sick field does not warn twice",
    kept .. "/" .. cropToasts(), "44_crop/1")
end
do
  -- Two barns whose ids cannot be read share the fallback key barn_livestock.
  local a, b = barn(1, nil, true), barn(1, nil, true)
  local W = world({ farm = 1, foreignSick = false, extra = { a, b } })
  scan(W)
  local first = barnToasts() .. "|" .. keys(W, 1)
  a._farm = 2
  scan(W)
  local oneLeft = barnToasts() .. "|" .. keys(W, 1)
  b._farm = 2
  scan(W)
  local none = keys(W, 1)
  b._farm = 1
  scan(W)
  T.eq("M3 NAMED: the shared fallback key warns once, survives while any authorized barn uses it, goes with the last, and a returning barn warns again",
    first .. "/" .. oneLeft .. "/" .. none .. "/" .. barnToasts(), "1|barn_livestock/1|barn_livestock//2")
end

-- ══════════════════════════════════════════════════════════════════════════
-- T. TOPOLOGIES, PURITY, THE UPDATE-TIME CHECK, UNLOAD
-- ══════════════════════════════════════════════════════════════════════════
do
  local W = world({ player = false, ownSick = true })   -- a dedicated server: no local player, both barns sick
  scan(W)
  T.eq("T1 NAMED: a dedicated server presents no barn, of any farm, and returns empty lists", barnToasts() .. "/" .. #W.dog:getWarnings(1) .. "/" .. #W.dog:getWarnings(2), "0/0/0")
  W = world({ farm = 0 })               -- a spectator
  scan(W)
  T.eq("T2 a spectator (farm 0) sees and reads nothing", barnToasts() .. "/" .. #W.dog:getWarnings(0) .. "/" .. #W.dog:getWarnings(2), "0/0/0")
  -- A non-ordinary farm that does exist: the base game's guided-tour farm (FarmManager GUIDED_TOUR 14),
  -- with its own doghouse and a sick barn of its own.
  W = world({ farm = 14 })
  local dh14 = { getOwnerFarmId = function() return 14 end }
  W.mission.doghouses[dh14] = true
  W.placeables[#W.placeables + 1] = barn(14, "BARN-TOUR", true)
  g_farmManager = { getFarms = function() return { { farmId = 1 }, { farmId = 2 }, { farmId = 14 } } end }
  scan(W)
  T.eq("T2b NAMED: a player on a non-ordinary farm (the guided tour's 14) is no presentation context: its own sick barn shows nothing",
    barnToasts() .. "/" .. #W.dog:getWarnings(14), "0/0")
  W = world({ client = true, farm = 1 }) -- a pure client on farm 1
  scan(W)
  local internal2 = ids(W.dog.warnings[2])
  T.eq("T3 a pure client walks only its own farm's barns: farm 2's sick barn is never even cached", internal2 .. "/" .. barnToasts(), "/0")
end
do
  local W = world({ farm = 1, ownSick = true })   -- both barns sick: a listen host caches farm 2's too
  scan(W)
  local before = keys(W, 1) .. "|" .. ids(W.dog.warnings[1]) .. "|" .. tostring(W.dog.lastScan)
  W.dog:getWarnings(1); W.dog:getWarnings(2); W.dog:getWarnings(1)
  T.eq("T4 the getter is pure: keys, cache and cadence unchanged", keys(W, 1) .. "|" .. ids(W.dog.warnings[1]) .. "|" .. tostring(W.dog.lastScan), before)
  -- The farm changes without a publish (a late actor): the next frame clears before the cadence.
  g_localPlayer.farmId = 2
  T.eq("T5 NAMED: a context the update has not caught up with returns empty for both farms, never farm 2's cached barn",
    #W.dog:getWarnings(1) .. "/" .. #W.dog:getWarnings(2), "0/0")
  tick(W, 1)
  T.eq("T5b the update-time check, before the cadence return, clears the old farm's barn rows and key and keeps no foreign row",
    keys(W, 1) .. "|" .. ids(W.dog.warnings[1]) .. "|" .. barnToasts(), "||1")
end
do
  local W = world({ farm = 1, ownSick = true, foreignSick = false })
  scan(W)
  local other = { farmId = 2 }
  MC:publish(MessageType.PLAYER_FARM_CHANGED, other)
  T.eq("T6 another player's switch changes nothing here", keys(W, 1) .. "/" .. ids(W.dog:getWarnings(1)), "BARN-ONE_livestock/BARN-ONE_livestock")
  T.eq("T7 NAMED: main.lua's release site is found once", nRelease, 1)
  if RELEASE ~= nil then run(RELEASE, { dogWarning = W.dog }) end
  T.eq("T8 NAMED: at unload the dog's subscriber is released and every row and key is gone",
    subscriberCount(W.dog) .. "/" .. ids(W.dog.warnings[1]) .. "/" .. keys(W, 1), "0//")
end

do
  local W = world({ farm = 1, foreignSick = false })
  W.dog:_notify(1, { { fieldId = "BARN-ONE", type = "livestock" } })
  W.dog.warnings[1] = { { fieldId = "BARN-ONE", type = "livestock" } }
  T.eq("T9 NAMED: a barn row with no binding (a display id alone) is never toasted or returned", barnToasts() .. "/" .. #W.dog:getWarnings(1), "0/0")
  local shed = { getOwnerFarmId = function() return 1 end }   -- in the roster, owned by farm 1, not a husbandry
  W.placeables[#W.placeables + 1] = shed
  W.dog:_notify(1, { { fieldId = "SHED", type = "livestock", _binding = shed } })
  W.dog.warnings[1] = { { fieldId = "SHED", type = "livestock", _binding = shed } }
  T.eq("T9b NAMED: a row bound to a placeable that is not a husbandry is never toasted or returned", barnToasts() .. "/" .. #W.dog:getWarnings(1), "0/0")
end

T.eq("strings unchanged: barn fallback", DogEarlyWarning.BARN_WARNING_FALLBACK, "Your dog senses something wrong at Barn %s.")
T.eq("cadence unchanged", DogEarlyWarning.CADENCE_MS, 60000)

g_currentMission, g_farmManager, g_farmlandManager, g_localPlayer, g_messageCenter, g_diseaseManager, g_server = nil, nil, nil, nil, nil, nil, nil

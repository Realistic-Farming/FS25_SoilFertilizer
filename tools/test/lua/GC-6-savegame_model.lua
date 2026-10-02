-- GC-6-savegame_model.lua - the native save path, MODELED for Soil's native save boundary.
--
-- NOT A TEST. Loaded first in --!load, in the REAL global table (the runner's --!env: modenv
-- switch comes after the tools/ models), where the engine's own scripts and C functions
-- live. Ported from FS25_StockGuard's SG2-4a-savegame_model.lua (the same controller, the
-- same C side) without its vehicle half.
--
-- SavegameController (SavegameController.lua, byte-identical in 1.21.1.0 and 1.24.0.0):
--   :328-333 addSaveTask and :334-343 executeSaveTask VERBATIM for the density-map task;
--   :366-372 onSaveTaskComplete VERBATIM; :373-436 onSaveStartComplete with the career XML
--   call (:384), the fruit and haulm branch (:392-423) and the height branch (:556-568)
--   VERBATIM, then executeSaveTask (:588-595); the writes between them that touch neither
--   the career chain nor the height map are OMITTED; :672-690 onSaveComplete reduced to its
--   state, directory and callback; :700-727 saveSavegame reduced to its state and start call.
-- FSCareerMissionInfo: :425-431 setSavegameDirectory, and a saveToXMLFile that writes
--   careerSavegame.xml; ENGINE_CAREER_HOOK, when set, runs at the end of the chain body,
--   where every module's append runs (Soil's saveSoilData among them in a game).
-- C functions, MODELED: saveWriteSavegameStart calls the named callback with a staging
--   directory; saveWriteSavegameFinish moves the staged files to the final directory and
--   then calls the named callback (a later frame unless ENGINE_SAVE.finishSync);
--   prepareSaveDensityMapToFile captures a map's CURRENT image version,
--   savePreparedDensityMapToFile writes the captured one and completes on a later frame,
--   saveDensityMapToFile writes the current one directly. Each map carries a version the
--   bench bumps to move the world, so the disk shows which moment's image was written.
-- g_asyncTaskManager, MODELED: one task per frame; ENGINE_RUN_FRAMES runs the queue.

Savegame = Savegame or {}
Savegame.ERROR_OK = 0
Savegame.ERROR_WRITE = 7

ENGINE_DISK = {}

-- ── the density maps ────────────────────────────────────────────────────────────
ENGINE_HEIGHT_ID = 900
ENGINE_MAPS = {
    [1] = { filename = "densityMap_fruits.gdm", version = 1 },
    [3] = { filename = "densityMap_grass.gdm", version = 1 },
    [4] = { filename = "densityMap_grassHaulm.gdm", version = 1 },
    [ENGINE_HEIGHT_ID] = { filename = "densityMap_height.gdm", version = 1 },
}
function getDensityMapFilename(id) local m = ENGINE_MAPS[id] return m ~= nil and m.filename or nil end
ENGINE_FRUIT_DESCS = {
    { index = 1, name = "WHEAT", terrainDataPlaneId = 1, terrainDataPlaneIdHaulm = nil },
    { index = 2, name = "BARLEY", terrainDataPlaneId = 1, terrainDataPlaneIdHaulm = nil },
    { index = 20, name = "GRASS", terrainDataPlaneId = 3, terrainDataPlaneIdHaulm = 4 },
}
g_fruitTypeManager.getFruitTypes = function() return ENGINE_FRUIT_DESCS end

ENGINE_PREPARED = {}
ENGINE_PREPARE_LOG = {}
ENGINE_DIRECT_LOG = {}
function prepareSaveDensityMapToFile(id, path)
    ENGINE_PREPARE_LOG[#ENGINE_PREPARE_LOG + 1] = { id = id, path = path, version = ENGINE_MAPS[id].version }
    ENGINE_PREPARED[id] = { version = ENGINE_MAPS[id].version, path = path }
end
function saveDensityMapToFile(id, path)
    ENGINE_DIRECT_LOG[#ENGINE_DIRECT_LOG + 1] = { id = id, path = path, version = ENGINE_MAPS[id].version }
    ENGINE_DISK[path] = { image = id, version = ENGINE_MAPS[id].version }
end
function savePreparedDensityMapToFile(id, callbackName, target)
    local p = ENGINE_PREPARED[id]
    if p ~= nil then
        ENGINE_DISK[p.path] = { image = id, version = p.version }
        ENGINE_PREPARED[id] = nil
    end
    g_asyncTaskManager:addTask(function() target[callbackName](target, true) end)
end

-- ── the async task manager ──────────────────────────────────────────────────────
g_asyncTaskManager = { tasks = {} }
function g_asyncTaskManager:addTask(fn) self.tasks[#self.tasks + 1] = fn end
function g_asyncTaskManager:setAllowedTimePerFrame(_) end
function ENGINE_RUN_FRAMES(between, limit)
    local frame = 0
    while #g_asyncTaskManager.tasks > 0 and frame < (limit or 1000) do
        frame = frame + 1
        if between ~= nil then between(frame) end
        local fn = table.remove(g_asyncTaskManager.tasks, 1)
        fn()
    end
    return frame
end

-- ── the savegame C functions ────────────────────────────────────────────────────
ENGINE_SAVE = { stagingPrefix = "staging", finalDir = nil, startError = nil, finishError = nil, errorAfterMove = false, finishSync = false }
function saveWriteSavegameStart(index, _name, _maxSize, callbackName, target)
    local staging = ENGINE_SAVE.stagingPrefix .. tostring(index)
    target[callbackName](target, ENGINE_SAVE.startError or Savegame.ERROR_OK, ENGINE_SAVE.startError == nil and staging or nil)
end
local function moveStaged(staging, final)
    local moves = {}
    for path, data in pairs(ENGINE_DISK) do
        if path:sub(1, #staging + 1) == staging .. "/" then moves[path] = data end
    end
    for path, data in pairs(moves) do
        ENGINE_DISK[final .. path:sub(#staging + 1)] = data
        ENGINE_DISK[path] = nil
    end
end
function saveWriteSavegameFinish(_metadata, _desc, callbackName, target)
    local savegame = target.currentSavegame
    local staging = savegame.savegameDirectory
    local final = ENGINE_SAVE.finalDir
    local errorCode = ENGINE_SAVE.finishError or Savegame.ERROR_OK
    local moved = errorCode == Savegame.ERROR_OK or ENGINE_SAVE.errorAfterMove == true
    local function complete()
        if moved then moveStaged(staging, final) end
        target[callbackName](target, errorCode, moved and final or nil)
    end
    if ENGINE_SAVE.finishSync then complete() else g_asyncTaskManager:addTask(complete) end
end
function startFrameRepeatMode() return false end
function endFrameRepeatMode() end

-- ── FSCareerMissionInfo (the career save) ──────────────────────────────────────
FSCareerMissionInfo = FSCareerMissionInfo or {}
FSCareerMissionInfo.__index = FSCareerMissionInfo
function FSCareerMissionInfo.new(fields) return setmetatable(fields or {}, FSCareerMissionInfo) end
function FSCareerMissionInfo:setSavegameDirectory(directory) self.savegameDirectory = directory end
ENGINE_CAREER_HOOK = nil
ENGINE_CAREER_CALLS = 0
function FSCareerMissionInfo:saveToXMLFile()
    ENGINE_CAREER_CALLS = ENGINE_CAREER_CALLS + 1
    ENGINE_DISK[self.savegameDirectory .. "/careerSavegame.xml"] = { mapId = self.mapId, heightVersion = ENGINE_MAPS[ENGINE_HEIGHT_ID].version }
    if ENGINE_CAREER_HOOK ~= nil then ENGINE_CAREER_HOOK(self) end
end

-- ── SavegameController ──────────────────────────────────────────────────────────
SavegameController = SavegameController or {}
SavegameController.__index = SavegameController
SavegameController.SAVE_TASK_DENSITY_MAP = 0
function SavegameController.new()
    local self = setmetatable({}, SavegameController)
    self.isSavingGame = false
    self.savingErrorCode = Savegame.ERROR_OK
    self.completed = {}
    self.onSaveCompleteCallback = function(target, errorCode) target.completed[#target.completed + 1] = errorCode end
    self.onSaveCompleteCallbackTarget = self
    return self
end
--- :700-727, reduced.
function SavegameController:saveSavegame(savegame, blocking)
    self.isSavingGame = true
    self.isSavingBlocking = blocking
    self.currentSavegame = savegame
    saveWriteSavegameStart(savegame.savegameIndex, savegame.savegameName, 0, "onSaveStartComplete", self)
end
--- :328-333 VERBATIM.
function SavegameController:addSaveTask(taskType, taskParam)
    table.insert(self.saveTasks, { ["type"] = taskType, ["param"] = taskParam })
end
--- :334-343 VERBATIM (the density-map task).
function SavegameController:executeSaveTask()
    if self.currentSaveTask > #self.saveTasks then
        self:onSaveTaskComplete(true)
        return
    else
        local taskData = self.saveTasks[self.currentSaveTask]
        self.currentSaveTask = self.currentSaveTask + 1
        if taskData.type == SavegameController.SAVE_TASK_DENSITY_MAP then
            savePreparedDensityMapToFile(taskData.param, "onSaveTaskComplete", self)
            return
        end
    end
end
--- :366-372 VERBATIM.
function SavegameController:onSaveTaskComplete(_)
    if self.currentSaveTask > #self.saveTasks then
        saveWriteSavegameFinish(self.savegameMetadata, self.savegameDisplayDesc, "onSaveComplete", self)
    else
        self:executeSaveTask()
    end
end
--- :373-436, the modeled branches VERBATIM.
function SavegameController:onSaveStartComplete(errorCode, savegameDirectory)
    self.savingErrorCode = errorCode
    if errorCode == Savegame.ERROR_OK and savegameDirectory ~= nil then
        local startedRepeat = false
        if self.isSavingBlocking then
            startedRepeat = startFrameRepeatMode()
        end
        self.saveTasks = {}
        self.currentSaveTask = 1
        local savegame = self.currentSavegame
        savegame:setSavegameDirectory(savegameDirectory)
        savegame:saveToXMLFile()
        local dir = savegame.savegameDirectory
        local savedDensityMaps = {}
        for _, fruitTypeDesc in pairs(g_fruitTypeManager:getFruitTypes()) do
            local id = fruitTypeDesc.terrainDataPlaneId
            local haulmId = fruitTypeDesc.terrainDataPlaneIdHaulm
            if id ~= nil then
                local filename = getDensityMapFilename(id)
                if savedDensityMaps[filename] == nil then
                    savedDensityMaps[filename] = true
                    if self.isSavingBlocking then
                        saveDensityMapToFile(id, dir .. "/" .. filename)
                    else
                        g_asyncTaskManager:addTask(function()
                            prepareSaveDensityMapToFile(id, dir .. "/" .. filename)
                            self:addSaveTask(SavegameController.SAVE_TASK_DENSITY_MAP, id)
                        end)
                    end
                end
            end
            if haulmId ~= nil then
                local filename = getDensityMapFilename(haulmId)
                if savedDensityMaps[filename] == nil then
                    savedDensityMaps[filename] = true
                    if self.isSavingBlocking then
                        saveDensityMapToFile(haulmId, dir .. "/" .. filename)
                    else
                        g_asyncTaskManager:addTask(function()
                            prepareSaveDensityMapToFile(haulmId, dir .. "/" .. filename)
                            self:addSaveTask(SavegameController.SAVE_TASK_DENSITY_MAP, haulmId)
                        end)
                    end
                end
            end
        end
        local heightFilename = getDensityMapFilename(g_currentMission.terrainDetailHeightId)
        if heightFilename ~= nil and savedDensityMaps[heightFilename] == nil then
            savedDensityMaps[heightFilename] = true
            if self.isSavingBlocking then
                saveDensityMapToFile(g_currentMission.terrainDetailHeightId, dir .. "/" .. heightFilename)
            else
                g_asyncTaskManager:addTask(function()
                    prepareSaveDensityMapToFile(g_currentMission.terrainDetailHeightId, dir .. "/" .. heightFilename)
                    self:addSaveTask(SavegameController.SAVE_TASK_DENSITY_MAP, g_currentMission.terrainDetailHeightId)
                end)
            end
        end
        if self.isSavingBlocking then
            self:executeSaveTask()
        else
            g_asyncTaskManager:addTask(function()
                self:executeSaveTask()
            end)
        end
        if startedRepeat then
            endFrameRepeatMode()
            return
        end
    else
        self:onSaveComplete(errorCode)
    end
end
--- :672-690, reduced to the state, the directory and the callback.
function SavegameController:onSaveComplete(errorCode, finalSavegameDirectory)
    self.savingErrorCode = errorCode
    self.isSavingGame = false
    local savegame = self.currentSavegame
    if savegame ~= nil and finalSavegameDirectory ~= nil and finalSavegameDirectory ~= "" then
        savegame:setSavegameDirectory(finalSavegameDirectory)
    end
    self.onSaveCompleteCallback(self.onSaveCompleteCallbackTarget, errorCode)
end

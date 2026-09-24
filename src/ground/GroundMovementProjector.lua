--
-- GroundMovementProjector
--
-- RSF-F208, contract section 2, one projector for both observers: the per-cell
-- projection of a completed native primitive onto the Soil condition cells, shared
-- by the Soil-alone movement carriers (GroundMovementCarrier, section 3) and the
-- StockGuard lease path (GroundConditionAdmission, section 7). Iris's answer 2 of
-- 2026-09-23: Soil owns native-to-Soil projection and shares its owner projection
-- with its standalone observer; StockGuard never runs a second one.
--
-- WHAT IS PROJECTED, per cell and per primitive, from the cell's WHOLE occupancy
-- before and after (GroundNativeObserver.readCell), never from the brush's pixels:
--   * a PICKUP moves each source cell's pre-removal condition out, by the litres that
--     cell actually lost, to a sink the caller supplies (the carrier's account; the
--     lease's collected list); a cell is cleared only when its whole-cell occupancy
--     is known to be zero afterwards, and a partial removal keeps its condition;
--   * a DROP lands a mixture the caller supplies where the cells actually gained,
--     combined with what survived there through the coordinator's conservative
--     combine; litres the mixture cannot explain are of unknown condition;
--   * a REDISTRIBUTION (smoothing, levelling, an area cleared) feeds what the losing
--     cells lost, with their captured condition, litre-weighted, onto the cells that
--     gained in the same primitive; a gain nothing explains is unknown;
--   * a CONVERSION (a type change in place) is incoming material of unknown condition
--     unless a registered conversion basis vouches for it; Soil registers none, so it
--     propagates unknown (contract section 2, "unexplained native conversion").
-- An unreadable occupancy is never permission to clear and never a source that can be
-- priced: the cell is marked unavailable. Parts that do not account for the native
-- whole-cell occupancy are marked unavailable rather than vouched for.
--
-- THE CONTEXT is whatever the caller has: { coordinator, cells, geometry, stats }.
-- A carrier frame is one; a lease's delivery context is another. `stats`, when
-- present, takes the projected / cleared / unavailable counts.
--

GroundMovementProjector = GroundMovementProjector or {}
local P = GroundMovementProjector

P.EPSILON = 1e-3
-- A cell's observed litres may differ from the native return by the density map's
-- quantisation; below this the difference is treated as none.
P.TOLERANCE = 1

local function bump(ctx, key)
    local st = ctx.stats
    if type(st) == "table" and type(st[key]) == "number" then st[key] = st[key] + 1 end
end

--- The condition record a cell holds now, or nils when it cannot be vouched for.
function P.cellCondition(ctx, gx, gz)
    if ctx.coordinator:isUnavailable(gx, gz) then return nil, nil end
    local rec = ctx.cells:readConditionCell(ctx.geometry, gx, gz)
    if rec == nil or rec.refused ~= nil or not rec.ageAvailable or not rec.wetnessAvailable then return nil, nil end
    return rec.ageRaw, rec.wetnessRaw
end

--- Capture the pre-removal condition of every cell a primitive may touch. Runs
--- BEFORE the native call (contract section 2), on the cells the envelope named.
function P.captureCells(ctx, cells)
    for _, cell in ipairs(cells or {}) do
        cell.ageRaw, cell.wetnessRaw = P.cellCondition(ctx, cell.gx, cell.gz)
    end
end

function P.markUnavailable(ctx, cell, reason)
    ctx.coordinator:markUnavailable(cell.gx, cell.gz, reason)
    bump(ctx, "unavailable")
end

--- Every cell the primitive covers goes unavailable: an envelope too large to read,
--- a native throw, a refused barrier's changed cells. Bytes are kept, never cleared
--- or invented (contract section 2).
function P.markAll(ctx, cells, reason)
    local n = 0
    for _, cell in ipairs(cells or {}) do
        P.markUnavailable(ctx, cell, reason)
        n = n + 1
    end
    return n
end

local function clearIfEmpty(ctx, cell)
    if (cell.afterWhole or 0) <= P.EPSILON then
        local cleared = ctx.coordinator:clearCellIfEmpty(ctx.geometry, cell.gx, cell.gz, { known = true, positive = false })
        if cleared then bump(ctx, "cleared") return true end
    end
    return false
end

--- A PICKUP of `ft`. `sink(litres, ageRaw, wetnessRaw)` receives each source cell's
--- removal with its captured condition. Returns the litres the cells account for; the
--- caller prices what the native call took beyond that as unknown.
---@return number seen, table counts { projected, cleared, unavailable }
function P.pickup(ctx, cells, ft, sink)
    local seen = 0
    local counts = { projected = 0, cleared = 0, unavailable = 0 }
    for _, cell in ipairs(cells or {}) do
        local b, a = cell.before, cell.after
        if b == nil or a == nil then
            -- Unreadable occupancy: not permission to clear, not a source we can price.
            P.markUnavailable(ctx, cell, "OCCUPANCY_UNKNOWN")
            counts.unavailable = counts.unavailable + 1
        else
            local removed = (b[ft] or 0) - (a[ft] or 0)
            if removed > P.EPSILON then
                seen = seen + removed
                if type(sink) == "function" then sink(removed, cell.ageRaw, cell.wetnessRaw) end
                if clearIfEmpty(ctx, cell) then counts.cleared = counts.cleared + 1 end
            end
        end
    end
    return seen, counts
end

--- Land `contributions` on one cell that gained `arrived` litres, combined with what
--- survived there (the cell's WHOLE occupancy before the primitive, contract section
--- 2). The parts must account for the native whole-cell occupancy afterwards, or the
--- projection cannot be vouched for.
---@return string outcome  "PROJECTED" | "MISMATCH" | "REFUSED" | "EMPTY"
local function land(ctx, cell, arrived, contributions)
    local surviving = cell.beforeWhole or 0
    if math.abs(surviving + arrived - (cell.afterWhole or 0)) > P.TOLERANCE then
        P.markUnavailable(ctx, cell, "OCCUPANCY_MISMATCH")
        return "MISMATCH"
    end
    local destination = { occupied = surviving > P.EPSILON, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }
    local combined = GroundConditionCoordinator.combine(destination, contributions)
    if combined.empty then return "EMPTY" end
    local ok = ctx.coordinator:applyProjection(ctx.geometry, cell.gx, cell.gz, combined)
    if ok then bump(ctx, "projected") return "PROJECTED" end
    return "REFUSED"
end

--- The share of a mixture that `arrived` litres carry: each component scaled by
--- arrived / total, plus an unknown component for litres the mixture cannot explain.
local function share(mixture, total, arrived)
    local contributions = {}
    if total > P.EPSILON then
        for _, m in ipairs(mixture) do
            contributions[#contributions + 1] = { litres = m.litres * arrived / total, ageRaw = m.ageRaw, wetnessRaw = m.wetnessRaw }
        end
    else
        contributions[1] = { litres = arrived, ageRaw = nil, wetnessRaw = nil }
    end
    return contributions
end

--- A DROP of `ft`: `mixture` ({ { litres, ageRaw, wetnessRaw }, ... }, already aged
--- by the caller) totalling `total` lands where the cells gained. An empty mixture is
--- material of unknown condition, which is what a drop from carried stock Soil never
--- captured is (the StockGuard path today).
---@return table counts { projected, unavailable, refused }
function P.drop(ctx, cells, ft, mixture, total)
    mixture, total = mixture or {}, tonumber(total) or 0
    local counts = { projected = 0, unavailable = 0, refused = 0 }
    for _, cell in ipairs(cells or {}) do
        local b, a = cell.before, cell.after
        if b == nil or a == nil then
            P.markUnavailable(ctx, cell, "OCCUPANCY_UNKNOWN")
            counts.unavailable = counts.unavailable + 1
        else
            local arrived = (a[ft] or 0) - (b[ft] or 0)
            if arrived > P.EPSILON then
                local outcome = land(ctx, cell, arrived, share(mixture, total, arrived))
                if outcome == "PROJECTED" then counts.projected = counts.projected + 1
                elseif outcome == "MISMATCH" then counts.unavailable = counts.unavailable + 1
                elseif outcome == "REFUSED" then counts.refused = counts.refused + 1 end
            end
        end
    end
    return counts
end

--- A REDISTRIBUTION within one primitive (smoothing, levelling, an area cleared):
--- measured on the WHOLE cell. Losing cells feed a pool with their captured
--- condition; gaining cells draw from it litre-weighted; a gain the pool cannot
--- explain is unknown; a cell at known whole-zero afterwards is cleared and a
--- partial loss keeps its condition. Contract section 2 (Bob's intake, 2026-09-23):
--- the arriving condition of moved material is the litre-weighted pre-removal
--- condition of the cells that lost it in the same primitive.
---@return table counts { projected, cleared, unavailable, refused }
function P.redistribute(ctx, cells)
    local counts = { projected = 0, cleared = 0, unavailable = 0, refused = 0 }
    local pool, total, gainers = {}, 0, {}
    for _, cell in ipairs(cells or {}) do
        if cell.before == nil or cell.after == nil then
            P.markUnavailable(ctx, cell, "OCCUPANCY_UNKNOWN")
            counts.unavailable = counts.unavailable + 1
        else
            local lost = (cell.beforeWhole or 0) - (cell.afterWhole or 0)
            if lost > P.EPSILON then
                pool[#pool + 1] = { litres = lost, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }
                total = total + lost
                if clearIfEmpty(ctx, cell) then counts.cleared = counts.cleared + 1 end
            elseif lost < -P.EPSILON then
                gainers[#gainers + 1] = cell
            end
        end
    end
    for _, cell in ipairs(gainers) do
        local arrived = (cell.afterWhole or 0) - (cell.beforeWhole or 0)
        local outcome = land(ctx, cell, arrived, share(pool, total, arrived))
        if outcome == "PROJECTED" then counts.projected = counts.projected + 1
        elseif outcome == "MISMATCH" then counts.unavailable = counts.unavailable + 1
        elseif outcome == "REFUSED" then counts.refused = counts.refused + 1 end
    end
    return counts
end

--- A CONVERSION in place: the litres of `toFt` that appeared in a cell are incoming
--- material. With no registered conversion basis their condition is unknown, and the
--- conservative combine makes the cell's component unknown (contract section 2:
--- unexplained native conversion). `basisKnown` is false for every basis today; when
--- Soil registers one, the converted litres carry the cell's captured condition.
---@return table counts { projected, unavailable, refused }
function P.convert(ctx, cells, fromFt, toFt, basisKnown)
    local counts = { projected = 0, unavailable = 0, refused = 0 }
    for _, cell in ipairs(cells or {}) do
        local b, a = cell.before, cell.after
        if b == nil or a == nil then
            P.markUnavailable(ctx, cell, "OCCUPANCY_UNKNOWN")
            counts.unavailable = counts.unavailable + 1
        else
            local converted = (a[toFt] or 0) - (b[toFt] or 0)
            if converted > P.EPSILON then
                local contribution
                if basisKnown then
                    contribution = { { litres = converted, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw } }
                else
                    contribution = { { litres = converted, ageRaw = nil, wetnessRaw = nil } }
                end
                -- The material never left the cell: what survives is the whole cell
                -- minus what changed type, and the whole occupancy is unchanged.
                local surviving = (cell.beforeWhole or 0) - converted
                local destination = { occupied = surviving > P.EPSILON, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }
                local combined = GroundConditionCoordinator.combine(destination, contribution)
                if not combined.empty then
                    local ok = ctx.coordinator:applyProjection(ctx.geometry, cell.gx, cell.gz, combined)
                    if ok then bump(ctx, "projected") counts.projected = counts.projected + 1
                    else counts.refused = counts.refused + 1 end
                end
            end
        end
    end
    return counts
end

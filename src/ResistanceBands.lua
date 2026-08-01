-- ResistanceBands.lua - CD-11: the resistance DATA CONTRACT (server -> client).
--
-- CD-9 simulates per-field per-mode fungicide resistance and persists it four ways, but
-- no client could ever see it: `resistance` occurred zero times in NetworkEvents.lua, and
-- every field-sync handler replaces a client's field table WHOLESALE, so even a stream-only
-- addition would have been wiped by the next broadcast. This module is the missing fifth
-- path, to the client (F67's consequence for this family).
--
-- THE SHAPE, and why it is this shape:
--   * The SERVER computes a BAND from the raw score. A client never computes a band from a
--     raw value and never receives one -- that is the multiplayer principle this system
--     exists to hold. Every render path goes through bandFromRatio here, so a server and a
--     client can never disagree about where a cut point sits.
--   * UNKNOWN is a VALUE, not an absence. A field the player has never scouted, and a field
--     whose bands have not arrived yet, both read UNKNOWN. Nothing may treat a missing
--     entry as WORKING; that would render "your fungicide is fine" about ground nobody has
--     looked at, which is the exact failure the contract forbids.
--
-- This module is a PURE READER of field.resistance. It never writes it. The only state it
-- introduces is field.resistanceBands on the CLIENT, populated solely from server values.
--
-- Precedent followed deliberately: OrganicCertification's encode/apply pair (F54, fixed
-- 2026-07-24), which solved this identical problem -- a field-scoped value that had to
-- survive the wholesale-replace handlers. Bands ride every payload the way organic does
-- rather than being side-cached, because a value that travels cannot be wiped by a replace.

ResistanceBands = {}

local BANDS = SoilConstants.RESISTANCE.BANDS

--- The resistance ceiling for a FRAC mode. Naturals cap lower than synthetics.
---
--- Reads RESISTANCE.NATURAL_MODES, which is keyed by MODE. The CD-11 brief's pseudocode
--- calls isNaturalFungicide(mode) here; that takes a fill-type NAME, so it returns false for
--- every mode and would band a saturated natural against the synthetic ceiling. The
--- constant carries the mapping instead, and the suite asserts it matches CD-9's own.
---@param mode string   FRAC group ("3", "11", "M2", ...)
---@return number
function ResistanceBands.ceilingForMode(mode)
    if SoilConstants.RESISTANCE.NATURAL_MODES[mode] then
        return SoilConstants.RESISTANCE.MAX_NATURAL
    end
    return SoilConstants.RESISTANCE.MAX_SYNTHETIC
end

--- Map a fraction-of-ceiling to a band. THE single band authority: server and client both
--- call this, so a display discrepancy cannot arise from divergent band math.
---@param ratio number  score / ceiling
---@return number       a RESISTANCE.BANDS value (never UNKNOWN; that is a gate outcome)
function ResistanceBands.bandFromRatio(ratio)
    local R = SoilConstants.RESISTANCE
    if (ratio or 0) >= R.BAND_CUT_FINISHED then return BANDS.FINISHED end
    if (ratio or 0) >= R.BAND_CUT_SLIPPING then return BANDS.SLIPPING end
    return BANDS.WORKING
end

--- True when this field's resistance may be shown to the player at all.
---
-- THE GATE, and its one known limitation, stated rather than hidden.
--
-- The brief asks this gate to key on a FIELD-LEVEL "has this field ever been scouted"
-- signal, independent of the per-outbreak diseaseDiscovered flag. NO SUCH SIGNAL EXISTS in
-- the shipped source -- diseaseDiscovered is the only scout state a field carries, and it
-- resets on every fresh infection (SoilFertilitySystem.lua:2126, :2364). That is the
-- confirm the brief owed back to Engineering, and the answer is "there is none".
--
-- So this gate uses diseaseDiscovered ALONE. It deliberately does NOT copy getScoutReport's
-- published expression (`field.activeDisease and not field.diseaseDiscovered`), which the
-- brief names as inverted: a field with no active disease falls straight through that and
-- reads as fully scouted. Keying on diseaseDiscovered alone FAILS CLOSED instead -- an
-- unscouted field reads UNKNOWN whether or not it currently has a disease, which is the
-- hard obligation (the server must never send a clean-looking band for unscouted ground).
--
-- THE INHERITED DEFECT, flagged so it is not mistaken for correct: because
-- diseaseDiscovered resets on every fresh infection, a farmer's resistance history goes
-- DARK exactly when a new outbreak starts, even though resistance itself persists across
-- infections and has not changed. Over-hiding, never under-hiding. Fixing it means adding a
-- field-level scouted signal to CD-9's data model, which is not this brief's to extend.
---@param field table
---@return boolean
function ResistanceBands.isFieldRevealed(field)
    return (field ~= nil) and (field.diseaseDiscovered == true)
end

--- True when this machine owns the raw scores: the server, a listen-server host, or single
--- player. False on a pure client, which may only ever read what the server sent.
---@return boolean
function ResistanceBands.hasServerPicture()
    return g_server ~= nil
end

--- Server-side: the band for one mode on one field, computed from the raw score.
---
--- A revealed field with NO entry for a mode has zero resistance on it by definition, so it
--- bands WORKING rather than UNKNOWN. That is truthful -- the player has scouted this
--- ground and has never burned that mode -- and it keeps the server and client answers
--- identical for the same field state.
---@return number   a RESISTANCE.BANDS value, UNKNOWN only when the gate closes
function ResistanceBands.computeBand(field, mode)
    if not ResistanceBands.isFieldRevealed(field) then return BANDS.UNKNOWN end
    local scores = field.resistance
    local score = (type(scores) == "table" and scores[mode]) or 0
    return ResistanceBands.bandFromRatio(score / ResistanceBands.ceilingForMode(mode))
end

--- Server-side: every band this field may publish, as a flat { mode, band, mode, band, ... }
--- array ready for the wire. Returns an EMPTY array for a gated field, so an unscouted
--- field sends nothing at all rather than sending something a client has to interpret.
---
--- Bounded by the FRAC-group count (seven today), not by field history.
---@param field table
---@return table   flat array, always even-length
function ResistanceBands.encodeFieldBands(field)
    local out = {}
    if not ResistanceBands.isFieldRevealed(field) then return out end
    local scores = field and field.resistance
    if type(scores) ~= "table" then return out end
    for mode, score in pairs(scores) do
        if type(mode) == "string" and type(score) == "number" and score > 0 then
            out[#out + 1] = mode
            out[#out + 1] = ResistanceBands.bandFromRatio(score / ResistanceBands.ceilingForMode(mode))
        end
    end
    return out
end

--- Client-side: attach a decoded band list onto a field table so run()'s wholesale replace
--- carries it. Mirrors OrganicCertification.applyFieldOrganic: a field with nothing to say
--- keeps no sub-table, so the wire never resurrects one where the model would not.
---@param field table
---@param flat table|nil   flat { mode, band, ... } array as produced by encodeFieldBands
function ResistanceBands.applyFieldBands(field, flat)
    if not field then return end
    if type(flat) ~= "table" or #flat < 2 then
        field.resistanceBands = nil
        return
    end
    local bands = {}
    for i = 1, #flat - 1, 2 do
        local mode, band = flat[i], tonumber(flat[i + 1])
        if type(mode) == "string" and mode ~= "" and band ~= nil then
            -- Clamp to the known enum: a malformed or hostile packet must not invent a band.
            if band >= BANDS.WORKING and band <= BANDS.FINISHED then
                bands[mode] = band
            end
        end
    end
    field.resistanceBands = next(bands) and bands or nil
end

-- A revealed field can publish at most one band per FRAC group (seven exist today). The
-- read cap is a malformed/hostile-packet guard, not a design limit: it only bounds how many
-- entries a reader will pull before giving up, and is generous enough that a legitimate
-- payload can never reach it.
local MAX_WIRE_BANDS = 32

--- Write this field's bands onto a stream. Symmetric with readStream; both must be called
--- at the SAME position in every payload that carries them.
function ResistanceBands.writeStream(streamId, field)
    local flat = ResistanceBands.encodeFieldBands(field)
    local n = math.floor(#flat / 2)
    streamWriteInt32(streamId, n)
    for i = 1, n * 2 - 1, 2 do
        streamWriteString(streamId, flat[i])
        streamWriteInt32(streamId, flat[i + 1])
    end
end

--- Read a band list off a stream. Always consumes exactly what writeStream wrote, so a
--- field with no bands still costs one int and never desynchronises the reader.
---@return table   flat { mode, band, ... } array for applyFieldBands
function ResistanceBands.readStream(streamId)
    local n = streamReadInt32(streamId) or 0
    if n < 0 then n = 0 end
    if n > MAX_WIRE_BANDS then n = MAX_WIRE_BANDS end
    local flat = {}
    for _ = 1, n do
        flat[#flat + 1] = streamReadString(streamId)
        flat[#flat + 1] = streamReadInt32(streamId)
    end
    return flat
end

--- THE PUBLIC READ SURFACE. The whole contract the presentation build consumes.
---
--- Resolves against whichever picture this machine actually has:
---   * server or single player -- computes from the raw score it owns;
---   * client -- reads the band the server sent, and NEVER computes one from a raw value.
---
--- Returns UNKNOWN, never nil, for unscouted ground, an unsynced field, or a mode with no
--- resistance yet. Callers must treat UNKNOWN as distinct from every real band.
---@param field table|nil
---@param mode string
---@return number   a RESISTANCE.BANDS value
function ResistanceBands.getBand(field, mode)
    if not field or not mode then return BANDS.UNKNOWN end
    if not ResistanceBands.isFieldRevealed(field) then return BANDS.UNKNOWN end

    -- What the server sent is authoritative wherever it exists.
    local sent = field.resistanceBands
    if type(sent) == "table" and sent[mode] ~= nil then return sent[mode] end

    -- Server, listen-server host, or single player: the raw score is ours to band.
    if ResistanceBands.hasServerPicture() then
        return ResistanceBands.computeBand(field, mode)
    end

    -- Pure client, field revealed, no band sent for this mode. LOAD-BEARING COUPLING:
    -- encodeFieldBands publishes every mode carrying resistance on a revealed field and is
    -- bounded by the FRAC-group count, so it has no truncation path -- silence therefore
    -- means "zero on that mode", not "not sent". Anything that ever makes the encoder drop
    -- a non-zero mode (a payload budget, a partial update) MUST revisit this line, or a
    -- burned-out mode would render as WORKING on every client.
    return BANDS.WORKING
end

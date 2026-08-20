--[[
    History - save/trim/delete for CombatLedgerDB.encounters. Most-recent-
    first, capped at CL.MAX_ENCOUNTERS (trim-oldest).

    Reads/writes the CombatLedgerDB global directly rather than through
    CL.db - SavedVariables are restored from disk after Core.lua's own
    init line runs, replacing the table wholesale (see Core.lua's
    EnsureSettingsTable for the same issue with .settings), so a cached
    table reference risks writing into an orphaned copy that never
    actually gets saved.
]]

local CL = CombatLedger

local function EnsureEncountersTable()
    if not CombatLedgerDB.encounters then
        CombatLedgerDB.encounters = {}
    end
end

-- Named after the toughest mob in the pull (highest UnitHealthMax
-- sampled while fighting it - see Aggregator's mobHealth) rather than
-- the zone name, since every boss pull inside an instance would
-- otherwise share the same zone name with nothing to tell separate
-- pulls apart in the segment dropdown/history list. Falls back to
-- whichever mob took the most tracked-side damage if health sampling
-- came up empty, then to the zone name.
local function ComputeLabel(encounter)
    local bestGuid, bestHealth = nil, 0
    local hpGuid, hp
    for hpGuid, hp in pairs(encounter.mobHealth or {}) do
        if hp > bestHealth then
            bestGuid, bestHealth = hpGuid, hp
        end
    end

    if not bestGuid then
        local bestAmount = 0
        local dmgGuid, amount
        for dmgGuid, amount in pairs(encounter.mobTally or {}) do
            if amount > bestAmount then
                bestGuid, bestAmount = dmgGuid, amount
            end
        end
    end

    if bestGuid then
        local info = CL.GuidCache and CL.GuidCache.Resolve(bestGuid)
        if info and info.name then return info.name end
    end

    if IsInInstance and IsInInstance() then
        return (GetRealZoneText and GetRealZoneText()) or encounter.zone or "Instance"
    end
    return encounter.zone or "Unknown"
end

local function SaveEncounter(encounter)
    if not encounter then return end
    EnsureEncountersTable()

    if not encounter.label then
        encounter.label = ComputeLabel(encounter)
    end
    encounter.mobTally = nil -- label-only scratch data, not worth persisting
    encounter.mobHealth = nil -- label-only scratch data, not worth persisting

    table.insert(CombatLedgerDB.encounters, 1, encounter)
    while table.getn(CombatLedgerDB.encounters) > CL.MAX_ENCOUNTERS do
        table.remove(CombatLedgerDB.encounters, table.getn(CombatLedgerDB.encounters))
    end
end

local function GetHistory()
    EnsureEncountersTable()
    return CombatLedgerDB.encounters
end

local function DeleteEncounter(index)
    EnsureEncountersTable()
    table.remove(CombatLedgerDB.encounters, index)
end

local function ClearHistory()
    CombatLedgerDB.encounters = {}
end

CL.History = {
    SaveEncounter = SaveEncounter,
    GetHistory = GetHistory,
    DeleteEncounter = DeleteEncounter,
    ClearHistory = ClearHistory,
}

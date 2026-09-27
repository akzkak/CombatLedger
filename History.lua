--[[
    History - save/trim/delete for CombatLedgerDB.encountersByChar[key].
    Most-recent-first, capped at Options' "Saved fights" (trim-oldest) - PER
    CHARACTER, since CombatLedgerDB itself is account-wide (plain
    SavedVariables, not SavedVariablesPerCharacter - see the .toc) and a
    flat shared list meant every alt on the account saw every other alt's
    saved encounters mixed into the same history.

    Reads/writes the CombatLedgerDB global directly rather than through
    CL.db - SavedVariables are restored from disk after Core.lua's own
    init line runs, replacing the table wholesale (see Core.lua's
    EnsureSettingsTable for the same issue with .settings), so a cached
    table reference risks writing into an orphaned copy that never
    actually gets saved.

    encounter.series (Aggregator's bucketed damage/healing/taken-per-2s
    timeline) is real content, not scratch data like mobTally/mobHealth -
    it's kept through the save so UI_EncounterReport can graph a saved
    encounter, not just the live one.
]]

local CL = CombatLedger

local function CharKey()
    local name = UnitName("player") or "Unknown"
    local realm = (GetRealmName and GetRealmName()) or ""
    return name .. "-" .. realm
end

-- Returns this character's history key, creating its list if needed.
-- A legacy account-wide list (CombatLedgerDB.encounters) is moved into
-- the first character that logs in, then removed so no other character
-- imports it again.
local function EnsureEncountersTable()
    if not CombatLedgerDB.encountersByChar then
        CombatLedgerDB.encountersByChar = {}
    end
    local key = CharKey()
    if not CombatLedgerDB.encountersByChar[key] then
        CombatLedgerDB.encountersByChar[key] = {}
    end
    if CombatLedgerDB.encounters and table.getn(CombatLedgerDB.encounters) > 0 then
        local i
        for i = 1, table.getn(CombatLedgerDB.encounters) do
            table.insert(CombatLedgerDB.encountersByChar[key], CombatLedgerDB.encounters[i])
        end
        CombatLedgerDB.encounters = nil
    end
    return key
end

-- Named after the toughest mob in the pull (highest UnitHealthMax
-- sampled while fighting it - see Aggregator's mobHealth) rather than
-- the zone name, since every boss pull inside an instance would
-- otherwise share the same zone name with nothing to tell separate
-- pulls apart in the segment dropdown/history list. Falls back to
-- whichever mob took the most tracked-side damage if health sampling
-- came up empty, then to the zone name.
local function ComputeLabel(encounter)
    -- A boss fight is named after its boss or BigWigs encounter.
    if encounter.bossName then return encounter.bossName end
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

-- Drops the oldest fights beyond Options' "Saved fights" - also called
-- straight from Options when that number is lowered.
local function TrimHistory()
    local key = EnsureEncountersTable()
    local list = CombatLedgerDB.encountersByChar[key]
    local cap = CL.GetSetting("maxEncounters") or CL.MAX_SAVED_FIGHTS
    while table.getn(list) > cap do
        table.remove(list, table.getn(list))
    end
end

local function SaveEncounter(encounter)
    if not encounter then return end
    local key = EnsureEncountersTable()
    local list = CombatLedgerDB.encountersByChar[key]

    if not encounter.label then
        encounter.label = ComputeLabel(encounter)
    end
    encounter.mobTally = nil -- label-only scratch data, not worth persisting
    encounter.mobHealth = nil -- label-only scratch data, not worth persisting
    -- Merge same-named mobs' per-target breakdowns (a trash pull can hit
    -- dozens of GUIDs) - see Aggregator.lua's CompactTargets.
    CL.Aggregator.CompactTargets(encounter)

    table.insert(list, 1, encounter)
    TrimHistory()
end

-- Fights saved before target compaction existed are still GUID-keyed -
-- compact them once per session, the first time History is read.
local compactedOldSaves = false

local function GetHistory()
    local key = EnsureEncountersTable()
    local list = CombatLedgerDB.encountersByChar[key]
    if not compactedOldSaves then
        compactedOldSaves = true
        local i
        for i = 1, table.getn(list) do
            CL.Aggregator.CompactTargets(list[i])
        end
    end
    return list
end

-- A saved boss fight. pullBy is only ever set for bosses, which also
-- covers fights saved before isBoss existed.
local function IsBossFight(encounter)
    return encounter.isBoss or encounter.pullBy ~= nil
end

-- History as the UI lists it: while "Remember boss fights only" is on,
-- trash fights saved before the option was turned on are hidden (not
-- deleted - turning the option off shows them again).
local function GetShownHistory()
    local list = GetHistory()
    if not CL.GetSetting("historyBossOnly") then return list end
    local shown = {}
    local i
    for i = 1, table.getn(list) do
        if IsBossFight(list[i]) then table.insert(shown, list[i]) end
    end
    return shown
end

-- Deletes a saved fight, identified by the encounter itself (list
-- positions differ between the full and the shown history).
local function DeleteEncounter(encounter)
    local list = GetHistory()
    local i
    for i = 1, table.getn(list) do
        if list[i] == encounter then
            table.remove(list, i)
            return
        end
    end
end

local function ClearHistory()
    local key = EnsureEncountersTable()
    CombatLedgerDB.encountersByChar[key] = {}
end

CL.History = {
    SaveEncounter = SaveEncounter,
    GetHistory = GetHistory,
    GetShownHistory = GetShownHistory,
    IsBossFight = IsBossFight,
    DeleteEncounter = DeleteEncounter,
    ClearHistory = ClearHistory,
    TrimHistory = TrimHistory,
}

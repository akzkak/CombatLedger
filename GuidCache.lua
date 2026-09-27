--[[
    GuidCache - identity and roster scope for the GUIDs combat events carry.

    Resolve(guid) -> { name, class, classToken, isPlayer, lastSeen } or nil.
    SuperWoW lets a raw GUID stand in for a unit token, so UnitName/
    UnitClass/UnitIsPlayer answer for any unit the client currently knows,
    targeted or not. A GUID the client can't resolve yet returns nil and is
    retried on the next call rather than cached as unknown.

    Roster scope: IsTracked(guid) is true for the player, party/raid members
    and their pets - "us". Nampower's *_OTHER events cover everyone nearby,
    so Events.lua only records an event when at least one side is tracked.
    GetOwner(petGuid) maps a pet to its owner for pet merging.
]]

local CL = CombatLedger

local ZERO_GUID = "0x0000000000000000"

-- [guid] = { name, class, classToken, isPlayer, lastSeen }. Entries idle
-- for STALE_TIMEOUT are evicted by CleanupStale (Events.lua calls it
-- periodically) and the whole cache is purged on every loading screen.
-- Recorded data copies the name at creation time, so eviction never
-- loses anything already shown.
local cache = {}
local STALE_TIMEOUT = 300

local function Resolve(guid)
    if not guid or guid == "" or guid == ZERO_GUID then return nil end

    local entry = cache[guid]
    if entry then
        entry.lastSeen = GetTime()
        return entry
    end

    -- UnitName(guid) raises ("Unknown unit name") rather than returning
    -- nil for a GUID the client can't place, so every lookup is guarded.
    local name
    if UnitName then
        local ok, result = pcall(UnitName, guid)
        if ok then name = result end
    end
    if not name or name == "" then return nil end

    local isPlayer = UnitIsPlayer and UnitIsPlayer(guid)

    local class, classToken
    if UnitClass then
        local ok, localized, token = pcall(UnitClass, guid)
        if ok then
            class, classToken = localized, token
        end
    end

    entry = {
        name = name,
        class = class,
        classToken = classToken,
        isPlayer = isPlayer,
        lastSeen = GetTime(),
    }
    cache[guid] = entry
    return entry
end

local function Purge()
    cache = {}
end

local function CleanupStale()
    local now = GetTime()
    local toRemove = {}
    local guid, entry
    for guid, entry in pairs(cache) do
        if now - entry.lastSeen > STALE_TIMEOUT then
            table.insert(toRemove, guid)
        end
    end
    local i
    for i = 1, table.getn(toRemove) do
        cache[toRemove[i]] = nil
    end
end

--------------------------------------------------------------------------
-- Roster scope
--------------------------------------------------------------------------

local tracked = {}  -- [guid] = true for player/party/raid members and their pets
local petOwner = {} -- [petGuid] = ownerGuid

-- Guarded so one bad token can't abort a rebuild halfway and leave the
-- roster partial. ownerUnit (pets only) records the pet -> owner link.
local function AddUnit(unit, ownerUnit)
    local ok, exists, guid = pcall(UnitExists, unit)
    if ok and exists and guid then
        tracked[guid] = true
        if ownerUnit then
            local ownerOk, ownerExists, ownerGuid = pcall(UnitExists, ownerUnit)
            if ownerOk and ownerExists and ownerGuid then
                petOwner[guid] = ownerGuid
            end
        end
    end
end

-- Rebuilt from scratch on roster/pet changes (see Events.lua).
local function RefreshRoster()
    tracked = {}
    petOwner = {}
    AddUnit("player")
    AddUnit("pet", "player")

    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        local i
        for i = 1, 40 do
            AddUnit("raid" .. i)
            -- Raid pet tokens are "raidNpet" (suffix), unlike party's
            -- "partypetN" (prefix).
            AddUnit("raid" .. i .. "pet", "raid" .. i)
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        local i
        for i = 1, 4 do
            AddUnit("party" .. i)
            AddUnit("partypet" .. i, "party" .. i)
        end
    end
end

local function IsTracked(guid)
    if not guid then return false end
    return tracked[guid] == true
end

local function GetOwner(guid)
    if not guid then return nil end
    return petOwner[guid]
end

--------------------------------------------------------------------------
-- Combat state
--------------------------------------------------------------------------

local function UnitInCombat(unit)
    local ok, inCombat = pcall(UnitAffectingCombat, unit)
    return ok and inCombat and true or false
end

-- True if any group member or pet is flagged in combat (in a raid this
-- includes the player's own raid slot; callers either already know the
-- player is out of combat or don't mind). Raid and party ranges are both
-- scanned when nonzero: GetNumPartyMembers() can be nonzero inside a raid
-- on this client. Pets count, so a Feign Death hunter's fighting pet
-- keeps the group "in combat". Cached for GROUP_COMBAT_CACHE_SECONDS
-- because heal/dispel lazy-start (Aggregator.lua) may ask on every event
-- and a raid scan is up to 80 unit checks.
local GROUP_COMBAT_CACHE_SECONDS = 0.25
local groupCombatCheckedAt = nil
local groupCombatCached = false

local function AnyGroupMemberInCombat()
    local now = GetTime()
    if groupCombatCheckedAt and now - groupCombatCheckedAt < GROUP_COMBAT_CACHE_SECONDS then
        return groupCombatCached
    end
    groupCombatCheckedAt = now

    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    local result = UnitInCombat("pet")
    local i
    if not result and raidN > 0 then
        for i = 1, raidN do
            if UnitInCombat("raid" .. i) or UnitInCombat("raid" .. i .. "pet") then result = true break end
        end
    end
    if not result and partyN > 0 then
        for i = 1, partyN do
            if UnitInCombat("party" .. i) or UnitInCombat("partypet" .. i) then result = true break end
        end
    end
    groupCombatCached = result
    return result
end

CL.GuidCache = {
    UnitInCombat = UnitInCombat,
    AnyGroupMemberInCombat = AnyGroupMemberInCombat,
    Resolve = Resolve,
    Purge = Purge,
    CleanupStale = CleanupStale,
    RefreshRoster = RefreshRoster,
    IsTracked = IsTracked,
    GetOwner = GetOwner,
}

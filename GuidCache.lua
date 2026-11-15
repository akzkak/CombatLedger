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
local summonChecks = {} -- [summonGuid] = { owner, checkedAt, attempts }
local SUMMON_RECHECK_SECONDS = 3

-- Placeholders the client returns for a unit it knows exists but hasn't
-- received the name of yet (common right after a loading screen). Never
-- cached, so the next lookup tries again.
local PLACEHOLDER_NAMES = {
    ["Unknown"] = true,
    ["Unknown Being"] = true,
    ["Unknown Entity"] = true,
}
if UNKNOWNOBJECT then PLACEHOLDER_NAMES[UNKNOWNOBJECT] = true end
if UKNOWNBEING then PLACEHOLDER_NAMES[UKNOWNBEING] = true end

-- Reads name/class/isPlayer through `unit` (a token or the GUID itself)
-- and caches them under `guid`. Returns the entry, or nil while the name
-- is unavailable or still a placeholder. UnitName(guid) raises ("Unknown
-- unit name") for a GUID the client can't place, so lookups are guarded.
local function Remember(guid, unit)
    local name
    if UnitName then
        local ok, result = pcall(UnitName, unit)
        if ok then name = result end
    end
    if not name or name == "" or PLACEHOLDER_NAMES[name] then return nil end

    local isPlayer = UnitIsPlayer and UnitIsPlayer(unit)

    local class, classToken
    if UnitClass then
        local ok, localized, token = pcall(UnitClass, unit)
        if ok then
            class, classToken = localized, token
        end
    end

    local entry = {
        name = name,
        class = class,
        classToken = classToken,
        isPlayer = isPlayer,
        lastSeen = GetTime(),
    }
    cache[guid] = entry
    return entry
end

local function Resolve(guid)
    if not guid or guid == "" or guid == ZERO_GUID then return nil end

    local entry = cache[guid]
    if entry then
        entry.lastSeen = GetTime()
        return entry
    end
    return Remember(guid, guid)
end

local function Purge()
    cache = {}
    summonChecks = {}
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
    for guid, entry in pairs(summonChecks) do
        if now - entry.checkedAt > STALE_TIMEOUT then
            summonChecks[guid] = nil
        end
    end
end

--------------------------------------------------------------------------
-- Roster scope
--------------------------------------------------------------------------

local tracked = {}  -- [guid] = true for player/party/raid members and their pets
local petOwner = {} -- [petGuid] = ownerGuid
local petsByToken = {}
local petRosterDirty = false
local groupCombatCheckedAt = nil

-- Guarded so one bad token can't abort a rebuild halfway and leave the
-- roster partial. ownerUnit (pets only) records the pet -> owner link.
-- Roster names are cached through the unit token, which resolves even
-- when a lookup by GUID would still return a placeholder.
local function AddUnit(unit, ownerUnit)
    local ok, exists, guid = pcall(UnitExists, unit)
    if ok and exists and guid then
        tracked[guid] = true
        Remember(guid, unit)
        if ownerUnit then
            local ownerOk, ownerExists, ownerGuid = pcall(UnitExists, ownerUnit)
            if ownerOk and ownerExists and ownerGuid then
                petOwner[guid] = ownerGuid
            end
        end
        return guid
    end
end

local function RefreshPet(petUnit, ownerUnit)
    local previous = petsByToken[petUnit]
    local guid = AddUnit(petUnit, ownerUnit)
    petsByToken[petUnit] = guid
    -- A new pet is tracked immediately, even during a swap. The old
    -- GUID can be removed on the next tick along with other pet changes.
    if previous and previous ~= guid then petRosterDirty = true end
end

-- Group changes refresh immediately. Pet removals share a deferred rebuild.
local function RefreshRoster()
    tracked = {}
    petOwner = {}
    petsByToken = {}
    petRosterDirty = false
    groupCombatCheckedAt = nil
    AddUnit("player")
    RefreshPet("pet", "player")

    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        local i
        for i = 1, 40 do
            AddUnit("raid" .. i)
            -- Raid pet tokens are "raidNpet" (suffix), unlike party's
            -- "partypetN" (prefix).
            RefreshPet("raid" .. i .. "pet", "raid" .. i)
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        local i
        for i = 1, 4 do
            AddUnit("party" .. i)
            RefreshPet("partypet" .. i, "party" .. i)
        end
    end
end

-- UNIT_PET supplies the owner's token. Ignore target/nameplate pets and
-- party tokens while raiding, since the roster uses raid tokens then.
local function HandlePetChanged(unit)
    if type(unit) ~= "string" then return end
    if unit == "player" then
        RefreshPet("pet", unit)
    else
        local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
        if raid > 0 then
            local _, _, index = string.find(unit, "^raid([1-9]%d*)$")
            if not index or tonumber(index) > 40 then return end
            RefreshPet(unit .. "pet", unit)
        else
            local party = GetNumPartyMembers and GetNumPartyMembers() or 0
            local _, _, index = string.find(unit, "^party([1-4])$")
            if not index or party == 0 then return end
            RefreshPet("partypet" .. index, unit)
        end
    end
    groupCombatCheckedAt = nil
end

local function FlushPetChanges()
    if petRosterDirty then RefreshRoster() end
end

local function IsTracked(guid)
    if not guid then return false end
    return tracked[guid] == true
end

local function GetOwner(guid)
    if not guid then return nil end
    return petOwner[guid]
end

local function IsRealGuid(guid)
    return type(guid) == "string" and guid ~= "" and guid ~= ZERO_GUID
end

local function ReadSummoner(guid)
    local ok, owner
    if GetUnitField then
        ok, owner = pcall(GetUnitField, guid, "summonedBy")
        if ok and IsRealGuid(owner) then return owner end
        ok, owner = pcall(GetUnitField, guid, "createdBy")
        if ok and IsRealGuid(owner) then return owner end
    end
    if GetUnitGUID then
        ok, owner = pcall(GetUnitGUID, guid .. "owner")
        if ok and IsRealGuid(owner) then return owner end
    end
end

local function GetSummonOwner(guid)
    local entry = summonChecks[guid]
    local owner = entry and entry.owner
    if owner and tracked[owner] and not petOwner[owner] and not tracked[guid] then return owner end
end

-- Fire Nova can despawn between SPELL_GO and the first damage packet.
-- Keep the link across pet/roster updates and check current membership
-- when using it. A second packet can retry a lookup made before the
-- client knew the summon, then back off for ordinary enemy units.
local function LearnSummonOwner(guid)
    if not IsRealGuid(guid) or tracked[guid] or not (GetUnitField or GetUnitGUID) then return end
    local now = GetTime()
    local entry = summonChecks[guid]
    if entry then
        if entry.owner then
            entry.checkedAt = now
            return GetSummonOwner(guid)
        end
        if entry.attempts >= 2 and now - entry.checkedAt < SUMMON_RECHECK_SECONDS then return end
    else
        entry = { attempts = 0 }
        summonChecks[guid] = entry
    end
    entry.attempts = entry.attempts + 1
    entry.checkedAt = now
    local owner = ReadSummoner(guid)
    if owner ~= guid then entry.owner = owner end
    return GetSummonOwner(guid)
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
    HandlePetChanged = HandlePetChanged,
    FlushPetChanges = FlushPetChanges,
    IsTracked = IsTracked,
    GetOwner = GetOwner,
    GetSummonOwner = GetSummonOwner,
    LearnSummonOwner = LearnSummonOwner,
}

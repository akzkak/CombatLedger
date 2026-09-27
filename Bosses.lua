--[[
    Bosses - decides whether an enemy (or the current fight) is a boss.

    Sources, strongest first:
      1. BigWigs: a boss module that is engaged right now
         (GetEngagedEncounter), or an enemy whose name is one of a boss
         module's enable triggers - this also catches bosses the client
         shows with a normal level, and names multi-boss encounters after
         the encounter ("The Four Horsemen") rather than one of its mobs.
      2. The creature's rank: "worldboss", or an elite/rare elite whose
         level shows as "??" (UnitLevel -1). Most instance bosses are the
         latter, while elite trash almost always has a real level.

    BigWigs is optional; without it only the rank check applies.
]]

local CL = CombatLedger

--------------------------------------------------------------------------
-- BigWigs
--------------------------------------------------------------------------

-- Boss modules (those with a "bosskill" option, not trash modules) and
-- [enemy name] = encounter name from their enable triggers, minus
-- "wipemobs" (adds that don't mean the boss is up). Built on first use
-- and rebuilt after any addon loads, since BigWigs loads its zone
-- modules on demand.
local bossModules = nil
local encounterByTrigger = nil

local function IsBossModule(module)
    if type(module) ~= "table" or module.trashMod or not module.bossSync then return false end
    if type(module.toggleoptions) ~= "table" then return false end
    local _, option
    for _, option in pairs(module.toggleoptions) do
        if option == "bosskill" then return true end
    end
    return false
end

-- A module's name list may be a single string or a table of strings.
local function EachName(names, fn)
    if type(names) == "string" then
        fn(names)
    elseif type(names) == "table" then
        local _, name
        for _, name in pairs(names) do
            if type(name) == "string" then fn(name) end
        end
    end
end

local function BuildCache()
    local modules, triggers = {}, {}
    local bigWigs = BigWigs
    if type(bigWigs) == "table" and type(bigWigs.IterateModules) == "function" then
        local _, module
        for _, module in bigWigs:IterateModules() do
            if IsBossModule(module) then
                table.insert(modules, module)
                local encounterName = module.translatedName or module.bossSync
                local excluded = {}
                EachName(module.wipemobs, function(name) excluded[name] = true end)
                EachName(module.enabletrigger, function(name)
                    if not excluded[name] then triggers[name] = encounterName end
                end)
            end
        end
    end
    bossModules, encounterByTrigger = modules, triggers
end

local function EnsureCache()
    if bossModules then return end
    -- A broken module must not take boss detection down with it.
    if not pcall(BuildCache) then
        bossModules, encounterByTrigger = {}, {}
    end
end

-- Name of the BigWigs encounter that is engaged right now, or nil.
local function GetEngagedEncounter()
    EnsureCache()
    local i
    for i = 1, table.getn(bossModules) do
        local module = bossModules[i]
        if module.engaged then return module.translatedName or module.bossSync end
    end
    return nil
end

--------------------------------------------------------------------------
-- Rank
--------------------------------------------------------------------------

-- The GUID works as a unit token (SuperWoW); callers only ask about
-- enemies they just saw a hit involving, so the unit is in range.
local function HasBossRank(enemyGuid)
    local ok, classification = pcall(UnitClassification, enemyGuid)
    if not ok then return false end
    if classification == "worldboss" then return true end
    if classification == "elite" or classification == "rareelite" then
        local lvlOk, lvl = pcall(UnitLevel, enemyGuid)
        return lvlOk and lvl == -1
    end
    return false
end

-- Returns the encounter name if `enemyGuid` is a boss, else nil. The
-- name is the BigWigs encounter when a trigger matches, otherwise the
-- mob's own name.
local function Classify(enemyGuid)
    if not enemyGuid then return nil end
    local info = CL.GuidCache.Resolve(enemyGuid)
    local name = info and info.name
    EnsureCache()
    local encounterName = name and encounterByTrigger[name]
    local result = encounterName or (HasBossRank(enemyGuid) and (name or enemyGuid)) or nil
    if CL.debug then
        CL.LogLine(string.format("[BOSS_CHECK] guid=%s name=%s boss=%s", tostring(enemyGuid), tostring(name), tostring(result)))
    end
    return result
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function()
    bossModules, encounterByTrigger = nil, nil
end)

CL.Bosses = {
    Classify = Classify,
    GetEngagedEncounter = GetEngagedEncounter,
}

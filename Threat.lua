--[[
    Threat - live per-target threat, not built on Nampower/SuperWoW at
    all. This server answers a plain Blizzard addon message
    ("TWT_UDTSv4") with a reply over CHAT_MSG_ADDON (prefix "TWTv4=")
    containing every group member's current threat against your target -
    the same protocol TWThreat uses. Since the server is already doing
    the real threat math, this file is just the request/parse/poll
    plumbing - no aggregation of our own.

    Threat has no "Overall" or "History" - it's always a live snapshot
    of whatever the server just reported for the current target, reset
    the moment the target (or combat state) changes. UI_MainWindow.lua's
    Threat mode reads CL.Threat.GetSnapshot() directly instead of going
    through the Current/Overall/segment machinery every other mode uses.
]]

local CL = CombatLedger

local REQUEST_PREFIX = "TWT_UDTSv4"
local REPLY_PREFIX = "TWTv4="
local POLL_INTERVAL = 0.5 -- matches TWThreat's own polling cadence
local REQUEST_LIMIT = 19

-- [name] = guid, from a party/raid roster scan (SuperWoW's UnitExists
-- returns a real GUID as a third value - see GuidCache.lua for the same
-- trick) - threat packets only ever name party/raid members, so this is
-- always resolvable as long as the roster scan has run recently.
local nameToGuid = {}

-- [guid] = { name, threat, perc, melee, tank }
local current = {}
local tankGuid = nil
local lastUpdate = 0

local function AddRosterName(unit)
    local ok, exists, guid = pcall(UnitExists, unit)
    if ok and exists and guid then
        local name = UnitName(unit)
        if name then nameToGuid[name] = guid end
    end
end

local function RefreshRosterNames()
    nameToGuid = {}
    AddRosterName("player")
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        local i
        for i = 1, 40 do
            AddRosterName("raid" .. i)
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        local i
        for i = 1, 4 do
            AddRosterName("party" .. i)
        end
    end
end

-- Matches TWThreat's own channel selection: 'PARTY' is the
-- unconditional fallback, sent even while solo. The server intercepts
-- by the "TWT_UDTSv4" addon-message prefix itself, not real
-- party-channel membership, so there's no "not grouped" case where
-- this should return nil.
local function GroupChannel()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
    return "PARTY"
end

-- Manual split matching TWThreat's own __explode - avoids a gmatch/
-- gfind dependency either way.
local function SplitString(str, delimiter)
    local result = {}
    local from = 1
    local delimFrom, delimTo = string.find(str, delimiter, from, true)
    while delimFrom do
        table.insert(result, string.sub(str, from, delimFrom - 1))
        from = delimTo + 1
        delimFrom, delimTo = string.find(str, delimiter, from, true)
    end
    table.insert(result, string.sub(str, from))
    return result
end

-- body: "name:isTank:threat:perc:isMelee;name2:...;..."
local function HandleThreatPacket(body)
    if CL.debug then CL.LogLine("[Threat] packet body: " .. tostring(body)) end

    local newCurrent = {}
    local newTank = nil

    local entries = SplitString(body, ";")
    local i
    for i = 1, table.getn(entries) do
        if entries[i] ~= "" then
            local parts = SplitString(entries[i], ":")
            local name, tankFlag, threatStr, percStr, meleeFlag = parts[1], parts[2], parts[3], parts[4], parts[5]
            if name and tankFlag and threatStr and percStr then
                local guid = nameToGuid[name] or ("THREATNAME:" .. name)
                local isTank = (tankFlag == "1")
                -- floor to a clean integer - TWThreat parses this with
                -- its own __parseint for the same reason: the raw value
                -- can come through with float noise (e.g. 71.199997)
                -- that looks broken displayed raw.
                local percNum = tonumber(percStr) or 0
                newCurrent[guid] = {
                    name = name,
                    threat = tonumber(threatStr) or 0,
                    perc = math.floor(percNum + 0.5),
                    melee = (meleeFlag == "1"),
                    tank = isTank,
                }
                if isTank then newTank = guid end
                if CL.debug then
                    CL.LogLine("[Threat]   parsed " .. name .. " guid=" .. tostring(guid) ..
                        " threat=" .. tostring(threatStr) .. " perc=" .. tostring(percStr) .. " tank=" .. tostring(isTank))
                end
            elseif CL.debug then
                CL.LogLine("[Threat]   unparseable entry: " .. tostring(entries[i]))
            end
        end
    end

    if CL.debug then CL.LogLine("[Threat] " .. table.getn(entries) .. " entries -> " .. CL.TableCount(newCurrent) .. " players resolved") end

    current = newCurrent
    tankGuid = newTank
    lastUpdate = GetTime()

    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
end

local function RequestThreat()
    local channel = GroupChannel()
    if not channel then return end
    local ok, err = pcall(SendAddonMessage, REQUEST_PREFIX, "limit=" .. REQUEST_LIMIT, channel)
    if CL.debug then
        CL.LogLine("[Threat] request sent prefix=" .. REQUEST_PREFIX .. " channel=" .. channel .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:SetScript("OnEvent", function()
    if event == "CHAT_MSG_ADDON" then
        -- arg1 = prefix, arg2 = message, arg3 = channel, arg4 = sender.
        -- The reply's real addon-message prefix (arg1) isn't "TWTv4="
        -- itself - that marker is embedded inside the message body
        -- (arg2), so that's what has to be searched, not arg1.
        if CL.debug and arg1 and (string.find(arg1, "TWT", 1, true) or (arg2 and string.find(arg2, "TWT", 1, true))) then
            CL.LogLine("[Threat] CHAT_MSG_ADDON prefix=" .. tostring(arg1) .. " from=" .. tostring(arg4) .. " msg=" .. tostring(arg2))
        end
        if arg2 and string.find(arg2, REPLY_PREFIX, 1, true) then
            local prefixPos = string.find(arg2, REPLY_PREFIX, 1, true)
            local body = string.sub(arg2, prefixPos + string.len(REPLY_PREFIX))
            HandleThreatPacket(body)
        end
        return
    end
    RefreshRosterNames()
end)
RefreshRosterNames()

local accum = 0
local wasPolling = false
local debugAccum = 0
local lastTargetGuid = nil
f:SetScript("OnUpdate", function()
    accum = accum + arg1
    if accum < POLL_INTERVAL then return end
    accum = 0

    -- Don't bother the server at all unless some window is actually
    -- showing Threat mode right now.
    local hasUI = CL.UI and CL.UI.IsModeVisible
    local wantsThreat = hasUI and CL.UI.IsModeVisible("threat")
    local channel = wantsThreat and GroupChannel()
    local hasTargetOk, hasTarget, targetGuid, inCombat
    local polling = false
    if channel then
        hasTargetOk, hasTarget, targetGuid = pcall(UnitExists, "target")
        inCombat = hasTargetOk and hasTarget and UnitAffectingCombat("target")
        polling = inCombat
    end

    -- Target changed since the last poll (tab-targeting a different
    -- mob, retargeting after a kill, etc) - the old snapshot belongs to
    -- whatever was targeted before and isn't valid for the new one, so
    -- clear immediately rather than leaving it showing indefinitely if
    -- the new target never replies.
    if targetGuid ~= lastTargetGuid then
        if CL.debug then
            CL.LogLine("[Threat] target changed: " .. tostring(lastTargetGuid) .. " -> " .. tostring(targetGuid))
        end
        lastTargetGuid = targetGuid
        current = {}
        tankGuid = nil
        if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    end

    if CL.debug then
        debugAccum = debugAccum + POLL_INTERVAL
        if polling ~= wasPolling or debugAccum >= 3 then
            debugAccum = 0
            CL.LogLine("[Threat] state: polling=" .. tostring(polling) ..
                " hasUI=" .. tostring(hasUI) .. " wantsThreat=" .. tostring(wantsThreat) ..
                " channel=" .. tostring(channel) .. " hasTargetOk=" .. tostring(hasTargetOk) ..
                " hasTarget=" .. tostring(hasTarget) .. " inCombat=" .. tostring(inCombat))
        end
    end

    if polling then
        RequestThreat()
    elseif wasPolling then
        -- Target/combat state dropped since the last poll - clear
        -- rather than leave a stale snapshot from whatever was
        -- last being fought showing in Threat mode indefinitely.
        current = {}
        tankGuid = nil
        if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    end
    wasPolling = polling
end)

-- Sorted list of every currently-known party/raid member name (from the
-- last roster scan, independent of whether threat data has arrived yet)
-- - for UI_MainWindow.lua's Threat filter dropdown, so you can e.g. pre-
-- select yourself + the tank before combat even starts.
local function GetRosterNames()
    local names = {}
    local name, guid
    for name, guid in pairs(nameToGuid) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

CL.Threat = {
    GetSnapshot = function() return current end,
    GetTankGuid = function() return tankGuid end,
    IsAvailable = function() return GroupChannel() ~= nil end,
    GetLastUpdate = function() return lastUpdate end,
    GetRosterNames = GetRosterNames,
}

--[[
    Threat - live per-target threat.

    Primary path: this server answers a plain Blizzard addon message
    ("TWT_UDTSv4") with a reply over CHAT_MSG_ADDON (prefix "TWTv4=")
    containing group members' current threat against your target. This
    is the same request/reply protocol TWThreat uses; it needs no addon
    handshake or registration message. The request limit must stay in
    TWThreat's supported range: TWThreat exposes 5-11 visible bars and
    requests visibleBars - 1, so the largest valid request is 10.

    Fallback path: EstimateThreat() below reads a local threat ledger fed
    per event by Aggregator (NoteDamage/NoteHealing) and SPELL_GO - see
    the "Local threat estimation" section. Runs whenever a poll happens
    but no real reply has landed recently, so the real API always wins
    when available.

    Threat has no "Overall" or "History" - it's always a live snapshot
    of whatever the server just reported (or was last estimated) for the
    current target, reset the moment the target (or combat state)
    changes. UI_MainWindow.lua's Threat mode reads CL.Threat.GetSnapshot()
    directly instead of going through the Current/Overall/segment
    machinery every other mode uses.
]]

local CL = CombatLedger

local REQUEST_PREFIX = "TWT_UDTSv4"
local REPLY_PREFIX = "TWTv4="
local POLL_INTERVAL = 0.5 -- matches TWThreat's own polling cadence
-- TWThreat caps visibleBars at 11 and sends visibleBars - 1. Values above
-- 10 can be silently ignored by the server, leaving only local estimates.
local REQUEST_LIMIT = 10

-- How long to wait after a poll with no real reply before estimating -
-- generous enough that a real reply arriving just slightly late (server
-- hiccup, not "this group doesn't get real replies at all") still wins;
-- see EstimateThreat below and its call site in the poll loop.
local ESTIMATE_GRACE = 2

-- [guid] = { name, threat, perc, melee, tank } - declared here (not
-- down by the roster-scan code below, where these originally lived)
-- since EstimateThreat, defined next, assigns to all three and Lua's
-- single-pass compiler needs the local declaration to already be in
-- scope above any reference to it - a local declared later resolves as
-- a nonexistent global instead (confirmed the hard way: "attempt to
-- perform arithmetic on global 'lastUpdate' (a nil value)").
local current = {}
local tankGuid = nil
local lastUpdate = 0

-- ============================================================
-- Local threat estimation (fallback when no real server reply arrives -
-- see this file's header comment for why that's needed at all). Only a
-- TWTv4 server reply is truth; this is a best-effort estimate.
--
-- Threat is accumulated per event into its own ledger, never read back
-- from Aggregator's merged totals:
--   ledger[enemyGuid][actorGuid] = threat, modifiers already applied
-- That keeps pets as their own actors (a pet's threat belongs to the
-- pet, not its owner - Aggregator rolls pet damage into the owner's
-- bar, which is right for Damage Done but wrong here) and applies each
-- actor's stance/form/buff modifiers as they were when the hit landed,
-- not whatever they happen to be when the estimate is displayed.
--
-- Modelled: damage (with per-ability threat multipliers), explicit DBC
-- threat effects (Sunder Armor/Taunt-style, via SPELL_GO), healing
-- (0.5 per effective point, split across engaged enemies), Rogue's
-- innate 0.71, Warrior stances, Druid Bear/Cat Form, Blessing of
-- Salvation and Righteous Fury. NOT modelled: talents (Defiance, Feral
-- Instinct, Silent Resolve, Improved Righteous Fury, ...), items and
-- threat-drop abilities (Feign Death, Vanish, Fade).
-- ============================================================

-- Damage abilities with higher-than-normal threat coefficients (1.12
-- approximations).
local SPELL_DAMAGE_THREAT_MULT = {
    ["Mind Blast"] = 2.00,
    ["Searing Pain"] = 2.00,
    ["Shield Slam"] = 1.50,
    ["Revenge"] = 2.00,
    ["Maul"] = 1.75,
    ["Heroic Strike"] = 1.25,
    ["Cleave"] = 1.15,
    ["Thunder Clap"] = 1.75,
    ["Mocking Blow"] = 2.50,
    ["Holy Shield"] = 1.30,
    ["Lacerate"] = 1.30,
    ["Devastate"] = 1.50,
}

-- Nampower mirrors the vanilla SpellEffect and SpellAttr enums. These
-- constants are intentionally local to Threat mode; the normal meter
-- pipeline has no reason to know about threat-only DBC details.
local SPELL_EFFECT_THREAT = 63
local SPELL_EFFECT_THREAT_ALL = 91
local SPELL_ATTR_EX_NO_THREAT = 1024 -- 0x00000400

local SCHOOL_HOLY = 1
local HEAL_THREAT_PER_POINT = 0.5

local STANCE_MOD = { defensive = 1.3, battle = 0.8, berserker = 0.8 }
local FORM_MOD = { bear = 1.3, cat = 0.71 }
local ROGUE_MOD = 0.71
local SALVATION_MOD = 0.7
local RIGHTEOUS_FURY_MOD = 1.6

-- Warrior stance, learned from SPELL_GO: the stance spells themselves,
-- plus abilities usable in only one stance (which also covers a warrior
-- who was already in stance before we started watching).
local STANCE_SPELL_IDS = { [2457] = "battle", [71] = "defensive", [2458] = "berserker" }
local STANCE_LOCKED_ABILITIES = {
    ["Revenge"] = "defensive", ["Shield Block"] = "defensive", ["Shield Wall"] = "defensive",
    ["Taunt"] = "defensive", ["Disarm"] = "defensive",
    ["Overpower"] = "battle", ["Mocking Blow"] = "battle", ["Retaliation"] = "battle",
    ["Charge"] = "battle", ["Thunder Clap"] = "battle",
    ["Whirlwind"] = "berserker", ["Intercept"] = "berserker", ["Berserker Rage"] = "berserker",
    ["Recklessness"] = "berserker", ["Pummel"] = "berserker",
}
-- Shapeshift-bar icons are locale-free; used for the player's own stance.
local STANCE_ICONS = {
    ["Ability_Warrior_OffensiveStance"] = "battle",
    ["Ability_Warrior_DefensiveStance"] = "defensive",
    ["Ability_Racial_Avatar"] = "berserker",
}

local ZERO_GUID = "0x0000000000000000"

local function ValidGuid(guid)
    return guid and guid ~= "" and guid ~= ZERO_GUID and guid ~= "0x000000000"
end

local function SpellField(spellId, field)
    if not spellId or not GetSpellRecField then return nil end
    local ok, value = pcall(GetSpellRecField, spellId, field, 1)
    if ok then return value end
    return nil
end

local function IsTrackedGuid(guid)
    return guid and CL.GuidCache and CL.GuidCache.IsTracked(guid)
end

-- Per-spellId DBC lookups, cached - they run on every tracked damage
-- event and cast, and a spell's DBC record never changes.
local hasThreatCache = {}
local function SpellHasInitialDamageThreat(spellId)
    if not spellId or spellId < 0 then return true end
    local cached = hasThreatCache[spellId]
    if cached == nil then
        local attributesEx = tonumber(SpellField(spellId, "attributesEx")) or 0
        cached = not CL.HasBit(attributesEx, SPELL_ATTR_EX_NO_THREAT)
        hasThreatCache[spellId] = cached
    end
    return cached
end

local function SpellDamageThreatMult(spellName, spellId)
    if not SpellHasInitialDamageThreat(spellId) then return 0 end
    return (spellName and SPELL_DAMAGE_THREAT_MULT[spellName]) or 1.0
end

-- Returns the target-specific and all-engaged-enemy threat encoded in a
-- spell's DBC effects. EffectBasePoints is stored as value-1 in vanilla.
local explicitThreatCache = {}
local function ExplicitSpellThreat(spellId)
    local cached = explicitThreatCache[spellId]
    if cached then return cached[1], cached[2] end
    local targetThreat, allThreat = 0, 0
    local effects = SpellField(spellId, "effect")
    local basePoints = SpellField(spellId, "effectBasePoints")
    if type(effects) == "table" and type(basePoints) == "table" then
        local i
        for i = 1, 3 do
            local effect = tonumber(effects[i])
            local amount = (tonumber(basePoints[i]) or -1) + 1
            if effect == SPELL_EFFECT_THREAT then
                targetThreat = targetThreat + amount
            elseif effect == SPELL_EFFECT_THREAT_ALL then
                allThreat = allThreat + amount
            end
        end
    end
    explicitThreatCache[spellId] = { targetThreat, allThreat }
    return targetThreat, allThreat
end

--------------------------------------------------------------------------
-- Per-actor modifiers
--------------------------------------------------------------------------

local stanceByGuid = {} -- [warriorGuid] = "battle"/"defensive"/"berserker", from SPELL_GO

-- Buff-derived state per actor, refreshed at most every BUFF_SCAN_SECONDS
-- (a raid-wide scan per hit would be far too many UnitBuff calls).
-- SuperWoW lets UnitBuff take a raw GUID like every other unit API here.
local BUFF_SCAN_SECONDS = 2
local buffState = {} -- [guid] = { at, form, salvation, righteousFury }

local function ScanBuffs(guid)
    local state = buffState[guid]
    local now = GetTime()
    if state and now - state.at < BUFF_SCAN_SECONDS then return state end
    if not state then
        state = {}
        buffState[guid] = state
    end
    state.at = now
    state.form, state.salvation, state.righteousFury = nil, false, false
    if not UnitBuff then return state end
    local i
    for i = 1, 32 do
        local ok, texture = pcall(UnitBuff, guid, i)
        if not ok or not texture then break end
        if string.find(texture, "BearForm", 1, true) then
            state.form = "bear"
        elseif string.find(texture, "CatForm", 1, true) then
            state.form = "cat"
        elseif string.find(texture, "Salvation", 1, true) then
            state.salvation = true
        elseif string.find(texture, "SealOfFury", 1, true) then
            state.righteousFury = true
        end
    end
    return state
end

local function PlayerStance()
    if not GetShapeshiftFormInfo or not GetNumShapeshiftForms then return nil end
    local i
    for i = 1, GetNumShapeshiftForms() do
        local icon, _, active = GetShapeshiftFormInfo(i)
        if active and icon then
            local key, stance
            for key, stance in pairs(STANCE_ICONS) do
                if string.find(icon, key, 1, true) then return stance end
            end
        end
    end
    return nil
end

-- Total threat multiplier for one actor's action right now. school is
-- only used for Righteous Fury (Holy). Class-based modifiers apply to
-- players only - pets can report an internal class (UnitClass on a
-- pet isn't meaningful here), so they get just the buff-based ones.
local function ActorMod(guid, school)
    local info = CL.GuidCache.Resolve(guid)
    local classToken = info and info.isPlayer and info.classToken
    local mod = 1.0
    if classToken == "ROGUE" then
        mod = ROGUE_MOD
    elseif classToken == "WARRIOR" then
        local stance = stanceByGuid[guid]
        local ok, _, playerGuid = pcall(UnitExists, "player")
        if ok and guid == playerGuid then stance = PlayerStance() or stance end
        -- Unknown stance stays neutral rather than guessing either way.
        mod = (stance and STANCE_MOD[stance]) or 1.0
    end
    local buffs = ScanBuffs(guid)
    if classToken == "DRUID" and buffs.form then mod = mod * FORM_MOD[buffs.form] end
    if buffs.salvation then mod = mod * SALVATION_MOD end
    if buffs.righteousFury and school == SCHOOL_HOLY then mod = mod * RIGHTEOUS_FURY_MOD end
    return mod
end

--------------------------------------------------------------------------
-- Ledger
--------------------------------------------------------------------------

local ledger = {}           -- [enemyGuid][actorGuid] = threat
local meleeActors = {}      -- [enemyGuid][actorGuid] = true once they've auto-attacked it
local ledgerEncounter = nil -- the Aggregator encounter the ledger belongs to

-- A new Aggregator encounter means a new pull - start a fresh ledger.
local function SyncEncounter(enc)
    if enc ~= ledgerEncounter then
        ledger = {}
        meleeActors = {}
        ledgerEncounter = enc
    end
end

local function AddThreat(enemyGuid, actorGuid, amount)
    if amount == 0 or not ValidGuid(enemyGuid) or IsTrackedGuid(enemyGuid) then return end
    local byActor = ledger[enemyGuid]
    if not byActor then
        byActor = {}
        ledger[enemyGuid] = byActor
    end
    byActor[actorGuid] = math.max(0, (byActor[actorGuid] or 0) + amount)
end

-- Called by Aggregator.RecordDamage for every recorded hit (enc = the
-- live encounter). spellId nil = auto-attack.
local function NoteDamage(enc, casterGuid, targetGuid, spellId, spellName, school, amount)
    if not IsTrackedGuid(casterGuid) or not ValidGuid(targetGuid) or IsTrackedGuid(targetGuid) then return end
    SyncEncounter(enc)
    AddThreat(targetGuid, casterGuid, amount * SpellDamageThreatMult(spellName, spellId) * ActorMod(casterGuid, school))
    if not spellId then
        local byActor = meleeActors[targetGuid]
        if not byActor then
            byActor = {}
            meleeActors[targetGuid] = byActor
        end
        byActor[casterGuid] = true
    end
end

-- Called by Aggregator.RecordHealing with effective (not overheal)
-- healing: 0.5 threat per point, split across every enemy this pull
-- has engaged that's still alive (dead ones are dropped on UNIT_DIED).
local function NoteHealing(enc, casterGuid, effective)
    if not IsTrackedGuid(casterGuid) or not effective or effective <= 0 then return end
    SyncEncounter(enc)
    local count = 0
    local enemyGuid
    for enemyGuid in pairs(ledger) do count = count + 1 end
    if count == 0 then return end
    local each = effective * HEAL_THREAT_PER_POINT * ActorMod(casterGuid, SCHOOL_HOLY) / count
    for enemyGuid in pairs(ledger) do AddThreat(enemyGuid, casterGuid, each) end
end

-- Builds the same snapshot shape HandleThreatPacket produces, so the UI
-- needs no changes to consume either source. The tank is whoever the
-- enemy is actually targeting (the aggro holder the 110%/130% rule is
-- measured against), falling back to the top of the ledger.
local function EstimateThreat(targetGuid)
    if not ValidGuid(targetGuid) then return false end
    local enc = CL.Aggregator.GetCurrent()
    if not enc or enc ~= ledgerEncounter then return false end
    local byActor = ledger[targetGuid]
    if not byActor then return false end

    local okTT, existsTT, aggroGuid = pcall(UnitExists, "targettarget")
    if not (okTT and existsTT and aggroGuid and byActor[aggroGuid]) then aggroGuid = nil end

    local newCurrent = {}
    local maxThreat, topGuid = 0, nil
    local actorGuid, threat
    for actorGuid, threat in pairs(byActor) do
        if threat > 0 then
            local info = CL.GuidCache.Resolve(actorGuid)
            newCurrent[actorGuid] = {
                name = (info and info.name) or actorGuid,
                threat = threat,
                estimated = true,
                melee = (meleeActors[targetGuid] and meleeActors[targetGuid][actorGuid]) or false,
                tank = false,
            }
            if threat > maxThreat then maxThreat, topGuid = threat, actorGuid end
        end
    end
    if maxThreat <= 0 then return false end

    local newTank = (aggroGuid and newCurrent[aggroGuid]) and aggroGuid or topGuid
    local tankThreat = newCurrent[newTank].threat
    newCurrent[newTank].tank = true
    local _, entry
    for _, entry in pairs(newCurrent) do
        entry.perc = math.floor((entry.threat / tankThreat) * 100 + 0.5)
    end

    current = newCurrent
    tankGuid = newTank

    if CL.debug then
        CL.LogLine("[Threat] estimated target=" .. tostring(targetGuid) .. " " .. CL.TableCount(newCurrent) .. " actors (no real reply for " ..
            string.format("%.1f", GetTime() - lastUpdate) .. "s)")
    end

    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    return true
end

-- [name] = guid, from a party/raid roster scan (SuperWoW's UnitExists
-- returns a real GUID as a third value - see GuidCache.lua for the same
-- trick) - threat packets only ever name party/raid members, so this is
-- always resolvable as long as the roster scan has run recently.
local nameToGuid = {}

-- Set the moment the target changes, cleared the moment a fresh reply
-- lands. While set, the OLD target's bars are left showing rather than
-- snap-clearing to empty and popping back in half a second later - a
-- clean swap in place reads a lot better than a flash-to-blank. Only
-- if nothing comes back within STALE_TARGET_TIMEOUT do we give up and
-- actually clear, so bars for a target that stopped replying (dead,
-- out of range) don't linger forever.
local pendingTargetSince = nil
local STALE_TARGET_TIMEOUT = 2

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
    pendingTargetSince = nil

    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
end

local function RequestThreat()
    local channel = GroupChannel()
    if not channel then return end
    local requestBody = "limit=" .. REQUEST_LIMIT
    local ok, err = pcall(SendAddonMessage, REQUEST_PREFIX, requestBody, channel)
    if CL.debug then
        CL.LogLine("[Threat] request sent prefix=" .. REQUEST_PREFIX ..
            " body=" .. requestBody .. " channel=" .. channel .. " ok=" .. tostring(ok) ..
            (ok and "" or (" err=" .. tostring(err))))
    end
end

-- SPELL_GO: explicit DBC threat effects (Sunder Armor/Taunt-style
-- zero-damage threat, never the damage Aggregator already records) and
-- warrior stance tracking. Runs whether or not Threat mode is showing,
-- so an estimate opened mid-fight still covers the whole pull.
local function HandleThreatSpellGo(spellId, casterGuid, targetGuid, numTargetsHit)
    spellId = tonumber(spellId)
    if not spellId or not IsTrackedGuid(casterGuid) then return end

    local info = CL.GuidCache.Resolve(casterGuid)
    if info and info.classToken == "WARRIOR" then
        local stance = STANCE_SPELL_IDS[spellId]
        if not stance then
            local name = SpellField(spellId, "name")
            stance = name and STANCE_LOCKED_ABILITIES[name]
        end
        if stance then stanceByGuid[casterGuid] = stance end
    end

    local enc = CL.Aggregator.GetCurrent()
    if not enc then return end
    local targetThreat, allThreat = ExplicitSpellThreat(spellId)
    if targetThreat == 0 and allThreat == 0 then return end
    SyncEncounter(enc)
    local mod = ActorMod(casterGuid)

    -- The SPELL_GO primary target is reliable for single-target spells.
    -- If it is absent, use the live locked target as a best-effort target
    -- only for this explicit effect.
    if not ValidGuid(targetGuid) then
        local ok, exists, liveTargetGuid = pcall(UnitExists, "target")
        if ok and exists then targetGuid = liveTargetGuid end
    end

    if targetThreat ~= 0 and ValidGuid(targetGuid) and (tonumber(numTargetsHit) or 1) > 0 then
        AddThreat(targetGuid, casterGuid, targetThreat * mod)
    end
    if allThreat ~= 0 then
        local enemyGuid
        for enemyGuid in pairs(ledger) do
            AddThreat(enemyGuid, casterGuid, allThreat * mod)
        end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("SPELL_GO_SELF")
f:RegisterEvent("SPELL_GO_OTHER")
f:RegisterEvent("UNIT_DIED")
f:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        buffState = {}
        stanceByGuid = {}
        RefreshRosterNames()
        return
    end
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
    if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        RefreshRosterNames()
        return
    end
    -- The ledger resets itself per Aggregator encounter (SyncEncounter),
    -- so regen changes need no handling here. A dead enemy stops taking
    -- a share of healing threat.
    if event == "UNIT_DIED" then
        if arg1 then
            ledger[arg1] = nil
            meleeActors[arg1] = nil
        end
        return
    end
    if event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
        -- itemId, spellId, casterGuid, targetGuid, castFlags,
        -- numTargetsHit, numTargetsMissed, corpseOwnerGuid
        HandleThreatSpellGo(arg2, arg3, arg4, arg6)
        return
    end
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
    -- mob, retargeting after a kill, etc). The old snapshot technically
    -- belongs to whatever was targeted before, but leaving it showing
    -- until the new target's first reply lands (see pendingTargetSince
    -- above) reads far better than snap-clearing to empty and having
    -- bars pop back in ~0.5s later.
    if targetGuid ~= lastTargetGuid then
        if CL.debug then
            CL.LogLine("[Threat] target changed: " .. tostring(lastTargetGuid) .. " -> " .. tostring(targetGuid))
        end
        lastTargetGuid = targetGuid
        pendingTargetSince = GetTime()
    end

    -- New target never replied (dead before the packet came back, out
    -- of threat range, not a real mob, ...) - give up holding the old
    -- bars and actually clear.
    if pendingTargetSince and (GetTime() - pendingTargetSince) > STALE_TARGET_TIMEOUT then
        pendingTargetSince = nil
        if CL.debug then CL.LogLine("[Threat] pending target never replied - clearing") end
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
        -- Real reply always wins when it arrives (HandleThreatPacket
        -- overwrites current/lastUpdate unconditionally) - this only
        -- fires when nothing real has landed recently, so a group that
        -- DOES get real replies never sees estimated numbers at all.
        if (GetTime() - lastUpdate) > ESTIMATE_GRACE then
            if EstimateThreat(targetGuid) then
                -- A target-specific local snapshot is a valid response
                -- for stale-display purposes. Do not clear and repopulate
                -- it on the next line after STALE_TARGET_TIMEOUT.
                pendingTargetSince = nil
            end
        end
    elseif wasPolling then
        -- Target/combat state dropped since the last poll - clear
        -- rather than leave a stale snapshot from whatever was
        -- last being fought showing in Threat mode indefinitely.
        pendingTargetSince = nil
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

-- Same roster/naming as Aggregator.lua's TEST_ROSTER (Kobeni as the
-- "player", same class picks) so Test Mode reads as one consistent
-- preview cast across every mode, not a different fake group per tab.
-- classToken travels WITH each entry here (unlike the real snapshot,
-- which only ever carries a name/threat/perc/melee/tank - class comes
-- from CL.GuidCache.Resolve on a real GUID) since these guids aren't
-- real and GuidCache has nothing to resolve them to.
local TEST_THREAT_ROSTER = {
    { name = "Kobeni", classToken = "WARLOCK", threat = 12500, melee = false, tank = true },
    { name = "Kaladin", classToken = "WARRIOR", threat = 11800, melee = true, tank = false },
    { name = "Szeth", classToken = "ROGUE", threat = 8200, melee = true, tank = false },
    { name = "Dalinar", classToken = "PALADIN", threat = 6100, melee = true, tank = false },
    { name = "Shallan", classToken = "MAGE", threat = 4300, melee = false, tank = false },
    { name = "Jasnah", classToken = "PRIEST", threat = 3100, melee = false, tank = false },
    { name = "Adolin", classToken = "WARRIOR", threat = 2200, melee = true, tank = false },
}

-- Test Mode's stand-in for GetSnapshot() - same [guid] = {...} shape,
-- plus classToken (see above). Percentages are computed off the fake
-- tank's threat, same math the server would normally have already done
-- for the real perc field.
local function GetTestSnapshot()
    local snap = {}
    local tankThreat = TEST_THREAT_ROSTER[1].threat
    local i
    for i = 1, table.getn(TEST_THREAT_ROSTER) do
        local r = TEST_THREAT_ROSTER[i]
        snap["TESTTHREAT" .. i] = {
            name = r.name,
            classToken = r.classToken,
            threat = r.threat,
            perc = math.floor((r.threat / tankThreat) * 100 + 0.5),
            melee = r.melee,
            tank = r.tank,
        }
    end
    return snap
end

CL.Threat = {
    GetSnapshot = function() return current end,
    GetTestSnapshot = GetTestSnapshot,
    GetTankGuid = function() return tankGuid end,
    IsAvailable = function() return GroupChannel() ~= nil end,
    GetLastUpdate = function() return lastUpdate end,
    GetRosterNames = GetRosterNames,
    NoteDamage = NoteDamage,
    NoteHealing = NoteHealing,
}

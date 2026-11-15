--[[
    Threat - live per-target threat.

    Primary path: the server answers an addon message with prefix
    "TWT_UDTSv4" with a CHAT_MSG_ADDON reply (body marker "TWTv4=")
    listing group members' threat on your target - TWThreat's protocol,
    no handshake needed. The server only honors request limits up to 10.

    Fallback path: EstimateThreat() below reads a local threat ledger fed
    per event by Aggregator (NoteDamage/NoteHealing) and SPELL_GO - see
    the "Local threat estimation" section. Available solo or grouped
    whenever there is no fresh server reply for the target.

    Threat is a live snapshot for the current target only - no Overall
    or History. UI_MainWindow.lua reads CL.Threat.GetSnapshot() directly.
]]

local CL = CombatLedger

local REQUEST_PREFIX = "TWT_UDTSv4"
local REPLY_PREFIX = "TWTv4="
local POLL_INTERVAL = 0.5
-- The server ignores requests above 10 rows, which would leave only
-- local estimates.
local REQUEST_LIMIT = 10

-- Seconds without a server reply before the local estimate takes over;
-- long enough that a slightly late reply still wins.
local ESTIMATE_GRACE = 2
local UNANSWERED_LIMIT = 8
local BACKOFF_INTERVAL = 15
local MAX_REPLY_ROWS = 40
local MAX_REPLY_LENGTH = 4096

-- The displayed snapshot: [guid] = { name, threat, perc, melee, tank },
-- from a server reply or the estimate. Declared before the estimator,
-- which writes it (locals must be declared above their first use).
local current = {}
local tankGuid = nil
local serverSnapshotAt = nil
local lastServerReplyAt = 0

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
local enemyActivity = {}    -- last direct combat event, excluding shared threat
local ENEMY_IDLE_SECONDS = 30
local meleeActors = {}      -- [enemyGuid][actorGuid] = true once they've auto-attacked it
local ledgerEncounter = nil -- the Aggregator encounter the ledger belongs to

-- A new Aggregator encounter means a new pull - start a fresh ledger.
local function SyncEncounter(enc)
    if enc ~= ledgerEncounter then
        ledger = {}
        enemyActivity = {}
        meleeActors = {}
        ledgerEncounter = enc
    end
end

local function ForgetEnemy(guid)
    if not ValidGuid(guid) then return end
    ledger[guid] = nil
    enemyActivity[guid] = nil
    meleeActors[guid] = nil
end

local function PruneEnemies(now)
    local guid, seen
    for guid, seen in pairs(enemyActivity) do
        if now - seen >= ENEMY_IDLE_SECONDS then ForgetEnemy(guid) end
    end
end

local function MarkEnemyActivity(guid)
    local now = GetTime()
    if enemyActivity[guid] and now - enemyActivity[guid] >= ENEMY_IDLE_SECONDS then
        ForgetEnemy(guid)
    end
    enemyActivity[guid] = now
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
    SyncEncounter(enc)
    if casterGuid and ledger[casterGuid] and IsTrackedGuid(targetGuid) then
        MarkEnemyActivity(casterGuid)
    end
    if not IsTrackedGuid(casterGuid) or not ValidGuid(targetGuid) or IsTrackedGuid(targetGuid) then return end
    MarkEnemyActivity(targetGuid)
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
    PruneEnemies(GetTime())
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
local function EstimateThreat(targetGuid, now)
    if not ValidGuid(targetGuid) then return false end
    local enc = CL.Aggregator.GetCurrent()
    if not enc or enc ~= ledgerEncounter then return false end
    local seen = enemyActivity[targetGuid]
    if not seen or now - seen >= ENEMY_IDLE_SECONDS then
        ForgetEnemy(targetGuid)
        return false
    end
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
        CL.LogLine("[Threat] estimated target=" .. tostring(targetGuid) .. " " .. CL.TableCount(newCurrent) .. " actors")
    end

    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    return true
end

-- [name] = guid for group members; server replies name players, and
-- this maps them back to GUIDs.
local nameToGuid = {}

local targetGuid, requestedTarget, requestedAt
local requestChannel, nextQueryAt
local unansweredQueries = 0

local function ClearSnapshot()
    serverSnapshotAt = nil
    if not next(current) then return end
    current = {}
    tankGuid = nil
    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
end

local function InvalidateRequest()
    requestedTarget, requestedAt, nextQueryAt = nil, nil, nil
    ClearSnapshot()
end

local function AddRosterName(roster, unit)
    local ok, exists, guid = pcall(UnitExists, unit)
    if ok and exists and guid then
        local name = UnitName(unit)
        if name then roster[name] = guid end
    end
end

local function SameRoster(a, b)
    local name, guid
    for name, guid in pairs(a) do
        if b[name] ~= guid then return false end
    end
    for name in pairs(b) do
        if not a[name] then return false end
    end
    return true
end

local function RefreshRosterNames()
    local roster = {}
    AddRosterName(roster, "player")
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    local channel, prefix, count
    if raid > 0 then
        channel, prefix, count = "RAID", "raid", raid
    elseif party > 0 then
        channel, prefix, count = "PARTY", "party", party
    end
    local i
    for i = 1, count or 0 do AddRosterName(roster, prefix .. i) end

    local changed = requestChannel ~= channel or not SameRoster(nameToGuid, roster)
    requestChannel, nameToGuid = channel, roster
    if changed then
        unansweredQueries = 0
        InvalidateRequest()
    end
end

local function GetVisibleTarget()
    if not (CL.UI and CL.UI.IsModeVisible and CL.UI.IsModeVisible("threat")) then return end
    local ok, exists, guid = pcall(UnitExists, "target")
    if not (ok and exists and ValidGuid(guid) and not IsTrackedGuid(guid)) then return end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("target") then return end
    return guid
end

-- Plain-text split on a delimiter.
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

local function IsFinite(value)
    return value and value - value == 0
end

-- Validate into a fresh table before replacing the displayed snapshot.
local function ParseThreatPacket(body)
    local rows, tank, count = {}, nil, 0
    -- TWThreat may append tank-mode data after the per-target reply.
    local trailer = string.find(body, "#TMTv1=", 1, true)
    if trailer then body = string.sub(body, 1, trailer - 1) end

    local entries = SplitString(body, ";")
    local i
    for i = 1, table.getn(entries) do
        if entries[i] ~= "" then
            count = count + 1
            if count > MAX_REPLY_ROWS then return end
            local parts = SplitString(entries[i], ":")
            local name, tankFlag, threatStr, percStr, meleeFlag = parts[1], parts[2], parts[3], parts[4], parts[5]
            local threat, percent = tonumber(threatStr), tonumber(percStr)
            if name == "" or string.len(name) > 48 or string.find(name, "[%c|]") then return end
            if not IsFinite(threat) or not IsFinite(percent) then return end
            if tankFlag ~= "0" and tankFlag ~= "1" then return end
            if meleeFlag and meleeFlag ~= "" and meleeFlag ~= "0" and meleeFlag ~= "1" then return end
            local guid = nameToGuid[name] or ("THREATNAME:" .. name)
            rows[guid] = {
                name = name,
                threat = threat,
                perc = math.floor(percent + 0.5),
                melee = meleeFlag == "1",
                tank = tankFlag == "1",
            }
            if tankFlag == "1" then tank = guid end
        end
    end
    return rows, tank
end

local reportedRejectedReply = false
local function RejectReply(reason)
    if not reportedRejectedReply then
        CL.Print("Ignored a threat reply (" .. reason .. ").")
        reportedRejectedReply = true
    end
    if CL.debug then CL.LogLine("[Threat] ignored reply: " .. reason) end
end

local function HandleThreatReply(message, channel, sender)
    if not requestChannel then return end
    local marker = type(message) == "string" and string.find(message, REPLY_PREFIX, 1, true)
    if not marker then return end
    if channel and channel ~= "" and channel ~= requestChannel then
        RejectReply("unexpected channel")
        return
    end
    -- Server replies can have no sender or be attributed to the local
    -- player. Other players' addon messages cannot be server replies.
    if sender and sender ~= "" and sender ~= UnitName("player") then
        RejectReply("unexpected sender")
        return
    end
    local now = GetTime()
    if not requestedTarget or now - requestedAt > ESTIMATE_GRACE or GetVisibleTarget() ~= requestedTarget
        or not UnitAffectingCombat("target") then return end
    if string.len(message) > MAX_REPLY_LENGTH then
        RejectReply("oversized payload")
        return
    end
    local rows, tank = ParseThreatPacket(string.sub(message, marker + string.len(REPLY_PREFIX)))
    if not rows then
        RejectReply("malformed payload")
        return
    end
    if unansweredQueries >= UNANSWERED_LIMIT then
        nextQueryAt = now + POLL_INTERVAL
    end
    unansweredQueries = 0
    current, tankGuid, serverSnapshotAt, lastServerReplyAt = rows, tank, now, now
    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
end

local function RequestThreat(guid, now)
    requestedTarget, requestedAt = guid, now
    unansweredQueries = unansweredQueries + 1
    nextQueryAt = now + (unansweredQueries >= UNANSWERED_LIMIT and BACKOFF_INTERVAL or POLL_INTERVAL)
    local ok, err = pcall(SendAddonMessage, REQUEST_PREFIX, "limit=" .. REQUEST_LIMIT, requestChannel)
    if not ok and CL.debug then
        CL.LogLine("[Threat] request failed: " .. tostring(err))
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

    if targetThreat ~= 0 and ValidGuid(targetGuid) and not IsTrackedGuid(targetGuid)
        and (tonumber(numTargetsHit) or 1) > 0 then
        MarkEnemyActivity(targetGuid)
        AddThreat(targetGuid, casterGuid, targetThreat * mod)
    end
    if allThreat ~= 0 then
        PruneEnemies(GetTime())
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
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("SPELL_GO_SELF")
f:RegisterEvent("SPELL_GO_OTHER")
f:RegisterEvent("UNIT_DIED")
local function OnThreatEvent()
    if event == "PLAYER_ENTERING_WORLD" then
        buffState = {}
        stanceByGuid = {}
        targetGuid = nil
        unansweredQueries = 0
        InvalidateRequest()
        RefreshRosterNames()
        return
    end
    if event == "PLAYER_TARGET_CHANGED" then
        targetGuid = nil
        InvalidateRequest()
        return
    end
    if event == "CHAT_MSG_ADDON" then
        HandleThreatReply(arg2, arg3, arg4)
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
        ForgetEnemy(arg1)
        if arg1 and arg1 == targetGuid then InvalidateRequest() end
        return
    end
    if event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
        -- itemId, spellId, casterGuid, targetGuid, castFlags,
        -- numTargetsHit, numTargetsMissed, corpseOwnerGuid
        HandleThreatSpellGo(arg2, arg3, arg4, arg6)
        return
    end
end
f:SetScript("OnEvent", function()
    local ok, err = pcall(OnThreatEvent)
    if not ok then CL.RecordError("Threat:" .. tostring(event), err) end
end)
RefreshRosterNames()

local accum = 0
local function OnThreatUpdate()
    accum = accum + arg1
    if accum < POLL_INTERVAL then return end
    accum = 0

    local guid = GetVisibleTarget()
    if guid ~= targetGuid then
        targetGuid = guid
        InvalidateRequest()
    end
    if not guid then return end

    local now = GetTime()
    local canQuery = requestChannel and SendAddonMessage and UnitAffectingCombat("target")
    if canQuery and (not nextQueryAt or now >= nextQueryAt) then
        RequestThreat(guid, now)
    elseif not canQuery then
        requestedTarget, requestedAt, nextQueryAt = nil, nil, nil
    end

    if canQuery and serverSnapshotAt and now - serverSnapshotAt <= ESTIMATE_GRACE then return end
    serverSnapshotAt = nil
    if not EstimateThreat(guid, now) then ClearSnapshot() end
end
f:SetScript("OnUpdate", function()
    local ok, err = pcall(OnThreatUpdate)
    if not ok then CL.RecordError("Threat:OnUpdate", err) end
end)

-- Sorted group member names, for the Threat filter dropdown (usable
-- before any threat data exists).
local function GetRosterNames()
    local names = {}
    local name, guid
    for name, guid in pairs(nameToGuid) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Test mode roster, matching Aggregator.lua's TEST_ROSTER. Entries
-- carry classToken themselves since their fake GUIDs can't be resolved.
local TEST_THREAT_ROSTER = {
    { name = "Kobeni", classToken = "WARLOCK", threat = 12500, melee = false, tank = true },
    { name = "Kaladin", classToken = "WARRIOR", threat = 11800, melee = true, tank = false },
    { name = "Szeth", classToken = "ROGUE", threat = 8200, melee = true, tank = false },
    { name = "Dalinar", classToken = "PALADIN", threat = 6100, melee = true, tank = false },
    { name = "Shallan", classToken = "MAGE", threat = 4300, melee = false, tank = false },
    { name = "Jasnah", classToken = "PRIEST", threat = 3100, melee = false, tank = false },
    { name = "Adolin", classToken = "WARRIOR", threat = 2200, melee = true, tank = false },
}

-- Test mode's stand-in for GetSnapshot() (same shape, plus classToken).
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
    IsAvailable = function() return requestChannel ~= nil or GetVisibleTarget() ~= nil end,
    GetLastUpdate = function() return lastServerReplyAt end,
    GetRosterNames = GetRosterNames,
    NoteDamage = NoteDamage,
    NoteHealing = NoteHealing,
    ForgetEnemy = ForgetEnemy,
}

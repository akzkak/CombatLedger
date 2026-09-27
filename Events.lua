--[[
    Events - the event pipeline. Enables the Nampower CVars the combat
    events are gated behind, decodes each event's arguments and hands the
    result to the Aggregator; also owns encounter start/end timing and the
    /cl slash command.

    Every event and OnUpdate tick runs under pcall: an error is counted
    and reported once per event name (CL.RecordError, see /cl status)
    instead of breaking the handler for the rest of the session.

    With CL.debug on, every event logs its decoded arguments to
    CL.LOG_FILENAME (Core.lua's LogLine/FlushLog); "[FILTERED]" marks
    events that were seen but not recorded.
]]

local CL = CombatLedger

local cvarsToEnable = {
    "NP_EnableAutoAttackEvents",
    "NP_EnableSpellStartEvents",
    "NP_EnableSpellGoEvents",
    "NP_EnableSpellHealEvents",
    "NP_EnableSpellEnergizeEvents",
    "NP_EnableAuraCastEvents", -- AURA_CAST_ON_*, for the debuffs-given correlation below
    -- SPELL_DISPEL_* and BUFF/DEBUFF_ADDED_* need no CVar.
}
local function EnableCVars()
    local i
    for i = 1, table.getn(cvarsToEnable) do
        pcall(SetCVar, cvarsToEnable[i], "1")
    end
end

-- Spell name from the DBC, cached per spellId since it runs on nearly
-- every event and never changes. false caches a failed lookup so it
-- isn't retried every hit.
local spellNameCache = {}
local function SpellName(spellId)
    if not spellId or not GetSpellRecField then return nil end
    local cached = spellNameCache[spellId]
    if cached == nil then
        local ok, name = pcall(GetSpellRecField, spellId, "name")
        cached = (ok and type(name) == "string" and name ~= "") and name or false
        spellNameCache[spellId] = cached
    end
    return cached or nil
end

-- Nampower's *_OTHER events cover everyone nearby. An event is ours when
-- at least one side is the player, a group member or a pet (GuidCache's
-- roster): "we hit a mob" and "a mob hit us" pass, "a stranger hit an
-- unrelated mob" doesn't.
local function IsRelevant(guidA, guidB)
    if not CL.GuidCache then return false end
    return CL.GuidCache.IsTracked(guidA) or CL.GuidCache.IsTracked(guidB)
end

-- Time of the last relevant combat event. Drives the idle-timeout
-- fallback and trims trailing idle time off a finished encounter's
-- duration (Aggregator.EndEncounter). Only relevant events touch it -
-- nearby strangers' combat must not keep a finished fight "active".
local lastEventTime = 0
local function TouchActivity()
    lastEventTime = GetTime()
end

-- Mitigation observed on the event being handled, handed to
-- Aggregator.RecordDamage/RecordAvoidance (see ApplyMitigation there).
-- One reused scratch table: Record* reads it synchronously and never
-- keeps a reference. Returns nil when nothing was mitigated.
local mitScratch = {}
local function FillMitigation(absorbed, blocked, resisted, glancing, crushing)
    absorbed = tonumber(absorbed) or 0
    blocked = tonumber(blocked) or 0
    resisted = tonumber(resisted) or 0
    if absorbed <= 0 and blocked <= 0 and resisted <= 0 and not glancing and not crushing then
        return nil
    end
    mitScratch.absorbed = absorbed
    mitScratch.blocked = blocked
    mitScratch.resisted = resisted
    mitScratch.glancing = glancing
    mitScratch.crushing = crushing
    return mitScratch
end

-- AUTO_ATTACK_SELF/OTHER: attacker, target, totalDamage, hitInfo,
-- victimState, subDamageCount, blocked, absorbed, resisted. totalDamage
-- is already net of absorb/block/resist. A 0-damage swing was avoided
-- (victimState says how); off-hand swings carry hitInfo's 0x04 bit.
local function HandleAutoAttack(isSelf, attackerGuid, targetGuid, totalDamage, hitInfo, victimState, componentCount, blocked, absorbed, resisted)
    totalDamage = tonumber(totalDamage) or 0
    hitInfo = tonumber(hitInfo)
    local relevant = IsRelevant(attackerGuid, targetGuid)
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[AUTO_ATTACK_%s] atk=%s tgt=%s dmg=%d hitInfo=%s victimState=%s comp=%s blocked=%s absorbed=%s resisted=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER", tostring(attackerGuid), tostring(targetGuid), totalDamage,
            tostring(hitInfo), tostring(victimState), tostring(componentCount),
            tostring(blocked), tostring(absorbed), tostring(resisted)))
    end
    if not relevant then return end
    local isOffhand = CL.HasBit(hitInfo, CL.AUTO_ATTACK_HITFLAG_OFFHAND)
    local mit = FillMitigation(absorbed, blocked, resisted,
        CL.HasBit(hitInfo, CL.AUTO_ATTACK_HITFLAG_GLANCING),
        CL.HasBit(hitInfo, CL.AUTO_ATTACK_HITFLAG_CRUSHING))
    if totalDamage > 0 then
        local isCrit = CL.HasBit(hitInfo, CL.AUTO_ATTACK_HITFLAG_CRIT)
        CL.Aggregator.RecordDamage(attackerGuid, targetGuid, nil, nil, nil, totalDamage, isCrit, isOffhand, nil, mit)
    else
        -- A swing a shield soaked entirely arrives as a "normal" victim
        -- state with 0 damage - it's an absorb, not an unknown outcome.
        victimState = tonumber(victimState)
        local fullAbsorb = victimState == CL.VICTIMSTATE_NORMAL and mit and mit.absorbed > 0
        CL.Aggregator.RecordAvoidance(attackerGuid, targetGuid, victimState, isOffhand, mit, fullAbsorb)
    end
end

-- SPELL_DAMAGE_EVENT's effect argument is "effect1,effect2,effect3[,auraType]".
-- An aura type of 3 (PERIODIC_DAMAGE), 89 (PERIODIC_DAMAGE_PERCENT) or
-- 53 (PERIODIC_LEECH) marks the hit as a DoT tick rather than the spell's
-- direct hit, which lets the breakdown keep them apart (a direct hit can
-- crit, a tick can't). This is the only periodic signal damage events carry.
local PERIODIC_AURA_TYPES = { ["3"] = true, ["89"] = true, ["53"] = true }

-- Spells whose ticks carry no aura-type field (every hit is a tick).
-- Extend if another leech-style DoT turns out the same.
local ALWAYS_PERIODIC_SPELLS = {
    [18881] = true, -- Siphon Life
}

-- Captures the 4th field with a pattern instead of splitting, so nothing
-- is allocated per hit. A 3-field string (no aura type) doesn't match.
local function IsPeriodicEffect(effectStr, spellId)
    if ALWAYS_PERIODIC_SPELLS[spellId] then return true end
    if type(effectStr) ~= "string" then return false end
    local _, _, auraType = string.find(effectStr, "^[^,]*,[^,]*,[^,]*,([^,]*)")
    return auraType ~= nil and PERIODIC_AURA_TYPES[auraType] == true
end

-- SPELL_DAMAGE_EVENT's mitigation argument is "absorb,block,resist".
local function ParseSpellMitigation(text)
    if type(text) ~= "string" then return nil end
    local _, _, absorbed, blocked, resisted = string.find(text, "^(%d+),(%d+),(%d+)")
    if not absorbed then return nil end
    return FillMitigation(absorbed, blocked, resisted)
end

-- SPELL_DAMAGE_EVENT_SELF/OTHER: target, caster, spellId, amount,
-- mitigation, hitInfo (0x02 = crit), school, effect. A fully absorbed
-- spell (amount 0) isn't recorded.
local function HandleSpellDamage(isSelf, targetGuid, casterGuid, spellId, amount, mitigation, hitInfo, school, effect)
    amount = tonumber(amount) or 0
    spellId = tonumber(spellId)
    hitInfo = tonumber(hitInfo)
    local name = SpellName(spellId)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[SPELL_DAMAGE_EVENT_%s] tgt=%s caster=%s spell=%s(%s) dmg=%d mitigation=%s hitInfo=%s school=%s effect=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER", tostring(targetGuid), tostring(casterGuid),
            tostring(name), tostring(spellId), amount, tostring(mitigation), tostring(hitInfo), tostring(school), tostring(effect)))
    end
    if relevant and amount > 0 then
        local isCrit = CL.HasBit(hitInfo, CL.SPELL_DAMAGE_HITFLAG_CRIT)
        local isPeriodic = IsPeriodicEffect(effect, spellId)
        CL.Aggregator.RecordDamage(casterGuid, targetGuid, spellId, name, school, amount, isCrit, nil, isPeriodic,
            ParseSpellMitigation(mitigation))
    end
end

-- Heal events carry no overheal, so it's estimated from the target's
-- missing health when the event arrives (the health read is from before
-- the heal lands): effective = min(heal, maxHp - hp). SuperWoW accepts
-- the raw GUID as the unit. Outside the group health reads as a 0-100
-- percentage, which can't be compared to a heal amount - such heals
-- count as fully effective and are flagged unverified.
-- Returns effective, overheal, verified, hp, maxHp (the last two for
-- the debug log).
local function EstimateHeal(targetGuid, amount)
    if not targetGuid or not UnitHealth or not UnitHealthMax then return amount, 0, false end
    local okHp, hp = pcall(UnitHealth, targetGuid)
    local okMax, maxHp = pcall(UnitHealthMax, targetGuid)
    hp, maxHp = okHp and tonumber(hp), okMax and tonumber(maxHp)
    if not hp or not maxHp or maxHp <= 0 then return amount, 0, false, hp, maxHp end
    if maxHp == 100 and not CL.GuidCache.IsTracked(targetGuid) then return amount, 0, false, hp, maxHp end
    local deficit = maxHp - hp
    if deficit < 0 then deficit = 0 end
    local effective = (amount < deficit) and amount or deficit
    return effective, amount - effective, true, hp, maxHp
end

-- SPELL_HEAL_BY_SELF/OTHER: target, caster, spellId, amount, crit,
-- periodic. SPELL_HEAL_ON_SELF isn't registered: it duplicates whichever
-- BY_* event already reported a heal landing on the player.
local function HandleSpellHeal(targetGuid, casterGuid, spellId, amount, critFlag, periodicFlag)
    amount = tonumber(amount) or 0
    spellId = tonumber(spellId)
    local name = SpellName(spellId)
    local isCrit = (critFlag == "1" or critFlag == 1 or critFlag == true)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end
    local effective, overheal, verified, hp, maxHp
    if relevant and amount > 0 then
        effective, overheal, verified, hp, maxHp = EstimateHeal(targetGuid, amount)
    end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[SPELL_HEAL] tgt=%s caster=%s spell=%s(%s) heal=%d crit=%s periodic=%s hp=%s/%s eff=%s over=%s verified=%s",
            relevant and "" or "[FILTERED] ", tostring(targetGuid), tostring(casterGuid), tostring(name), tostring(spellId),
            amount, tostring(critFlag), tostring(periodicFlag), tostring(hp), tostring(maxHp),
            tostring(effective), tostring(overheal), tostring(verified)))
    end
    if relevant and amount > 0 then
        CL.Aggregator.RecordHealing(casterGuid, targetGuid, spellId, name, amount, effective, overheal, isCrit, verified)
    end
end

-- SPELL_DISPEL_BY_SELF/OTHER: caster, target, spellId. The spellId is
-- the aura that was removed, not the dispel spell, so the breakdown reads
-- "what was cleansed" (Poison x3) rather than "Cleanse x3".
local function HandleSpellDispel(casterGuid, targetGuid, spellId)
    spellId = tonumber(spellId)
    local name = SpellName(spellId)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[SPELL_DISPEL] caster=%s tgt=%s spell=%s(%s)",
            relevant and "" or "[FILTERED] ", tostring(casterGuid), tostring(targetGuid), tostring(name), tostring(spellId)))
    end
    if relevant then
        CL.Aggregator.RecordCleanse(casterGuid, targetGuid, spellId, name)
    end
end

-- Debuffs given need two events that each carry half the answer and fire
-- back to back for the same cast:
--   AURA_CAST_ON_*  spellId, caster, target  (who cast it, but not
--                   whether the aura is a buff or a debuff)
--   DEBUFF_ADDED_*  guid, slot, spellId      (only fires for debuffs,
--                   but has no caster)
-- AURA_CAST stashes the caster under (target, spellId); DEBUFF_ADDED
-- claims it. Buff-side casts are never claimed (BUFF_ADDED_* isn't
-- registered - "buffs given" doesn't fit a per-encounter meter, since
-- buffing happens before the pull) and expire in the OnUpdate sweep.
local pendingAuraCasts = {} -- [targetGuid.."|"..spellId] = { casterGuid, time }
local PENDING_AURA_WINDOW = 2 -- seconds; the pair normally arrives back to back

local function HandleAuraCast(spellId, casterGuid, targetGuid)
    spellId = tonumber(spellId)
    if not spellId or not targetGuid then return end
    if CL.debug then
        CL.LogLine(string.format("[AURA_CAST] caster=%s tgt=%s spell=%s(%s)",
            tostring(casterGuid), tostring(targetGuid), tostring(SpellName(spellId)), tostring(spellId)))
    end
    if not IsRelevant(casterGuid, targetGuid) then return end
    pendingAuraCasts[targetGuid .. "|" .. spellId] = { casterGuid = casterGuid, time = GetTime() }

    -- One AURA_CAST per actual cast, which is what the breakdown's
    -- "Casts" line counts for a DoT (whose damage entry counts ticks).
    CL.Aggregator.RecordCast(casterGuid, spellId, SpellName(spellId))
end

local function HandleDebuffAdded(guid, spellId)
    spellId = tonumber(spellId)
    if not spellId or not guid then return end
    local key = guid .. "|" .. spellId
    local pending = pendingAuraCasts[key]
    if CL.debug then
        CL.LogLine(string.format("[AURA_ADDED] DEBUFF guid=%s spell=%s(%s) matched=%s",
            tostring(guid), tostring(SpellName(spellId)), tostring(spellId), tostring(pending ~= nil)))
    end
    if not pending then return end
    pendingAuraCasts[key] = nil
    if (GetTime() - pending.time) > PENDING_AURA_WINDOW then return end
    if not IsRelevant(pending.casterGuid, guid) then return end
    CL.Aggregator.RecordDebuffGiven(pending.casterGuid, guid, spellId, SpellName(spellId))
end

-- Events whose argument layout isn't decoded yet (SPELL_ENERGIZE_*) are
-- logged raw so their shape can be read off a debug log.
local function LogRawEvent(tag)
    if not CL.debug then return end
    CL.LogLine(string.format("[RAW %s] a1=%s a2=%s a3=%s a4=%s a5=%s a6=%s a7=%s a8=%s a9=%s",
        tag, tostring(arg1), tostring(arg2), tostring(arg3), tostring(arg4),
        tostring(arg5), tostring(arg6), tostring(arg7), tostring(arg8), tostring(arg9)))
end

-- DAMAGE_SHIELD_SELF/OTHER: caster (the unit wearing Thorns/Retribution
-- Aura/...), target (whoever struck it), amount, school. No spellId comes
-- with it, so all reflect damage shares one synthetic "Reflect" entry.
local REFLECT_SPELL_ID = -1

local function HandleDamageShield(isSelf, casterGuid, targetGuid, amount, school)
    amount = tonumber(amount) or 0
    school = tonumber(school)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[DAMAGE_SHIELD_%s] caster=%s tgt=%s dmg=%d school=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER",
            tostring(casterGuid), tostring(targetGuid), amount, tostring(school)))
    end
    if relevant and amount > 0 then
        CL.Aggregator.RecordDamage(casterGuid, targetGuid, REFLECT_SPELL_ID, "Reflect", school, amount, false, nil, false)
    end
end

-- SPELL_MISS_SELF/OTHER: caster, target, spellId, missInfo (see
-- Aggregator's SPELL_MISS_KEY). Also covers yellow melee specials (a
-- dodged Sinister Strike), which never reach AUTO_ATTACK.
local function HandleSpellMiss(isSelf, casterGuid, targetGuid, spellId, missInfo)
    spellId = tonumber(spellId)
    missInfo = tonumber(missInfo)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format("%s[SPELL_MISS_%s] caster=%s tgt=%s spell=%s(%s) missInfo=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER", tostring(casterGuid), tostring(targetGuid),
            tostring(SpellName(spellId)), tostring(spellId), tostring(missInfo)))
    end
    if relevant and spellId then
        CL.Aggregator.RecordSpellMiss(casterGuid, targetGuid, spellId, missInfo)
    end
end

-- ENVIRONMENTAL_DMG_SELF/OTHER: unit, damageType, damage, absorb, resist.
-- There's no attacker, so it's Damage Taken only, under one synthetic
-- negative spellId per type so each type gets its own breakdown row.
-- Never starts an encounter: falling or drowning alone isn't a fight.
local ENVIRONMENT_TYPES = {
    [0] = { name = "Fatigue", school = 0 },
    [1] = { name = "Drowning", school = 0 },
    [2] = { name = "Falling", school = 0 },
    [3] = { name = "Lava", school = 2 },
    [4] = { name = "Slime", school = 3 },
    [5] = { name = "Fire", school = 2 },
    [6] = { name = "Falling", school = 0 },
}
local ENVIRONMENT_SPELL_ID_BASE = -100

local function HandleEnvironmentalDamage(isSelf, unitGuid, damageType, amount)
    damageType = tonumber(damageType)
    amount = tonumber(amount) or 0
    local tracked = CL.GuidCache.IsTracked(unitGuid)
    local live = CL.Aggregator.GetCurrent() ~= nil
    if CL.debug then
        CL.LogLine(string.format("%s[ENVIRONMENTAL_DMG_%s] unit=%s type=%s dmg=%d a4=%s a5=%s",
            (tracked and live) and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER", tostring(unitGuid),
            tostring(damageType), amount, tostring(arg4), tostring(arg5)))
    end
    if not tracked or not live or amount <= 0 then return end
    TouchActivity()
    local env = ENVIRONMENT_TYPES[damageType] or { name = "Environment", school = 0 }
    local spellId = ENVIRONMENT_SPELL_ID_BASE - (damageType or 99)
    CL.Aggregator.RecordDamage(nil, unitGuid, spellId, env.name, env.school, amount, false, nil, false)
end

--------------------------------------------------------------------------
-- Encounter lifecycle
--
-- Start: PLAYER_REGEN_DISABLED, or lazily on the first recorded event
-- (see Aggregator's ShouldLazyStart/IsGroupFighting).
-- End: PLAYER_REGEN_ENABLED only arms a pending end (pendingEndSince);
-- OnUpdate finishes the encounter once the player, every group member
-- and every pet have been out of combat for END_DEBOUNCE seconds. So
-- dying, Feign Death or briefly dropping combat mid-pull doesn't split
-- the fight while the group is still engaged, and re-entering combat
-- inside the debounce continues the same encounter.
-- Fallback: CL.IDLE_SECONDS without a relevant event ends it too
-- (targets like training dummies never toggle regen), unless the group
-- is still in combat.
--------------------------------------------------------------------------

local END_DEBOUNCE = 1.5
local pendingEndSince = nil
local autoShownMainWindow = false -- first PLAYER_ENTERING_WORLD only, see below

local function IsGrouped()
    return ((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0
        or ((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0
end

--------------------------------------------------------------------------
-- Automatic Overall resets (Options, "Clear Overall"): on joining a
-- group, leaving one, or entering an instance, each Off/Ask/Always.
-- Never applied mid-fight: a reset requested while an encounter is live
-- waits until it finishes (the latest request wins).
--------------------------------------------------------------------------

-- Grouped state as of the last roster event, so the join/leave rules
-- fire only on actual transitions. Re-read on the first loading screen,
-- since group info isn't available yet when this file loads.
local wasGrouped = IsGrouped()
local pendingReset = nil -- { mode, reason } waiting for the live fight to end

local function ApplyReset(mode, reason)
    if mode == "always" then
        CL.Aggregator.ResetOverall()
        if CL.UI and CL.UI.RefreshAllInstances then CL.UI.RefreshAllInstances() end
        CL.Print("Overall cleared - " .. reason)
    elseif mode == "ask" then
        StaticPopup_Show("COMBATLEDGER_CLEAR_OVERALL", reason)
    end
end

local function RequestReset(settingKey, reason)
    local mode = CL.GetSetting(settingKey)
    if mode ~= "ask" and mode ~= "always" then return end
    if CL.Aggregator.GetCurrent() then
        pendingReset = { mode = mode, reason = reason }
    else
        ApplyReset(mode, reason)
    end
end

-- Entering an instance counts only when it's a different instance than
-- the last one, or the player has been away from it for a while - a
-- corpse run or a quick trip out doesn't ask again. Saved, so a /reload
-- inside the instance doesn't count either.
local INSTANCE_REENTRY_SECONDS = 1800

local function CheckInstanceEntry()
    local inInstance = IsInInstance and IsInInstance()
    local zone = (GetRealZoneText and GetRealZoneText()) or ""
    local last = CombatLedgerDB.lastInstance
    if inInstance then
        if not last or last.zone ~= zone or (time() - (last.seen or 0)) > INSTANCE_REENTRY_SECONDS then
            RequestReset("clearOnEnterInstanceMode", "you entered " .. zone .. ".")
        end
        CombatLedgerDB.lastInstance = { zone = zone, seen = time() }
    elseif last then
        last.seen = time() -- time of leaving: the absence is measured from here
    end
end

local UnitInCombat = CL.GuidCache.UnitInCombat
local AnyGroupMemberInCombat = CL.GuidCache.AnyGroupMemberInCombat -- cached ~0.25s, see GuidCache.lua

local function FinishEncounter()
    pendingEndSince = nil
    local finished = CL.Aggregator.EndEncounter(lastEventTime)
    if not finished then return end

    if pendingReset then
        local reset = pendingReset
        pendingReset = nil
        ApplyReset(reset.mode, reset.reason)
    end

    -- Not saved: near-empty encounters (a stray hit before the idle
    -- timeout), and non-boss fights while "Remember boss fights only" is on.
    local bossOnly = CL.GetSetting("historyBossOnly") and not finished.isBoss
    if finished.duration > 1 and CL.TableCount(finished.units) > 0 and not bossOnly and CL.History then
        CL.History.SaveEncounter(finished)
    end

    -- The idle-timeout path can finish an encounter while the player is
    -- still flagged in combat; auto-hiding then would leave the window
    -- hidden mid-fight, so only hide when genuinely out of combat.
    if CL.UI and CL.UI.ApplyAutoHide and not UnitAffectingCombat("player") then
        CL.UI.ApplyAutoHide()
        CL.UI.ApplyCombatModes(false)
    end

    if CL.debug then
        CL.Print(string.format("Encounter ended: %.1fs, %d unit(s) tracked.",
            finished.duration, CL.TableCount(finished.units)))
        CL.LogLine(string.format("[REGEN] FinishEncounter: %.1fs, %d unit(s) tracked.",
            finished.duration, CL.TableCount(finished.units)))
        CL.FlushLog()
    end
end

-- Debug log only: the player's and group's combat flags at each regen
-- event, for reading encounter boundaries back out of a log.
local function LogRegenDiagnostic(evt)
    if not CL.debug then return end
    local okP, playerCombat = pcall(UnitAffectingCombat, "player")
    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    local othersInCombat = 0
    local i
    if raidN > 0 then
        for i = 1, raidN do
            local ok, inCombat = pcall(UnitAffectingCombat, "raid" .. i)
            if ok and inCombat then othersInCombat = othersInCombat + 1 end
        end
    elseif partyN > 0 then
        for i = 1, partyN do
            local ok, inCombat = pcall(UnitAffectingCombat, "party" .. i)
            if ok and inCombat then othersInCombat = othersInCombat + 1 end
        end
    end
    CL.LogLine(string.format("[REGEN] %s t=%.1f playerCombat=%s raidN=%d partyN=%d membersInCombat=%d",
        evt, GetTime(), tostring(okP and playerCombat), raidN, partyN, othersInCombat))
end

--------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------

-- Reads the 1.12 event globals (event, arg1..arg9) directly so it can be
-- pcall'd without building an argument table per event.
local function Dispatch()
    if event == "PLAYER_ENTERING_WORLD" then
        EnableCVars()
        CL.GuidCache.Purge()
        CL.GuidCache.RefreshRoster()
        -- Once per session, not per loading screen. SavedVariables are
        -- only in place by now (not at file load), so this is the first
        -- point where saved state and window layouts can be restored.
        if not autoShownMainWindow then
            autoShownMainWindow = true
            wasGrouped = IsGrouped()
            -- Restore before the first Show() so windows open on real data.
            CL.Aggregator.RestoreState(CombatLedgerDB.liveState)
            if CL.Aggregator.GetCurrent() then
                -- A restored live fight gets the normal idle/end handling;
                -- reloading out of combat means no REGEN_ENABLED will
                -- come, so arm the end debounce directly.
                TouchActivity()
                if not UnitInCombat("player") then
                    pendingEndSince = GetTime()
                end
            end
            if CL.UI and CL.UI.RestoreAllWindows then
                CL.UI.RestoreAllWindows()
            end
            if CL.UIOptions then
                CL.UIOptions.RefreshMinimapVisibility()
                CL.UIOptions.RefreshMinimapPosition()
            end
        end
        -- After the restore above, so a reset isn't undone by it.
        CheckInstanceEntry()
        return
    end

    if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" or event == "UNIT_PET" then
        -- UNIT_PET: a pet summoned/dismissed/killed changes the roster
        -- without changing group composition.
        CL.GuidCache.RefreshRoster()
        if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
            if CL.UI and CL.UI.ReconcileGroupVisibility then
                CL.UI.ReconcileGroupVisibility()
            end
            local grouped = IsGrouped()
            if grouped and not wasGrouped then
                RequestReset("clearOnJoinPartyMode", "you joined a group.")
            elseif wasGrouped and not grouped then
                RequestReset("clearOnLeavePartyMode", "you left the group.")
            end
            wasGrouped = grouped
        end
        return
    end

    if event == "PLAYER_LOGOUT" then
        -- Also fires on /reload. Current and Overall live only in
        -- Aggregator locals, so they're persisted here and restored on
        -- the next PLAYER_ENTERING_WORLD.
        CL.FlushLog()
        CombatLedgerDB.liveState = CL.Aggregator.SerializeState()
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        LogRegenDiagnostic("DISABLED")
        TouchActivity()
        pendingEndSince = nil
        CL.Aggregator.StartEncounter()
        if CL.UI and CL.UI.ApplyAutoShow then
            CL.UI.ApplyAutoShow()
            CL.UI.ApplyCombatModes(true)
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        LogRegenDiagnostic("ENABLED")
        if CL.Aggregator.GetCurrent() then
            pendingEndSince = GetTime()
        end
        return
    end

    if event == "AUTO_ATTACK_SELF" then
        HandleAutoAttack(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
        return
    end
    if event == "AUTO_ATTACK_OTHER" then
        HandleAutoAttack(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
        return
    end

    if event == "SPELL_DAMAGE_EVENT_SELF" then
        HandleSpellDamage(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        return
    end
    if event == "SPELL_DAMAGE_EVENT_OTHER" then
        HandleSpellDamage(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        return
    end

    if event == "SPELL_HEAL_BY_SELF" or event == "SPELL_HEAL_BY_OTHER" then
        HandleSpellHeal(arg1, arg2, arg3, arg4, arg5, arg6)
        return
    end

    if event == "SPELL_MISS_SELF" or event == "SPELL_MISS_OTHER" then
        HandleSpellMiss(event == "SPELL_MISS_SELF", arg1, arg2, arg3, arg4)
        return
    end

    if event == "ENVIRONMENTAL_DMG_SELF" or event == "ENVIRONMENTAL_DMG_OTHER" then
        HandleEnvironmentalDamage(event == "ENVIRONMENTAL_DMG_SELF", arg1, arg2, arg3)
        return
    end

    if event == "DAMAGE_SHIELD_SELF" then
        HandleDamageShield(true, arg1, arg2, arg3, arg4)
        return
    end
    if event == "DAMAGE_SHIELD_OTHER" then
        HandleDamageShield(false, arg1, arg2, arg3, arg4)
        return
    end

    if event == "SPELL_ENERGIZE_BY_SELF" or event == "SPELL_ENERGIZE_BY_OTHER" or event == "SPELL_ENERGIZE_ON_SELF" then
        LogRawEvent(event)
        return
    end

    if event == "SPELL_DISPEL_BY_SELF" or event == "SPELL_DISPEL_BY_OTHER" then
        HandleSpellDispel(arg1, arg2, arg3)
        return
    end

    if event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
        HandleAuraCast(arg1, arg2, arg3)
        return
    end

    if event == "DEBUFF_ADDED_SELF" or event == "DEBUFF_ADDED_OTHER" then
        HandleDebuffAdded(arg1, arg3)
        return
    end

    if event == "UNIT_DIED" then
        if arg1 then
            local attributed = CL.Aggregator.RecordDeath(arg1)
            -- The recap opens by itself only for the player's own death;
            -- a wipe would otherwise stack a window per raid member.
            if attributed and CL.UIDeathRecap then
                local ok, exists, playerGuid = pcall(UnitExists, "player")
                if ok and exists and attributed == playerGuid then
                    CL.UIDeathRecap.Show(attributed)
                end
            end
        end
        return
    end
end

--------------------------------------------------------------------------
-- Periodic work (OnUpdate)
--------------------------------------------------------------------------

local flushAccum = 0
local cleanupAccum = 0
local CACHE_CLEANUP_SECONDS = 60
local idleSuppressedLogged = false

-- Reads the OnUpdate elapsed-time global (arg1) directly; see Dispatch.
local function Tick()
    local elapsed = arg1
    flushAccum = flushAccum + elapsed
    if flushAccum >= 1 then
        flushAccum = 0
        -- Debug log writes are batched to once a second rather than per event.
        CL.FlushLog()
        -- A BigWigs encounter engaging marks the fight as a boss fight
        -- even before (or without) a hit on a rank-tagged boss.
        if CL.Aggregator.GetCurrent() then
            CL.Aggregator.MarkBoss(CL.Bosses.GetEngagedEncounter(), true)
        end
        -- AURA_CAST entries that were never claimed (buff casts, filtered
        -- targets) expire here so the table stays small.
        local key, pending
        for key, pending in pairs(pendingAuraCasts) do
            if (GetTime() - pending.time) > PENDING_AURA_WINDOW then
                pendingAuraCasts[key] = nil
            end
        end
    end

    cleanupAccum = cleanupAccum + elapsed
    if cleanupAccum >= CACHE_CLEANUP_SECONDS then
        cleanupAccum = 0
        CL.GuidCache.CleanupStale()
    end

    -- An encounter lazily started while the player was never flagged in
    -- combat (a heal on a fighting groupmate) gets no REGEN_ENABLED, so
    -- arm its end once the group is seen fighting. Not armed when the
    -- group isn't fighting either, so a solo training-dummy fight keeps
    -- relying on the idle timeout.
    if not pendingEndSince and CL.Aggregator.GetCurrent() and not UnitInCombat("player")
        and AnyGroupMemberInCombat() then
        pendingEndSince = GetTime()
    end

    if pendingEndSince then
        local now = GetTime()
        if not CL.Aggregator.GetCurrent() then
            pendingEndSince = nil
        elseif UnitInCombat("player") then
            -- Back in combat without a REGEN_DISABLED (restored state).
            pendingEndSince = nil
        else
            if AnyGroupMemberInCombat() then
                pendingEndSince = now
            elseif now - pendingEndSince >= END_DEBOUNCE then
                if CL.debug then CL.LogLine("[REGEN] debounced end - player and group out of combat") end
                FinishEncounter()
                return
            end
        end
    end

    -- Idle fallback. Suppressed while any group member is in combat: a
    -- quiet stretch in the player's own events (a healer off to the side)
    -- doesn't mean the raid stopped, and ending here would split the pull.
    if CL.Aggregator.GetCurrent() and lastEventTime > 0 and (GetTime() - lastEventTime) > CL.IDLE_SECONDS then
        local grouped = IsGrouped()
        if not grouped or not AnyGroupMemberInCombat() then
            if CL.debug and grouped and idleSuppressedLogged then
                CL.LogLine("[REGEN] idle-timeout finishing - group also clear")
            end
            idleSuppressedLogged = false
            FinishEncounter()
        else
            if CL.debug and not idleSuppressedLogged then
                CL.LogLine("[REGEN] idle-timeout suppressed - group still in combat")
            end
            idleSuppressedLogged = true
        end
    else
        idleSuppressedLogged = false
    end
end

local f = CreateFrame("Frame")

f:SetScript("OnEvent", function()
    CL.CountEvent(event)
    local ok, err = pcall(Dispatch)
    if not ok then CL.RecordError(event, err) end
end)

f:SetScript("OnUpdate", function()
    local ok, err = pcall(Tick)
    if not ok then CL.RecordError("Events:OnUpdate", err) end
end)

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("UNIT_PET")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("AUTO_ATTACK_SELF")
f:RegisterEvent("AUTO_ATTACK_OTHER")
f:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
f:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER")
f:RegisterEvent("SPELL_HEAL_BY_SELF")
f:RegisterEvent("SPELL_HEAL_BY_OTHER")
f:RegisterEvent("SPELL_MISS_SELF")
f:RegisterEvent("SPELL_MISS_OTHER")
f:RegisterEvent("ENVIRONMENTAL_DMG_SELF")
f:RegisterEvent("ENVIRONMENTAL_DMG_OTHER")
f:RegisterEvent("DAMAGE_SHIELD_SELF")
f:RegisterEvent("DAMAGE_SHIELD_OTHER")
f:RegisterEvent("SPELL_ENERGIZE_BY_SELF")
f:RegisterEvent("SPELL_ENERGIZE_BY_OTHER")
f:RegisterEvent("SPELL_ENERGIZE_ON_SELF")
f:RegisterEvent("SPELL_DISPEL_BY_SELF")
f:RegisterEvent("SPELL_DISPEL_BY_OTHER")
f:RegisterEvent("AURA_CAST_ON_SELF")
f:RegisterEvent("AURA_CAST_ON_OTHER")
f:RegisterEvent("DEBUFF_ADDED_SELF")
f:RegisterEvent("DEBUFF_ADDED_OTHER")
f:RegisterEvent("UNIT_DIED")

--------------------------------------------------------------------------
-- /cl status
--------------------------------------------------------------------------

-- Nampower's combat events, i.e. the data source. Counted separately from
-- lifecycle events so status can show whether combat data is arriving.
local COMBAT_EVENTS = {
    "AUTO_ATTACK_SELF", "AUTO_ATTACK_OTHER", "SPELL_DAMAGE_EVENT_SELF", "SPELL_DAMAGE_EVENT_OTHER",
    "SPELL_HEAL_BY_SELF", "SPELL_HEAL_BY_OTHER", "SPELL_MISS_SELF", "SPELL_MISS_OTHER",
    "ENVIRONMENTAL_DMG_SELF", "ENVIRONMENTAL_DMG_OTHER", "DAMAGE_SHIELD_SELF", "DAMAGE_SHIELD_OTHER",
    "SPELL_DISPEL_BY_SELF", "SPELL_DISPEL_BY_OTHER", "AURA_CAST_ON_SELF", "AURA_CAST_ON_OTHER",
    "DEBUFF_ADDED_SELF", "DEBUFF_ADDED_OTHER", "UNIT_DIED",
}

local function YesNo(v) return v and "|cff40ff40yes|r" or "|cffff4040no|r" end

local function PrintStatus()
    local version = (GetAddOnMetadata and GetAddOnMetadata("CombatLedger", "Version")) or "?"
    CL.Print("Status (v" .. version .. ")")

    -- Data source: Nampower's events plus SuperWoW's GUID-as-unit support.
    local npVersion = "not loaded"
    if GetNampowerVersion then
        local ok, a, b, c = pcall(GetNampowerVersion)
        if ok and a then
            npVersion = tostring(a)
            if b then npVersion = npVersion .. "." .. tostring(b) end
            if c then npVersion = npVersion .. "." .. tostring(c) end
        end
    end
    local okGuid, _, playerGuid = pcall(UnitExists, "player")
    CL.Print(string.format("  Nampower: %s   GUID units: %s   Debug log file: %s   Debug: %s",
        npVersion, YesNo(okGuid and playerGuid), YesNo(WriteCustomFile ~= nil), CL.debug and "on" or "off"))

    local diag = CL.Diagnostics
    local combatTotal = 0
    local i
    for i = 1, table.getn(COMBAT_EVENTS) do
        combatTotal = combatTotal + (diag.eventCounts[COMBAT_EVENTS[i]] or 0)
    end
    CL.Print(string.format("  Combat events received this session: %d", combatTotal))

    if CL.Threat and CL.Threat.GetLastUpdate then
        local last = CL.Threat.GetLastUpdate()
        CL.Print("  Threat: " .. ((last and last > 0)
            and string.format("last server reply %.0fs ago", GetTime() - last)
            or "no server reply this session (local estimate only)"))
    end

    local errorTags = 0
    local tag, count
    for tag, count in pairs(diag.errorCounts) do
        errorTags = errorTags + 1
        CL.Print(string.format("  |cffff4040Error|r %s x%d: %s", tag, count, tostring(diag.lastErrors[tag])))
    end
    if errorTags == 0 then CL.Print("  Errors: none") end

    local cur = CL.Aggregator.GetCurrent()
    if not cur then
        CL.Print("  No live encounter.")
        return
    end
    CL.Print(string.format("  Live encounter: %.1fs elapsed, %d unit(s) tracked.",
        GetTime() - cur.startTime, CL.TableCount(cur.units)))
    local guid, u
    for guid, u in pairs(cur.units) do
        CL.Print(string.format("    %s - dmgDone=%d dmgTaken=%d healDone=%d deaths=%d",
            tostring(u.name), u.damageDone.total, u.damageTaken.total, u.healingDone.total, u.deaths))
    end
end

SLASH_COMBATLEDGER1 = "/cl"
SlashCmdList["COMBATLEDGER"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "debug" then
        CL.debug = not CL.debug
        -- Persisted, so debug stays on across a relaunch and can capture
        -- the very first PLAYER_ENTERING_WORLD.
        CombatLedgerDB.settings.debug = CL.debug
        CL.Print("Debug " .. (CL.debug and "ON" or "OFF"))
    elseif msg == "status" then
        PrintStatus()
    elseif msg == "flush" then
        if not WriteCustomFile then
            CL.Print("WriteCustomFile isn't available on this Nampower build - can't write the debug log to file.")
        else
            CL.FlushLog()
            CL.Print("Log flushed to " .. CL.LOG_FILENAME .. ".")
        end
    elseif msg == "show" then
        if CL.UI then CL.UI.Show() end
    elseif msg == "hide" then
        if CL.UI then CL.UI.Hide() end
    elseif msg == "toggle" or msg == "" then
        if CL.UI then CL.UI.Toggle() end
    elseif msg == "history" then
        if CL.UIHistory then CL.UIHistory.Toggle() end
    elseif msg == "report" then
        local enc = CL.Aggregator.GetCurrentDisplay()
        if enc and CL.UIEncounterReport then
            CL.UIEncounterReport.Show(enc)
        else
            CL.Print("No current or recent encounter to report on yet.")
        end
    elseif msg == "options" or msg == "opt" then
        if CL.UIOptions then CL.UIOptions.Toggle() end
    elseif msg == "testdeath" then
        -- Shows the recap from the current rolling hit buffer without
        -- touching the real death count.
        local ok, exists, playerGuid = pcall(UnitExists, "player")
        if ok and exists and playerGuid then
            CL.Aggregator.SnapshotDeathRecap(playerGuid)
            if CL.UIDeathRecap then CL.UIDeathRecap.Show(playerGuid) end
        end
    else
        CL.Print("/cl toggle|show|hide - meter window. /cl options - lock/minimap/appearance settings. /cl history - saved encounters. /cl report - graph + leaderboard for the current/last fight. /cl testdeath - preview the death recap without dying. /cl debug - toggle event logging. /cl status - data source, errors and live encounter. /cl flush - force-write the debug log now.")
    end
end

EnableCVars()
CL.Print("Loaded. /cl toggle to show the meter, /cl options for settings, /cl help for commands.")

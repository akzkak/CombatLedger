--[[
    Aggregator - encounter lifecycle and all recorded combat data.

    The live encounter (`current`), the session-long Overall (`overall`)
    and saved History entries share one shape, so every window renders
    any of them with the same code:

        encounter = {
            label, zone, startTime, timestamp, duration, isBoss, bossName, pullBy,
            series,                          -- per-2s raid totals for the report graph
            units = {
                [guid] = {                   -- roster members only; pets merge into owners (option)
                    name, class, classToken, isPlayer, deaths,
                    damageDone  = bucket,    -- see NewBucket
                    damageTaken = bucket,    -- .targets = attackers
                    healingDone = { total (effective), raw, overheal, unverified, spells, targets },
                    cleanses, debuffsGiven = { total (count), spells, targets },
                },
            },
        }

    A bucket holds total, spells[spellId], melee/offhand/petMelee/
    petOffhand entries (auto-attacks have no spellId), per-target
    sub-buckets of the same shape, and optional spellMisses/mit tables.

    Every Record* writes into both `current` and `overall`: two
    independent unit tables fed the same events. Record* functions are the
    only mutators and each bumps dataVersion (see GetDataVersion).
]]

local CL = CombatLedger

local current = nil -- the live encounter, or nil if not in one

-- Bumped by every mutator (Record*, encounter start/end, resets,
-- restore); the UI skips redrawing windows whose data hasn't changed.
-- May over-count (a Record* that filters its event out still bumps it),
-- never under-count.
local dataVersion = 0

-- startTime is GetTime() (what every elapsed/rate calculation subtracts
-- from); startTimeReal is wall-clock time() for RestoreState's
-- staleness check.
local function NewEncounter()
    return {
        label = nil,
        zone = (GetRealZoneText and GetRealZoneText()) or "",
        startTime = GetTime(),
        startTimeReal = time(),
        units = {},
        activeDuration = 0, -- only meaningful for `overall` (see GetOverallDuration) - sum of finished encounters' durations, so idle time between pulls doesn't dilute Overall DPS
        pullBy = nil, -- { name, label } - set once, from whoever's action started this encounter
        mobTally = {}, -- [guid] = damage dealt to it by tracked casters - label-only, not a real bar entry (mobs are deliberately excluded from units)
        mobHealth = {}, -- [guid] = UnitHealthMax(guid), sampled once per mob - label-only, same reasoning as mobTally (see History.lua's ComputeLabel)
        -- Raid-wide damage/healing/taken per fixed time bucket, for
        -- UI_EncounterReport's graph. Bucketed rather than a per-event
        -- log so saved encounters stay small.
        series = {},
    }
end

-- Series bucket width. Only `current` records a series; Overall isn't a
-- single fight to graph.
local TIMELINE_BUCKET_SECONDS = 2

local function RecordSeriesPoint(enc, kind, amount)
    if not enc or not enc.startTime or not enc.series then return end
    local elapsed = GetTime() - enc.startTime
    local idx = math.floor(elapsed / TIMELINE_BUCKET_SECONDS) + 1
    if idx < 1 then idx = 1 end
    local bucket = enc.series[idx]
    if not bucket then
        bucket = { damage = 0, healing = 0, taken = 0 }
        enc.series[idx] = bucket
    end
    bucket[kind] = (bucket[kind] or 0) + amount
end

local overall = NewEncounter() -- long-lived; only cleared by ResetOverall()

-- Death recap: a rolling RECAP_WINDOW-second list of hits taken per
-- tracked unit (the raw sequence, not totals), snapshotted on death.
-- Session only - not saved with encounters.
local RECAP_WINDOW = 10 -- seconds of history kept per tracked unit
local recapBuffers = {} -- [guid] = { {time, attacker, label, amount, isCrit}, ... }, oldest first
local lastDeathRecap = {} -- [guid] = { deathTime, hits = {...snapshot...} }

local function RecordRecapHit(guid, attacker, label, amount, isCrit)
    local buf = recapBuffers[guid]
    if not buf then
        buf = {}
        recapBuffers[guid] = buf
    end
    table.insert(buf, { time = GetTime(), attacker = attacker, label = label, amount = amount, isCrit = isCrit })

    local cutoff = GetTime() - RECAP_WINDOW
    while table.getn(buf) > 0 and buf[1].time < cutoff do
        table.remove(buf, 1)
    end
end

local function SnapshotDeathRecap(guid)
    local buf = recapBuffers[guid]
    local copy = {}
    if buf then
        local i
        for i = 1, table.getn(buf) do
            copy[i] = buf[i]
        end
    end
    lastDeathRecap[guid] = { deathTime = GetTime(), hits = copy }
end

local function GetDeathRecap(guid)
    return guid and lastDeathRecap[guid]
end

local function NewAvoided()
    return { miss = 0, dodge = 0, parry = 0, block = 0, evade = 0, immune = 0, deflect = 0, other = 0 }
end

-- Melee entries carry their own avoidance counts (white-swing outcomes
-- from AUTO_ATTACK), so each melee row can show its own miss/dodge/parry
-- rates. Spell misses are kept separately in bucket.spellMisses.
local function NewMeleeEntry()
    return { hits = 0, crits = 0, total = 0, critTotal = 0, min = nil, max = nil, avoided = NewAvoided() }
end

local function NewBucket()
    return {
        total = 0,
        spells = {},
        melee = NewMeleeEntry(),
        -- Off-hand swings, kept apart from main-hand (different hit caps).
        offhand = NewMeleeEntry(),
        -- A merged pet's swings: same unit total as the owner, but its own
        -- breakdown row rather than inflating the owner's "Auto Attack".
        petMelee = NewMeleeEntry(),
        petOffhand = NewMeleeEntry(),
        -- Per-target sub-buckets (EnsureTargetEntry): who the damage
        -- landed on (damageDone) or came from (damageTaken).
        targets = {},
    }
end

-- The unit a guid's data is recorded under: its owner while "Merge pets
-- into owners" is on, itself otherwise. Only bucketing uses this;
-- relevance/roster checks use the pet's own guid.
local function AttributedGuid(guid)
    if CL.GetSetting("mergePets") == false then return guid end
    if CL.GuidCache and CL.GuidCache.GetOwner then
        local owner = CL.GuidCache.GetOwner(guid)
        if owner then return owner end
    end
    return guid
end

local function EnsureUnit(units, guid)
    local u = units[guid]
    if not u then
        local info = CL.GuidCache and CL.GuidCache.Resolve(guid)
        u = {
            name = (info and info.name) or guid,
            class = info and info.class,
            classToken = info and info.classToken,
            isPlayer = info and info.isPlayer,
            damageDone = NewBucket(),
            -- targets = who was healed.
            healingDone = { total = 0, overheal = 0, spells = {}, targets = {} },
            damageTaken = NewBucket(),
            -- Dispels: total is a count; spells are the auras removed.
            cleanses = { total = 0, spells = {}, targets = {} },
            -- Debuffs given: a count, from Events.lua's AURA_CAST +
            -- DEBUFF_ADDED correlation.
            debuffsGiven = { total = 0, spells = {}, targets = {} },
            deaths = 0,
        }
        units[guid] = u
    elseif u.name == guid then
        -- Recorded before the client knew the name (GuidCache returned
        -- nil); fill it in once it resolves.
        local info = CL.GuidCache and CL.GuidCache.Resolve(guid)
        if info then
            u.name, u.class, u.classToken, u.isPlayer = info.name, info.class, info.classToken, info.isPlayer
        end
    end
    return u
end

local function EnsureSpellEntry(spells, spellId, name, school)
    local s = spells[spellId]
    if not s then
        s = { name = name, school = school, hits = 0, crits = 0, total = 0, critTotal = 0, min = nil, max = nil }
        spells[spellId] = s
    else
        -- Fill in fields an earlier, less informed caller left empty.
        if name and not s.name then s.name = name end
        if school and not s.school then s.school = school end
    end
    return s
end

local function RecordHit(entry, amount, isCrit)
    entry.hits = entry.hits + 1
    entry.total = entry.total + amount
    if isCrit then
        entry.crits = entry.crits + 1
        entry.critTotal = (entry.critTotal or 0) + amount
    end
    if not entry.min or amount < entry.min then entry.min = amount end
    if not entry.max or amount > entry.max then entry.max = amount end
end

-- A spell entry's "directHits"/"tickHits" sub-entry. These are extra
-- detail recorded alongside the entry's combined totals (which everything
-- else reads), so the breakdown can show a spell's direct hits and DoT
-- ticks separately - a direct hit can crit, a tick can't.
local function EnsureSplitBucket(entry, key)
    local b = entry[key]
    if not b then
        b = { hits = 0, crits = 0, total = 0, critTotal = 0, min = nil, max = nil }
        entry[key] = b
    end
    return b
end

local lastFinished = nil -- frozen snapshot of the previous fight, shown as "Current Fight" between pulls
local lastFinishedTime = nil -- GetTime() when lastFinished was set - see ShouldLazyStart below

local bossTagCache = {} -- [enemyGuid] = encounter name or false, see BossNameCached - cleared per encounter

local function StartEncounter()
    dataVersion = dataVersion + 1
    if current then return end
    current = NewEncounter()
    bossTagCache = {}
    lastFinished = nil -- a new fight is live - stop showing the frozen previous one
    if CL.debug then
        CL.Print("Encounter started.")
        CL.LogLine("[REGEN] StartEncounter (lazy-start guard passed or real PLAYER_REGEN_DISABLED)")
    end
end

-- Lazy start: Record* functions may start an encounter themselves when
-- none is live, since the first hit can arrive before (or, against
-- training dummies, without) PLAYER_REGEN_DISABLED. The danger is a
-- trailing event after a fight (a last DoT tick, a top-off heal) starting
-- a blank encounter that replaces the just-finished one in Current
-- Fight. Encounters only end once the player and the whole group are out
-- of combat, so anyone still fighting means a genuinely new pull.
local function IsPlayerInCombat()
    local ok, playerCombat = pcall(UnitAffectingCombat, "player")
    return ok and playerCombat and true or false
end

local function IsGroupFighting()
    return IsPlayerInCombat() or (CL.GuidCache and CL.GuidCache.AnyGroupMemberInCombat())
end

-- Guard for damage-style events: allow when the player or group is
-- fighting, or when the last end was more than PHANTOM_GUARD_WINDOW ago
-- (dummies may never flag combat). Refuse only just after an end, where
-- an unflagged hit is most likely a trailing tick.
local PHANTOM_GUARD_WINDOW = 3 -- seconds after a fight ends where an unflagged hit is treated as a trailing event, not a new pull
local function ShouldLazyStart()
    if IsGroupFighting() then return true end
    if lastFinishedTime and (GetTime() - lastFinishedTime) < PHANTOM_GUARD_WINDOW then
        return false
    end
    return true
end

local function GetCurrent()
    return current
end

-- What "Current Fight" shows: the live encounter, or the last finished
-- one (kept for review) until the next pull starts.
local function GetCurrentDisplay()
    return current or lastFinished
end

local function GetOverall()
    return overall
end

local function ResetOverall()
    dataVersion = dataVersion + 1
    overall = NewEncounter()
end

-- Adds fields that saves from older versions may lack, so Record* can
-- write into a restored unit without nil checks.
local function BackfillUnit(u)
    if not u.damageDone then u.damageDone = NewBucket() end
    if not u.damageDone.targets then u.damageDone.targets = {} end
    if not u.healingDone then u.healingDone = { total = 0, overheal = 0, spells = {}, targets = {} } end
    if not u.healingDone.targets then u.healingDone.targets = {} end
    if not u.damageTaken then u.damageTaken = NewBucket() end
    if not u.damageTaken.targets then u.damageTaken.targets = {} end
    if not u.cleanses then u.cleanses = { total = 0, spells = {}, targets = {} } end
    if not u.debuffsGiven then u.debuffsGiven = { total = 0, spells = {}, targets = {} } end
    if not u.deaths then u.deaths = 0 end
end

local function BackfillEncounter(enc)
    if not enc then return end
    -- Encounter-level fields older saves may lack.
    if not enc.mobTally then enc.mobTally = {} end
    if not enc.mobHealth then enc.mobHealth = {} end
    if not enc.series then enc.series = {} end
    if not enc.units then return end
    local guid, u
    for guid, u in pairs(enc.units) do
        BackfillUnit(u)
    end
end

-- Adds src's numbers into dst, recursively (spells, melee entries,
-- avoided/mit/spellMisses sub-tables all nest the same way). min/max
-- combine as min/max; `school` is an id, not a count, so it's kept;
-- strings (names) keep dst's value.
local NON_ADDITIVE = { school = true }
local function MergeStats(dst, src)
    local k, v
    for k, v in pairs(src) do
        if type(v) == "number" then
            if k == "min" then
                dst.min = dst.min and math.min(dst.min, v) or v
            elseif k == "max" then
                dst.max = dst.max and math.max(dst.max, v) or v
            elseif NON_ADDITIVE[k] then
                if dst[k] == nil then dst[k] = v end
            else
                dst[k] = (dst[k] or 0) + v
            end
        elseif type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            MergeStats(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local TARGET_BUCKETS = { "damageDone", "damageTaken", "healingDone", "cleanses", "debuffsGiven" }

-- Re-keys every per-target table of an encounter by name, merging
-- same-named entries (see TargetKey) - run when a fight is saved to
-- History and on an Overall restored from an older, GUID-keyed save.
-- Totals are unchanged; only same-named mobs stop being separate rows.
local function CompactTargets(enc)
    if not enc or not enc.units then return end
    local guid, u
    for guid, u in pairs(enc.units) do
        u.pendingCasts = nil -- stash for a DoT whose first tick never landed - meaningless once saved
        local i
        for i = 1, table.getn(TARGET_BUCKETS) do
            local bucket = u[TARGET_BUCKETS[i]]
            if bucket and bucket.targets then
                local merged = {}
                local key, t
                for key, t in pairs(bucket.targets) do
                    local name = t.name or key
                    if merged[name] then
                        MergeStats(merged[name], t)
                    else
                        merged[name] = t
                    end
                end
                bucket.targets = merged
            end
        end
    end
end

-- Current and Overall are saved to CombatLedgerDB.liveState on
-- PLAYER_LOGOUT (which /reload also fires) and restored on the next
-- PLAYER_ENTERING_WORLD - see Events.lua.
local function SerializeState()
    return { current = current, overall = overall }
end

-- A saved live encounter is only restored when it was saved within
-- RESTORE_STALE_SECONDS by wall clock (startTimeReal). Its startTime is a
-- GetTime() value, which keeps counting across a /reload but restarts
-- near 0 on a fresh client launch, so it can't tell a reload from a
-- relaunch by itself. Saves without startTimeReal are treated as stale.
-- Overall has no such issue: its duration is an accumulated number.
local RESTORE_STALE_SECONDS = 300
local function RestoreState(saved)
    dataVersion = dataVersion + 1
    if not saved then return end
    if saved.overall then
        overall = saved.overall
        BackfillEncounter(overall)
        CompactTargets(overall)
    end
    if saved.current and saved.current.startTimeReal
        and (time() - saved.current.startTimeReal) < RESTORE_STALE_SECONDS
        and saved.current.startTime and saved.current.startTime <= GetTime() then
        current = saved.current
        BackfillEncounter(current)
    end
end

-- Overall's duration counts only time spent in encounters (finished
-- ones plus the live one), so idle time between pulls doesn't dilute
-- Overall rates.
local function GetOverallDuration()
    local d = overall.activeDuration or 0
    if current then
        d = d + (GetTime() - current.startTime)
    end
    return d
end

-- Ends the live encounter. The duration runs to lastActivityTime (the
-- last relevant combat event, from Events.lua) rather than to now, so
-- time spent flagged in combat after the last hit - including the end
-- debounce - doesn't dilute rates. Only ever shortens, and only when
-- that time falls inside the encounter.
local function EndEncounter(lastActivityTime)
    dataVersion = dataVersion + 1
    if not current then return nil end
    current.duration = GetTime() - current.startTime
    if lastActivityTime and lastActivityTime >= current.startTime and lastActivityTime < GetTime() then
        local trimmed = lastActivityTime - current.startTime
        if trimmed > 0 and trimmed < current.duration then
            current.duration = trimmed
        end
    end
    current.timestamp = time()
    overall.activeDuration = (overall.activeDuration or 0) + current.duration
    local finished = current
    current = nil
    lastFinished = finished
    lastFinishedTime = GetTime()
    return finished
end

local function IsTrackedGuid(guid)
    return guid and CL.GuidCache and CL.GuidCache.IsTracked(guid)
end

-- The non-roster side of a caster/target pair (the enemy), or nil.
local function EnemyGuidFor(casterGuid, targetGuid)
    if casterGuid and targetGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        return AttributedGuid(targetGuid)
    elseif casterGuid and targetGuid and IsTrackedGuid(AttributedGuid(targetGuid)) then
        return AttributedGuid(casterGuid)
    end
    return nil
end

-- Each enemy is classified once per encounter (see Bosses.lua); the
-- first hit on each new enemy is still checked immediately, which keeps
-- pull attribution exact. Returns the encounter name or false.
local function BossNameCached(enemyGuid)
    if not enemyGuid then return false end
    local cached = bossTagCache[enemyGuid]
    if cached == nil then
        cached = CL.Bosses.Classify(enemyGuid) or false
        bossTagCache[enemyGuid] = cached
    end
    return cached
end

-- Marks the live encounter as a boss fight named `name`. A BigWigs
-- encounter name (fromBigWigs) replaces a mob name taken from rank.
local function MarkBoss(name, fromBigWigs)
    if not current or not name then return end
    if current.isBoss and current.bossName and not fromBigWigs then return end
    if current.bossName == name then return end
    dataVersion = dataVersion + 1
    current.isBoss = true
    current.bossName = name
end

-- The melee entry (main/off-hand, own/pet) an auto-attack belongs in.
local function MeleeEntryFor(bucket, isPet, isOffhand)
    if isPet then
        return isOffhand and bucket.petOffhand or bucket.petMelee
    end
    return isOffhand and bucket.offhand or bucket.melee
end

-- Mitigation observed on a hit (see Events.lua's FillMitigation): amounts
-- absorbed/blocked/resisted plus how many hits each affected, and
-- glancing/crushing counts. Kept in a lazily created `mit` subtable on
-- whatever it's applied to (bucket, per-target entry, spell/melee
-- entry), so units that never see mitigation carry no extra tables.
local function AddMitAmount(m, key, amount)
    if amount and amount > 0 then
        m[key] = (m[key] or 0) + amount
        m[key .. "Hits"] = (m[key .. "Hits"] or 0) + 1
    end
end

local function ApplyMitigation(t, mit)
    if not mit then return end
    local m = t.mit
    if not m then
        m = {}
        t.mit = m
    end
    AddMitAmount(m, "absorbed", mit.absorbed)
    AddMitAmount(m, "blocked", mit.blocked)
    AddMitAmount(m, "resisted", mit.resisted)
    if mit.glancing then m.glancing = (m.glancing or 0) + 1 end
    if mit.crushing then m.crushing = (m.crushing or 0) + 1 end
end

local function RecordDamageHit(entry, amount, isCrit, mit)
    RecordHit(entry, amount, isCrit)
    ApplyMitigation(entry, mit)
end

-- A per-target (damageDone.targets) or per-attacker (damageTaken.targets)
-- entry. Same shape as a damage bucket (spells/melee/offhand/pet
-- variants) so clicking it in the UI reuses the exact same per-ability
-- breakdown code as the unit-wide view, just scoped to this one unit.
--
-- Keyed by GUID in a live fight (two same-named adds stay apart), but by
-- NAME in Overall (units == overall.units): a session of trash would
-- otherwise grow one full breakdown per mob GUID ever hit, all of it
-- saved to disk on logout. Same idea as Skada's name-keyed targets.
local function TargetKey(units, guid)
    local info = CL.GuidCache and CL.GuidCache.Resolve(guid)
    local name = info and info.name
    if name and units == overall.units then return name, name end
    return guid, name or guid
end

local function EnsureTargetEntry(units, targets, guid)
    local key, name = TargetKey(units, guid)
    local t = targets[key]
    if not t then
        t = {
            name = name,
            total = 0, hits = 0, spells = {},
            melee = NewMeleeEntry(), offhand = NewMeleeEntry(),
            petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry(),
        }
        targets[key] = t
    end
    return t
end

-- Records one hit into a units table: Damage Done for a roster caster,
-- Damage Taken for a roster target. Mobs never get a unit of their own.
-- Either guid may be nil (environment damage has no caster).
local function RecordDamageInto(units, casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic, mit)
    if casterGuid then
        local attributed = AttributedGuid(casterGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            u.damageDone.total = u.damageDone.total + amount
            ApplyMitigation(u.damageDone, mit)
            if spellId then
                local entry = EnsureSpellEntry(u.damageDone.spells, spellId, spellName, school)
                -- Fold in casts counted before this spell's first damage
                -- (see RecordCastInto).
                if u.pendingCasts and u.pendingCasts[spellId] then
                    entry.casts = (entry.casts or 0) + u.pendingCasts[spellId]
                    u.pendingCasts[spellId] = nil
                end
                RecordDamageHit(entry, amount, isCrit, mit)
                RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
            else
                RecordDamageHit(MeleeEntryFor(u.damageDone, attributed ~= casterGuid, isOffhand), amount, isCrit, mit)
            end

            if targetGuid then
                local t = EnsureTargetEntry(units, u.damageDone.targets, targetGuid)
                t.total = t.total + amount
                t.hits = t.hits + 1
                ApplyMitigation(t, mit)
                if spellId then
                    local entry = EnsureSpellEntry(t.spells, spellId, spellName, school)
                    RecordDamageHit(entry, amount, isCrit, mit)
                    RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
                else
                    RecordDamageHit(MeleeEntryFor(t, attributed ~= casterGuid, isOffhand), amount, isCrit, mit)
                end
            end
        end
    end

    if targetGuid then
        local attributed = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            u.damageTaken.total = u.damageTaken.total + amount
            ApplyMitigation(u.damageTaken, mit)
            if spellId then
                local entry = EnsureSpellEntry(u.damageTaken.spells, spellId, spellName, school)
                RecordDamageHit(entry, amount, isCrit, mit)
                RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
            else
                RecordDamageHit(MeleeEntryFor(u.damageTaken, attributed ~= targetGuid, isOffhand), amount, isCrit, mit)
            end

            -- damageTaken.targets = attackers.
            if casterGuid then
                local s = EnsureTargetEntry(units, u.damageTaken.targets, casterGuid)
                s.total = s.total + amount
                s.hits = s.hits + 1
                ApplyMitigation(s, mit)
                if spellId then
                    local entry = EnsureSpellEntry(s.spells, spellId, spellName, school)
                    RecordDamageHit(entry, amount, isCrit, mit)
                    RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
                else
                    RecordDamageHit(MeleeEntryFor(s, false, isOffhand), amount, isCrit, mit)
                end
            end
        end
    end
end

-- `mit` (optional): see ApplyMitigation.
local function RecordDamage(casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic, mit)
    dataVersion = dataVersion + 1
    if not current then
        if not ShouldLazyStart() then return end
        StartEncounter()
    end

    -- Pull attribution: the caster of the first hit involving a boss
    -- "pulled" it. Set once; trash-only encounters never set it.
    local bossName = not current.pullBy and casterGuid and BossNameCached(EnemyGuidFor(casterGuid, targetGuid))
    if bossName then
        local info = CL.GuidCache and CL.GuidCache.Resolve(casterGuid)
        current.pullBy = { name = (info and info.name) or casterGuid, label = spellName or "Auto Attack" }
        MarkBoss(bossName)
        if CL.GetSetting("announcePulls") ~= false then
            CL.Print("Pull: " .. current.pullBy.name .. " (" .. current.pullBy.label .. ")")
        end
    end

    RecordDamageInto(current.units, casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic, mit)
    RecordDamageInto(overall.units, casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic, mit)
    -- Raw (un-merged) caster: threat belongs to the pet itself.
    if CL.Threat then CL.Threat.NoteDamage(current, casterGuid, targetGuid, spellId, spellName, school, amount) end

    if casterGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        RecordSeriesPoint(current, "damage", amount)
    end
    if targetGuid and IsTrackedGuid(AttributedGuid(targetGuid)) then
        RecordSeriesPoint(current, "taken", amount)
    end

    -- Damage and max health per enemy, only so History.lua can label a
    -- saved encounter after the toughest mob in it.
    if casterGuid and targetGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        local targetAttributed = AttributedGuid(targetGuid)
        if not IsTrackedGuid(targetAttributed) then
            current.mobTally[targetAttributed] = (current.mobTally[targetAttributed] or 0) + amount

            -- Max health doesn't change, so it's read once per mob per
            -- encounter (0 = unreadable, not retried).
            if UnitHealthMax and current.mobHealth[targetAttributed] == nil then
                local ok, maxHp = pcall(UnitHealthMax, targetAttributed)
                current.mobHealth[targetAttributed] = (ok and tonumber(maxHp)) or 0
            end
        end
    end

    if targetGuid then
        local attributedTarget = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributedTarget) then
            local attackerName = "Environment"
            if casterGuid then
                local info = CL.GuidCache and CL.GuidCache.Resolve(casterGuid)
                attackerName = (info and info.name) or casterGuid
            end
            local label = spellName
            if not label then
                local isPet = (attributedTarget ~= targetGuid)
                if isPet then
                    label = isOffhand and "Pet Off-Hand" or "Pet Auto Attack"
                else
                    label = isOffhand and "Off-Hand" or "Auto Attack"
                end
            end
            RecordRecapHit(attributedTarget, attackerName, label, amount, isCrit)
        end
    end
end

-- Cast counts (from AURA_CAST) for spells whose hits are DoT ticks, where
-- the hit count isn't the number of casts. Unit-wide entries only.
local function RecordCastInto(units, casterGuid, spellId, spellName)
    if not casterGuid or not spellId then return end
    local attributed = AttributedGuid(casterGuid)
    if not IsTrackedGuid(attributed) then return end
    local u = EnsureUnit(units, attributed)
    local entry = u.damageDone.spells[spellId]
    if entry then
        entry.casts = (entry.casts or 0) + 1
    else
        -- No damage entry yet (the cast lands before the first tick):
        -- stash the count on the unit rather than creating an entry, so
        -- non-damage casts (buffs) never become zero-damage rows.
        -- RecordDamageInto folds it in when the entry is created.
        u.pendingCasts = u.pendingCasts or {}
        u.pendingCasts[spellId] = (u.pendingCasts[spellId] or 0) + 1
    end
end

local function RecordCast(casterGuid, spellId, spellName)
    dataVersion = dataVersion + 1
    -- Never starts an encounter: AURA_CAST fires for every buff and heal
    -- too, so a cast alone isn't evidence of a fight. The cost is that a
    -- fight-opening DoT cast can go uncounted.
    if not current then return end
    RecordCastInto(current.units, casterGuid, spellId, spellName)
    RecordCastInto(overall.units, casterGuid, spellId, spellName)
end

local VICTIMSTATE_KEY = {
    [CL.VICTIMSTATE_MISS] = "miss",
    [CL.VICTIMSTATE_DODGE] = "dodge",
    [CL.VICTIMSTATE_PARRY] = "parry",
    [CL.VICTIMSTATE_BLOCK] = "block",
    [CL.VICTIMSTATE_EVADE] = "evade",
    [CL.VICTIMSTATE_IMMUNE] = "immune",
    [CL.VICTIMSTATE_DEFLECT] = "deflect",
}

local function RecordAvoidanceInto(units, casterGuid, targetGuid, key, isOffhand, mit)
    if casterGuid then
        local attributed = AttributedGuid(casterGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            local entry = MeleeEntryFor(u.damageDone, attributed ~= casterGuid, isOffhand)
            entry.avoided[key] = (entry.avoided[key] or 0) + 1
            ApplyMitigation(entry, mit)
            ApplyMitigation(u.damageDone, mit)
        end
    end
    if targetGuid then
        local attributed = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            local entry = MeleeEntryFor(u.damageTaken, attributed ~= targetGuid, isOffhand)
            entry.avoided[key] = (entry.avoided[key] or 0) + 1
            ApplyMitigation(entry, mit)
            ApplyMitigation(u.damageTaken, mit)
        end
    end
end

-- An auto-attack swing that did no damage: counted by outcome on the
-- melee entry (victimState, or "absorb" for a swing a shield soaked
-- entirely). `mit` carries a fully blocked/absorbed swing's amount.
local function RecordAvoidance(casterGuid, targetGuid, victimState, isOffhand, mit, fullAbsorb)
    dataVersion = dataVersion + 1
    if not current then
        if not ShouldLazyStart() then return end
        StartEncounter()
    end
    local key = fullAbsorb and "absorb" or VICTIMSTATE_KEY[victimState] or "other"
    RecordAvoidanceInto(current.units, casterGuid, targetGuid, key, isOffhand, mit)
    RecordAvoidanceInto(overall.units, casterGuid, targetGuid, key, isOffhand, mit)
end

-- Healing totals are EFFECTIVE healing (raw minus estimated overheal), so
-- bars, rates, spell shares and healing threat all ignore overheal.
-- raw/overheal/unverified ride alongside; min/max and the per-crit
-- averages use raw heal size, since that's what the spell actually did.
-- `unverified` = raw amount whose target health couldn't be read, so
-- it was counted as fully effective.
local function AddHeal(t, amount, effective, overheal, unverified)
    t.total = t.total + effective
    t.raw = (t.raw or 0) + amount
    t.overheal = (t.overheal or 0) + overheal
    if unverified then t.unverified = (t.unverified or 0) + amount end
end

local function RecordHealHit(entry, amount, effective, overheal, isCrit, unverified)
    entry.hits = entry.hits + 1
    AddHeal(entry, amount, effective, overheal, unverified)
    if isCrit then
        entry.crits = entry.crits + 1
        entry.critTotal = (entry.critTotal or 0) + effective
        entry.critRaw = (entry.critRaw or 0) + amount
    end
    if not entry.min or amount < entry.min then entry.min = amount end
    if not entry.max or amount > entry.max then entry.max = amount end
end

-- SPELL_MISS_* missInfo -> outcome key (vmangos SpellMissInfo; 7 and 8
-- are both immune variants).
local SPELL_MISS_KEY = {
    [1] = "miss", [2] = "resist", [3] = "dodge", [4] = "parry", [5] = "block",
    [6] = "evade", [7] = "immune", [8] = "immune", [9] = "deflect",
    [10] = "absorb", [11] = "reflect",
}

-- Spell misses live in bucket.spellMisses[spellId] (an avoided-style
-- count table), NOT as spell entries - many missed spells never deal
-- damage (Sunder Armor, Taunt, a resisted curse) and would otherwise
-- show up as zero-damage rows. The breakdown window joins them onto the
-- matching spell entry by spellId.
local function BumpSpellMiss(bucket, spellId, key)
    local misses = bucket.spellMisses
    if not misses then
        misses = {}
        bucket.spellMisses = misses
    end
    local av = misses[spellId]
    if not av then
        av = {}
        misses[spellId] = av
    end
    av[key] = (av[key] or 0) + 1
end

local function RecordSpellMissInto(units, casterGuid, targetGuid, spellId, key)
    if casterGuid then
        local attributed = AttributedGuid(casterGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            BumpSpellMiss(u.damageDone, spellId, key)
            if targetGuid then
                BumpSpellMiss(EnsureTargetEntry(units, u.damageDone.targets, targetGuid), spellId, key)
            end
        end
    end
    if targetGuid then
        local attributed = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            BumpSpellMiss(u.damageTaken, spellId, key)
            if casterGuid then
                BumpSpellMiss(EnsureTargetEntry(units, u.damageTaken.targets, casterGuid), spellId, key)
            end
        end
    end
end

-- A spell (including yellow melee specials like Sinister Strike) that
-- missed/was resisted/dodged/etc. - SPELL_MISS_SELF/OTHER.
local function RecordSpellMiss(casterGuid, targetGuid, spellId, missInfo)
    dataVersion = dataVersion + 1
    if not spellId then return end
    if not current then
        if not ShouldLazyStart() then return end
        StartEncounter()
    end
    local key = SPELL_MISS_KEY[missInfo] or "other"
    RecordSpellMissInto(current.units, casterGuid, targetGuid, spellId, key)
    RecordSpellMissInto(overall.units, casterGuid, targetGuid, spellId, key)
end

local function RecordHealingInto(units, casterGuid, targetGuid, spellId, spellName, amount, effective, overheal, isCrit, unverified)
    if not casterGuid then return end
    local attributed = AttributedGuid(casterGuid)
    if not IsTrackedGuid(attributed) then return end
    local u = EnsureUnit(units, attributed)
    AddHeal(u.healingDone, amount, effective, overheal, unverified)
    RecordHealHit(EnsureSpellEntry(u.healingDone.spells, spellId, spellName, nil), amount, effective, overheal, isCrit, unverified)

    if targetGuid then
        local key, name = TargetKey(units, targetGuid)
        local t = u.healingDone.targets[key]
        if not t then
            t = { name = name, total = 0, hits = 0, overheal = 0, spells = {} }
            u.healingDone.targets[key] = t
        end
        t.hits = t.hits + 1
        AddHeal(t, amount, effective, overheal, unverified)
        RecordHealHit(EnsureSpellEntry(t.spells, spellId, spellName, nil), amount, effective, overheal, isCrit, unverified)
    end
end

-- amount = raw heal from the event; effective/overheal come from
-- Events.lua's target-health estimate (verified = health was readable).
local function RecordHealing(casterGuid, targetGuid, spellId, spellName, amount, effective, overheal, isCrit, verified)
    dataVersion = dataVersion + 1
    -- Starts an encounter only while the player or group is in combat
    -- (a healer healing before landing a hit). Out-of-combat top-offs and
    -- trailing HoT ticks never start one.
    if not current then
        if not IsGroupFighting() then return end
        StartEncounter()
    end
    local unverified = not verified
    RecordHealingInto(current.units, casterGuid, targetGuid, spellId, spellName, amount, effective, overheal, isCrit, unverified)
    RecordHealingInto(overall.units, casterGuid, targetGuid, spellId, spellName, amount, effective, overheal, isCrit, unverified)
    if CL.Threat then CL.Threat.NoteHealing(current, casterGuid, effective) end

    if casterGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        RecordSeriesPoint(current, "healing", effective)
    end
end

-- Records one occurrence into a count-only bucket ("cleanses" or
-- "debuffsGiven"): total and per-spell/per-target counts.
local function RecordCountEventInto(units, bucketKey, casterGuid, targetGuid, spellId, spellName)
    if not casterGuid then return end
    local attributed = AttributedGuid(casterGuid)
    if not IsTrackedGuid(attributed) then return end
    local u = EnsureUnit(units, attributed)
    local bucket = u[bucketKey]
    bucket.total = bucket.total + 1
    RecordHit(EnsureSpellEntry(bucket.spells, spellId, spellName, nil), 1, false)

    if targetGuid then
        local key, name = TargetKey(units, targetGuid)
        local t = bucket.targets[key]
        if not t then
            t = { name = name, total = 0, hits = 0, spells = {} }
            bucket.targets[key] = t
        end
        t.total = t.total + 1
        t.hits = t.hits + 1
        RecordHit(EnsureSpellEntry(t.spells, spellId, spellName, nil), 1, false)
    end
end

local function RecordCleanse(casterGuid, targetGuid, spellId, spellName)
    dataVersion = dataVersion + 1
    -- Same combat-gated start as RecordHealing.
    if not current then
        if not IsGroupFighting() then return end
        StartEncounter()
    end
    RecordCountEventInto(current.units, "cleanses", casterGuid, targetGuid, spellId, spellName)
    RecordCountEventInto(overall.units, "cleanses", casterGuid, targetGuid, spellId, spellName)
end

local function RecordDebuffGiven(casterGuid, targetGuid, spellId, spellName)
    dataVersion = dataVersion + 1
    if not current then
        if not ShouldLazyStart() then return end
        StartEncounter()
    end
    RecordCountEventInto(current.units, "debuffsGiven", casterGuid, targetGuid, spellId, spellName)
    RecordCountEventInto(overall.units, "debuffsGiven", casterGuid, targetGuid, spellId, spellName)
end

local function RecordDeath(guid)
    dataVersion = dataVersion + 1
    local attributed = guid
    -- Pet deaths aren't counted (a pet dying isn't its owner dying).
    if CL.GuidCache and CL.GuidCache.GetOwner(guid) then return nil end
    if not IsTrackedGuid(attributed) then return nil end
    local u = EnsureUnit(overall.units, attributed)
    u.deaths = u.deaths + 1
    if current then
        local uc = EnsureUnit(current.units, attributed)
        uc.deaths = uc.deaths + 1
    end
    SnapshotDeathRecap(attributed)
    return attributed
end

--------------------------------------------------------------------------
-- Test mode: a fabricated encounter for previewing appearance settings.
-- Built with the same helpers as real data, so breakdowns work on it.
--------------------------------------------------------------------------

local testEncounter = nil -- cached once generated, not regenerated every refresh

-- Amounts scale with `power` (1.0 = top of every mode).
local function FakeHits(bucket, entry, count, avgAmount, critPct)
    local i
    for i = 1, count do
        local isCrit = (math.random(100) <= critPct)
        local amount = math.floor(avgAmount * (0.8 + math.random() * 0.4))
        if isCrit then amount = math.floor(amount * 1.8) end
        RecordHit(entry, amount, isCrit)
        bucket.total = bucket.total + amount
    end
end

local TEST_SPELLS_WARLOCK = { { id = 172, name = "Corruption", school = "Shadow" }, { id = 686, name = "Shadow Bolt", school = "Shadow" } }
local TEST_SPELLS_GENERIC = { { id = 133, name = "Fireball", school = "Fire" }, { id = 585, name = "Smite", school = "Holy" } }

local function FakeDamageDone(u, power)
    local bucket = u.damageDone
    FakeHits(bucket, bucket.melee, math.floor(18 * power) + 4, 220 * power, 18)
    local spellList = (u.classToken == "WARLOCK") and TEST_SPELLS_WARLOCK or TEST_SPELLS_GENERIC
    local i
    for i = 1, table.getn(spellList) do
        local sp = spellList[i]
        local entry = EnsureSpellEntry(bucket.spells, sp.id, sp.name, sp.school)
        FakeHits(bucket, entry, math.floor(10 * power) + 2, 350 * power, 22)
    end

    -- Two targets, so the Targets list and "All Enemies" row show.
    local bossTotal = math.floor(bucket.total * 0.7)
    bucket.targets["TESTBOSS"] = { name = "Training Dummy", total = bossTotal, hits = math.floor((bucket.melee.hits or 0) * 0.7), spells = {}, melee = NewMeleeEntry(), offhand = NewMeleeEntry(), petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry() }
    bucket.targets["TESTADD1"] = { name = "Training Dummy's Friend", total = bucket.total - bossTotal, hits = math.floor((bucket.melee.hits or 0) * 0.3), spells = {}, melee = NewMeleeEntry(), offhand = NewMeleeEntry(), petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry() }
end

local function FakeHealingDone(u, power)
    local bucket = u.healingDone
    local entry = EnsureSpellEntry(bucket.spells, 2050, "Lesser Heal", "Holy")
    local i
    for i = 1, math.floor(12 * power) + 2 do
        local isCrit = (math.random(100) <= 15)
        local amount = math.floor(300 * power * (0.8 + math.random() * 0.4))
        if isCrit then amount = math.floor(amount * 1.5) end
        local overheal = math.floor(amount * 0.15)
        RecordHealHit(entry, amount, amount - overheal, overheal, isCrit, false)
        AddHeal(bucket, amount, amount - overheal, overheal, false)
    end

    -- Two recipients for the "Healed" list.
    local tankTotal = math.floor(bucket.total * 0.6)
    bucket.targets["TESTTANK"] = { name = "Kaladin", total = tankTotal, hits = math.floor(entry.hits * 0.6), overheal = 0, spells = {} }
    bucket.targets["TESTSELF"] = { name = u.name, total = bucket.total - tankTotal, hits = entry.hits - math.floor(entry.hits * 0.6), overheal = 0, spells = {} }
end

local function FakeDamageTaken(u, power)
    local bucket = u.damageTaken
    FakeHits(bucket, bucket.melee, math.floor(8 * power) + 3, 150 * power, 10)

    -- One attacker for the "Attackers" list.
    bucket.targets["TESTBOSS"] = { name = "Training Dummy", total = bucket.total, hits = bucket.melee.hits, spells = {}, melee = NewMeleeEntry(), offhand = NewMeleeEntry(), petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry() }
end

-- Fills a count-only bucket with one ability and one recipient.
local function FakeCountEvent(bucket, spellId, spellName, count, recipientGuid, recipientName)
    local entry = EnsureSpellEntry(bucket.spells, spellId, spellName, nil)
    local i
    for i = 1, count do
        RecordHit(entry, 1, false)
        bucket.total = bucket.total + 1
    end
    if count > 0 then
        bucket.targets[recipientGuid] = { name = recipientName, total = count, hits = count, spells = {} }
    end
end

local function FakeCleanses(u, power)
    FakeCountEvent(u.cleanses, 4987, "Cleanse", math.floor(3 * power), "TESTTANK", "Kaladin")
end

local function FakeDebuffsGiven(u, power)
    FakeCountEvent(u.debuffsGiven, 172, "Corruption", math.floor(4 * power), "TESTBOSS", "Training Dummy")
end

-- name, classToken, power (1.0 = tops every mode; the first entry plays
-- the player).
local TEST_ROSTER = {
    { name = "Kobeni", classToken = "WARLOCK", power = 1.0, isPlayer = true },
    { name = "Kaladin", classToken = "WARRIOR", power = 0.92 },
    { name = "Szeth", classToken = "ROGUE", power = 0.88 },
    { name = "Dalinar", classToken = "PALADIN", power = 0.85 },
    { name = "Shallan", classToken = "MAGE", power = 0.75 },
    { name = "Jasnah", classToken = "PRIEST", power = 0.7 },
    { name = "Adolin", classToken = "WARRIOR", power = 0.65 },
    { name = "Teft", classToken = "HUNTER", power = 0.6 },
    { name = "Renarin", classToken = "DRUID", power = 0.55 },
    { name = "Navani", classToken = "SHAMAN", power = 0.5 },
}

-- Built directly rather than via EnsureUnit, whose GuidCache.Resolve
-- expects real GUIDs.
local function NewTestUnit(r)
    return {
        name = r.name,
        class = r.classToken,
        classToken = r.classToken,
        isPlayer = r.isPlayer,
        damageDone = NewBucket(),
        healingDone = { total = 0, overheal = 0, spells = {}, targets = {} },
        damageTaken = NewBucket(),
        cleanses = { total = 0, spells = {}, targets = {} },
        debuffsGiven = { total = 0, spells = {}, targets = {} },
        deaths = 0,
    }
end

local function GenerateTestEncounter()
    local enc = NewEncounter()
    enc.label = "Test Data"
    enc.duration = 60
    local i
    for i = 1, table.getn(TEST_ROSTER) do
        local r = TEST_ROSTER[i]
        local guid = "TESTUNIT" .. i
        local u = NewTestUnit(r)
        enc.units[guid] = u
        FakeDamageDone(u, r.power)
        FakeHealingDone(u, r.power)
        FakeDamageTaken(u, r.power)
        FakeCleanses(u, r.power)
        FakeDebuffsGiven(u, r.power)
    end
    enc.units["TESTUNIT7"].deaths = 1 -- Adolin - one fake death, for previewing Deaths mode
    return enc
end

local function GetTestEncounter()
    if not testEncounter then
        testEncounter = GenerateTestEncounter()
    end
    return testEncounter
end

local function ClearTestEncounter()
    testEncounter = nil
end

CL.Aggregator = {
    SERIES_BUCKET_SECONDS = TIMELINE_BUCKET_SECONDS,
    StartEncounter = StartEncounter,
    EndEncounter = EndEncounter,
    GetCurrent = GetCurrent,
    GetCurrentDisplay = GetCurrentDisplay,
    GetOverall = GetOverall,
    GetOverallDuration = GetOverallDuration,
    ResetOverall = ResetOverall,
    MarkBoss = MarkBoss,
    CompactTargets = CompactTargets,
    GetDataVersion = function() return dataVersion end,
    GetDeathRecap = GetDeathRecap,
    SnapshotDeathRecap = SnapshotDeathRecap, -- exposed for /cl testdeath - doesn't touch the real death counter
    RecordDamage = RecordDamage,
    RecordAvoidance = RecordAvoidance,
    RecordSpellMiss = RecordSpellMiss,
    RecordHealing = RecordHealing,
    RecordCast = RecordCast,
    RecordCleanse = RecordCleanse,
    RecordDebuffGiven = RecordDebuffGiven,
    RecordDeath = RecordDeath,
    GetTestEncounter = GetTestEncounter,
    ClearTestEncounter = ClearTestEncounter,
    SerializeState = SerializeState,
    RestoreState = RestoreState,
}

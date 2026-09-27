--[[
    UI_MainWindow - the live meter. Instantiable: "main" is always
    created (auto-shown, tied to /cl toggle, not closable), and Options
    can spawn additional independent windows (own frame/bars/mode/
    segment/layout) so someone can watch Damage in one window and
    Healing in another at the same time. Window state (frame/bars/
    lastShownCount) lives on a per-window `inst` table.

    Pooled StatusBar rows sized/positioned like GreedMeter's UI/Frames.lua
    (fixed bar pool, class-colored fill, dark bg texture, name/value
    FontStrings) and window chrome (backdrop, drag-move, resize grip,
    pfUI skin pass) like LootLedger's CreateLootWindow - same visual
    language, not shared code.

    Mode/segment controls are simple click-to-cycle buttons rather than
    a dropdown menu - keeps the UI simple with a fraction of the code a
    full UIDropDownMenu would need.
]]

local CL = CombatLedger
local UI = {}
CL.UI = UI

local MAX_BARS = 20
local BAR_HEIGHT = 18
local BAR_GAP = 2
local HEADER_HEIGHT = 28 -- a few extra px of breathing room below the button row before the first bar
local FOOTER_GAP = 12

local WINDOW_WIDTH, WINDOW_HEIGHT = 220, 260
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 160, 100
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 500, 600

local REFRESH_INTERVAL = 0.2
local IDLE_REFRESH_SECONDS = 2 -- see the refresh driver at the bottom of this file

-- Threat differs from every other mode: it's a live snapshot (Threat.lua)
-- rather than recorded data, with no Current/Overall/History, so it has
-- its own path through RefreshInstance/ShowBarTooltip instead of
-- GetActiveEncounter.
local MODE_ORDER = { "damage", "healing", "taken", "cleanses", "debuffs", "deaths", "threat" }
local MODE_TITLES = { damage = "Damage Done", healing = "Healing Done", taken = "Damage Taken", cleanses = "Dispels", debuffs = "Debuffs Given", deaths = "Deaths", threat = "Threat" }

-- Cleanses/Debuffs are counts, not amounts - no meaningful "rate" or
-- "crit %" the way damage/healing have, so bars/tooltips/announce show
-- a plain count for these instead.
local COUNT_ONLY_MODES = { cleanses = true, debuffs = true }
local COUNT_WORD = { cleanses = "dispel", debuffs = "debuff" }

local function CountLabel(mode, n)
    local word = COUNT_WORD[mode] or "event"
    return n .. " " .. word .. ((n == 1) and "" or "s")
end

-- Segment button labels. A selected History fight shows its own label
-- instead (ShowHistoryEncounterIn); "history" is only the fallback.
local SEGMENT_LABELS = { current = "Current", overall = "Overall", history = "History" }

-- Every open window, keyed by id. "main" always exists; extra windows
-- (from Options' "New Window" button) get ids like "window2", "window3",
-- ... CL.UIWindows exposes this to UI_Options.lua for the window list.
local instances = {}
local instanceOrder = {}
CL.UIWindows = instances

-- The window an announce confirmation is for; set before showing the
-- COMBATLEDGER_ANNOUNCE popup and read in its OnAccept.
local pendingAnnounceInst = nil

-- Dropdown menu itself (CL.ShowDropdown/CL.CloseDropdown) moved to
-- Core.lua so UI_Options.lua can use the same one for its Bar texture/
-- Font/Number format pickers instead of duplicating it.

local function FormatNumber(n)
    return CL.FormatNumber(n)
end

local function ClassColor(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b
    end
    return 0.6, 0.6, 0.6
end

-- {r, g, b} table form, for the segment dropdown's Current/Overall rows
-- (see ShowDropdown's `color` option field) - makes those two stand out
-- in class color from the plain-white History entries below them.
local function PlayerClassColorTable()
    local ok, _, classToken = pcall(UnitClass, "player")
    local r, g, b = ClassColor(ok and classToken or nil)
    return { r, g, b }
end

local function MetricTotal(u, mode)
    if mode == "healing" then
        return (u.healingDone and u.healingDone.total) or 0
    elseif mode == "taken" then
        return (u.damageTaken and u.damageTaken.total) or 0
    elseif mode == "cleanses" then
        return (u.cleanses and u.cleanses.total) or 0
    elseif mode == "debuffs" then
        return (u.debuffsGiven and u.debuffsGiven.total) or 0
    elseif mode == "deaths" then
        return u.deaths or 0
    end
    return (u.damageDone and u.damageDone.total) or 0
end

local function SortByTotalDesc(a, b) return a.total > b.total end

-- `out` (optional) is a list to refill in place - RefreshInstance passes
-- its own per-window one so a redraw reuses the same entry tables
-- instead of allocating a fresh table per unit every time. Only ever
-- filled by direct index assignment (never table.insert/remove, whose
-- Lua 5.0 setn bookkeeping would go stale), and trailing entries from a
-- longer previous list are cleared so table.getn stays right.
local function BuildSortedList(units, mode, out)
    local list = out or {}
    local n = 0
    local guid, u
    for guid, u in pairs(units) do
        local val = MetricTotal(u, mode)
        if val > 0 then
            n = n + 1
            local e = list[n]
            if not e then
                e = {}
                list[n] = e
            end
            e.guid, e.name, e.classToken, e.total = guid, u.name, u.classToken, val
        end
    end
    local i
    for i = table.getn(list), n + 1, -1 do
        list[i] = nil
    end
    table.sort(list, SortByTotalDesc)

    return list
end

-- Threat mode's list, built from CL.Threat.GetSnapshot() rather than
-- recorded units. `filterSet` ([name] = true) limits it to those names;
-- nil/empty shows everyone.
-- The second return is the "Pull Aggro At" reference row, kept out of
-- the sorted list so bar scaling uses real entries only. A non-tank pulls
-- aggro above 110% of the tank's threat in melee, 130% at range; the row
-- shows how much more threat the player can generate before that.
local function BuildThreatList(filterSet)
    local list = {}
    -- Test Mode substitutes a fake snapshot (see Threat.lua's
    -- GetTestSnapshot) so Threat mode previews with dummy bars + the
    -- Pull Aggro At marker below, same as every other mode already did.
    local snapshot = CL.testMode and CL.Threat and CL.Threat.GetTestSnapshot and CL.Threat.GetTestSnapshot()
        or (CL.Threat and CL.Threat.GetSnapshot())
    if not snapshot then return list, nil end
    local hasFilter = filterSet and next(filterSet) ~= nil
    local playerName = UnitName("player")
    local tankThreat, playerMelee, playerIsTank
    local playerThreat = 0
    local guid, t
    for guid, t in pairs(snapshot) do
        if not hasFilter or filterSet[t.name] then
            -- Test entries carry their own classToken directly (fake
            -- guids have nothing for GuidCache to resolve); real ones
            -- still resolve through the roster cache as before.
            local classToken = t.classToken
            if not classToken and CL.GuidCache then
                local info = CL.GuidCache.Resolve(guid)
                classToken = info and info.classToken
            end
            table.insert(list, {
                guid = guid,
                name = t.name,
                classToken = classToken,
                total = t.threat,
                perc = t.perc,
                melee = t.melee,
                tank = t.tank,
            })
        end
        if t.tank then tankThreat = t.threat end
        if t.name == playerName then
            playerMelee = t.melee
            playerThreat = t.threat or 0
            playerIsTank = t.tank
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)

    -- Remember the real sorted rank before the display-only self pinning
    -- in RefreshInstance potentially moves the player higher in the
    -- visible list. The label must still say e.g. "15.", not pretend the
    -- player became rank 4 merely because the window is short.
    local rankIndex
    for rankIndex = 1, table.getn(list) do
        list[rankIndex].threatRank = rankIndex
    end

    -- How much more threat the PLAYER can generate before pulling -
    -- the threshold minus the player's own current threat, not minus
    -- the tank's. No marker while the player is the one tanking.
    local marker = nil
    if tankThreat and tankThreat > 0 and not playerIsTank then
        local threshold = tankThreat * (playerMelee and 1.1 or 1.3)
        local remaining = threshold - playerThreat
        if remaining < 0 then remaining = 0 end
        marker = {
            guid = "THREAT_AGRO_MARKER",
            name = "Pull Aggro At",
            total = remaining,
            isAgroMarker = true,
        }
    end

    return list, marker
end

-- Per-ability totals for the hover tooltip's "By spell" section: melee
-- rows plus each spell, sorted descending.
local function BuildSpellSummary(u, mode)
    local list = {}
    if not u then return list end
    local bucket
    if mode == "healing" then
        bucket = u.healingDone
    elseif mode == "taken" then
        bucket = u.damageTaken
    elseif mode == "cleanses" then
        bucket = u.cleanses
    elseif mode == "debuffs" then
        bucket = u.debuffsGiven
    else
        bucket = u.damageDone
    end
    if not bucket then return list end

    if bucket.melee and bucket.melee.total and bucket.melee.total > 0 then
        table.insert(list, { name = "Auto Attack", total = bucket.melee.total })
    end
    if bucket.offhand and bucket.offhand.total and bucket.offhand.total > 0 then
        table.insert(list, { name = "Off-Hand", total = bucket.offhand.total })
    end
    if bucket.petMelee and bucket.petMelee.total and bucket.petMelee.total > 0 then
        table.insert(list, { name = "Pet Auto Attack", total = bucket.petMelee.total })
    end
    if bucket.petOffhand and bucket.petOffhand.total and bucket.petOffhand.total > 0 then
        table.insert(list, { name = "Pet Off-Hand", total = bucket.petOffhand.total })
    end
    if bucket.spells then
        local spellId, s
        for spellId, s in pairs(bucket.spells) do
            table.insert(list, { name = s.name or ("Spell " .. tostring(spellId)), total = s.total })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- Who this player's damage/healing/etc actually landed on, same data
-- the breakdown window's per-target list uses.
local function BuildTargetSummary(u, mode)
    local list = {}
    local bucket
    if mode == "healing" then
        bucket = u and u.healingDone
    elseif mode == "taken" then
        bucket = u and u.damageTaken
    elseif mode == "cleanses" then
        bucket = u and u.cleanses
    elseif mode == "debuffs" then
        bucket = u and u.debuffsGiven
    else
        bucket = u and u.damageDone
    end
    if not bucket or not bucket.targets then return list end
    local guid, t
    for guid, t in pairs(bucket.targets) do
        if t.total > 0 then -- miss-only targets (see Aggregator.lua's RecordSpellMissInto)
            table.insert(list, { name = t.name, total = t.total })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- Deaths mode: what actually killed them, not a rate - reuses the same
-- recap buffer the dedicated Death Recap window snapshots on UNIT_DIED
-- (see Aggregator.lua). Only the live current/overall segments have a
-- recap available (it's not saved into history), so a saved encounter's
-- Deaths tab just shows the count with no further detail.
local function ShowDeathTooltip(bar, u)
    GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
    GameTooltip:AddLine(u.name, ClassColor(u.classToken))
    GameTooltip:AddDoubleLine("Deaths", tostring(u.deaths or 0), 1, 1, 1, 1, 1, 1)

    local recap = CL.Aggregator.GetDeathRecap(bar.guid)
    local hits = recap and recap.hits
    if hits and table.getn(hits) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Last death (most recent first):", 1, 0.82, 0)
        local n = table.getn(hits)
        local shown = 0
        local i
        for i = n, 1, -1 do
            if shown >= 6 then break end
            shown = shown + 1
            local h = hits[i]
            local label = (shown == 1) and ("Killing blow: " .. h.attacker .. " (" .. h.label .. ")")
                or (h.attacker .. " (" .. h.label .. ")")
            GameTooltip:AddDoubleLine(label, FormatNumber(h.amount) .. (h.isCrit and " CRIT" or ""),
                0.9, 0.9, 0.9, 1, 1, 1)
        end
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("No hit history recorded for this death", 0.6, 0.6, 0.6)
    end

    GameTooltip:Show()
end

-- The actual encounter object behind whatever segment this window has
-- selected - current/overall/history all resolve through here so
-- Refresh, the tooltip, Announce, and the breakdown window don't each
-- need their own copy of this branching.
local function GetActiveEncounter(inst)
    if CL.testMode then
        return CL.Aggregator.GetTestEncounter()
    end
    local f = inst.frame
    if f.segment == "overall" then
        return CL.Aggregator.GetOverall()
    elseif f.segment == "history" then
        return f.historyEncounter
    end
    return CL.Aggregator.GetCurrentDisplay()
end

-- The bar tooltip is a brief summary: each list shows its top entries
-- and folds the rest into one "...and N more" line.
local TOOLTIP_TOP_TARGETS = 3
local TOOLTIP_TOP_SPELLS = 5

-- Adds a titled, sorted list (entries of { name, total }) capped at
-- `limit` rows, with percentages of `grandTotal`.
local function AddTopList(title, list, limit, grandTotal)
    local n = table.getn(list)
    if n == 0 then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(title, 1, 0.82, 0)
    local function Pct(value)
        return (grandTotal > 0) and string.format(" (%.1f%%)", value / grandTotal * 100) or ""
    end
    local shown = (n > limit) and limit or n
    local i
    for i = 1, shown do
        GameTooltip:AddDoubleLine(list[i].name, FormatNumber(list[i].total) .. Pct(list[i].total),
            0.9, 0.9, 0.9, 1, 1, 1)
    end
    if n > shown then
        local rest = 0
        for i = shown + 1, n do rest = rest + list[i].total end
        GameTooltip:AddDoubleLine("...and " .. (n - shown) .. " more", FormatNumber(rest) .. Pct(rest),
            0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    end
end

local function ShowBarTooltip(inst, bar)
    if not bar.guid then return end

    if inst.frame.mode == "threat" then
        local snapshot = CL.Threat and CL.Threat.GetSnapshot()
        local t = snapshot and snapshot[bar.guid]
        if not t then return end
        local info = CL.GuidCache and CL.GuidCache.Resolve(bar.guid)
        GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
        GameTooltip:AddLine(t.name, ClassColor(info and info.classToken))
        GameTooltip:AddDoubleLine("Threat", FormatNumber(t.threat), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("% of Tank", t.perc .. "%", 1, 1, 1, 1, 1, 1)
        if t.melee then
            GameTooltip:AddLine("In melee range", 0.7, 0.7, 0.7)
        end
        if t.tank then
            GameTooltip:AddLine("Currently tanking", 1, 0.82, 0)
        end
        GameTooltip:Show()
        return
    end

    local enc = GetActiveEncounter(inst)
    local u = enc and enc.units and enc.units[bar.guid]
    if not u then return end

    local mode = inst.frame.mode

    if mode == "deaths" then
        ShowDeathTooltip(bar, u)
        return
    end

    local total = MetricTotal(u, mode)

    local duration = 1
    if inst.frame.segment == "overall" then
        duration = CL.Aggregator.GetOverallDuration()
    elseif enc then
        duration = (enc.duration and enc.duration > 0) and enc.duration or (GetTime() - enc.startTime)
    end
    if duration <= 0 then duration = 1 end

    GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
    GameTooltip:AddLine(u.name, ClassColor(u.classToken))
    if COUNT_ONLY_MODES[mode] then
        GameTooltip:AddDoubleLine(MODE_TITLES[mode] or "Total", CountLabel(mode, total), 1, 1, 1, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine(MODE_TITLES[mode] or "Total", FormatNumber(total), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Rate", FormatNumber(total / duration) .. " " .. CL.RateSuffix(mode), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Duration", string.format("%.1fs", duration), 1, 1, 1, 1, 1, 1)

    if mode == "healing" and u.healingDone then
        CL.AddOverhealLines(u.healingDone, function(label, value, dim)
            local c = dim and 0.6 or 1
            GameTooltip:AddDoubleLine(label, value, c, c, c, c, c, c)
        end)
    end

    if mode == "damage" or mode == "taken" then
        local bucket = (mode == "taken") and u.damageTaken or u.damageDone
        if bucket then
            local function AddSums(sum, av)
                local k, v
                for k, v in pairs(av) do
                    sum[k] = (sum[k] or 0) + v
                end
            end

            local sum = {}
            local hits = 0
            local entry
            for _, entry in ipairs({ bucket.melee, bucket.offhand, bucket.petMelee, bucket.petOffhand }) do
                if entry then
                    hits = hits + (entry.hits or 0)
                    if entry.avoided then AddSums(sum, entry.avoided) end
                end
            end
            local avoided, summary = CL.SummarizeAvoided(sum)
            if avoided > 0 then
                local swings = hits + avoided
                local label = (mode == "taken") and "Swings avoided" or "Swings missed"
                GameTooltip:AddDoubleLine(label,
                    string.format("%d/%d (%.0f%%)", avoided, swings, (avoided / swings) * 100), 1, 1, 1, 1, 1, 1)
                GameTooltip:AddLine(summary, 0.7, 0.7, 0.7)
            end

            CL.AddMitigationLines(bucket, hits, function(label, value)
                GameTooltip:AddDoubleLine(label, value, 1, 1, 1, 1, 1, 1)
            end)

            -- Spell misses (SPELL_MISS_*) - a count only, since a spell's
            -- hit total mixes direct hits with DoT ticks and wouldn't be a
            -- fair denominator here (the breakdown window does it per spell).
            if bucket.spellMisses then
                local spellSum = {}
                local av
                for _, av in pairs(bucket.spellMisses) do AddSums(spellSum, av) end
                local spellAvoided, spellSummary = CL.SummarizeAvoided(spellSum)
                if spellAvoided > 0 then
                    GameTooltip:AddDoubleLine((mode == "taken") and "Spells avoided" or "Spells missed",
                        tostring(spellAvoided), 1, 1, 1, 1, 1, 1)
                    GameTooltip:AddLine(spellSummary, 0.7, 0.7, 0.7)
                end
            end
        end
    end

    AddTopList("By target:", BuildTargetSummary(u, mode), TOOLTIP_TOP_TARGETS, total)
    AddTopList("By spell:", BuildSpellSummary(u, mode), TOOLTIP_TOP_SPELLS, total)

    -- The tooltip is a summary; the full lists live in the breakdown.
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click for the full breakdown", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function CreateBar(inst, parent, index)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetStatusBarTexture(CL.GetBarTexture())
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarColor(0.6, 0.6, 0.6, 0.9)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(CL.GetBarTexture())
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
    bar.bg = bg

    -- Border overlay (Options: "Show bar border" / "Highlight my bar") on
    -- a child frame one level up: a backdrop on the StatusBar itself
    -- would draw underneath its own fill texture.
    local borderFrame = CreateFrame("Frame", nil, bar)
    borderFrame:SetAllPoints(bar)
    borderFrame:SetFrameLevel(bar:GetFrameLevel() + 10)
    borderFrame:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    borderFrame:SetBackdropBorderColor(1, 1, 1, 0)
    bar.borderFrame = borderFrame

    -- Class icon slot - off by default (Options: "Show class icon"),
    -- hidden and unanchored until RefreshInstance decides per-refresh
    -- whether to show it. When it's off, nameText sits exactly where it
    -- always has (bar:LEFT+4) - no permanently-reserved gap for people
    -- who never turn this on.
    local classIcon = bar:CreateTexture(nil, "OVERLAY")
    classIcon:SetWidth(height - 4)
    classIcon:SetHeight(height - 4)
    classIcon:SetPoint("LEFT", bar, "LEFT", 3, 0)
    -- Bundled img/classicons.tga (pfUI's, see README): the stock
    -- UI-Classes-Circle atlas doesn't render on this client.
    classIcon:SetTexture("Interface\\AddOns\\CombatLedger\\img\\classicons")
    classIcon:Hide()
    bar.classIcon = classIcon

    local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    valueText:SetText("")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    -- LEFT is re-anchored each refresh depending on the class icon;
    -- RIGHT stops at valueText so long names don't run into the value.
    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
    nameText:SetPoint("RIGHT", valueText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetText("")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    bar:EnableMouse(true)
    bar:SetScript("OnMouseUp", function()
        -- No breakdown data exists for Threat (see Threat.lua) - it's a
        -- live server snapshot, not something recorded per-ability.
        if bar.guid and CL.UIBreakdown and inst.frame.mode ~= "threat" then
            CL.UIBreakdown.Show(bar.guid, inst.frame.mode, inst.frame.segment, inst.frame.historyEncounter)
        end
    end)
    bar:SetScript("OnEnter", function() ShowBarTooltip(inst, bar) end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    bar.targetPct = 0
    bar:Hide()
    return bar
end

-- The resize grip only takes up room when it's actually shown - locked
-- (grip hidden) reclaims that space for bars instead of leaving it
-- empty below the last one.
local function FooterGap()
    if CL.GetSetting("lockWindow") then return 4 end
    return FOOTER_GAP
end

-- Threat mode doesn't scroll: returns how many rows fit and, when the
-- player ranks below them, moves the player into the last visible slot
-- (display only - threatRank keeps the real rank for the label).
local function PinThreatPlayerToViewport(list, window, hasMarker)
    if not list or not window then return 1 end

    local step = CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP
    local viewportHeight = window:GetHeight() - HEADER_HEIGHT - FooterGap()
    local visibleRows = math.floor((viewportHeight + BAR_GAP) / step)
    if visibleRows < 1 then visibleRows = 1 end
    if visibleRows > MAX_BARS then visibleRows = MAX_BARS end

    local visiblePlayerRows = visibleRows - (hasMarker and 1 or 0)
    if visiblePlayerRows < 1 then visiblePlayerRows = 1 end

    local playerName = UnitName("player")
    local playerIndex
    local i
    for i = 1, table.getn(list) do
        if list[i].name == playerName then
            playerIndex = i
            break
        end
    end

    if playerIndex and playerIndex > visiblePlayerRows then
        local playerEntry = table.remove(list, playerIndex)
        table.insert(list, visiblePlayerRows, playerEntry)
    end

    return visibleRows
end

-- How far the bar list can scroll, computed from window:GetHeight()
-- (set directly) because anchor-derived heights like
-- GetVerticalScrollRange() can read stale on this client.
local function GetMaxBarScroll(window)
    local viewportHeight = window:GetHeight() - HEADER_HEIGHT - FooterGap()
    local maxScroll = window.barParent:GetHeight() - viewportHeight
    if maxScroll < 0 then maxScroll = 0 end
    return maxScroll
end

local RefreshInstance -- forward-declared, assigned below
local ShowThreatFilterDropdown -- forward-declared, assigned below

local function CreateHeaderButton(parent, width, initialText)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(width)
    btn:SetHeight(16)
    -- Same flat backdrop as the window; ApplyButtonSkin only recolors it.
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    btn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
    btn:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

    -- Subtle raised-button sheen (no Blizzard button art dependency) so
    -- this reads as an actual button rather than a flat tinted box when
    -- pfUI isn't skinning it.
    local sheen = btn:CreateTexture(nil, "ARTWORK")
    sheen:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    sheen:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    if sheen.SetGradientAlpha then
        sheen:SetGradientAlpha("VERTICAL", 1, 1, 1, 0.12, 1, 1, 1, 0)
    else
        sheen:SetVertexColor(1, 1, 1, 0.06)
    end

    -- Press feedback: darken on mouse-down. OnMouseUp isn't delivered
    -- reliably when the click opens a menu or window, so btn.pressedAt
    -- also lets SetButtonTooltip's OnUpdate revert it after a timeout.
    btn:SetScript("OnMouseDown", function()
        btn.pressedAt = GetTime()
        btn:SetBackdropColor(0.05, 0.05, 0.06, 0.9)
    end)
    btn:SetScript("OnMouseUp", function()
        btn.pressedAt = nil
        local fr, fg, fb, fa = CL.GetButtonNormalFill()
        btn:SetBackdropColor(fr, fg, fb, fa)
    end)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(btn)
    label:SetJustifyH("CENTER")
    label:SetText(initialText or "")
    CL.ApplyFont(label)
    btn.label = label
    return btn
end

-- Sets the mode/segment button's label. The button's width comes from
-- the window's current width (ComputeHeaderButtonWidths), not the text,
-- so it doesn't jump around as labels change and shrinks with the
-- window. Text that doesn't fit is truncated with "..." (a FontString
-- isn't clipped by its frame and would bleed into the next button).
-- btn.fullText/btn.isSegBtn keep the original text so a reflow (resize,
-- font change) re-truncates from it.
local SEG_BTN_PREFERRED, MODE_BTN_PREFERRED = 90, 100
local HEADER_BTN_MIN_WIDTH = 20
-- Space the left button group (margin + R/!) actually occupies, plus
-- breathing room before Mode/Segment start - see CreateWindowFrame's
-- real anchor math (resetBtn/announceBtn) for what this approximates.
local HEADER_LEFT_GROUP_WIDTH = 46
local HEADER_RIGHT_PADDING = 20

local function ComputeHeaderButtonWidths(windowWidth)
    local preferredTotal = SEG_BTN_PREFERRED + MODE_BTN_PREFERRED
    local available = (windowWidth or 0) - HEADER_LEFT_GROUP_WIDTH - HEADER_RIGHT_PADDING
    if available >= preferredTotal then
        return SEG_BTN_PREFERRED, MODE_BTN_PREFERRED
    end
    if available < HEADER_BTN_MIN_WIDTH * 2 then
        available = HEADER_BTN_MIN_WIDTH * 2
    end
    return available * (SEG_BTN_PREFERRED / preferredTotal), available * (MODE_BTN_PREFERRED / preferredTotal)
end

local function SetHeaderButtonText(btn, text, isSegBtn)
    btn.fullText = text
    btn.isSegBtn = isSegBtn
    btn.label:SetText(text)
    local parent = btn:GetParent()
    local segW, modeW = ComputeHeaderButtonWidths(parent and parent:GetWidth())
    local w = isSegBtn and segW or modeW
    local target = w - 12
    if btn.label:GetStringWidth() > target then
        local truncated = text
        while string.len(truncated) > 1 and btn.label:GetStringWidth() > target do
            truncated = string.sub(truncated, 1, string.len(truncated) - 1)
            btn.label:SetText(truncated .. "...")
        end
    end
    btn:SetWidth(w)
end

-- Re-runs SetHeaderButtonText from the remembered original text/role -
-- for RestyleAll's font-size-change refresh and the resize grip's live
-- drag, where the button's available width may have changed without
-- the underlying text changing.
local function ReflowHeaderButton(btn)
    if btn.fullText then
        SetHeaderButtonText(btn, btn.fullText, btn.isSegBtn)
    end
end

-- Re-applies texture/font/height to every pooled bar in every open
-- window after an Options change, and repositions each pool (bar
-- Y-offsets were computed from the height at creation time).
local function RestyleAll()
    local id, inst
    for id, inst in pairs(instances) do
        local window = inst.frame
        if window then
            if CL.GetSetting("lockWindow") then
                window.resizeGrip:Hide()
            else
                window.resizeGrip:Show()
            end
            window.barScroll:ClearAllPoints()
            window.barScroll:SetPoint("TOPLEFT", window, "TOPLEFT", 6, -HEADER_HEIGHT)
            window.barScroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -6, FooterGap())
            window.barParent:SetWidth(window:GetWidth() - 12)
            -- Height is sized to the actual shown count, not the full
            -- MAX_BARS pool (see RefreshInstance) - invalidate the
            -- cached count so the refresh below recomputes it for the
            -- new bar height instead of leaving it at a stale size.
            inst.lastShownCount = -1
            local themeR, themeG, themeB = CL.GetThemeColor()
            CL.ApplyWindowSkin(window, themeR, themeG, themeB, 0.8)
            CL.ApplyButtonSkin(window.resetBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.announceBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.segBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.modeBtn, themeR, themeG, themeB)
            CL.ApplyFont(window.resetBtn.label)
            CL.ApplyFont(window.announceBtn.label)
            CL.ApplyFont(window.segBtn.label)
            CL.ApplyFont(window.modeBtn.label)
            -- A font change changes label widths; re-fit them now.
            ReflowHeaderButton(window.segBtn)
            ReflowHeaderButton(window.modeBtn)
            local newBarHeight = CL.GetBarHeight(BAR_HEIGHT)
            CL.RepositionBarPool(inst.bars, newBarHeight, BAR_GAP)
            local i
            for i = 1, table.getn(inst.bars) do
                local bar = inst.bars[i]
                bar:SetStatusBarTexture(CL.GetBarTexture())
                bar.bg:SetTexture(CL.GetBarTexture())
                CL.ApplyFont(bar.nameText, CL.GetFontSize())
                CL.ApplyFont(bar.valueText, CL.GetFontSize())
                -- The class icon follows the bar height.
                bar.classIcon:SetWidth(newBarHeight - 4)
                bar.classIcon:SetHeight(newBarHeight - 4)
            end
            RefreshInstance(inst)
        end
    end
    -- Dropdown row fonts aren't refreshed here - CL.ShowDropdown (Core.lua)
    -- already re-applies CL.ApplyFont to every row's text each time it
    -- opens, so there's nothing stale to catch up on a pure appearance
    -- change while it's closed.
end
CL.OnAppearanceChanged(RestyleAll)

-- Tooltip plus hover/press visuals for a header button. restR/G/B
-- (optional) is the resting border color; hover brightens it to white.
-- alwaysRestR/G/B (optional) forces a fixed resting color regardless of
-- "Match pfUI"/"Class colored menus".
--
-- Driven by polling MouseIsOver in OnUpdate rather than OnEnter/OnLeave:
-- a click that opens a menu or window can swallow the Leave/Up events
-- on this client, which would leave the button stuck highlighted or
-- pressed. The resting fill is re-asserted every frame for the same
-- reason. This is the only hover handler - ApplyButtonSkin tells pfUI
-- not to install its own.
local function SetButtonTooltip(btn, title, subtitle, restR, restG, restB, alwaysRestR, alwaysRestG, alwaysRestB)
    local function NormalBorderColor()
        if alwaysRestR then return alwaysRestR, alwaysRestG, alwaysRestB end
        if restR and CL.GetSetting("classColorMenus") then return restR, restG, restB end
        -- Matches CL.ApplyButtonSkin's own resting color while pfUI is
        -- matched (SkinButton's CreateBackdrop call sets exactly this),
        -- so owning hover unconditionally doesn't fight the rest-state
        -- color pfUI itself set up.
        if CL.IsMatchPfui() and pfUI.api and pfUI.api.GetStringColor and pfUI_config then
            local ok, r, g, b = pcall(pfUI.api.GetStringColor, pfUI_config.appearance.border.color)
            if ok and r then return r, g, b end
        end
        return CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B
    end
    local wasOver = false
    btn:SetScript("OnUpdate", function()
        if btn.pressedAt and (GetTime() - btn.pressedAt) > 0.15 then
            btn.pressedAt = nil
        end
        if not btn.pressedAt then
            local fr, fg, fb, fa = CL.GetButtonNormalFill()
            btn:SetBackdropColor(fr, fg, fb, fa)
        end
        local isOver = MouseIsOver(btn)
        if isOver ~= wasOver then
            if isOver then
                GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
                GameTooltip:SetText(title, 1, 1, 1)
                if subtitle then
                    GameTooltip:AddLine(subtitle, 0.7, 0.7, 0.7)
                end
                GameTooltip:Show()
            else
                GameTooltip:Hide()
            end
            wasOver = isOver
        end
        if restR then
            if isOver then
                btn:SetBackdropBorderColor(1, 1, 1, 1)
            else
                local r, g, b = NormalBorderColor()
                btn:SetBackdropBorderColor(r, g, b, 1)
            end
        end
    end)
end

-- Posts this window's top N (Options: Announce top) for its current
-- mode/segment to the configured channel: a header, then one line per rank.
local function AnnounceTop(inst)
    local window = inst.frame
    local isThreat = (window.mode == "threat")

    local enc, units, list
    if isThreat then
        list = BuildThreatList(window.threatFilter)
    else
        enc = GetActiveEncounter(inst)
        units = enc and enc.units or {}
        list = BuildSortedList(units, window.mode)
    end
    if table.getn(list) == 0 then
        CL.Print("Nothing to announce - no data for the current mode" .. (isThreat and "" or "/segment") .. ".")
        return
    end

    local duration = 1
    if not isThreat then
        if window.segment == "overall" then
            duration = CL.Aggregator.GetOverallDuration()
        elseif enc then
            duration = (enc.duration and enc.duration > 0) and enc.duration or (GetTime() - enc.startTime)
        end
        if duration <= 0 then duration = 1 end
    end

    local segLabel = isThreat and "Live" or ((window.segment == "overall") and "Overall" or "Current Fight")
    local channel = CL.ResolveAnnounceChannel()
    local count = CL.GetSetting("announceCount") or 5
    if count > table.getn(list) then count = table.getn(list) end

    SendChatMessage("CombatLedger - " .. (MODE_TITLES[window.mode] or window.mode) .. " (" .. segLabel .. "):", channel)
    local i
    for i = 1, count do
        local entry = list[i]
        local line
        if isThreat then
            line = i .. ". " .. entry.name .. " - " .. FormatNumber(entry.total) .. " (" .. (entry.perc or 0) .. "%)" .. (entry.tank and " [Tank]" or "")
        elseif window.mode == "deaths" then
            line = i .. ". " .. entry.name .. " - " .. entry.total .. ((entry.total == 1) and " death" or " deaths")
        elseif COUNT_ONLY_MODES[window.mode] then
            line = i .. ". " .. entry.name .. " - " .. CountLabel(window.mode, entry.total)
        else
            line = i .. ". " .. entry.name .. " - " .. FormatNumber(entry.total) .. " (" .. FormatNumber(entry.total / duration) .. ")"
        end
        SendChatMessage(line, channel)
    end
end

-- `inst.defaultMode`/`defaultSegment` seed a fresh window (ignored once
-- a saved window state - see CL.GetWindowState - already has values).
local function CreateWindowFrame(inst)
    local id = inst.id
    local f = CreateFrame("Frame", "CombatLedgerMainWindow" .. (id == "main" and "" or id), UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.8))
    f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    -- MEDIUM, like the other CombatLedger windows: higher strata draw
    -- over Blizzard's character/bag/quest panels. Dropdowns place
    -- themselves one tier above their anchor.
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true) -- can't be dragged/pushed off-screen, unlike before
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if CL.GetSetting("lockWindow") then return end
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout(id, this)
    end)
    f:Hide()

    CL.ApplyLayout(id, f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local savedWinState = CL.GetWindowState(id)
    f.mode = (savedWinState and savedWinState.mode) or inst.defaultMode or "damage"
    f.segment = (savedWinState and savedWinState.segment) or inst.defaultSegment or "current"
    -- Threat's own filter (which roster names to show - see
    -- ShowThreatFilterDropdown) instead of Current/Overall/History,
    -- since threat has neither. [name] = true means "included"; empty
    -- means "show everyone".
    f.threatFilter = (savedWinState and savedWinState.threatFilter) or {}

    -- Not in UISpecialFrames: a meter shouldn't close on a stray Escape.
    -- The mode and segment buttons double as the title.

    -- Header row: Reset/Announce (left, compact single-letter - full
    -- names live in each button's own hover tooltip) ... Mode |
    -- Segment (right, click opens a dropdown - these two show the full
    -- word/name directly, see SetHeaderButtonText).
    local resetBtn = CreateHeaderButton(f, 18, "R")
    resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("COMBATLEDGER_RESET_DATA", "Saved History is kept.")
    end)
    SetButtonTooltip(resetBtn, "Reset", "Clear Current Fight and Overall (History is kept)", themeR, themeG, themeB)
    CL.ApplyButtonSkin(resetBtn, themeR, themeG, themeB)
    f.resetBtn = resetBtn

    -- Options open from the minimap icon's right-click or /cl options.
    local announceBtn = CreateHeaderButton(f, 18, "!")
    announceBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
    announceBtn:SetScript("OnClick", function()
        -- Confirm first - this button sits right next to Options/Reset
        -- in the header, easy to fat-finger, and firing it by accident
        -- spams whatever chat channel is configured.
        pendingAnnounceInst = inst
        StaticPopup_Show("COMBATLEDGER_ANNOUNCE", CL.GetSetting("announceCount") or 5)
    end)
    SetButtonTooltip(announceBtn, "Announce", "Post the top " .. (CL.GetSetting("announceCount") or 5) ..
        " to chat (channel/count set in Options)", themeR, themeG, themeB)
    CL.ApplyButtonSkin(announceBtn, themeR, themeG, themeB)
    f.announceBtn = announceBtn

    -- Extra windows are created and closed from Options' Windows list,
    -- so every window has the same header with no close button.
    local segBtn = CreateHeaderButton(f, 20, "")
    SetHeaderButtonText(segBtn, (f.mode == "threat") and "Filter" or SEGMENT_LABELS[f.segment], true)
    segBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Threat has no Current/Overall/History (see Threat.lua) - this
    -- button becomes a name filter for it instead ("Filter"), same
    -- slot, different job. Called once at creation (a window can be
    -- created already in Threat mode, from a saved window state) and
    -- again on every mode switch.
    local function UpdateSegButtonForMode()
        if f.mode == "threat" then
            SetHeaderButtonText(segBtn, "Filter", true)
            SetButtonTooltip(segBtn, "Filter", "Choose which raid/party members show up in Threat mode", themeR, themeG, themeB)
        else
            SetHeaderButtonText(segBtn, SEGMENT_LABELS[f.segment], true)
            SetButtonTooltip(segBtn, "Segment", "Current Fight / Overall / a recent saved encounter", themeR, themeG, themeB)
        end
    end

    segBtn:SetScript("OnClick", function()
        -- Clear the pressed look here: opening a menu from this click
        -- can swallow the OnMouseUp that would normally clear it.
        segBtn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
        if f.mode == "threat" then
            ShowThreatFilterDropdown(inst)
            return
        end
        local options = {}
        local classColor = PlayerClassColorTable()
        table.insert(options, { label = "Overall", color = classColor, onClick = function()
            f.segment = "overall"
            SetHeaderButtonText(segBtn, SEGMENT_LABELS.overall, true)
            CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
        table.insert(options, { label = "Current", color = classColor, onClick = function()
            f.segment = "current"
            SetHeaderButtonText(segBtn, SEGMENT_LABELS.current, true)
            CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
        if CL.History then
            local hist = CL.History.GetHistory()
            local n = table.getn(hist)
            local limit = (n < 4) and n or 4 -- most recent 4 (+Current/Overall = 6 rows); full list + delete/clear lives in /cl history
            local i
            for i = 1, limit do
                local enc = hist[i]
                table.insert(options, { label = enc.label or "Encounter", onClick = function()
                    UI.ShowHistoryEncounterIn(inst, enc)
                end })
            end
        end
        CL.ShowDropdown(segBtn, options)
    end)
    UpdateSegButtonForMode()
    CL.ApplyButtonSkin(segBtn, themeR, themeG, themeB)
    f.segBtn = segBtn

    local modeBtn = CreateHeaderButton(f, 20, "")
    SetHeaderButtonText(modeBtn, MODE_TITLES[f.mode] or f.mode, false)
    modeBtn:SetPoint("RIGHT", segBtn, "LEFT", -4, 0)

    -- Switches this window's mode. `persist` saves it as the window's
    -- chosen mode; the automatic in-combat switch (UI.ApplyCombatModes)
    -- doesn't, so a reload mid-fight comes back in the chosen mode.
    local function SetMode(key, persist)
        f.mode = key
        SetHeaderButtonText(modeBtn, MODE_TITLES[key] or key, false)
        UpdateSegButtonForMode()
        if persist then CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter) end
        RefreshInstance(inst)
    end
    f.SetMode = SetMode

    modeBtn:SetScript("OnClick", function()
        -- Same explicit reset as segBtn above - see that comment.
        modeBtn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
        local options = {}
        local i
        for i = 1, table.getn(MODE_ORDER) do
            local key = MODE_ORDER[i]
            table.insert(options, { label = MODE_TITLES[key] or key, onClick = function()
                -- A manual pick during combat is kept after the fight.
                inst.restoreMode = nil
                SetMode(key, true)
            end })
        end
        CL.ShowDropdown(modeBtn, options)
    end)
    SetButtonTooltip(modeBtn, "Mode", "Damage Done / Healing Done / Damage Taken / Deaths / Threat", themeR, themeG, themeB)
    CL.ApplyButtonSkin(modeBtn, themeR, themeG, themeB)
    f.modeBtn = modeBtn

    -- A real ScrollFrame (not a whole-row index shift like the History
    -- window) so a bar that only partially fits the remaining space
    -- renders cut off right at the edge instead of being hidden
    -- entirely or leaving blank space below the last whole one - scroll
    -- wheel moves through the rest via SetVerticalScroll.
    local barScroll = CreateFrame("ScrollFrame", nil, f)
    barScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    barScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FooterGap())
    f.barScroll = barScroll

    -- The scroll child must not be anchored (SetScrollChild positions
    -- it). Its width is set explicitly and kept in sync on resize, since
    -- the ScrollFrame's own width can read stale right after a resize.
    local barParent = CreateFrame("Frame", nil, barScroll)
    barParent:SetWidth(f:GetWidth() - 12)
    barParent:SetHeight(MAX_BARS * (CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP))
    f.barParent = barParent
    barScroll:SetScrollChild(barParent)

    barScroll:EnableMouseWheel(true)
    barScroll:SetScript("OnMouseWheel", function()
        -- Threat deliberately shows only what fits and pins the player
        -- into that fixed snapshot; all recorded modes retain scrolling.
        if f.mode == "threat" then
            barScroll:SetVerticalScroll(0)
            return
        end
        local delta = arg1
        if not delta then return end
        local scrollStep = CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP
        local cur = barScroll:GetVerticalScroll()
        local maxScroll = GetMaxBarScroll(f)
        local new = cur - delta * scrollStep
        if new < 0 then new = 0 end
        if new > maxScroll then new = maxScroll end
        barScroll:SetVerticalScroll(new)
    end)

    local i
    for i = 1, MAX_BARS do
        inst.bars[i] = CreateBar(inst, barParent, i)
    end

    -- Bottom-right resize grip: a tinted square (the chat-frame resize
    -- texture doesn't render on this client).
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    grip:SetBackdropColor(themeR, themeG, themeB, 0.4)
    grip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    grip:SetScript("OnMouseDown", function()
        if CL.GetSetting("lockWindow") then return end
        this.sizing = true
        this.startX, this.startY = GetCursorPosition()
        this.startW, this.startH = f:GetWidth(), f:GetHeight()
        this.scale = f:GetEffectiveScale()
    end)
    grip:SetScript("OnMouseUp", function()
        this.sizing = nil
        CL.SaveLayout(id, f)
    end)
    grip:SetScript("OnUpdate", function()
        if not this.sizing then return end
        local x, y = GetCursorPosition()
        local scale = this.scale or 1
        local newW = this.startW + (x - this.startX) / scale
        local newH = this.startH - (y - this.startY) / scale
        if newW < MIN_WINDOW_WIDTH then newW = MIN_WINDOW_WIDTH end
        if newW > MAX_WINDOW_WIDTH then newW = MAX_WINDOW_WIDTH end
        if newH < MIN_WINDOW_HEIGHT then newH = MIN_WINDOW_HEIGHT end
        if newH > MAX_WINDOW_HEIGHT then newH = MAX_WINDOW_HEIGHT end
        f:SetWidth(newW)
        f:SetHeight(newH)
        barParent:SetWidth(newW - 12)
        -- Mode/Segment shrink live as the window narrows (see
        -- SetHeaderButtonText) instead of only picking up the new width
        -- on the next label change.
        ReflowHeaderButton(f.segBtn)
        ReflowHeaderButton(f.modeBtn)
    end)
    if CL.GetSetting("lockWindow") then grip:Hide() end
    f.resizeGrip = grip

    -- Only pfUI-skins the window's own chrome while "Match pfUI" is on -
    -- CreateBackdrop applies pfUI's background/border unconditionally
    -- whenever pfUI is loaded at all, which would override the manual
    -- opacity/texture Options even with Match pfUI unchecked.
    CL.ApplyWindowSkin(f, themeR, themeG, themeB, 0.8)

    inst.frame = f
    return f
end

RefreshInstance = function(inst)
    local window = inst.frame
    if not window or not window:IsShown() then return end

    local isThreat = (window.mode == "threat")
    local enc, list, threatMarker
    local duration = 1

    -- What this draw reflects - the refresh loop (see the driver at the
    -- bottom of this file) skips windows whose data hasn't moved on.
    inst.drawnVersion = CL.Aggregator.GetDataVersion()
    inst.drawnAt = GetTime()

    if isThreat then
        list, threatMarker = BuildThreatList(window.threatFilter)
    else
        enc = GetActiveEncounter(inst)
        local units = enc and enc.units or {}
        inst.sortedList = inst.sortedList or {}
        list = BuildSortedList(units, window.mode, inst.sortedList)

        if window.segment == "overall" then
            -- Active-combat time only, frozen between fights - see
            -- Aggregator's GetOverallDuration.
            duration = CL.Aggregator.GetOverallDuration()
        elseif enc then
            if enc.duration and enc.duration > 0 then
                duration = enc.duration
            else
                duration = GetTime() - enc.startTime
            end
        end
        if duration <= 0 then duration = 1 end
    end

    local maxVal = 1
    if list[1] and list[1].total > 0 then
        maxVal = list[1].total
    end

    -- Display-only ordering adjustment for Threat mode. Do this after
    -- maxVal is captured from the true #1 entry so pinning a low-threat
    -- player into a very short viewport never changes bar scaling.
    local threatVisibleRows
    if isThreat then
        threatVisibleRows = PinThreatPlayerToViewport(list, window, threatMarker ~= nil)
        -- At an extreme one-row height, the player takes priority over
        -- the reference marker so the always-visible promise still holds.
        if threatVisibleRows <= 1 then threatMarker = nil end
    end

    -- Pinned to the very top regardless of sort order - it's a
    -- reference line, not a real threat total, so it never competes for
    -- the #1 spot on its own (tiny) value.
    if threatMarker then
        table.insert(list, 1, threatMarker)
    end

    -- Threat has no scrolling: discard display entries below the fixed
    -- viewport after self-pinning. BuildThreatList itself remains complete
    -- for announcements and other non-display consumers.
    if isThreat then
        while table.getn(list) > threatVisibleRows do
            table.remove(list)
        end
        window.barScroll:SetVerticalScroll(0)
    end

    local shown = 0
    local rank = 0
    local i
    for i = 1, MAX_BARS do
        local bar = inst.bars[i]
        local entry = list[i]
        if entry then
            shown = shown + 1
            local pct = entry.total / maxVal
            if pct > 1 then pct = 1 end
            if entry.isAgroMarker then pct = 1 end -- always full-width, a reference line not a real total
            bar.targetPct = pct
            -- Bars glide only while a fight is live; a finished Current
            -- Fight snaps to its final values so the end looks instant.
            local shouldSnap = not CL.IsSmoothBars()
                or (not isThreat and window.segment == "current" and not CL.Aggregator.GetCurrent())
            if shouldSnap then
                bar:SetValue(pct)
            end
            if entry.isAgroMarker then
                bar:SetStatusBarColor(0.75, 0.1, 0.1, 0.9)
                bar.nameText:SetText(entry.name)
                bar.valueText:SetText("+" .. FormatNumber(entry.total))
            elseif isThreat then
                rank = rank + 1
                -- The player's own threat row is solid red so it stands
                -- out in a moving list (Threat mode only).
                if entry.name == UnitName("player") then
                    bar:SetStatusBarColor(1, 0.2, 0.2, 1)
                else
                    local r, g, b = ClassColor(entry.classToken)
                    bar:SetStatusBarColor(r, g, b, 0.9)
                end
                bar.nameText:SetText((entry.threatRank or rank) .. ". " .. (entry.tank and "|cffFFD100[T]|r " or "") .. entry.name)
                bar.valueText:SetText(FormatNumber(entry.total) .. "  (" .. (entry.perc or 0) .. "%)")
            else
                rank = rank + 1
                local r, g, b = ClassColor(entry.classToken)
                bar:SetStatusBarColor(r, g, b, 0.9)
                bar.nameText:SetText(rank .. ". " .. entry.name)
                if window.mode == "deaths" then
                    bar.valueText:SetText(entry.total .. ((entry.total == 1) and " death" or " deaths"))
                elseif COUNT_ONLY_MODES[window.mode] then
                    bar.valueText:SetText(CountLabel(window.mode, entry.total))
                else
                    local rate = entry.total / duration
                    bar.valueText:SetText(FormatNumber(entry.total) .. "  (" .. FormatNumber(rate) .. ")")
                end
            end

            -- Bar border: "Highlight my bar" (own row) takes precedence
            -- over "Show bar border" (every row); the aggro marker gets
            -- neither.
            if entry.isAgroMarker then
                bar.borderFrame:SetBackdropBorderColor(1, 1, 1, 0)
            elseif CL.GetSetting("highlightSelf") and entry.name == UnitName("player") then
                local sc = CL.GetSetting("highlightSelfColor")
                bar.borderFrame:SetBackdropBorderColor(sc[1], sc[2], sc[3], 1)
            elseif CL.GetSetting("barBorderEnabled") then
                local bc = CL.GetSetting("barBorderColor")
                bar.borderFrame:SetBackdropBorderColor(bc[1], bc[2], bc[3], 1)
            else
                bar.borderFrame:SetBackdropBorderColor(1, 1, 1, 0)
            end

            -- Class icon (Options: "Show class icon"), only for entries
            -- with a known class. Re-setting the LEFT point replaces the
            -- previous one.
            if not entry.isAgroMarker and CL.GetSetting("showClassIcon") and entry.classToken and CL.CLASS_ICON_TCOORDS[entry.classToken] then
                local coords = CL.CLASS_ICON_TCOORDS[entry.classToken]
                bar.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                bar.classIcon:Show()
                bar.nameText:SetPoint("LEFT", bar.classIcon, "RIGHT", 3, 0)
            else
                bar.classIcon:Hide()
                bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
            end

            bar.guid = entry.guid
            bar:Show()
        else
            bar.guid = nil
            bar:Hide()
        end
    end

    -- The scroll child is sized to the bars shown (not the whole pool),
    -- and only resized when that count changes: constant SetHeight calls
    -- on a scroll child leave its scroll range unreliable on this client.
    if shown ~= inst.lastShownCount then
        inst.lastShownCount = shown
        window.barParent:SetHeight(math.max(shown, 1) * (CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP))
    end

    -- Re-clamp scroll position in case the list got shorter (mode/
    -- segment switch, a unit dropping off) since the last scroll -
    -- SetVerticalScroll doesn't do this on its own if the scroll child
    -- shrinks out from under an existing offset.
    local maxScroll = GetMaxBarScroll(window)
    if window.barScroll:GetVerticalScroll() > maxScroll then
        window.barScroll:SetVerticalScroll(maxScroll)
    end
end

-- Threat mode's segment button: a name filter listing every group
-- member. Each click toggles a name and reopens the menu, so several
-- names can be picked in one go with the shared dropdown.
ShowThreatFilterDropdown = function(inst)
    local f = inst.frame
    local names = (CL.Threat and CL.Threat.GetRosterNames and CL.Threat.GetRosterNames()) or {}
    local options = {}

    if table.getn(names) == 0 then
        table.insert(options, { label = "No group members found", onClick = function() end })
    else
        local i
        for i = 1, table.getn(names) do
            local name = names[i]
            local included = f.threatFilter[name]
            table.insert(options, {
                label = (included and "|cff33ff33[x]|r " or "|cff888888[ ]|r ") .. name,
                onClick = function()
                    if included then
                        f.threatFilter[name] = nil
                    else
                        f.threatFilter[name] = true
                    end
                    CL.SaveWindowState(inst.id, f.mode, f.segment, f.threatFilter)
                    RefreshInstance(inst)
                    ShowThreatFilterDropdown(inst)
                end,
            })
        end
        table.insert(options, { label = "|cffff5555Clear Filter (show everyone)|r", onClick = function()
            f.threatFilter = {}
            CL.SaveWindowState(inst.id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
    end

    CL.ShowDropdown(f.segBtn, options)
end

local function NewInstance(id, opts)
    opts = opts or {}
    local inst = {
        id = id,
        frame = nil,
        bars = {},
        lastShownCount = -1,
        defaultMode = opts.defaultMode,
        defaultSegment = opts.defaultSegment,
    }
    instances[id] = inst
    table.insert(instanceOrder, id)
    return inst
end

local function ShowInstance(inst)
    if not inst.frame then CreateWindowFrame(inst) end
    inst.frame:Show()
    RefreshInstance(inst)
end

-- Opens a saved encounter (from History.lua) in the same bar-list/
-- breakdown-click UI as the live meter, rather than a chat dump - reuses
-- everything, just points GetActiveEncounter at a static snapshot
-- instead of Current/Overall.
function UI.ShowHistoryEncounterIn(inst, encounter)
    if not encounter then return end
    if not inst.frame then CreateWindowFrame(inst) end
    inst.frame.segment = "history"
    inst.frame.historyEncounter = encounter
    if inst.frame.segBtn then
        SetHeaderButtonText(inst.frame.segBtn, encounter.label or SEGMENT_LABELS.history, true)
    end
    CL.SaveWindowState(inst.id, inst.frame.mode, inst.frame.segment, inst.frame.threatFilter)
    inst.frame:Show()
    RefreshInstance(inst)
end

--------------------------------------------------------------------------
-- Extra window management (Options' "New Window" list)
--------------------------------------------------------------------------

local nextExtraNum = 2

-- id -> label shown in Options' window list
function UI.GetWindowList()
    local list = {}
    local i
    for i = 1, table.getn(instanceOrder) do
        local id = instanceOrder[i]
        local inst = instances[id]
        if inst then
            local label = (inst.frame and MODE_TITLES[inst.frame.mode]) or (inst.defaultMode and MODE_TITLES[inst.defaultMode]) or "Window"
            table.insert(list, { id = id, label = label, closable = (id ~= "main") })
        end
    end
    return list
end

function UI.CreateExtraWindow()
    local id = "window" .. nextExtraNum
    while instances[id] do
        nextExtraNum = nextExtraNum + 1
        id = "window" .. nextExtraNum
    end
    nextExtraNum = nextExtraNum + 1
    local inst = NewInstance(id)
    CL.SaveWindowState(id, inst.defaultMode or "damage", inst.defaultSegment or "current")
    ShowInstance(inst)
    return id
end

function UI.CloseExtraWindow(id)
    if id == "main" then return end
    local inst = instances[id]
    if not inst then return end
    if inst.frame then inst.frame:Hide() end
    instances[id] = nil
    local i
    for i = 1, table.getn(instanceOrder) do
        if instanceOrder[i] == id then
            table.remove(instanceOrder, i)
            break
        end
    end
    CL.ForgetWindowState(id)
end

local function IsGrouped()
    return ((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0
        or ((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0
end

-- Whether window `id`'s Auto-hide / Grouped-only rules forbid showing it
-- right now (live combat and group state). Both rules apply together:
-- clearing one doesn't show the window if the other still forbids it.
function UI.IsSuppressedNow(id)
    local onlyGrouped = CL.GetWindowOption(id, "onlyShowGrouped", false)
    if onlyGrouped and not IsGrouped() then return true end
    local autoHide = CL.GetWindowOption(id, "autoHideOutOfCombat", false)
    if autoHide and not UnitAffectingCombat("player") then return true end
    return false
end

-- Recreates every remembered window at login/reload, shown or hidden
-- per its Auto-hide/Grouped-only rules so nothing flashes up that
-- shouldn't be there. Auto-show isn't consulted: it reacts to combat
-- starting, not to a window's resting state.
function UI.RestoreAllWindows()
    local function RestoreOne(id, inst)
        if UI.IsSuppressedNow(id) then
            CreateWindowFrame(inst)
            inst.frame:Hide()
        else
            ShowInstance(inst)
        end
    end

    RestoreOne("main", instances["main"])

    local ids = CL.GetExtraWindowIds()
    local i
    for i = 1, table.getn(ids) do
        local id = ids[i]
        if id ~= "main" and not instances[id] then
            RestoreOne(id, NewInstance(id))
        end
    end
end

--------------------------------------------------------------------------
-- Main instance - the public CL.UI surface everything else (Events.lua,
-- the minimap button, /cl commands, UI_BreakdownWindow's fallback) uses.
--------------------------------------------------------------------------

local mainInst = NewInstance("main")

-- Show/Hide/Toggle act on every meter window (minimap click, /cl
-- toggle, keybind). Toggle decides on/off from the main window's state.
-- Show skips windows whose own rules forbid them right now
-- (UI.IsSuppressedNow).
function UI.Show()
    local id, inst
    for id, inst in pairs(instances) do
        if not UI.IsSuppressedNow(id) then
            ShowInstance(inst)
        end
    end
end

function UI.Hide()
    local id, inst
    for id, inst in pairs(instances) do
        if inst.frame then inst.frame:Hide() end
    end
end

function UI.Toggle()
    if mainInst.frame and mainInst.frame:IsShown() then
        UI.Hide()
    else
        UI.Show()
    end
end

-- One-time copy of Main's size/position onto window `id` (not a lasting
-- link): Main's layout is saved under `id`, then applied if it's open.
function UI.MirrorMainLayout(id)
    if id == "main" or not mainInst.frame then return end
    CL.SaveLayout(id, mainInst.frame)
    local inst = instances[id]
    if inst and inst.frame then
        CL.ApplyLayout(id, inst.frame, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)
    end
end

-- Shows one specific window by id, creating its frame if needed (same
-- lazy-create as ShowInstance) - used by Options' per-window Hide/
-- Grouped checkboxes to reveal a window immediately when a restriction
-- is unchecked, without having to wait for (or fake) a combat/group
-- transition event.
function UI.ShowWindowById(id)
    local inst = instances[id]
    if inst then ShowInstance(inst) end
end

-- Called on PLAYER_REGEN_DISABLED (combat start) - shows every window
-- with its own "Auto-show on combat start" option on. A window that
-- also has "Only show while grouped" on is skipped here if you're not
-- currently grouped (e.g. a Threat meter that should only ever appear
-- for a real pull, not solo combat).
function UI.ApplyAutoShow()
    local id, inst
    for id, inst in pairs(instances) do
        if CL.GetWindowOption(id, "autoShowInCombat", true) then
            if not CL.GetWindowOption(id, "onlyShowGrouped", false) or IsGrouped() then
                ShowInstance(inst)
            end
        end
    end
end

-- Called (only while out of combat - see Events.lua's own guard) to
-- hide every window with its own "Auto-hide out of combat" option on.
function UI.ApplyAutoHide()
    local id, inst
    for id, inst in pairs(instances) do
        if CL.GetWindowOption(id, "autoHideOutOfCombat", false) and inst.frame then
            inst.frame:Hide()
        end
    end
end

-- Per-window "In combat" mode (window option combatMode, "" = off): on
-- combat start a window switches to it, remembering its own mode; when
-- the fight ends it switches back, unless the mode was changed by hand
-- in between.
function UI.ApplyCombatModes(inCombat)
    local id, inst
    for id, inst in pairs(instances) do
        local f = inst.frame
        if f and f.SetMode then
            if inCombat then
                local combatMode = CL.GetWindowOption(id, "combatMode", "")
                if combatMode ~= "" and combatMode ~= f.mode then
                    inst.restoreMode = f.mode
                    f.SetMode(combatMode, false)
                end
            elseif inst.restoreMode then
                local mode = inst.restoreMode
                inst.restoreMode = nil
                f.SetMode(mode, false)
            end
        end
    end
end

-- Mode keys and titles in menu order, for Options.
function UI.GetModeChoices()
    local list = {}
    local i
    for i = 1, table.getn(MODE_ORDER) do
        table.insert(list, { key = MODE_ORDER[i], label = MODE_TITLES[MODE_ORDER[i]] })
    end
    return list
end

-- On roster changes: "Only show while grouped" windows hide when you
-- leave a group and reappear when you join one, unless their other rules
-- (UI.IsSuppressedNow) still forbid it.
function UI.ReconcileGroupVisibility()
    local id, inst
    for id, inst in pairs(instances) do
        if CL.GetWindowOption(id, "onlyShowGrouped", false) then
            if not IsGrouped() then
                if inst.frame then inst.frame:Hide() end
            elseif CL.GetWindowOption(id, "autoShowInCombat", true) and not UI.IsSuppressedNow(id) then
                ShowInstance(inst)
            end
        end
    end
end

function UI.Refresh()
    RefreshInstance(mainInst)
end

-- Every open window (main + any "+ New Window" extras) at once - used
-- where a change isn't scoped to just the main window, e.g. clearing
-- Overall from the join-party prompt below.
function UI.RefreshAllInstances()
    for _, inst in pairs(instances) do
        RefreshInstance(inst)
    end
end

-- Called by Threat.lua the moment a fresh threat packet arrives, so
-- threat bars update immediately instead of waiting for the next
-- throttled tick - every other mode's data only changes on our own
-- event pipeline (already inside the same throttled refresh loop), but
-- threat is a live server push on its own ~0.5s cadence.
function UI.RefreshMode(mode)
    local id, inst
    for id, inst in pairs(instances) do
        if inst.frame and inst.frame.mode == mode then
            RefreshInstance(inst)
        end
    end
end

-- Whether any shown window is in `mode` (Threat.lua only polls the
-- server while Threat mode is visible).
function UI.IsModeVisible(mode)
    local id, inst
    for id, inst in pairs(instances) do
        if inst.frame and inst.frame.mode == mode and inst.frame:IsShown() then
            return true
        end
    end
    return false
end

function UI.GetActiveModeSegment()
    if not mainInst.frame then return "damage", "current" end
    return mainInst.frame.mode, mainInst.frame.segment
end

function UI.GetActiveEncounter()
    return GetActiveEncounter(mainInst)
end

function UI.ShowHistoryEncounter(encounter)
    UI.ShowHistoryEncounterIn(mainInst, encounter)
end

-- Refresh loop for every shown window. Bar smoothing runs every frame so
-- bars glide to their new values; redraws run at most every
-- REFRESH_INTERVAL and only when something could have changed.
local driver = CreateFrame("Frame")
local accum = 0
local function DriverTick()
    local id, inst
    for id, inst in pairs(instances) do
        local window = inst.frame
        if window and window:IsShown() and CL.IsSmoothBars() then
            local speed = CL.GetBarSpeed() -- 1 (slow) - 10 (near-instant)
            local rate = speed * 1.6 * arg1
            if rate > 1 then rate = 1 end
            local i
            for i = 1, table.getn(inst.bars) do
                local bar = inst.bars[i]
                if bar:IsShown() and bar.targetPct then
                    local cur = bar:GetValue()
                    local target = bar.targetPct
                    if math.abs(target - cur) < 0.002 then
                        bar:SetValue(target)
                    else
                        bar:SetValue(cur + (target - cur) * rate)
                    end
                end
            end
        end
    end

    accum = accum + arg1
    if accum < REFRESH_INTERVAL then return end
    accum = 0
    local now = GetTime()
    local version = CL.Aggregator.GetDataVersion()
    local live = CL.Aggregator.GetCurrent() ~= nil
    for id, inst in pairs(instances) do
        local window = inst.frame
        if window and window:IsShown() then
            -- Redraw only when something could have changed: new data,
            -- or a live fight on a Current/Overall view (the rate column
            -- divides by a duration that keeps growing with no new
            -- events). Threat mode redraws itself when a snapshot lands
            -- (UI.RefreshMode). IDLE_REFRESH_SECONDS is a slow safety net
            -- for anything that changes without going through either
            -- (a late-resolving name, etc).
            local timeDriven = live and window.mode ~= "threat" and window.segment ~= "history"
            if inst.drawnVersion ~= version or timeDriven
                or not inst.drawnAt or (now - inst.drawnAt) >= IDLE_REFRESH_SECONDS then
                RefreshInstance(inst)
            end
        end
    end
end
driver:SetScript("OnUpdate", function()
    local ok, err = pcall(DriverTick)
    if not ok then CL.RecordError("UI:refresh", err) end
end)

-- Manual reset (the R button) and the automatic reset rules
-- (Events.lua); %s is the reason or a note.
StaticPopupDialogs["COMBATLEDGER_RESET_DATA"] = {
    text = "Reset Current Fight and Overall?\n%s",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        CL.Aggregator.ResetData()
        UI.RefreshAllInstances()
        CL.Print("Data reset.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

StaticPopupDialogs["COMBATLEDGER_ANNOUNCE"] = {
    text = "Post the top %d to chat?", -- %d filled in from StaticPopup_Show's text_arg1 (the announce count)
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if pendingAnnounceInst then
            AnnounceTop(pendingAnnounceInst)
            pendingAnnounceInst = nil
        end
    end,
    OnCancel = function()
        pendingAnnounceInst = nil
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

-- Windows aren't created at file load: SavedVariables (and so saved
-- layouts) aren't available until after every file has run. Events.lua
-- calls UI.RestoreAllWindows() on the first PLAYER_ENTERING_WORLD.

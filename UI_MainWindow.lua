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
local HEADER_HEIGHT = 28 -- a few extra px of breathing room below the title/button row before the first bar
local FOOTER_GAP = 12

local WINDOW_WIDTH, WINDOW_HEIGHT = 220, 260
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 160, 100
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 500, 600

local REFRESH_INTERVAL = 0.2

-- "Buffs Given" was built (same mechanism as Debuffs) but is hidden -
-- prebuffing happens out of combat, before the encounter it's for even
-- starts, so it doesn't fit this addon's per-encounter model. See
-- Aggregator.lua.
-- Threat is last, matching GreedMeter's own ordering - and unlike every
-- other mode, it isn't built from anything CombatLedger aggregates
-- itself. It's a live snapshot from this server's own threat API (see
-- Threat.lua) with no Current/Overall/History distinction, so it gets
-- its own code path through RefreshInstance/ShowBarTooltip below rather
-- than flowing through GetActiveEncounter like everything else.
local MODE_ORDER = { "damage", "healing", "taken", "cleanses", "debuffs", "deaths", "threat" }
local MODE_TITLES = { damage = "Damage Done", healing = "Healing Done", taken = "Damage Taken", cleanses = "Dispels", debuffs = "Debuffs Given", deaths = "Deaths", threat = "Threat" }
-- First-letter button labels (Damage/Deaths both start with "D", so
-- Deaths gets "Dt" to stay distinguishable) - full names still show in
-- each button's hover tooltip and the dropdown menu itself.
local MODE_BTN_LABELS = { damage = "D", healing = "H", taken = "T", cleanses = "Di", debuffs = "Db", deaths = "Dt", threat = "Th" }

-- Cleanses/Debuffs are counts, not amounts - no meaningful "rate" or
-- "crit %" the way damage/healing have, so bars/tooltips/announce show
-- a plain count for these instead.
local COUNT_ONLY_MODES = { cleanses = true, debuffs = true }
local COUNT_WORD = { cleanses = "dispel", debuffs = "debuff" }

local function CountLabel(mode, n)
    local word = COUNT_WORD[mode] or "event"
    return n .. " " .. word .. ((n == 1) and "" or "s")
end

local SEGMENT_LABELS = { current = "C", overall = "O", history = "H" }

-- Every open window, keyed by id. "main" always exists; extra windows
-- (from Options' "New Window" button) get ids like "window2", "window3",
-- ... CL.UIWindows exposes this to UI_Options.lua for the window list.
local instances = {}
local instanceOrder = {}
CL.UIWindows = instances

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

local function BuildSortedList(units, mode)
    local list = {}
    local guid, u
    for guid, u in pairs(units) do
        local val = MetricTotal(u, mode)
        if val > 0 then
            table.insert(list, { guid = guid, name = u.name, classToken = u.classToken, total = val })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- Threat mode's own list builder - CL.Threat.GetSnapshot() is already a
-- flat [guid]={name,threat,perc,melee,tank} table refreshed live by the
-- server (see Threat.lua), not something built up from recorded events
-- the way every other mode's list is, so this doesn't go through
-- MetricTotal/units at all. classToken comes from GuidCache since threat
-- entries are always real roster members (a real guid, not a synthetic
-- one) whenever the roster scan managed to resolve them. `filterSet`
-- ([name]=true) narrows the list to just those names - see
-- ShowThreatFilterDropdown; nil/empty shows everyone.
-- Second return value is the "Pull Aggro At" reference row (mirrors
-- TWThreat's own calcAGROPerc) - not a real player, so it's kept
-- separate from the sorted list rather than mixed in, letting
-- RefreshInstance compute bar-width scaling from real entries only
-- before pinning this to the top. Vanilla's threat-override rule: a
-- non-tank needs more than 130% of the tank's threat to pull aggro at
-- range, 110% in melee - the value shown is how much MORE threat you
-- specifically still need, not the raw threshold.
local function BuildThreatList(filterSet)
    local list = {}
    local snapshot = CL.Threat and CL.Threat.GetSnapshot()
    if not snapshot then return list, nil end
    local hasFilter = filterSet and next(filterSet) ~= nil
    local playerName = UnitName("player")
    local tankThreat, playerMelee
    local guid, t
    for guid, t in pairs(snapshot) do
        if not hasFilter or filterSet[t.name] then
            local info = CL.GuidCache and CL.GuidCache.Resolve(guid)
            table.insert(list, {
                guid = guid,
                name = t.name,
                classToken = info and info.classToken,
                total = t.threat,
                perc = t.perc,
                melee = t.melee,
                tank = t.tank,
            })
        end
        if t.tank then tankThreat = t.threat end
        if t.name == playerName then playerMelee = t.melee end
    end
    table.sort(list, function(a, b) return a.total > b.total end)

    local marker = nil
    if tankThreat and tankThreat > 0 then
        local threshold = tankThreat * (playerMelee and 1.1 or 1.3)
        marker = {
            guid = "THREAT_AGRO_MARKER",
            name = "Pull Aggro At",
            total = threshold - tankThreat,
            isAgroMarker = true,
        }
    end

    return list, marker
end

-- Same list either mode uses: melee + petMelee + each spell, sorted
-- descending. Reused by the hover tooltip below (GreedMeter shows this
-- exact "By spell" breakdown on mouseover rather than requiring a click).
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
        table.insert(list, { name = t.name, total = t.total })
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

    if mode == "damage" or mode == "taken" then
        local bucket = (mode == "taken") and u.damageTaken or u.damageDone
        if bucket then
            local sum = { miss = 0, dodge = 0, parry = 0, block = 0, evade = 0, immune = 0, deflect = 0, other = 0 }
            local hits = 0
            local entry
            for _, entry in ipairs({ bucket.melee, bucket.offhand, bucket.petMelee, bucket.petOffhand }) do
                if entry then
                    hits = hits + (entry.hits or 0)
                    if entry.avoided then
                        local k, v
                        for k, v in pairs(entry.avoided) do
                            sum[k] = (sum[k] or 0) + v
                        end
                    end
                end
            end
            local avoided = sum.miss + sum.dodge + sum.parry + sum.block + sum.evade + sum.immune + sum.deflect + sum.other
            local swings = hits + avoided
            if swings > 0 then
                local parts = {}
                if sum.dodge > 0 then table.insert(parts, sum.dodge .. " dodge") end
                if sum.parry > 0 then table.insert(parts, sum.parry .. " parry") end
                if sum.miss > 0 then table.insert(parts, sum.miss .. " miss") end
                if sum.block > 0 then table.insert(parts, sum.block .. " block") end
                if sum.evade > 0 then table.insert(parts, sum.evade .. " evade") end
                if sum.immune > 0 then table.insert(parts, sum.immune .. " immune") end
                if sum.deflect > 0 then table.insert(parts, sum.deflect .. " deflect") end
                if sum.other > 0 then table.insert(parts, sum.other .. " other") end
                local label = (mode == "taken") and "Avoided" or "Swings missed"
                GameTooltip:AddDoubleLine(label,
                    string.format("%d/%d (%.0f%%)", avoided, swings, (avoided / swings) * 100), 1, 1, 1, 1, 1, 1)
                if table.getn(parts) > 0 then
                    GameTooltip:AddLine(table.concat(parts, ", "), 0.7, 0.7, 0.7)
                end
            end
        end
    end

    do
        local targets = BuildTargetSummary(u, mode)
        if table.getn(targets) > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("By target:", 1, 0.82, 0)
            local i
            for i = 1, table.getn(targets) do
                GameTooltip:AddDoubleLine(targets[i].name, FormatNumber(targets[i].total), 0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
    end

    local spells = BuildSpellSummary(u, mode)
    if table.getn(spells) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("By spell:", 1, 0.82, 0)
        local i
        for i = 1, table.getn(spells) do
            local pct = (total > 0) and (spells[i].total / total * 100) or 0
            GameTooltip:AddDoubleLine(spells[i].name,
                FormatNumber(spells[i].total) .. " (" .. string.format("%.1f", pct) .. "%)", 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end

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

    -- Class icon slot - off by default (Options: "Show class icon"),
    -- hidden and unanchored until RefreshInstance decides per-refresh
    -- whether to show it. When it's off, nameText sits exactly where it
    -- always has (bar:LEFT+4) - no permanently-reserved gap for people
    -- who never turn this on.
    local classIcon = bar:CreateTexture(nil, "OVERLAY")
    classIcon:SetWidth(height - 4)
    classIcon:SetHeight(height - 4)
    classIcon:SetPoint("LEFT", bar, "LEFT", 3, 0)
    classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circle")
    classIcon:Hide()
    bar.classIcon = classIcon

    local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    valueText:SetText("")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    -- LEFT anchor is re-set every refresh (see RefreshInstance) based on
    -- whether the class icon is actually showing for this entry - starts
    -- at the same bar:LEFT+4 as always here. RIGHT is bounded to
    -- valueText (was unbounded) - an unbounded name could run straight
    -- into it once both were long enough. Created after valueText so it
    -- can anchor off it.
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

-- How far the bar list can actually scroll. Deliberately NOT
-- barScroll:GetVerticalScrollRange() - that depends on the ScrollFrame's
-- own anchor-derived height, and this client doesn't reliably keep that
-- current (same class of geometry staleness as the breakdown window's
-- target-list layout, which works around it the same way: compute from
-- window:GetHeight(), a value that's directly SetHeight'd rather than
-- anchor-derived, instead of trusting a read-back that may be stale).
local function GetMaxBarScroll(window)
    local viewportHeight = window:GetHeight() - HEADER_HEIGHT - FooterGap()
    local maxScroll = window.barParent:GetHeight() - viewportHeight
    if maxScroll < 0 then maxScroll = 0 end
    return maxScroll
end

local RefreshInstance -- forward-declared, assigned below
local ShowThreatFilterDropdown -- forward-declared, assigned below

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
            CL.ApplyButtonSkin(window.optionsBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.announceBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.segBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.modeBtn, themeR, themeG, themeB)
            CL.ApplyFont(window.title)
            CL.ApplyFont(window.resetBtn.label)
            CL.ApplyFont(window.optionsBtn.label)
            CL.ApplyFont(window.announceBtn.label)
            CL.ApplyFont(window.segBtn.label)
            CL.ApplyFont(window.modeBtn.label)
            CL.RepositionBarPool(inst.bars, CL.GetBarHeight(BAR_HEIGHT), BAR_GAP)
            local i
            for i = 1, table.getn(inst.bars) do
                local bar = inst.bars[i]
                bar:SetStatusBarTexture(CL.GetBarTexture())
                bar.bg:SetTexture(CL.GetBarTexture())
                CL.ApplyFont(bar.nameText, CL.GetFontSize())
                CL.ApplyFont(bar.valueText, CL.GetFontSize())
            end
            RefreshInstance(inst)
        end
    end
    if dropdownFrame then
        for i = 1, table.getn(dropdownFrame.rows) do
            CL.ApplyFont(dropdownFrame.rows[i].text)
        end
    end
end
CL.OnAppearanceChanged(RestyleAll)

local function CreateHeaderButton(parent, width, initialText)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(width)
    btn:SetHeight(16)
    -- Flat WHITE8X8 shape, matching the window's own backdrop (see
    -- CL.WINDOW_BACKDROP) - used to be Blizzard's rounded Tooltip
    -- border, which stayed even after ApplyButtonSkin started recoloring
    -- the border to the new near-black flat color, since ApplyButtonSkin
    -- only ever recolors whatever backdrop shape was already set here -
    -- it never looked right mixed with the flat window frame around it.
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

    -- Click feedback (darkens briefly on press) - a plain backdrop box
    -- otherwise gives zero visual response to a click, part of why it
    -- reads as "off" without pfUI's own button skin doing this for us.
    btn:SetScript("OnMouseDown", function()
        btn:SetBackdropColor(0.05, 0.05, 0.06, 0.9)
    end)
    btn:SetScript("OnMouseUp", function()
        btn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
    end)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(btn)
    label:SetJustifyH("CENTER")
    label:SetText(initialText or "")
    CL.ApplyFont(label)
    btn.label = label
    return btn
end

-- restR/G/B (optional) is the button's normal border color - if given,
-- hovering brightens the border to white and leaving restores it,
-- independent of pfUI's own skin-time highlight hook (which stacks via
-- HookScript and can leave a button with no visible hover feedback once
-- enough buttons chain together - simpler to just own this ourselves
-- than rely on pfUI's hook order).
local function SetButtonTooltip(btn, title, subtitle, restR, restG, restB)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title, 1, 1, 1)
        if subtitle then
            GameTooltip:AddLine(subtitle, 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
        -- Skipped while matching pfUI - pfUI's own hover highlight
        -- (from SkinButton) owns the border then, not this.
        if restR and not CL.IsMatchPfui() then btn:SetBackdropBorderColor(1, 1, 1, 1) end
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        -- Restores to the flat near-black border (matching
        -- CL.ApplyButtonSkin's own manual-skin color), not the passed-in
        -- restR/G/B theme color - those are still accepted for callers
        -- that haven't been updated, but the flat skin no longer uses
        -- theme-colored chrome, so restoring to it here left the border
        -- stuck class-colored after the first hover once ApplyButtonSkin
        -- switched away from it.
        if restR and not CL.IsMatchPfui() then btn:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1) end
    end)
end

-- Posts this window's current mode/segment's top N (Options: Announce
-- Count) to the configured chat channel - one line per rank plus a
-- header, same shape GreedMeter's own announce button produces.
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
    f:SetFrameStrata("TOOLTIP") -- highest strata - a live meter shouldn't be able to end up hidden behind something else
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

    -- Deliberately NOT registered in UISpecialFrames - this is a live
    -- meter meant to stay up throughout a session, not a dialog that
    -- should vanish on a stray Escape (easy to hit by accident while
    -- canceling a cast, closing another window, etc). Only /cl hide,
    -- /cl toggle, and (for extra windows) the close button hide it.
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cff" .. themeHex .. MODE_TITLES[f.mode] .. "|r")
    CL.ApplyFont(title)
    f.title = title

    -- Forward-declared - assigned once announceBtn/modeBtn exist below,
    -- referenced by both the resize grip's OnUpdate further down and
    -- the mode-dropdown's onClick above the assignment point (both are
    -- closures that only run later, so the upvalue just needs to exist
    -- here, not be assigned yet).
    local UpdateTitleVisibility

    -- Second header row: Reset (left) ... Mode | Segment (right, click-
    -- to-cycle). Compact single-letter labels - full names are still in
    -- each button's hover tooltip and in the dropdown menu itself.
    local resetBtn = CreateHeaderButton(f, 18, "R")
    resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("COMBATLEDGER_RESET_OVERALL")
    end)
    SetButtonTooltip(resetBtn, "Reset", "Clear the Overall segment", themeR, themeG, themeB)
    CL.ApplyButtonSkin(resetBtn, themeR, themeG, themeB)
    f.resetBtn = resetBtn

    local optionsBtn = CreateHeaderButton(f, 18, "O")
    optionsBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
    optionsBtn:SetScript("OnClick", function()
        if CL.UIOptions then CL.UIOptions.Toggle() end
    end)
    SetButtonTooltip(optionsBtn, "Options", "Lock window, minimap button, timing settings", themeR, themeG, themeB)
    CL.ApplyButtonSkin(optionsBtn, themeR, themeG, themeB)
    f.optionsBtn = optionsBtn

    local announceBtn = CreateHeaderButton(f, 18, "!")
    announceBtn:SetPoint("LEFT", optionsBtn, "RIGHT", 4, 0)
    announceBtn:SetScript("OnClick", function()
        AnnounceTop(inst)
    end)
    SetButtonTooltip(announceBtn, "Announce", "Post the top " .. (CL.GetSetting("announceCount") or 5) ..
        " to chat (channel/count set in Options)", themeR, themeG, themeB)
    CL.ApplyButtonSkin(announceBtn, themeR, themeG, themeB)
    f.announceBtn = announceBtn

    -- Extra (non-main) windows get a close button - main only ever
    -- hides via /cl hide / /cl toggle, matching its original behavior.
    -- Created before segBtn/modeBtn so they can anchor off it (avoids
    -- the segment button sitting underneath it in the same corner).
    local closeBtn = nil
    if id ~= "main" then
        closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetWidth(18)
        closeBtn:SetHeight(18)
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        closeBtn:SetScript("OnClick", function()
            UI.CloseExtraWindow(id)
        end)
        f.closeBtn = closeBtn
        if pfUI and pfUI.api then
            pcall(pfUI.api.SkinCloseButton, closeBtn)
        end
    end

    local segBtn = CreateHeaderButton(f, 20, (f.mode == "threat") and "F" or SEGMENT_LABELS[f.segment])
    if closeBtn then
        segBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, 0)
    else
        segBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    end

    -- Threat has no Current/Overall/History (see Threat.lua) - this
    -- button becomes a name filter for it instead ("F"), same slot,
    -- different job. Called once at creation (a window can be created
    -- already in Threat mode, from a saved window state) and again on
    -- every mode switch.
    local function UpdateSegButtonForMode()
        if f.mode == "threat" then
            segBtn.label:SetText("F")
            SetButtonTooltip(segBtn, "Filter", "Choose which raid/party members show up in Threat mode", themeR, themeG, themeB)
        else
            segBtn.label:SetText(SEGMENT_LABELS[f.segment])
            SetButtonTooltip(segBtn, "Segment", "Current Fight / Overall / a recent saved encounter", themeR, themeG, themeB)
        end
    end

    segBtn:SetScript("OnClick", function()
        if f.mode == "threat" then
            ShowThreatFilterDropdown(inst)
            return
        end
        local options = {}
        local classColor = PlayerClassColorTable()
        table.insert(options, { label = "Overall", color = classColor, onClick = function()
            f.segment = "overall"
            segBtn.label:SetText(SEGMENT_LABELS.overall)
            CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
        table.insert(options, { label = "Current", color = classColor, onClick = function()
            f.segment = "current"
            segBtn.label:SetText(SEGMENT_LABELS.current)
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

    local modeBtn = CreateHeaderButton(f, 20, MODE_BTN_LABELS[f.mode])
    modeBtn:SetPoint("RIGHT", segBtn, "LEFT", -4, 0)
    modeBtn:SetScript("OnClick", function()
        local options = {}
        local i
        for i = 1, table.getn(MODE_ORDER) do
            local key = MODE_ORDER[i]
            table.insert(options, { label = MODE_TITLES[key] or key, onClick = function()
                f.mode = key
                modeBtn.label:SetText(MODE_BTN_LABELS[key] or key)
                f.title:SetText("|cff" .. themeHex .. MODE_TITLES[key] .. "|r")
                UpdateTitleVisibility()
                UpdateSegButtonForMode()
                CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
                RefreshInstance(inst)
            end })
        end
        CL.ShowDropdown(modeBtn, options)
    end)
    SetButtonTooltip(modeBtn, "Mode", "Damage Done / Healing Done / Damage Taken / Deaths / Threat", themeR, themeG, themeB)
    CL.ApplyButtonSkin(modeBtn, themeR, themeG, themeB)
    f.modeBtn = modeBtn

    -- The title sits centered on the SAME row as the header buttons
    -- (see resetBtn/segBtn above) - fine at normal widths where there's
    -- clear space between the two button clusters, but at a narrow
    -- resize the title's actual rendered text can be wider than that
    -- gap and overlaps the buttons into an unreadable mess. Measuring
    -- the real gap (announceBtn's right edge to modeBtn's left edge)
    -- against the title's actual string width - not a fixed width
    -- threshold - means a short title like "Deaths" stays visible
    -- longer than "Debuffs Given" would, instead of both hiding at the
    -- same arbitrary cutoff.
    UpdateTitleVisibility = function()
        local gap = modeBtn:GetLeft() - announceBtn:GetRight()
        if gap < title:GetStringWidth() + 6 then
            title:Hide()
        else
            title:Show()
        end
    end
    UpdateTitleVisibility()

    -- A real ScrollFrame (not a whole-row index shift like the History
    -- window) so a bar that only partially fits the remaining space
    -- renders cut off right at the edge instead of being hidden
    -- entirely or leaving blank space below the last whole one - scroll
    -- wheel moves through the rest via SetVerticalScroll.
    local barScroll = CreateFrame("ScrollFrame", nil, f)
    barScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    barScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FooterGap())
    f.barScroll = barScroll

    -- SetScrollChild manages the child's own position internally - it
    -- must NOT be anchored with SetPoint beforehand (that left it
    -- effectively unpositioned/invisible, taking every bar with it).
    -- Width has to be tracked explicitly instead (kept in sync on
    -- resize, see the grip's OnUpdate and RestyleAll above) since a
    -- ScrollFrame's own GetWidth() is anchor-derived and not reliably
    -- readable right after a size change on this client.
    local barParent = CreateFrame("Frame", nil, barScroll)
    barParent:SetWidth(f:GetWidth() - 12)
    barParent:SetHeight(MAX_BARS * (CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP))
    f.barParent = barParent
    barScroll:SetScrollChild(barParent)

    barScroll:EnableMouseWheel(true)
    barScroll:SetScript("OnMouseWheel", function()
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

    -- Bottom-right resize grip, same tinted-square approach as
    -- LootLedger's (Blizzard's chat-frame resize texture doesn't render
    -- on this client).
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
        UpdateTitleVisibility()
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

    if isThreat then
        list, threatMarker = BuildThreatList(window.threatFilter)
    else
        enc = GetActiveEncounter(inst)
        local units = enc and enc.units or {}
        list = BuildSortedList(units, window.mode)

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

    -- Pinned to the very top regardless of sort order - it's a
    -- reference line, not a real threat total, so it never competes for
    -- the #1 spot on its own (tiny) value.
    if threatMarker then
        table.insert(list, 1, threatMarker)
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
            if not CL.IsSmoothBars() then
                bar:SetValue(pct)
            end
            if entry.isAgroMarker then
                bar:SetStatusBarColor(0.75, 0.1, 0.1, 0.9)
                bar.nameText:SetText(entry.name)
                bar.valueText:SetText("+" .. FormatNumber(entry.total))
            elseif isThreat then
                rank = rank + 1
                local r, g, b = ClassColor(entry.classToken)
                bar:SetStatusBarColor(r, g, b, 0.9)
                bar.nameText:SetText(rank .. ". " .. (entry.tank and "|cffFFD100[T]|r " or "") .. entry.name)
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

            -- Class icon - opt-in (Options: "Show class icon"), and
            -- only for entries that resolved a real class (not the
            -- aggro-marker reference row, and not mobs/unresolved
            -- units, which have no classToken at all). SetPoint on the
            -- same anchor point ("LEFT") replaces the previous one, so
            -- this doesn't need a ClearAllPoints first.
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

    -- Scroll child's height tracks how many entries are actually shown,
    -- not the full MAX_BARS pool - otherwise the scroll range extends
    -- into empty unused pool space past the real last bar. Only touched
    -- when the count actually changes, not every 0.2s refresh - this
    -- client doesn't reliably keep a ScrollFrame's scroll range usable
    -- under constant SetHeight churn on its scroll child (same class of
    -- geometry-staleness issue documented elsewhere in this addon).
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

-- Threat mode's stand-in for the segment button (see UpdateSegButtonFor
-- Mode in CreateWindowFrame) - a toggle list of every known raid/party
-- name instead of Current/Overall/History. Reuses the same shared
-- ShowDropdown/dropdownFrame as everything else; each row's onClick
-- toggles that name and re-opens itself immediately after ShowDropdown
-- closes it, which reads as a dropdown that "stays open" for picking
-- several names in one go without actually needing a second dropdown
-- implementation that behaves differently from every other menu here.
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
    if inst.frame.segBtn and inst.frame.segBtn.label then
        inst.frame.segBtn.label:SetText(SEGMENT_LABELS.history)
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

-- Recreates every extra window remembered from a previous session (main
-- is handled separately by UI.Show, see Events.lua). Safe to call once,
-- after the real SavedVariables are restored.
function UI.RestoreExtraWindows()
    local ids = CL.GetExtraWindowIds()
    local i
    for i = 1, table.getn(ids) do
        local id = ids[i]
        if id ~= "main" and not instances[id] then
            local inst = NewInstance(id)
            ShowInstance(inst)
        end
    end
end

--------------------------------------------------------------------------
-- Main instance - the public CL.UI surface everything else (Events.lua,
-- the minimap button, /cl commands, UI_BreakdownWindow's fallback) uses.
--------------------------------------------------------------------------

local mainInst = NewInstance("main")

function UI.Show()
    ShowInstance(mainInst)
end

function UI.Hide()
    if mainInst.frame then mainInst.frame:Hide() end
end

function UI.Toggle()
    if mainInst.frame and mainInst.frame:IsShown() then
        UI.Hide()
    else
        UI.Show()
    end
end

function UI.Refresh()
    RefreshInstance(mainInst)
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

-- Threat.lua polls the server on its own timer only while this is true,
-- rather than unconditionally every 0.5s regardless of whether anyone's
-- actually looking at Threat mode - same reasoning TWThreat's own
-- update loop uses (it only queries while at least one of its display
-- features is actually enabled).
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

-- Throttled refresh loop for every open window - only does work while a
-- window is actually shown (RefreshInstance bails immediately
-- otherwise). Bar-value smoothing runs every frame, separately from the
-- throttle, so bars glide toward their new value instead of jumping -
-- like Details' animated bars - rather than only updating in
-- REFRESH_INTERVAL-sized steps.
local driver = CreateFrame("Frame")
local accum = 0
driver:SetScript("OnUpdate", function()
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
    for id, inst in pairs(instances) do
        RefreshInstance(inst)
    end
end)

StaticPopupDialogs["COMBATLEDGER_RESET_OVERALL"] = {
    text = "Clear the Overall segment? Current Fight and saved History aren't affected.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        CL.Aggregator.ResetOverall()
        for _, inst in pairs(instances) do
            RefreshInstance(inst)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

-- NOT called here at file-load time - this client restores the real
-- CombatLedgerDB from disk AFTER all files finish executing, so
-- CreateWindowFrame's CL.ApplyLayout would always read an empty
-- placeholder and silently never restore the saved size/position (every
-- reload, not just occasionally). Events.lua's first PLAYER_ENTERING_WORLD
-- calls UI.Show() (and UI.RestoreExtraWindows()) instead, once the real
-- saved data is actually there.

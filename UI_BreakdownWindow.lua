--[[
    UI_BreakdownWindow - "Player Details" layout. Click a bar on
    the main meter to open this: a per-ability list + a permanent Targets
    section on the left, and a persistent detail panel on the right for
    whatever ability is selected (click, not hover - a real panel beats a
    tooltip that vanishes the moment you look away). Same pooled-row/
    window-chrome approach as UI_MainWindow.lua, not shared code.
]]

local CL = CombatLedger
local BD = {}
CL.UIBreakdown = BD

local MAX_BARS = 20
local BAR_HEIGHT = 16
local BAR_GAP = 2
local HEADER_HEIGHT = 26
local FOOTER_GAP = 12

local MAX_TARGET_BARS = 6
local TARGET_BAR_HEIGHT = 14
local TARGET_BAR_GAP = 1
local TARGETS_LABEL_HEIGHT = 14

-- Height needed to show `count` target rows (0 if none) - the Targets
-- area is sized to what's actually there each refresh, not a fixed
-- reservation for the full MAX_TARGET_BARS pool, so it doesn't eat into
-- the ability list's space at a normal window size when there are only
-- one or two targets.
local function TargetsAreaHeight(count)
    if count <= 0 then return 0 end
    local h = TARGETS_LABEL_HEIGHT + count * (TARGET_BAR_HEIGHT + TARGET_BAR_GAP)
    if count > 1 then
        -- Room for the "All Enemies" reset row below the target list.
        h = h + (TARGET_BAR_HEIGHT + TARGET_BAR_GAP)
    end
    return h
end

local DETAIL_ROW_HEIGHT = 14
local MAX_DETAIL_ROWS = 14
local DETAIL_ICON_SIZE = 32 -- the "nice big" spell icon next to the selected ability's name

local WINDOW_WIDTH, WINDOW_HEIGHT = 460, 320
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 360, 240
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 700, 600

local REFRESH_INTERVAL = 0.2
local IDLE_REFRESH_SECONDS = 2 -- same redraw gating as UI_MainWindow.lua's driver
local drawnVersion, drawnAt = nil, nil -- what the last BD.Refresh reflected

-- "Buffs Given" was built (same mechanism as Debuffs) but is hidden -
-- see Aggregator.lua/UI_MainWindow's own note.
local MODE_TITLES = { damage = "Damage Done", healing = "Healing Done", taken = "Damage Taken", cleanses = "Dispels", debuffs = "Debuffs Given", deaths = "Deaths" }

-- Cleanses/Debuffs are counts, not amounts - see UI_MainWindow's own
-- copy of this set for why.
local COUNT_ONLY_MODES = { cleanses = true, debuffs = true }

-- Every mode with a per-ability breakdown also gets a per-target/
-- recipient/attacker list, same underlying mechanism (see Aggregator.lua's
-- damageDone.targets / healingDone.targets / damageTaken.targets), just
-- different wording for what the "other end" of the number represents.
local MODE_TARGET_LABEL = { damage = "Targets", healing = "Healed", taken = "Attackers", cleanses = "Dispelled", debuffs = "Given To" }
local MODE_ALL_LABEL = { damage = "All Enemies", healing = "Everyone", taken = "All Attackers", cleanses = "Everyone", debuffs = "Everyone" }

local function ModeBucket(u, mode)
    if not u then return nil end
    if mode == "healing" then return u.healingDone end
    if mode == "taken" then return u.damageTaken end
    if mode == "cleanses" then return u.cleanses end
    if mode == "debuffs" then return u.debuffsGiven end
    -- Deaths is a plain counter (u.deaths), not a spell/target bucket -
    -- deliberately no case here, since falling through to u.damageDone
    -- would show the player's own damage breakdown while labeled
    -- "Deaths".
    if mode == "deaths" then return nil end
    return u.damageDone
end

-- Cycled by row index so each spell/melee line is visually distinct -
-- unlike the main meter's bars, these aren't tied to a class color.
local ROW_COLORS = {
    { 0.95, 0.55, 0.15 },
    { 0.35, 0.75, 0.95 },
    { 0.75, 0.35, 0.95 },
    { 0.95, 0.35, 0.55 },
    { 0.45, 0.85, 0.35 },
    { 0.95, 0.85, 0.25 },
    { 0.35, 0.95, 0.85 },
    { 0.85, 0.55, 0.95 },
}

local window = nil
local bars = {}
local targetBars = {}
local detailRows = {}
local currentGuid = nil
local currentName = nil
local currentClassToken = nil
local selectedKey = nil -- stable id (see BuildSpellList) for whichever ability the detail panel shows
local selectedTargetGuid = nil -- click a target row to filter the ability list to just what hit them
local lastTargetCount = -1 -- only re-layout the left column when this actually changes (see BD.Refresh)

-- One breakdown window shared by every meter window, so it remembers
-- the mode/segment (and History encounter) it was opened from.
local currentMode = "damage"
local currentSegment = "current"
local currentHistoryEncounter = nil

-- Returns mode, segment and encounter for the breakdown. A separate
-- function so BD.Refresh stays under Lua 5.0's 32-upvalue limit.
local function ResolveActiveState()
    local enc
    if CL.testMode then
        enc = CL.Aggregator.GetTestEncounter()
    elseif currentSegment == "overall" then
        enc = CL.Aggregator.GetOverall()
    elseif currentSegment == "history" then
        enc = currentHistoryEncounter
    else
        enc = CL.Aggregator.GetCurrentDisplay()
    end
    return currentMode, currentSegment, enc
end

local function FormatNumber(n)
    return CL.FormatNumber(n)
end

-- |cffRRGGBB hex for a class token, falling back to the player's own
-- theme color for non-players (mobs, or a token we don't recognize).
local function ClassColorHex(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    local _, _, _, hex = CL.GetThemeColor()
    return hex
end

-- Takes an already-resolved bucket (u.damageDone / .healingDone /
-- .damageTaken, or - when a target is selected - that target's own
-- per-ability breakdown, which has the exact same shape) rather than
-- picking one internally, so the same function serves both the unit-
-- wide view and the "only what hit this target" filtered view.
local function BuildSpellList(bucket)
    local list = {}
    if not bucket then return list end

    -- Main-hand and off-hand share one row, but the entry keeps both so
    -- the detail panel can show their avoidance separately (different
    -- hit caps).
    -- Main-hand + off-hand mitigation merged for the combined melee row
    -- (see Aggregator.lua's ApplyMitigation) - nil if neither has any.
    local function MergeMit(a, b)
        if not a then return b end
        if not b then return a end
        local merged = {}
        local k, v
        for k, v in pairs(a) do merged[k] = v end
        for k, v in pairs(b) do merged[k] = (merged[k] or 0) + v end
        return merged
    end

    local function AddCombinedMeleeEntry(key, name, mainEntry, offEntry)
        local hits = (mainEntry and mainEntry.hits or 0) + (offEntry and offEntry.hits or 0)
        if hits <= 0 then return end
        local total = (mainEntry and mainEntry.total or 0) + (offEntry and offEntry.total or 0)
        local crits = (mainEntry and mainEntry.crits or 0) + (offEntry and offEntry.crits or 0)
        local critTotal = (mainEntry and mainEntry.critTotal or 0) + (offEntry and offEntry.critTotal or 0)
        local minVal, maxVal = nil, nil
        local i, e
        for i, e in ipairs({ mainEntry, offEntry }) do
            if e and e.min and (not minVal or e.min < minVal) then minVal = e.min end
            if e and e.max and (not maxVal or e.max > maxVal) then maxVal = e.max end
        end
        table.insert(list, {
            key = key,
            name = name,
            hits = hits,
            crits = crits,
            total = total,
            critTotal = critTotal,
            min = minVal,
            max = maxVal,
            mainHand = mainEntry,
            offHand = offEntry,
            isMelee = true,
            mit = MergeMit(mainEntry and mainEntry.mit, offEntry and offEntry.mit),
        })
    end
    AddCombinedMeleeEntry("melee", "Auto Attack", bucket.melee, bucket.offhand)
    AddCombinedMeleeEntry("petMelee", "Pet Auto Attack", bucket.petMelee, bucket.petOffhand)

    if bucket.spells then
        local spellId, s
        for spellId, s in pairs(bucket.spells) do
            table.insert(list, {
                key = "spell:" .. tostring(spellId),
                name = s.name or ("Spell " .. tostring(spellId)),
                hits = s.hits,
                crits = s.crits,
                total = s.total,
                critTotal = s.critTotal,
                min = s.min,
                max = s.max,
                spellId = spellId,
                -- Direct-hit-vs-DoT-tick split (see Aggregator.lua's
                -- EnsureSplitBucket / Events.lua's IsPeriodicEffect) -
                -- nil on a spell that's never had a periodic tick.
                directHits = s.directHits,
                tickHits = s.tickHits,
                -- Real cast count (see Aggregator.lua's RecordCast) -
                -- nil on a spell that never had a cast event tracked.
                casts = s.casts,
                -- Healing only (see Aggregator.lua's RecordHealHit) -
                -- total above is effective healing.
                raw = s.raw,
                critRaw = s.critRaw,
                overheal = s.overheal,
                unverified = s.unverified,
                -- SPELL_MISS_* outcomes for this spell (see Aggregator.lua's
                -- BumpSpellMiss) - kept beside, not inside, the spell entry.
                avoided = bucket.spellMisses and bucket.spellMisses[spellId],
                mit = s.mit,
            })
        end
    end

    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- The "other end" of this mode's number - who was damaged (damage),
-- who was healed (healing), or who it came from (taken). Click a row to
-- filter the ability list to just that one's own per-ability breakdown.
local function BuildTargetList(u, mode)
    local list = {}
    local bucket = ModeBucket(u, mode)
    if not bucket or not bucket.targets then return list end
    local guid, t
    for guid, t in pairs(bucket.targets) do
        -- A target that only ever missed/resisted (see Aggregator.lua's
        -- RecordSpellMissInto) has total 0 - not worth a row.
        if t.total > 0 then
            table.insert(list, { guid = guid, name = t.name, hits = t.hits, total = t.total })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

local function CreateBar(parent, index)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetStatusBarTexture(CL.GetBarTexture())
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarColor(CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B, 0.9)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(CL.GetBarTexture())
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
    bar.bg = bg

    local icon = bar:CreateTexture(nil, "OVERLAY")
    icon:SetWidth(height - 2)
    icon:SetHeight(height - 2)
    icon:SetPoint("LEFT", bar, "LEFT", 2, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- crop Blizzard's default icon border
    icon:Hide()
    bar.icon = icon

    local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    valueText:SetText("")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    -- Bounded on both sides (was LEFT-only) - an unbounded name string
    -- (e.g. "Mind Flay") ran straight into the value/stats text (e.g.
    -- "439 (4h, 0% crit)") once both were long enough. Created after
    -- valueText so it can anchor its right edge off it.
    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 3, 0)
    nameText:SetPoint("RIGHT", valueText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetText("")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    bar:EnableMouse(true)
    bar:SetScript("OnMouseUp", function()
        if bar.key then
            selectedKey = bar.key
            BD.Refresh()
        end
    end)

    bar:Hide()
    return bar
end

local function CreateTargetBar(parent, index)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(TARGET_BAR_HEIGHT)
    -- Position is set each refresh (see BD.Refresh) rather than fixed
    -- here, since the "All Enemies" row bumps every target down one
    -- slot whenever it's shown.

    local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
    valueText:SetJustifyH("RIGHT")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    -- Bounded on both sides (was LEFT-only) - see CreateBar's nameText
    -- for why. Created after valueText so it can anchor off it.
    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", bar, "LEFT", 2, 0)
    nameText:SetPoint("RIGHT", valueText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    bar:EnableMouse(true)
    bar:SetScript("OnMouseUp", function()
        if not bar.guid then return end
        -- Click again to clear the filter and go back to the unit-wide view.
        selectedTargetGuid = (selectedTargetGuid == bar.guid) and nil or bar.guid
        selectedKey = nil -- the previously selected ability may not exist for this target
        BD.Refresh()
    end)

    bar:Hide()
    return bar
end

-- Reset row shown below the target list once there are enough targets
-- that finding-and-reclicking the currently selected one isn't the
-- fastest way back to the unit-wide view.
local function CreateAllEnemiesBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(TARGET_BAR_HEIGHT)

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", bar, "LEFT", 2, 0)
    text:SetJustifyH("LEFT")
    text:SetText("All Enemies")
    CL.ApplyFont(text, CL.GetFontSize())
    bar.text = text

    bar:EnableMouse(true)
    bar:SetScript("OnMouseUp", function()
        selectedTargetGuid = nil
        selectedKey = nil
        BD.Refresh()
    end)

    bar:Hide()
    return bar
end

local function GetDetailRow(parent, index)
    local row = detailRows[index]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetHeight(DETAIL_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * DETAIL_ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * DETAIL_ROW_HEIGHT))
        local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        right:SetJustifyH("RIGHT")
        CL.ApplyFont(right, CL.GetFontSize())
        row.right = right

        -- Icon slot, used by the "Top Ability" row only. Its space is
        -- always reserved so every row's text lines up.
        local icon = row:CreateTexture(nil, "OVERLAY")
        icon:SetWidth(DETAIL_ROW_HEIGHT - 2)
        icon:SetHeight(DETAIL_ROW_HEIGHT - 2)
        icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        row.icon = icon

        -- Bounded on both sides (was LEFT-only) - an unbounded name
        -- string just overlapped straight into the value/stats text
        -- once it was long enough (e.g. "Mind Flay" + "(4h, 0% crit)").
        -- Created after `right` so it can anchor off it.
        local left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        left:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        left:SetPoint("RIGHT", right, "LEFT", -4, 0)
        left:SetJustifyH("LEFT")
        CL.ApplyFont(left, CL.GetFontSize())
        row.left = left
        detailRows[index] = row
    end
    return row
end

local function CreateWindow()
    local f = CreateFrame("Frame", "CombatLedgerBreakdownWindow", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    local themeR, themeG, themeB = CL.GetThemeColor()
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.8))
    f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout("breakdown", this)
    end)
    f:Hide()

    CL.ApplyLayout("breakdown", f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local alreadyRegistered = false
    local i
    for i = 1, table.getn(UISpecialFrames) do
        if UISpecialFrames[i] == "CombatLedgerBreakdownWindow" then
            alreadyRegistered = true
        end
    end
    if not alreadyRegistered then
        table.insert(UISpecialFrames, "CombatLedgerBreakdownWindow")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("")
    CL.ApplyFont(title)
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Left column: ability list on top, Targets pinned at the bottom -
    -- both always visible (no more spell/target toggle).
    local leftPane = CreateFrame("Frame", nil, f)
    leftPane:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    -- "BOTTOM" (not "CENTER") - horizontally centered like CENTER is,
    -- but at the window's actual bottom edge instead of its vertical
    -- midpoint, which is what CENTER would pin the Y to as well.
    leftPane:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, FOOTER_GAP)
    f.leftPane = leftPane

    local targetsLabel = leftPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetsLabel:SetJustifyH("LEFT")
    targetsLabel:SetText("Targets:")
    targetsLabel:SetTextColor(1, 0.82, 0)
    CL.ApplyFont(targetsLabel)
    f.targetsLabel = targetsLabel

    local targetParent = CreateFrame("Frame", nil, leftPane)
    f.targetParent = targetParent
    for i = 1, MAX_TARGET_BARS do
        targetBars[i] = CreateTargetBar(targetParent, i)
    end

    local allEnemiesBar = CreateAllEnemiesBar(targetParent)
    f.allEnemiesBar = allEnemiesBar

    -- Anchored by TOPLEFT + BOTTOMRIGHT on the same pane so its height
    -- is well defined.
    local barParent = CreateFrame("Frame", nil, leftPane)
    f.barParent = barParent
    for i = 1, MAX_BARS do
        bars[i] = CreateBar(barParent, i)
    end

    -- Sizes the Targets area to however many target rows there actually
    -- are (0 if none/not damage mode) instead of always reserving room
    -- for the full MAX_TARGET_BARS pool - otherwise the reservation ate
    -- into the ability list's space even with just one or two targets.
    local function LayoutLeftColumn(targetCount)
        local h = TargetsAreaHeight(targetCount)
        targetsLabel:ClearAllPoints()
        targetParent:ClearAllPoints()
        barParent:ClearAllPoints()
        if h > 0 then
            targetsLabel:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 2, h - TARGETS_LABEL_HEIGHT)
            targetsLabel:Show()
            targetParent:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 2, 0)
            targetParent:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -2, 0)
            targetParent:SetHeight(h - TARGETS_LABEL_HEIGHT)
            targetParent:Show()
            barParent:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 0, 0)
            barParent:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", 0, h + 4)
        else
            targetsLabel:Hide()
            targetParent:Hide()
            barParent:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 0, 0)
            barParent:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", 0, 0)
        end
    end
    LayoutLeftColumn(0)
    f.LayoutLeftColumn = LayoutLeftColumn

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", barParent, "CENTER", 0, 0)
    empty:SetText("No data yet")
    CL.ApplyFont(empty)
    f.emptyLabel = empty

    -- Right column: persistent detail panel for whatever ability is
    -- selected (click a row on the left, not hover - a real panel that
    -- stays up beats a tooltip that vanishes the moment you look away).
    local rightPane = CreateFrame("Frame", nil, f)
    -- "TOP" (not "CENTER") - horizontally centered like CENTER is, but
    -- at the window's actual top edge instead of its vertical midpoint.
    rightPane:SetPoint("TOPLEFT", f, "TOP", 4, -HEADER_HEIGHT)
    rightPane:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_GAP)
    f.rightPane = rightPane

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOP", f, "TOP", 0, -HEADER_HEIGHT)
    divider:SetPoint("BOTTOM", f, "BOTTOM", 0, FOOTER_GAP)
    divider:SetTexture(0.4, 0.4, 0.4, 0.6)

    -- Shown only for a selected ability (not the Overall summary);
    -- detailName moves right of it while shown (RefreshDetailPanel).
    local detailIcon = rightPane:CreateTexture(nil, "OVERLAY")
    detailIcon:SetWidth(DETAIL_ICON_SIZE)
    detailIcon:SetHeight(DETAIL_ICON_SIZE)
    detailIcon:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 0, 0)
    detailIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    detailIcon:Hide()
    f.detailIcon = detailIcon

    local detailName = rightPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailName:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 0, 0)
    detailName:SetJustifyH("LEFT")
    detailName:SetText("")
    CL.ApplyFont(detailName)
    f.detailName = detailName

    local detailPanel = CreateFrame("Frame", nil, rightPane)
    detailPanel:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 0, -(DETAIL_ICON_SIZE + 4))
    detailPanel:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", 0, 0)
    f.detailPanel = detailPanel
    for i = 1, MAX_DETAIL_ROWS do
        GetDetailRow(detailPanel, i)
    end

    local detailEmpty = rightPane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailEmpty:SetPoint("CENTER", detailPanel, "CENTER", 0, 0)
    detailEmpty:SetText("No data yet")
    detailEmpty:SetTextColor(0.6, 0.6, 0.6)
    CL.ApplyFont(detailEmpty)
    f.detailEmpty = detailEmpty

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
        this.sizing = true
        this.startX, this.startY = GetCursorPosition()
        this.startW, this.startH = f:GetWidth(), f:GetHeight()
        this.scale = f:GetEffectiveScale()
    end)
    grip:SetScript("OnMouseUp", function()
        this.sizing = nil
        CL.SaveLayout("breakdown", f)
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
    end)
    f.resizeGrip = grip

    CL.ApplyWindowSkin(f, themeR, themeG, themeB, 0.8)
    if pfUI and pfUI.api then
        pcall(pfUI.api.SkinCloseButton, closeBtn)
    end

    window = f
    return f
end

-- Rendered as persistent label/value rows (rather than a hover tooltip)
-- so it stays up while you look at it. With nothing selected, shows an
-- overall summary for the unit instead of just an empty placeholder -
-- the panel has plenty of room, no reason to leave it blank until you
-- click something.
local function RefreshDetailPanel(entry, list, targets, duration, unitTotal, mode, filteredTargetName, bucket)
    if not window then return end

    -- Default/no-selection state - only the "specific entry selected"
    -- branch far below overrides this with a real icon + repositioned
    -- name. Reset unconditionally here rather than in every "no
    -- selection" branch below (deaths/empty/Overall summary all return
    -- before reaching that branch) so none of them can forget to.
    window.detailIcon:Hide()
    window.detailName:SetPoint("TOPLEFT", window.rightPane, "TOPLEFT", 0, 0)

    local idx = 0
    local function Line(label, value, vr, vg, vb, icon)
        idx = idx + 1
        if idx > MAX_DETAIL_ROWS then return end
        local row = detailRows[idx]
        row.left:SetText(label)
        row.left:SetTextColor(1, 1, 1)
        row.right:SetText(value)
        row.right:SetTextColor(vr or 1, vg or 1, vb or 1)
        -- Rows are pooled/reused across refreshes - a row that showed an
        -- icon before must have it explicitly hidden if this refresh's
        -- call for that same row index doesn't pass one, or it'd keep
        -- showing whatever icon was left over from before.
        if icon then
            row.icon:SetTexture(icon)
            row.icon:Show()
        else
            row.icon:Hide()
        end
        row:Show()
    end
    local function DimLine(label, value, dim)
        local c = dim and 0.6 or 1
        Line(label, value, c, c, c)
    end
    -- A grey, label-only row (e.g. "3 dodge, 1 parry").
    local function Note(text)
        idx = idx + 1
        if idx > MAX_DETAIL_ROWS then return end
        local row = detailRows[idx]
        row.left:SetText(text)
        row.left:SetTextColor(0.7, 0.7, 0.7)
        row.right:SetText("")
        row.icon:Hide()
        row:Show()
    end
    local function Header(label)
        idx = idx + 1
        if idx > MAX_DETAIL_ROWS then return end
        local row = detailRows[idx]
        row.left:SetText(label)
        row.left:SetTextColor(1, 0.82, 0)
        row.right:SetText("")
        row.icon:Hide()
        row:Show()
    end

    -- Deaths has no per-ability list (see ModeBucket) - just the raw
    -- count, no Rate/Hits/Abilities/Top Ability, none of which mean
    -- anything for a counter. Hit-by-hit detail on any one death lives
    -- in the dedicated Death Recap window instead.
    if mode == "deaths" then
        window.detailEmpty:Hide()
        window.detailName:SetText("Overall")
        Line("Total", (unitTotal or 0) .. ((unitTotal == 1) and " death" or " deaths"))
        for i = idx + 1, MAX_DETAIL_ROWS do
            detailRows[i]:Hide()
        end
        return
    end

    if not entry then
        if not list or table.getn(list) == 0 then
            window.detailName:SetText("")
            window.detailEmpty:Show()
            local i
            for i = 1, MAX_DETAIL_ROWS do
                detailRows[i]:Hide()
            end
            return
        end
        window.detailEmpty:Hide()

        window.detailName:SetText(filteredTargetName and ("Overall  |cffffcc00vs " .. filteredTargetName .. "|r") or "Overall")
        Line("Total", FormatNumber(unitTotal or 0))
        Line("Rate", FormatNumber((unitTotal or 0) / (duration or 1)) .. " " .. CL.RateSuffix(mode))
        Line("Duration", string.format("%.1fs", duration or 0))
        if mode == "healing" then CL.AddOverhealLines(bucket, DimLine) end

        local totalHits, totalCrits = 0, 0
        local i
        for i = 1, table.getn(list) do
            totalHits = totalHits + (list[i].hits or 0)
            totalCrits = totalCrits + (list[i].crits or 0)
        end
        Line("Hits", tostring(totalHits))
        if totalHits > 0 then
            Line("Overall Crit", string.format("%d (%.0f%%)", totalCrits, totalCrits / totalHits * 100))
        end
        if mode == "damage" or mode == "taken" then
            local meleeHits = CL.AddAvoidanceLines(bucket, mode, Line, Note)
            CL.AddMitigationLines(bucket, meleeHits, DimLine)
        end
        Line("Abilities", tostring(table.getn(list)))

        local top = list[1]
        if top then
            local topPct = (unitTotal and unitTotal > 0) and (top.total / unitTotal * 100) or 0
            Header("Top Ability")
            local topIcon = top.isMelee and CL.MELEE_ICON or CL.GetSpellIcon(top.spellId)
            Line(top.name, FormatNumber(top.total) .. string.format(" (%.0f%%)", topPct), nil, nil, nil, topIcon)
        end

        if mode ~= "deaths" and targets and table.getn(targets) > 0 then
            Header((MODE_TARGET_LABEL[mode] or "Targets") .. ": " .. table.getn(targets))
            local topTarget = targets[1]
            local topTargetPct = (unitTotal and unitTotal > 0) and (topTarget.total / unitTotal * 100) or 0
            Line(topTarget.name, FormatNumber(topTarget.total) .. string.format(" (%.0f%%)", topTargetPct))
        end

        for i = idx + 1, MAX_DETAIL_ROWS do
            detailRows[i]:Hide()
        end
        return
    end

    window.detailEmpty:Hide()
    window.detailName:SetText(entry.name .. (filteredTargetName and ("  |cffffcc00vs " .. filteredTargetName .. "|r") or ""))

    -- A specific ability is selected here (not the Overall summary,
    -- which returns before reaching this point) - show its icon big,
    -- next to the name, same as the "nice big" ask.
    local bigIcon = entry.isMelee and CL.MELEE_ICON or CL.GetSpellIcon(entry.spellId)
    if bigIcon then
        window.detailIcon:SetTexture(bigIcon)
        window.detailIcon:Show()
        window.detailName:SetPoint("TOPLEFT", window.detailIcon, "TOPRIGHT", 6, -(DETAIL_ICON_SIZE / 2 - 7))
    else
        window.detailIcon:Hide()
        window.detailName:SetPoint("TOPLEFT", window.rightPane, "TOPLEFT", 0, 0)
    end

    local totalText = FormatNumber(entry.total)
    if unitTotal and unitTotal > 0 then
        totalText = totalText .. string.format(" (%.0f%%)", entry.total / unitTotal * 100)
    end
    Line("Total", totalText)
    Line("Rate", FormatNumber(entry.total / (duration or 1)) .. " " .. CL.RateSuffix(mode))
    if mode == "healing" then CL.AddOverhealLines(entry, DimLine) end

    -- Count line: "Casts" for a pure DoT (its hits are ticks; falls back
    -- to hits where casts weren't tracked), nothing for a spell with both
    -- direct hits and ticks (the lines below cover it), "Hits" otherwise.
    local hasTicks = entry.tickHits and entry.tickHits.hits > 0
    local hasDirect = entry.directHits and entry.directHits.hits > 0
    if hasTicks and hasDirect then
        -- skip - Direct Hits/Ticks lines below take this slot instead
    elseif hasTicks then
        Line("Casts", tostring(entry.casts or entry.hits or 0))
    else
        Line("Hits", tostring(entry.hits or 0))
    end

    -- Spells with both a direct hit and DoT ticks (Rake, Immolate) get
    -- separate count and min/max lines for each, since one blended range
    -- would describe neither.
    if hasTicks then
        local dh = entry.directHits
        if dh and dh.hits > 0 then
            local dhLine = tostring(dh.hits)
            if dh.min and dh.max then
                dhLine = dhLine .. "  (" .. FormatNumber(dh.min) .. " - " .. FormatNumber(dh.max) .. ")"
            end
            Line("Direct Hits", dhLine)
        end
        local th = entry.tickHits
        local thLine = tostring(th.hits)
        if th.min and th.max then
            thLine = thLine .. "  (" .. FormatNumber(th.min) .. " - " .. FormatNumber(th.max) .. ")"
        end
        Line("Ticks", thLine)
    elseif entry.min and entry.max then
        Line("Min / Max", FormatNumber(entry.min) .. " / " .. FormatNumber(entry.max))
    end

    -- Misses right after the hit counts (they're attempts too), before
    -- crits and mitigation, so they're never the lines cut off at
    -- MAX_DETAIL_ROWS. `landed` = successful attempts to compare against.
    local verb = (mode == "taken") and "avoided" or "missed"
    local function AvoidanceLines(label, avoidedTable, landed)
        local avoided, summary = CL.SummarizeAvoided(avoidedTable)
        if avoided <= 0 then return end
        local attempts = (landed or 0) + avoided
        Line(label, string.format("%d/%d (%.0f%%)", avoided, attempts, avoided / attempts * 100), 1, 0.82, 0)
        Note(summary)
    end
    if entry.mainHand or entry.offHand then
        -- Main and off hand have different hit caps, so a dual wielder
        -- sees them separately; otherwise it's just "Missed".
        local offHandSwings = entry.offHand and ((entry.offHand.hits or 0) + CL.SummarizeAvoided(entry.offHand.avoided)) or 0
        if offHandSwings > 0 then
            AvoidanceLines("Main hand " .. verb, entry.mainHand and entry.mainHand.avoided, entry.mainHand and entry.mainHand.hits)
            AvoidanceLines("Off-hand " .. verb, entry.offHand.avoided, entry.offHand.hits)
        else
            AvoidanceLines((mode == "taken") and "Avoided" or "Missed", entry.mainHand and entry.mainHand.avoided, entry.mainHand and entry.mainHand.hits)
        end
    elseif entry.avoided then
        -- A DoT's ticks aren't separate attempts - one cast lands or
        -- misses once, so compare against casts/direct hits instead.
        local landed = entry.hits
        if hasTicks then
            landed = (hasDirect and entry.directHits.hits) or entry.casts or entry.hits
        end
        AvoidanceLines((mode == "taken") and "Avoided" or "Missed", entry.avoided, landed)
    end

    if entry.crits ~= nil then
        local hits = entry.hits or 0
        local crits = entry.crits or 0
        local critPct = (hits > 0) and (crits / hits * 100) or 0
        local critTotal = entry.critTotal or 0
        local critDmgPct = (entry.total and entry.total > 0) and (critTotal / entry.total * 100) or 0
        -- Heals average raw heal size (what the spell did), not the
        -- overheal-reduced effective amount.
        local sizeTotal = entry.raw or entry.total or 0
        local sizeCrit = entry.raw and (entry.critRaw or 0) or critTotal
        Line("Crits", string.format("%d (%.0f%%)", crits, critPct))
        if crits > 0 then
            Line(entry.raw and "Crit healing" or "Crit damage", string.format("%s (%.0f%%)", FormatNumber(critTotal), critDmgPct))
        end
        -- Average normal and crit size share one line to leave room.
        local nonCritHits = hits - crits
        local avgNormal = (nonCritHits > 0) and FormatNumber((sizeTotal - sizeCrit) / nonCritHits) or nil
        local avgCrit = (crits > 0) and FormatNumber(sizeCrit / crits) or nil
        if avgNormal and avgCrit then
            Line(entry.raw and "Avg heal / crit" or "Avg hit / crit", avgNormal .. " / " .. avgCrit)
        elseif avgNormal then
            Line(entry.raw and "Avg heal" or "Avg hit", avgNormal)
        elseif avgCrit then
            Line("Avg crit", avgCrit)
        end
    end

    CL.AddMitigationLines(entry, entry.isMelee and entry.hits, DimLine)

    local i
    for i = idx + 1, MAX_DETAIL_ROWS do
        detailRows[i]:Hide()
    end
end

function BD.Refresh()
    if not window or not window:IsShown() then return end
    if not currentGuid then return end
    drawnVersion = CL.Aggregator.GetDataVersion()
    drawnAt = GetTime()

    local mode, segment, enc = ResolveActiveState()

    local u = enc and enc.units and enc.units[currentGuid]
    if u then
        currentName = u.name
        currentClassToken = u.classToken
    end

    window.targetsLabel:SetText((MODE_TARGET_LABEL[mode] or "Targets") .. ":")

    -- Always visible (not a toggle), sized to however many there
    -- actually are so it doesn't eat into the ability list's space when
    -- there's only one or two. Deaths mode has no per-target breakdown.
    local targets = (mode ~= "deaths") and BuildTargetList(u, mode) or {}
    local targetCount = table.getn(targets)
    if targetCount > MAX_TARGET_BARS then targetCount = MAX_TARGET_BARS end
    -- Re-anchor only when the count changes: repeated re-anchoring
    -- leaves stale rendering and stale GetHeight() reads on this client.
    if targetCount ~= lastTargetCount and window.LayoutLeftColumn then
        window.LayoutLeftColumn(targetCount)
        lastTargetCount = targetCount
    end

    -- A selected target filters the ability list to that target's own
    -- sub-bucket (same shape as the unit's). Falls back to the unit-wide
    -- view if the target is gone (reset, compaction, mode change).
    local modeBucket = ModeBucket(u, mode)
    local filteredTarget = nil
    if selectedTargetGuid and mode ~= "deaths" and modeBucket and modeBucket.targets then
        filteredTarget = modeBucket.targets[selectedTargetGuid]
    end
    if selectedTargetGuid and not filteredTarget then
        selectedTargetGuid = nil
    end

    local bucket = filteredTarget or modeBucket
    -- Deaths has no bucket (see ModeBucket) - its "total" is just the
    -- raw death counter.
    local unitTotal = (mode == "deaths") and ((u and u.deaths) or 0) or ((bucket and bucket.total) or 0)

    window.title:SetText("|cff" .. ClassColorHex(currentClassToken) .. (currentName or "Unknown") ..
        "|r  " .. (MODE_TITLES[mode] or mode) .. (filteredTarget and ("  |cffffcc00vs " .. filteredTarget.name .. "|r") or ""))

    local duration = 1
    if segment == "overall" then
        duration = CL.Aggregator.GetOverallDuration()
    elseif enc then
        duration = (enc.duration and enc.duration > 0) and enc.duration or (GetTime() - enc.startTime)
    end
    if duration <= 0 then duration = 1 end

    local list = BuildSpellList(bucket)

    local maxVal = 1
    if list[1] and list[1].total > 0 then
        maxVal = list[1].total
    end

    local themeR, themeG, themeB = CL.GetThemeColor()
    -- Show only as many fixed-size bars as fit above the Targets area,
    -- computed from window:GetHeight() and the fixed offsets (anchor-
    -- derived heights can read stale right after a layout change).
    local barHeight = CL.GetBarHeight(BAR_HEIGHT)
    local windowHeight = window:GetHeight()
    local reserved = HEADER_HEIGHT + FOOTER_GAP
    if targetCount > 0 then reserved = reserved + TargetsAreaHeight(targetCount) + 4 end
    local availHeight = windowHeight - reserved
    local fit = math.floor((availHeight + BAR_GAP) / (barHeight + BAR_GAP))
    if fit < 1 then fit = 1 end
    if fit > MAX_BARS then fit = MAX_BARS end

    local realCount = table.getn(list)
    if realCount > fit then realCount = fit end

    local shown = 0
    local selectedEntry = nil
    local i
    for i = 1, MAX_BARS do
        local bar = bars[i]
        local entry = (i <= realCount) and list[i] or nil
        if entry then
            shown = shown + 1
            local pct = entry.total / maxVal
            if pct > 1 then pct = 1 end
            bar:SetValue(pct)
            local col = ROW_COLORS[math.mod(i - 1, table.getn(ROW_COLORS)) + 1]
            bar:SetStatusBarColor(col[1], col[2], col[3], 0.9)
            local isSelected = (entry.key == selectedKey)
            if isSelected then
                selectedEntry = entry
                bar.nameText:SetTextColor(themeR, themeG, themeB)
            else
                bar.nameText:SetTextColor(1, 1, 1)
            end
            bar.nameText:SetText(entry.name)
            if entry.isMelee then
                bar.icon:SetTexture(CL.MELEE_ICON)
                bar.icon:Show()
            else
                local tex = CL.GetSpellIcon(entry.spellId)
                if tex then
                    bar.icon:SetTexture(tex)
                    bar.icon:Show()
                else
                    bar.icon:Hide()
                end
            end
            if COUNT_ONLY_MODES[mode] then
                -- Count-only mode - hits always equals total and there's
                -- no such thing as a crit dispel/buff/debuff, so the
                -- usual "(Nh, X% crit)" suffix is just noise here.
                bar.valueText:SetText(tostring(entry.total))
            else
                local critPct = 0
                if entry.hits and entry.hits > 0 then
                    critPct = math.floor((entry.crits / entry.hits) * 100)
                end
                bar.valueText:SetText(FormatNumber(entry.total) .. "  (" .. (entry.hits or 0) ..
                    "h, " .. critPct .. "% crit)")
            end
            bar.key = entry.key
            bar:Show()
        else
            bar.key = nil
            bar:Hide()
        end
    end

    if shown == 0 then
        window.emptyLabel:Show()
    else
        window.emptyLabel:Hide()
    end

    RefreshDetailPanel(selectedEntry, list, targets, duration, unitTotal, mode,
        filteredTarget and filteredTarget.name, bucket)

    -- "All Enemies" sits at slot 1 (once there's more than one target to
    -- pick from), bumping the actual target rows down one slot and one
    -- number so the whole Targets list reads as a single numbered list.
    local showAllEnemies = targetCount > 1
    local slotSize = TARGET_BAR_HEIGHT + TARGET_BAR_GAP
    local shift = showAllEnemies and 1 or 0

    if window.allEnemiesBar then
        if showAllEnemies then
            window.allEnemiesBar.text:SetText("1. " .. (MODE_ALL_LABEL[mode] or "All Enemies"))
            if selectedTargetGuid then
                window.allEnemiesBar.text:SetTextColor(1, 1, 1)
            else
                window.allEnemiesBar.text:SetTextColor(themeR, themeG, themeB)
            end
            window.allEnemiesBar:ClearAllPoints()
            window.allEnemiesBar:SetPoint("TOPLEFT", window.targetParent, "TOPLEFT", 0, 0)
            window.allEnemiesBar:SetPoint("TOPRIGHT", window.targetParent, "TOPRIGHT", 0, 0)
            window.allEnemiesBar:Show()
        else
            window.allEnemiesBar:Hide()
        end
    end

    for i = 1, MAX_TARGET_BARS do
        local tbar = targetBars[i]
        local t = (i <= targetCount) and targets[i] or nil
        if t then
            local slot = (i - 1) + shift
            tbar:ClearAllPoints()
            tbar:SetPoint("TOPLEFT", window.targetParent, "TOPLEFT", 0, -(slot * slotSize))
            tbar:SetPoint("TOPRIGHT", window.targetParent, "TOPRIGHT", 0, -(slot * slotSize))
            tbar.nameText:SetText((i + shift) .. ". " .. t.name)
            tbar.valueText:SetText(FormatNumber(t.total))
            if t.guid == selectedTargetGuid then
                tbar.nameText:SetTextColor(themeR, themeG, themeB)
                tbar.valueText:SetTextColor(themeR, themeG, themeB)
            else
                tbar.nameText:SetTextColor(1, 1, 1)
                tbar.valueText:SetTextColor(1, 1, 1)
            end
            tbar.guid = t.guid
            tbar:Show()
        else
            tbar.guid = nil
            tbar:Hide()
        end
    end
end

-- Re-applies texture/font/height to every pooled element after an
-- Options change - see CL.OnAppearanceChanged in Core.lua.
local function RestyleBars()
    if not window then return end
    local themeR, themeG, themeB = CL.GetThemeColor()
    CL.ApplyWindowSkin(window, themeR, themeG, themeB, 0.8)
    CL.ApplyFont(window.title)
    CL.ApplyFont(window.targetsLabel)
    CL.ApplyFont(window.emptyLabel)
    CL.ApplyFont(window.detailName)
    CL.ApplyFont(window.detailEmpty)
    local barHeight = CL.GetBarHeight(BAR_HEIGHT)
    CL.RepositionBarPool(bars, barHeight, BAR_GAP)
    local i
    for i = 1, table.getn(bars) do
        local bar = bars[i]
        bar:SetStatusBarTexture(CL.GetBarTexture())
        bar.bg:SetTexture(CL.GetBarTexture())
        bar.icon:SetWidth(barHeight - 2)
        bar.icon:SetHeight(barHeight - 2)
        CL.ApplyFont(bar.nameText, CL.GetFontSize())
        CL.ApplyFont(bar.valueText, CL.GetFontSize())
    end
    for i = 1, table.getn(targetBars) do
        CL.ApplyFont(targetBars[i].nameText, CL.GetFontSize())
        CL.ApplyFont(targetBars[i].valueText, CL.GetFontSize())
    end
    for i = 1, table.getn(detailRows) do
        CL.ApplyFont(detailRows[i].left, CL.GetFontSize())
        CL.ApplyFont(detailRows[i].right, CL.GetFontSize())
    end
    if window.allEnemiesBar then
        CL.ApplyFont(window.allEnemiesBar.text, CL.GetFontSize())
    end
    BD.Refresh()
end
CL.OnAppearanceChanged(RestyleBars)

-- mode/segment/historyEncounter (optional) come from whichever meter
-- window's bar was clicked - see UI_MainWindow.lua's CreateBar. Falls
-- back to Damage/Current if omitted (e.g. called from somewhere that
-- doesn't track its own mode/segment).
function BD.Show(guid, mode, segment, historyEncounter)
    if not guid then return end
    currentGuid = guid
    currentName = nil
    currentClassToken = nil
    currentMode = mode or "damage"
    currentSegment = segment or "current"
    currentHistoryEncounter = historyEncounter
    selectedKey = nil
    selectedTargetGuid = nil
    lastTargetCount = -1
    if not window then CreateWindow() end
    window:Show()
    BD.Refresh()
end

function BD.Hide()
    if window then window:Hide() end
end

local driver = CreateFrame("Frame")
local accum = 0
local function DriverTick()
    accum = accum + arg1
    if accum < REFRESH_INTERVAL then return end
    accum = 0
    if not window or not window:IsShown() then return end
    -- Same rule as the main window's driver: redraw on new data, every
    -- tick during a live fight on a Current/Overall view (rates divide
    -- by a still-growing duration), else only as a slow safety net.
    local now = GetTime()
    local timeDriven = CL.Aggregator.GetCurrent() ~= nil and currentSegment ~= "history"
    if drawnVersion ~= CL.Aggregator.GetDataVersion() or timeDriven
        or not drawnAt or (now - drawnAt) >= IDLE_REFRESH_SECONDS then
        BD.Refresh()
    end
end
driver:SetScript("OnUpdate", function()
    local ok, err = pcall(DriverTick)
    if not ok then CL.RecordError("Breakdown:refresh", err) end
end)

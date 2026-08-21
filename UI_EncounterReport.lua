--[[
    UI_EncounterReport - a real per-encounter summary: shape-of-the-fight
    graph (Aggregator's bucketed series) plus a leaderboard, for one
    saved (or the live) encounter. Opened from a History row's "Report"
    button, or /cl report for whatever's currently showing as Current
    Fight.

    Deliberately not a full event-by-event log viewer - see Aggregator's
    series comment for why that tradeoff was made. This is the first
    real consumer of series data; a future scrubbable timeline (click a
    graph point, see exactly what landed there) would need a separate,
    live-only raw event buffer layered on top of this, the same way
    DeathRecap's rolling buffer already works.
]]

local CL = CombatLedger
local RC = {}
CL.UIEncounterReport = RC

local HEADER_HEIGHT = 40
local TOGGLE_HEIGHT = 20
local GRAPH_HEIGHT = 90
local LEADER_GAP_ABOVE = 6
local BAR_HEIGHT = 16
local BAR_GAP = 2
local FOOTER_GAP = 12
local MAX_LEADER_BARS = 10
local GRAPH_BARS = 40

local WINDOW_WIDTH, WINDOW_HEIGHT = 400, 400
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 300, 280
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 700, 700

local METRIC_UNIT_FIELD = { damage = "damageDone", healing = "healingDone", taken = "damageTaken" }
local METRIC_LABELS = { damage = "Damage", healing = "Healing", taken = "Taken" }
local METRIC_ORDER = { "damage", "healing", "taken" }
local METRIC_COLOR = {
    damage = { 0.95, 0.55, 0.15 },
    healing = { 0.25, 0.85, 0.35 },
    taken = { 0.85, 0.2, 0.2 },
}

local window = nil
local toggleBtns = {}
local graphBars = {}
local leaderBars = {}

local function FormatNumber(n)
    return CL.FormatNumber(n)
end

local function ClassColorHex(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "ffffff"
end

local function ClassColorRGB(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b
    end
    return 0.7, 0.7, 0.7
end

-- Downsamples encounter.series (fixed 2s buckets, may run long past
-- GRAPH_BARS worth of them) into exactly GRAPH_BARS points, each the
-- average per-second rate over its merged window - averaging by actual
-- elapsed seconds (not just bucket count) keeps a shorter trailing
-- group from reading as artificially taller/shorter than a full one.
local function BuildGraphPoints(encounter, metric)
    local series = (encounter and encounter.series) or {}
    local total = table.getn(series)
    local points = {}
    if total < 1 then return points, 0 end

    local bucketSeconds = (CL.Aggregator and CL.Aggregator.SERIES_BUCKET_SECONDS) or 2
    local perGroup = math.ceil(total / GRAPH_BARS)
    if perGroup < 1 then perGroup = 1 end

    local i = 1
    local maxRate = 0
    while i <= total do
        local groupEnd = i + perGroup - 1
        if groupEnd > total then groupEnd = total end
        local sum = 0
        local j
        for j = i, groupEnd do
            local b = series[j]
            if b then sum = sum + (b[metric] or 0) end
        end
        local seconds = (groupEnd - i + 1) * bucketSeconds
        local rate = (seconds > 0) and (sum / seconds) or 0
        table.insert(points, rate)
        if rate > maxRate then maxRate = rate end
        i = i + perGroup
    end

    return points, maxRate
end

local function CreateGraphBar(parent)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(CL.GetBarTexture())
    tex:Hide()
    return tex
end

local function CreateLeaderBar(parent, index)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    local bar = CreateFrame("Button", nil, parent)
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:EnableMouse(true)
    bar:RegisterForClicks("LeftButtonUp")

    local statusBar = CreateFrame("StatusBar", nil, bar)
    statusBar:SetAllPoints(bar)
    statusBar:SetStatusBarTexture(CL.GetBarTexture())
    statusBar:SetMinMaxValues(0, 1)
    statusBar:SetValue(0)
    bar.statusBar = statusBar

    local bg = statusBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(statusBar)
    bg:SetTexture(CL.GetBarTexture())
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
    bar.bg = bg

    local nameText = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", statusBar, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    local valueText = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", statusBar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    bar:SetScript("OnClick", function()
        if bar.guid and window and window.encounter and CL.UIBreakdown then
            CL.UIBreakdown.Show(bar.guid, window.metric, "history", window.encounter)
        end
    end)

    bar:Hide()
    return bar
end

local function RestyleReport()
    if not window then return end
    local r, g, b = CL.GetThemeColor()
    CL.ApplyWindowSkin(window, r, g, b, 0.85)
    CL.ApplyFont(window.title)
    CL.ApplyFont(window.subText)
    CL.ApplyFont(window.graphEmptyLabel)
    CL.ApplyFont(window.leaderEmptyLabel)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    CL.RepositionBarPool(leaderBars, height, BAR_GAP)
    local i
    for i = 1, table.getn(leaderBars) do
        leaderBars[i].statusBar:SetStatusBarTexture(CL.GetBarTexture())
        leaderBars[i].bg:SetTexture(CL.GetBarTexture())
        CL.ApplyFont(leaderBars[i].nameText, CL.GetFontSize())
        CL.ApplyFont(leaderBars[i].valueText, CL.GetFontSize())
    end
    for i = 1, table.getn(graphBars) do
        graphBars[i]:SetTexture(CL.GetBarTexture())
    end
end
CL.OnAppearanceChanged(RestyleReport)

local function CreateToggleButton(parent, metric, index)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(TOGGLE_HEIGHT)
    btn:SetWidth(70)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 6 + (index - 1) * 74, -HEADER_HEIGHT + 2)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    btn:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(btn)
    label:SetJustifyH("CENTER")
    label:SetText(METRIC_LABELS[metric])
    CL.ApplyFont(label)
    btn.label = label
    btn.metric = metric
    btn:SetScript("OnClick", function()
        if window then
            window.metric = btn.metric
            RC.Refresh()
        end
    end)
    return btn
end

local function CreateWindow()
    local f = CreateFrame("Frame", "CombatLedgerEncounterReportWindow", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.85))
    f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout("encounterReport", this)
    end)
    f:Hide()

    CL.ApplyLayout("encounterReport", f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local alreadyRegistered = false
    local i
    for i = 1, table.getn(UISpecialFrames) do
        if UISpecialFrames[i] == "CombatLedgerEncounterReportWindow" then
            alreadyRegistered = true
        end
    end
    if not alreadyRegistered then
        table.insert(UISpecialFrames, "CombatLedgerEncounterReportWindow")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cff" .. themeHex .. "Encounter Report|r")
    CL.ApplyFont(title)
    f.title = title

    local subText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subText:SetPoint("TOP", f, "TOP", 0, -20)
    CL.ApplyFont(subText)
    f.subText = subText

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    for i = 1, table.getn(METRIC_ORDER) do
        toggleBtns[i] = CreateToggleButton(f, METRIC_ORDER[i], i)
    end

    local graphFrame = CreateFrame("Frame", nil, f)
    graphFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -(HEADER_HEIGHT + TOGGLE_HEIGHT + 6))
    graphFrame:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -(HEADER_HEIGHT + TOGGLE_HEIGHT + 6))
    graphFrame:SetHeight(GRAPH_HEIGHT)
    graphFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    graphFrame:SetBackdropColor(0, 0, 0, 0.3)
    f.graphFrame = graphFrame

    for i = 1, GRAPH_BARS do
        graphBars[i] = CreateGraphBar(graphFrame)
    end

    local graphEmpty = graphFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    graphEmpty:SetPoint("CENTER", graphFrame, "CENTER", 0, 0)
    graphEmpty:SetText("No timeline data")
    CL.ApplyFont(graphEmpty)
    f.graphEmptyLabel = graphEmpty

    local leaderLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leaderLabel:SetPoint("TOPLEFT", graphFrame, "BOTTOMLEFT", 0, -LEADER_GAP_ABOVE)
    leaderLabel:SetText("Leaderboard")
    CL.ApplyFont(leaderLabel)
    f.leaderLabel = leaderLabel

    local leaderParent = CreateFrame("Frame", nil, f)
    leaderParent:SetPoint("TOPLEFT", leaderLabel, "BOTTOMLEFT", 0, -4)
    leaderParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_GAP)
    f.leaderParent = leaderParent

    for i = 1, MAX_LEADER_BARS do
        leaderBars[i] = CreateLeaderBar(leaderParent, i)
    end

    local leaderEmpty = leaderParent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    leaderEmpty:SetPoint("CENTER", leaderParent, "CENTER", 0, 0)
    leaderEmpty:SetText("No data")
    CL.ApplyFont(leaderEmpty)
    f.leaderEmptyLabel = leaderEmpty

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
        CL.SaveLayout("encounterReport", f)
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
        RC.Refresh()
    end)
    f.resizeGrip = grip

    CL.ApplyWindowSkin(f, themeR, themeG, themeB, 0.85)
    if pfUI and pfUI.api then
        pcall(pfUI.api.SkinCloseButton, closeBtn)
    end

    window = f
    window.metric = "damage"
    return f
end

local function RefreshGraph()
    local encounter = window.encounter
    local points, maxRate = BuildGraphPoints(encounter, window.metric)
    local numPoints = table.getn(points)
    local color = METRIC_COLOR[window.metric]
    local graphFrame = window.graphFrame
    local graphWidth = graphFrame:GetWidth()
    -- Stretch to fill the full width regardless of point count, so a
    -- short fight (fewer than GRAPH_BARS downsampled groups) still
    -- reads as a complete graph instead of a partial one hugging the
    -- left edge.
    local barWidth = graphWidth / ((numPoints > 0) and numPoints or 1)

    if numPoints == 0 then
        window.graphEmptyLabel:Show()
    else
        window.graphEmptyLabel:Hide()
    end

    local i
    for i = 1, GRAPH_BARS do
        local bar = graphBars[i]
        local value = (i <= numPoints) and points[i] or nil
        if value and maxRate > 0 then
            local pct = value / maxRate
            if pct > 1 then pct = 1 end
            if pct < 0.02 then pct = 0.02 end
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", graphFrame, "BOTTOMLEFT", (i - 1) * barWidth, 0)
            bar:SetWidth(barWidth > 1 and (barWidth - 1) or 1)
            bar:SetHeight(GRAPH_HEIGHT * pct)
            bar:SetVertexColor(color[1], color[2], color[3], 0.9)
            bar:Show()
        else
            bar:Hide()
        end
    end
end

local function RefreshLeaderboard()
    local encounter = window.encounter
    local field = METRIC_UNIT_FIELD[window.metric]
    local list = {}
    if encounter and encounter.units then
        local guid, u
        for guid, u in pairs(encounter.units) do
            local bucket = u[field]
            local total = (bucket and bucket.total) or 0
            if total > 0 then
                table.insert(list, { guid = guid, u = u, total = total })
            end
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)

    local maxVal = (list[1] and list[1].total) or 1
    local shown = 0
    local i
    for i = 1, MAX_LEADER_BARS do
        local bar = leaderBars[i]
        local entry = list[i]
        if entry then
            shown = shown + 1
            local r, g, b = ClassColorRGB(entry.u.classToken)
            bar.statusBar:SetStatusBarColor(r, g, b, 0.9)
            bar.statusBar:SetValue((maxVal > 0) and (entry.total / maxVal) or 0)
            local hex = ClassColorHex(entry.u.classToken)
            bar.nameText:SetText(i .. ". |cff" .. hex .. entry.u.name .. "|r")
            bar.valueText:SetText(FormatNumber(entry.total))
            bar.guid = entry.guid
            bar:Show()
        else
            bar.guid = nil
            bar:Hide()
        end
    end

    if shown == 0 then
        window.leaderEmptyLabel:Show()
    else
        window.leaderEmptyLabel:Hide()
    end
end

function RC.Refresh()
    if not window or not window:IsShown() or not window.encounter then return end

    local enc = window.encounter
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    window.title:SetText("|cff" .. themeHex .. (enc.label or "Encounter") .. "|r")

    local durText = string.format("%.0fs", enc.duration or 0)
    local zoneText = enc.zone or ""
    local pullText = (enc.pullBy and enc.pullBy.name) and (" - pulled by " .. enc.pullBy.name) or ""
    window.subText:SetText(zoneText .. "  -  " .. durText .. pullText)

    local i
    for i = 1, table.getn(toggleBtns) do
        local btn = toggleBtns[i]
        if btn.metric == window.metric then
            btn:SetBackdropColor(themeR, themeG, themeB, 0.5)
        else
            btn:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
        end
    end

    RefreshGraph()
    RefreshLeaderboard()
end

function RC.Show(encounter)
    if not encounter then return end
    if not window then CreateWindow() end
    window.encounter = encounter
    window:Show()
    RC.Refresh()
end

function RC.Hide()
    if window then window:Hide() end
end

--[[
    UI_HistoryWindow - browse saved encounters (History.lua).
    Click a row to open it in the main meter's bar-list UI via
    CL.UI.ShowHistoryEncounter - reuses the live meter's rendering/click-
    to-breakdown instead of a chat dump. Per-row delete, "Clear All" with
    a confirmation popup (same StaticPopupDialogs pattern LootLedger uses
    for its own history window).
]]

local CL = CombatLedger
local HW = {}
CL.UIHistory = HW

local ROW_HEIGHT = 34
local ROW_GAP = 3
local HEADER_HEIGHT = 46
local FOOTER_GAP = 12

local WINDOW_WIDTH, WINDOW_HEIGHT = 260, 320
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 200, 150
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 500, 700

local window = nil
local rows = {}
local MAX_ROWS = 20
local scrollOffset = 0

local function FormatTimeAgo(seconds)
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp")
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (ROW_HEIGHT + ROW_GAP)))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (ROW_HEIGHT + ROW_GAP)))
    row:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    row:SetBackdropColor(0.12, 0.12, 0.12, 0.75)
    row:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local labelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    labelText:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
    labelText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -52, -4)
    labelText:SetJustifyH("LEFT")
    CL.ApplyFont(labelText, CL.GetFontSize())
    row.labelText = labelText

    local subText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subText:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 4)
    subText:SetJustifyH("LEFT")
    CL.ApplyFont(subText, CL.GetFontSize())
    row.subText = subText

    local deleteBtn = CreateFrame("Button", nil, row)
    deleteBtn:EnableMouse(true)
    deleteBtn:RegisterForClicks("LeftButtonUp")
    deleteBtn:SetWidth(16)
    deleteBtn:SetHeight(16)
    deleteBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -3, -3)
    deleteBtn:SetFrameLevel(row:GetFrameLevel() + 1)
    local delTex = deleteBtn:CreateTexture(nil, "OVERLAY")
    delTex:SetAllPoints(deleteBtn)
    delTex:SetTexture("Interface\\Buttons\\UI-StopButton")
    deleteBtn:SetScript("OnClick", function()
        if row.encounterIndex then
            CL.History.DeleteEncounter(row.encounterIndex)
            HW.Refresh()
        end
    end)
    deleteBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(deleteBtn, "ANCHOR_LEFT")
        GameTooltip:SetText("Delete")
        GameTooltip:Show()
    end)
    deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.deleteBtn = deleteBtn

    local reportBtn = CreateFrame("Button", nil, row)
    reportBtn:EnableMouse(true)
    reportBtn:RegisterForClicks("LeftButtonUp")
    reportBtn:SetWidth(28)
    reportBtn:SetHeight(16)
    reportBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -21, -3)
    reportBtn:SetFrameLevel(row:GetFrameLevel() + 1)
    reportBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    reportBtn:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
    local reportLabel = reportBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reportLabel:SetAllPoints(reportBtn)
    reportLabel:SetJustifyH("CENTER")
    reportLabel:SetText("Rpt")
    CL.ApplyFont(reportLabel)
    reportBtn.label = reportLabel
    reportBtn:SetScript("OnClick", function()
        if row.encounterEntry and CL.UIEncounterReport then
            CL.UIEncounterReport.Show(row.encounterEntry)
        end
    end)
    reportBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(reportBtn, "ANCHOR_LEFT")
        GameTooltip:SetText("Encounter Report")
        GameTooltip:Show()
    end)
    reportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.reportBtn = reportBtn

    row:SetScript("OnClick", function()
        if row.encounterEntry and CL.UI and CL.UI.ShowHistoryEncounter then
            CL.UI.ShowHistoryEncounter(row.encounterEntry)
        end
    end)
    row:SetScript("OnEnter", function()
        local r, g, b = CL.GetThemeColor()
        row:SetBackdropBorderColor(r, g, b, 1)
    end)
    row:SetScript("OnLeave", function()
        row:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end)

    row:Hide()
    return row
end

local function CreateWindow()
    local f = CreateFrame("Frame", "CombatLedgerHistoryWindow", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", -260, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.85))
    f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout("history", this)
    end)
    f:Hide()

    CL.ApplyLayout("history", f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local alreadyRegistered = false
    local i
    for i = 1, table.getn(UISpecialFrames) do
        if UISpecialFrames[i] == "CombatLedgerHistoryWindow" then
            alreadyRegistered = true
        end
    end
    if not alreadyRegistered then
        table.insert(UISpecialFrames, "CombatLedgerHistoryWindow")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cff" .. themeHex .. "History|r")
    CL.ApplyFont(title)
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local clearBtn = CreateFrame("Button", nil, f)
    clearBtn:SetWidth(60)
    clearBtn:SetHeight(16)
    clearBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -20)
    clearBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    clearBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.75)
    clearBtn:SetBackdropBorderColor(1, 0.15, 0.15, 1)
    local clearLabel = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clearLabel:SetAllPoints(clearBtn)
    clearLabel:SetJustifyH("CENTER")
    clearLabel:SetText("|cffff5555Clear All|r")
    CL.ApplyFont(clearLabel)
    clearBtn.label = clearLabel
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("COMBATLEDGER_CLEAR_HISTORY")
    end)
    f.clearBtn = clearBtn

    local rowParent = CreateFrame("Frame", nil, f)
    rowParent:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    rowParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_GAP)
    rowParent:EnableMouseWheel(true)
    rowParent:SetScript("OnMouseWheel", function()
        local delta = arg1
        if not delta then return end
        local hist = CL.History.GetHistory()
        local fit = math.floor((rowParent:GetHeight() + ROW_GAP) / (ROW_HEIGHT + ROW_GAP))
        if fit < 1 then fit = 1 end
        local maxOff = table.getn(hist) - fit
        if maxOff < 0 then maxOff = 0 end
        if delta > 0 then scrollOffset = scrollOffset - 1 else scrollOffset = scrollOffset + 1 end
        if scrollOffset < 0 then scrollOffset = 0 end
        if scrollOffset > maxOff then scrollOffset = maxOff end
        HW.Refresh()
    end)
    f.rowParent = rowParent

    for i = 1, MAX_ROWS do
        rows[i] = CreateRow(rowParent, i)
    end

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", rowParent, "CENTER", 0, 0)
    empty:SetText("No saved encounters yet")
    CL.ApplyFont(empty)
    f.emptyLabel = empty

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
        CL.SaveLayout("history", f)
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
        HW.Refresh()
    end)
    f.resizeGrip = grip

    CL.ApplyWindowSkin(f, themeR, themeG, themeB, 0.85)
    if pfUI and pfUI.api then
        pcall(pfUI.api.SkinCloseButton, closeBtn)
    end
    clearBtn:SetBackdropBorderColor(1, 0.15, 0.15, 1)

    window = f
    return f
end

function HW.Refresh()
    if not window or not window:IsShown() then return end

    local hist = CL.History.GetHistory()
    local total = table.getn(hist)

    local fit = math.floor((window.rowParent:GetHeight() + ROW_GAP) / (ROW_HEIGHT + ROW_GAP))
    if fit < 1 then fit = 1 end
    local maxOff = total - fit
    if maxOff < 0 then maxOff = 0 end
    if scrollOffset > maxOff then scrollOffset = maxOff end
    if scrollOffset < 0 then scrollOffset = 0 end

    local now = time()
    local shown = 0
    local i
    for i = 1, MAX_ROWS do
        local row = rows[i]
        local index = i + scrollOffset
        local entry = (i <= fit) and hist[index] or nil
        if entry then
            shown = shown + 1
            row.encounterIndex = index
            row.encounterEntry = entry
            row.labelText:SetText(entry.label or "Unknown")
            local durText = string.format("%.0fs", entry.duration or 0)
            local agoText = FormatTimeAgo(now - (entry.timestamp or now))
            row.subText:SetText(durText .. "  -  " .. agoText)
            row:Show()
        else
            row.encounterIndex = nil
            row.encounterEntry = nil
            row:Hide()
        end
    end

    if shown == 0 then
        window.emptyLabel:Show()
    else
        window.emptyLabel:Hide()
    end
end

local function RestyleRows()
    if window then
        local r, g, b = CL.GetThemeColor()
        CL.ApplyWindowSkin(window, r, g, b, 0.85)
        CL.ApplyFont(window.title)
        CL.ApplyFont(window.emptyLabel)
        if window.clearBtn and window.clearBtn.label then
            CL.ApplyFont(window.clearBtn.label)
        end
    end
    local i
    for i = 1, table.getn(rows) do
        CL.ApplyFont(rows[i].labelText, CL.GetFontSize())
        CL.ApplyFont(rows[i].subText, CL.GetFontSize())
        CL.ApplyFont(rows[i].reportBtn.label, CL.GetFontSize())
    end
end
CL.OnAppearanceChanged(RestyleRows)

function HW.Show()
    if not window then CreateWindow() end
    window:Show()
    HW.Refresh()
end

function HW.Hide()
    if window then window:Hide() end
end

function HW.Toggle()
    if window and window:IsShown() then
        HW.Hide()
    else
        HW.Show()
    end
end

StaticPopupDialogs["COMBATLEDGER_CLEAR_HISTORY"] = {
    text = "Clear all saved CombatLedger encounters?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        CL.History.ClearHistory()
        HW.Refresh()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

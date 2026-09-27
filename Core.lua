--[[
    CombatLedger - core: shared namespace, settings and saved layout,
    appearance helpers, number formatting, diagnostics and the debug log.

    CombatLedger reads Nampower's structured combat events (GUIDs, spell
    ids, raw amounts, hit flags) rather than parsing localized combat-log
    text. Load order (.toc): Core, GuidCache, Aggregator, Threat, Events,
    History, then the UI files.
]]

-- Shared namespace; every file starts with `local CL = CombatLedger` and
-- attaches its module (CL.GuidCache, CL.Aggregator, ...).
CombatLedger = CombatLedger or {}
local CL = CombatLedger

-- Key Bindings panel labels for Bindings.xml's toggle action.
BINDING_HEADER_COMBATLEDGER_TITLE = "CombatLedger"
BINDING_NAME_COMBATLEDGER_TOGGLE = "Toggle CombatLedger windows"

CombatLedgerDB = CombatLedgerDB or { encounters = {} }
CombatLedgerDB.encounters = CombatLedgerDB.encounters or {}
CombatLedgerDB.settings = CombatLedgerDB.settings or {}
CL.db = CombatLedgerDB

-- Idle fallback for ending an encounter: this long without a relevant
-- combat event ends it even if combat state never changed (training
-- dummies don't toggle regen). Normal ends are combat-state driven - see
-- Events.lua's encounter lifecycle.
CL.IDLE_SECONDS = 12

-- User settings with their defaults (edited in UI_Options.lua). Only
-- values that differ from these are stored in CombatLedgerDB.settings.
CL.defaultSettings = {
    matchPfui = true, -- while true (and pfUI is loaded), bar texture + font mirror pfUI's own instead of barTexture/fontKey/fontSize below
    barTexture = "flat", -- pfUI's own flat bar look, bundled in img/bar.tga (see CL.GetBarTexture) - the default even without pfUI installed
    hideBorder = false, -- ShaguDPS-style borderless window, independent of matchPfui
    fontKey = "friz",
    fontSize = 10,
    barHeight = nil, -- nil = each window's own built-in default
    smoothBars = true,
    barSpeed = 8, -- 1 (slow drift) - 10 (near-instant), only used while smoothBars is on
    numberFormat = "abbreviated", -- "abbreviated" (1.2k) / "full" (1,234) / "raw" (1234)
    lockWindow = false,
    showMinimapButton = true,
    announceChannel = "auto", -- "auto" (raid > party > say) / "say" / "party" / "raid" / "guild"
    announceCount = 5,
    windowOpacityPct = 81, -- background alpha, as a percent - ignored while matchPfui is on
    -- Auto-show/auto-hide/grouped-only are per window: CL.GetWindowOption.
    pfuiDock = false, -- dock the main window into pfUI's right chat panel (see UI_PfuiDock.lua) - opt-in, since it moves/resizes the window
    showClassIcon = false, -- class icon before the name on each bar - opt-in, redundant with the existing class-colored bar fill for some tastes
    classColorMenus = false, -- header/dropdown buttons take the player's class color instead of the flat near-black default - see CL.ApplyButtonSkin
    highlightSelf = false, -- border around whichever bar is the player's own, in highlightSelfColor below - opt-in, some people find a border on every meter distracting
    highlightSelfColor = { 1, 0.82, 0 }, -- Options color picker; gold by default
    barBorderEnabled = false, -- border around EVERY bar, in barBorderColor below - independent of highlightSelf, which always wins on your own row regardless of this
    barBorderColor = { 1, 1, 1 }, -- user-customizable via Options' color picker
    -- Automatic Overall resets (see Events.lua's reset rules): "off" / "ask" / "always".
    clearOnJoinPartyMode = "off", -- going from solo to grouped
    clearOnLeavePartyMode = "off", -- going from grouped to solo
    clearOnEnterInstanceMode = "off", -- entering an instance (not a re-entry after a short absence)

    announcePulls = true, -- "Pull: X (spell)" chat print at the start of a boss encounter (not regular elite trash) - see Bosses.lua
    maxEncounters = 50, -- Options' "Saved fights": history kept per character, oldest dropped first (Skada's "Saved fights")
    historyBossOnly = false, -- Options' "Remember boss fights only": only boss pulls are saved to History (Skada's option of the same name)
    mergePets = true, -- pets roll up into their owner's bar in every meter mode (Skada's "Merge pets into owners"); off = pets get their own rows. Threat always keeps pets separate - see Threat.lua
}

-- SavedVariables are loaded after this file runs and replace
-- CombatLedgerDB wholesale, so every accessor re-ensures its sub-table
-- instead of trusting the load-time defaults above.
local function EnsureSettingsTable()
    if not CombatLedgerDB.settings then
        CombatLedgerDB.settings = {}
    end
end

function CL.GetSetting(key)
    EnsureSettingsTable()
    local v = CombatLedgerDB.settings[key]
    if v == nil then return CL.defaultSettings[key] end
    return v
end

function CL.SetSetting(key, value)
    EnsureSettingsTable()
    CombatLedgerDB.settings[key] = value
end

-- Per-window size/position. `key` is a window id ("main", "breakdown",
-- "deathRecap", "history", or an extra meter window's id).
local function EnsureLayoutTable()
    if not CombatLedgerDB.layout then
        CombatLedgerDB.layout = {}
    end
end

function CL.GetLayout(key)
    EnsureLayoutTable()
    return CombatLedgerDB.layout[key]
end

function CL.SaveLayout(key, frame)
    EnsureLayoutTable()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    CombatLedgerDB.layout[key] = {
        width = frame:GetWidth(),
        height = frame:GetHeight(),
        point = point or "CENTER",
        relPoint = relPoint or "CENTER",
        x = x or 0,
        y = y or 0,
    }
end

-- Applies a saved layout if one exists (returns true); otherwise leaves
-- the frame's defaults alone (false). Optional min/max bounds clamp a
-- saved size into what the window's current layout can fit.
function CL.ApplyLayout(key, frame, minW, minH, maxW, maxH)
    local saved = CL.GetLayout(key)
    if not saved then return false end
    if saved.width then
        local w = saved.width
        if minW and w < minW then w = minW end
        if maxW and w > maxW then w = maxW end
        frame:SetWidth(w)
    end
    if saved.height then
        local h = saved.height
        if minH and h < minH then h = minH end
        if maxH and h > maxH then h = maxH end
        frame:SetHeight(h)
    end
    frame:ClearAllPoints()
    frame:SetPoint(saved.point or "CENTER", UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
    return true
end

-- Meter windows and their mode/segment/threat filter. A non-"main" key
-- here is what makes UI.RestoreAllWindows recreate that extra window on
-- login; closing a window forgets its key.
local function EnsureWindowsTable()
    if not CombatLedgerDB.windows then
        CombatLedgerDB.windows = {}
    end
end

function CL.GetWindowState(id)
    EnsureWindowsTable()
    return CombatLedgerDB.windows[id]
end

function CL.SaveWindowState(id, mode, segment, threatFilter)
    EnsureWindowsTable()
    CombatLedgerDB.windows[id] = { mode = mode, segment = segment, threatFilter = threatFilter }
end

function CL.ForgetWindowState(id)
    EnsureWindowsTable()
    CombatLedgerDB.windows[id] = nil
    if CombatLedgerDB.windowOptions then
        CombatLedgerDB.windowOptions[id] = nil
    end
end

-- Per-window behavior toggles (auto-show, auto-hide, grouped only).
-- Stored apart from SaveWindowState's record, which is replaced whole on
-- every mode/segment change.
local function EnsureWindowOptionsTable()
    if not CombatLedgerDB.windowOptions then
        CombatLedgerDB.windowOptions = {}
    end
end

function CL.GetWindowOption(id, key, default)
    EnsureWindowOptionsTable()
    local opts = CombatLedgerDB.windowOptions[id]
    if not opts or opts[key] == nil then return default end
    return opts[key]
end

function CL.SetWindowOption(id, key, value)
    EnsureWindowOptionsTable()
    if not CombatLedgerDB.windowOptions[id] then
        CombatLedgerDB.windowOptions[id] = {}
    end
    CombatLedgerDB.windowOptions[id][key] = value
end

-- Every remembered window id other than "main" (which is handled
-- separately since it always exists and is never closable).
function CL.GetExtraWindowIds()
    EnsureWindowsTable()
    local ids = {}
    local id, _
    for id, _ in pairs(CombatLedgerDB.windows) do
        if id ~= "main" then
            table.insert(ids, id)
        end
    end
    return ids
end

-- pfUI presence comes from the addon manager, not the `pfUI` global:
-- other addons on this client can create a pfUI-shaped table even when
-- pfUI itself isn't loaded.
function CL.HasPfui()
    local ok, loaded = pcall(IsAddOnLoaded, "pfUI")
    return ok and loaded and true or false
end

-- "Match pfUI" (default on, only with pfUI loaded) uses pfUI's own bar
-- texture, font and window skin; off, the manual barTexture/fontKey/
-- fontSize settings apply (Options greys them out while matching).
function CL.IsMatchPfui()
    return CL.HasPfui() and (CL.GetSetting("matchPfui") ~= false)
end

-- Manual bar textures. All but "blizzard" are bundled in img/ (the
-- pfUI-derived ones under pfUI's MIT license - see README), so they work
-- without pfUI installed. pfUI itself only exposes its one selected bar
-- texture (media["img:bar"]), which is what "Match pfUI" uses instead.
CL.BAR_TEXTURES = {
    { key = "flat", label = "Flat (default)" },
    { key = "blizzard", label = "Blizzard Default" },
    { key = "raid", label = "Smooth Gradient", file = "bar_smooth" },
    { key = "elvui", label = "ElvUI Style", file = "bar_elvui" },
    { key = "gradient", label = "pfUI Gradient", file = "bar_gradient" },
    { key = "striped", label = "Striped", file = "bar_striped" },
    { key = "tukui", label = "TukUI Style", file = "bar_tukui" },
}

function CL.GetAvailableBarTextures()
    return CL.BAR_TEXTURES
end

function CL.GetBarTexture()
    if CL.IsMatchPfui() and pfUI.media and pfUI.media["img:bar"] then
        return pfUI.media["img:bar"]
    end
    local key = CL.GetSetting("barTexture") or "flat"
    if key == "flat" then
        return "Interface\\AddOns\\CombatLedger\\img\\bar"
    end
    if key ~= "blizzard" then
        local i
        for i = 1, table.getn(CL.BAR_TEXTURES) do
            local t = CL.BAR_TEXTURES[i]
            if t.key == key and t.file then
                return "Interface\\AddOns\\CombatLedger\\img\\" .. t.file
            end
        end
    end
    return "Interface\\TargetingFrame\\UI-StatusBar"
end

-- The client's own built-in font files - no LibSharedMedia dependency,
-- so this works standalone. Covers the handful of fonts every 1.12
-- client ships with.
CL.FONTS = {
    { key = "friz", label = "Friz Quadrata (default)", path = "Fonts\\FRIZQT__.TTF" },
    { key = "arial", label = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
    { key = "skurri", label = "Skurri", path = "Fonts\\SKURRI.TTF" },
    { key = "morpheus", label = "Morpheus", path = "Fonts\\MORPHEUS.ttf" },
    -- Bundled (fonts/Expressway.ttf), not a stock client font - see README.
    { key = "expressway", label = "Expressway", path = "Interface\\AddOns\\CombatLedger\\fonts\\Expressway.ttf" },
}

function CL.GetFontPath()
    if CL.IsMatchPfui() and pfUI.font_default then
        return pfUI.font_default
    end
    local key = CL.GetSetting("fontKey") or "friz"
    local i
    for i = 1, table.getn(CL.FONTS) do
        if CL.FONTS[i].key == key then return CL.FONTS[i].path end
    end
    return "Fonts\\FRIZQT__.TTF"
end

function CL.GetFontSize()
    if CL.IsMatchPfui() and pfUI_config and pfUI_config.global and pfUI_config.global.font_size then
        return pfUI_config.global.font_size
    end
    return CL.GetSetting("fontSize") or 10
end

-- Applies the chosen font family to a FontString (at creation, and again
-- from appearance-changed listeners). `size` is for bar text, which the
-- "Font size" option controls; omit it elsewhere to keep the FontString's
-- own template size.
function CL.ApplyFont(fontString, size)
    if not fontString then return end
    if not size then
        local _, curSize = fontString:GetFont()
        size = curSize or CL.GetFontSize()
    end
    fontString:SetFont(CL.GetFontPath(), size, "OUTLINE")
end

-- Applies the font family (native sizes kept) to every FontString under
-- a frame. Callers that want bar text at CL.GetFontSize() apply that
-- afterwards.
function CL.ApplyFontToTree(frame)
    if not frame then return end
    local regions = { frame:GetRegions() }
    local i
    for i = 1, table.getn(regions) do
        local r = regions[i]
        if r.SetFont and r.GetFont then
            CL.ApplyFont(r)
        end
    end
    local children = { frame:GetChildren() }
    for i = 1, table.getn(children) do
        CL.ApplyFontToTree(children[i])
    end
end

-- The Options bar-height override, or the window's own `default`.
function CL.GetBarHeight(default)
    return CL.GetSetting("barHeight") or default
end

-- Frame strata, lowest to highest. Shadows sit one tier below their
-- window and dropdowns one tier above their anchor, so nothing from other
-- addons can land in between.
CL.STRATA_ORDER = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }

function CL.NextLowerStrata(strata)
    local i
    for i = 1, table.getn(CL.STRATA_ORDER) do
        if CL.STRATA_ORDER[i] == strata then
            return CL.STRATA_ORDER[math.max(1, i - 1)]
        end
    end
    return "BACKGROUND" -- unrecognized input - safest fallback
end

-- One tier above `strata` (used by CL.ShowDropdown).
function CL.NextHigherStrata(strata)
    local i
    for i = 1, table.getn(CL.STRATA_ORDER) do
        if CL.STRATA_ORDER[i] == strata then
            return CL.STRATA_ORDER[math.min(table.getn(CL.STRATA_ORDER), i + 1)]
        end
    end
    return "TOOLTIP" -- unrecognized input - safest fallback (definitely on top)
end

-- Window background alpha; only used while "Match pfUI" is off.
function CL.GetWindowOpacity()
    return (CL.GetSetting("windowOpacityPct") or 81) / 100
end

-- `fallback` is the window's own alpha, used while matching pfUI.
function CL.GetBackdropAlpha(fallback)
    if CL.IsMatchPfui() then return fallback end
    return CL.GetWindowOpacity()
end

-- Flat 1px-edged panel matching pfUI's default window backdrop; colors
-- are set separately with SetBackdropColor/SetBackdropBorderColor.
CL.WINDOW_BACKDROP = {
    bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
    edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
    insets = { left = -1, right = -1, top = -1, bottom = -1 },
}

-- Soft drop shadow (bundled img/glow2.tga, pfUI's), drawn 5px outside
-- the window on every side.
CL.WINDOW_SHADOW = {
    edgeFile = "Interface\\AddOns\\CombatLedger\\img\\glow2", edgeSize = 8,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

-- Near-black border used by the manual skin for windows and buttons.
-- Chrome stays neutral; only text is class-colored.
CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B = 0.059, 0.059, 0.059

-- Skins a window with pfUI's backdrop while "Match pfUI" is on, otherwise
-- with the manual flat backdrop. Called at creation and on every
-- appearance change, so it must switch cleanly both ways: pfUI's
-- CreateBackdrop puts its skin on child frames (f.backdrop,
-- f.backdrop_shadow) and clears f's own backdrop only the first time, so
-- manual mode hides those children and pfUI mode clears f's backdrop
-- itself every time.
function CL.ApplyWindowSkin(f, borderR, borderG, borderB, opacityFallback)
    if CL.IsMatchPfui() and pfUI.api then
        local ok = pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
        end)
        if ok and f.backdrop then
            f:SetBackdrop(nil)
            f.backdrop:Show()
            -- Border left as pfUI draws it; only text is class-colored.
            if f.backdrop_shadow then f.backdrop_shadow:Show() end
            return
        end
    end
    if f.backdrop then f.backdrop:Hide() end
    if f.backdrop_shadow then f.backdrop_shadow:Hide() end
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(opacityFallback))
    -- "Hide border" (manual skin only): the edge goes transparent.
    if CL.GetSetting("hideBorder") then
        f:SetBackdropBorderColor(0, 0, 0, 0)
    else
        f:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    end

    -- Manual-skin shadow: a child frame created once, then shown/hidden.
    if not CL.GetSetting("hideBorder") then
        if not f.flatShadow then
            f.flatShadow = CreateFrame("Frame", nil, f)
            -- One tier below the window's own strata (see STRATA_ORDER).
            f.flatShadow:SetFrameStrata(CL.NextLowerStrata(f:GetFrameStrata()))
            f.flatShadow:SetFrameLevel(1)
            f.flatShadow:SetPoint("TOPLEFT", f, "TOPLEFT", -5, 5)
            f.flatShadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 5, -5)
            f.flatShadow:SetBackdrop(CL.WINDOW_SHADOW)
        end
        f.flatShadow:SetBackdropBorderColor(0, 0, 0, 0.35)
        f.flatShadow:Show()
    elseif f.flatShadow then
        f.flatShadow:Hide()
    end
end

-- A header button's resting fill color: pfUI's configured background
-- while matching pfUI, otherwise the flat default. UI_MainWindow's
-- SetButtonTooltip re-asserts it every frame, so it must match whatever
-- skin is active.
function CL.GetButtonNormalFill()
    if CL.IsMatchPfui() and pfUI.api and pfUI.api.GetStringColor and pfUI_config then
        local ok, r, g, b, a = pcall(pfUI.api.GetStringColor, pfUI_config.appearance.border.background)
        if ok and r then return r, g, b, a end
    end
    return 0.12, 0.12, 0.14, 0.9
end

function CL.ApplyButtonSkin(btn, borderR, borderG, borderB)
    local matchedPfui = false
    if CL.IsMatchPfui() and pfUI.api then
        local ok = pcall(pfUI.api.SkinButton, btn, nil, nil, nil, nil, true)
        matchedPfui = ok
    end
    -- "Class colored menus" overrides the border in either skin.
    if CL.GetSetting("classColorMenus") then
        btn:SetBackdropBorderColor(borderR, borderG, borderB, 1)
    elseif not matchedPfui then
        btn:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    end
end

-- Shared click-menu (the meter's Mode/Segment buttons, Options pickers):
-- a plain frame with pooled rows instead of UIDropDownMenu. One can be
-- open at a time; an invisible full-screen catcher closes it on an
-- outside click.
local dropdownFrame = nil
local dropdownCatcher = nil -- full-screen invisible button that closes the menu on an outside click

function CL.CloseDropdown()
    if dropdownFrame then dropdownFrame:Hide() end
    if dropdownCatcher then dropdownCatcher:Hide() end
end

-- `options` is an array of { label, onClick, color (optional {r,g,b}) }.
function CL.ShowDropdown(anchor, options)
    if not dropdownCatcher then
        dropdownCatcher = CreateFrame("Button", nil, UIParent)
        dropdownCatcher:SetAllPoints(UIParent)
        dropdownCatcher:SetFrameLevel(1)
        dropdownCatcher:EnableMouse(true)
        dropdownCatcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        dropdownCatcher:SetScript("OnClick", CL.CloseDropdown)
    end
    if not dropdownFrame then
        dropdownFrame = CreateFrame("Frame", nil, UIParent)
        -- Same strata as the catcher, one level above it.
        dropdownFrame:SetFrameLevel(2)
        dropdownFrame:SetBackdrop(CL.WINDOW_BACKDROP)
        dropdownFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
        dropdownFrame:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
        dropdownFrame.rows = {}
    end

    -- One tier above the anchor's current strata, recomputed per open.
    local dropStrata = CL.NextHigherStrata(anchor:GetFrameStrata())
    dropdownCatcher:SetFrameStrata(dropStrata)
    dropdownFrame:SetFrameStrata(dropStrata)

    dropdownCatcher:Show()

    local ROW_H = 16
    local width = 150
    local count = table.getn(options)
    local height = count * ROW_H + 6
    dropdownFrame:SetWidth(width)
    dropdownFrame:SetHeight(height)
    dropdownFrame:ClearAllPoints()
    -- Opens upward when there's no room below the anchor.
    local anchorBottom = anchor:GetBottom() or 0
    if anchorBottom - height < 10 then
        dropdownFrame:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
    else
        dropdownFrame:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    end

    local i
    for i = 1, count do
        local row = dropdownFrame.rows[i]
        if not row then
            row = CreateFrame("Button", nil, dropdownFrame)
            row:SetHeight(ROW_H)
            row:EnableMouse(true)
            row:RegisterForClicks("LeftButtonUp")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetTexture("Interface\\Buttons\\WHITE8X8")
            hl:SetVertexColor(1, 1, 1, 0.15)
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("LEFT", row, "LEFT", 4, 0)
            text:SetJustifyH("LEFT")
            CL.ApplyFont(text)
            row.text = text
            dropdownFrame.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", dropdownFrame, "TOPLEFT", 3, -3 - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", dropdownFrame, "TOPRIGHT", -3, -3 - (i - 1) * ROW_H)
        row.text:SetText(options[i].label)
        -- Rows are pooled, so every row sets its color (white by default).
        local color = options[i].color
        if color then
            row.text:SetTextColor(color[1], color[2], color[3])
        else
            row.text:SetTextColor(1, 1, 1)
        end
        local onClick = options[i].onClick
        row:SetScript("OnClick", function()
            CL.CloseDropdown()
            if onClick then onClick() end
        end)
        row:Show()
    end
    local j
    for j = count + 1, table.getn(dropdownFrame.rows) do
        dropdownFrame.rows[j]:Hide()
    end

    dropdownFrame:Show()
end

function CL.IsSmoothBars()
    local v = CL.GetSetting("smoothBars")
    if v == nil then return true end
    return v
end

function CL.GetBarSpeed()
    return CL.GetSetting("barSpeed") or 8
end

-- Re-stacks a pooled bar list after a bar-height change (each bar's Y
-- offset depends on the height).
function CL.RepositionBarPool(pool, height, gap)
    local i
    for i = 1, table.getn(pool) do
        local bar = pool[i]
        bar:SetHeight(height)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", bar:GetParent(), "TOPLEFT", 0, -((i - 1) * (height + gap)))
        bar:SetPoint("TOPRIGHT", bar:GetParent(), "TOPRIGHT", 0, -((i - 1) * (height + gap)))
    end
end

-- Number formatting, shared by every window (Options: Number format).
CL.NUMBER_FORMATS = {
    { key = "abbreviated", label = "Abbreviated (1.2k)" },
    { key = "full", label = "Full (1,234)" },
    { key = "raw", label = "Raw (1234)" },
}

local function AddCommas(numStr)
    local formatted = numStr
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

-- Rate unit label per mode ("DPS", "HPS", "DTPS"; "/s" otherwise).
CL.RATE_SUFFIXES = { damage = "DPS", healing = "HPS", taken = "DTPS" }

function CL.RateSuffix(mode)
    return CL.RATE_SUFFIXES[mode] or "/s"
end

function CL.FormatNumber(n)
    n = n or 0
    if n < 0 then n = 0 end
    local mode = CL.GetSetting("numberFormat") or "abbreviated"
    if mode == "raw" then
        return tostring(math.floor(n))
    elseif mode == "full" then
        return AddCommas(tostring(math.floor(n)))
    end
    if n >= 1000000 then
        return string.format("%.1fm", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(math.floor(n))
end

-- Overheal/unverified lines for any healing bucket or spell entry (see
-- Aggregator.lua's AddHeal), shared by the main tooltip and the breakdown
-- panel. addLine(label, value, dim). Entries without `raw` (saved before
-- overheal tracking) show nothing.
function CL.AddOverhealLines(t, addLine)
    local raw = t and t.raw
    if not raw or raw <= 0 then return end
    local over = t.overheal or 0
    addLine("Overheal (est.)", string.format("%s (%.0f%%)", CL.FormatNumber(over), over / raw * 100))
    local unverified = t.unverified or 0
    if unverified > 0 then
        addLine("Unverified", string.format("%s (%.0f%%)", CL.FormatNumber(unverified), unverified / raw * 100), true)
    end
end

-- Display order for avoidance/miss outcomes. Melee entries always carry
-- the first set (Aggregator.lua's NewAvoided); spell misses
-- (SPELL_MISS_*) can add resist/absorb/reflect, so every key is optional.
CL.AVOID_KEYS = { "dodge", "parry", "miss", "resist", "block", "absorb", "reflect", "evade", "immune", "deflect", "other" }

-- Returns the total count and a "3 dodge, 1 parry" summary (nil if empty).
function CL.SummarizeAvoided(av)
    if not av then return 0, nil end
    local total, parts = 0, {}
    local i
    for i = 1, table.getn(CL.AVOID_KEYS) do
        local key = CL.AVOID_KEYS[i]
        local n = av[key] or 0
        if n > 0 then
            total = total + n
            table.insert(parts, n .. " " .. key)
        end
    end
    if total == 0 then return 0, nil end
    return total, table.concat(parts, ", ")
end

-- Mitigation lines for anything carrying a `mit` table (Aggregator.lua's
-- ApplyMitigation), shared by the main tooltip and the breakdown panel.
-- meleeHits = the hit count glancing/crushing percentages are taken of
-- (they only ever happen on white melee swings). addLine(label, value).
function CL.AddMitigationLines(t, meleeHits, addLine)
    local m = t and t.mit
    if not m then return end
    local function Amount(label, key)
        local amount = m[key] or 0
        if amount > 0 then
            local n = m[key .. "Hits"] or 0
            addLine(label, string.format("%s (%d %s)", CL.FormatNumber(amount), n, (n == 1) and "hit" or "hits"))
        end
    end
    local function Count(label, key)
        local n = m[key] or 0
        if n > 0 then
            if meleeHits and meleeHits > 0 then
                addLine(label, string.format("%d (%.0f%%)", n, n / meleeHits * 100))
            else
                addLine(label, tostring(n))
            end
        end
    end
    Amount("Absorbed", "absorbed")
    Amount("Blocked", "blocked")
    Amount("Resisted", "resisted")
    Count("Glancing", "glancing")
    Count("Crushing", "crushing")
end

-- Appearance-changed notifications: each UI file registers a listener
-- that re-applies fonts/textures/sizes; Options fires it after a change.
CL.appearanceListeners = {}

function CL.OnAppearanceChanged(fn)
    table.insert(CL.appearanceListeners, fn)
end

function CL.FireAppearanceChanged()
    local i
    for i = 1, table.getn(CL.appearanceListeners) do
        local ok, err = pcall(CL.appearanceListeners[i])
        if not ok then
            CL.Print("Appearance listener error: " .. tostring(err))
        end
    end
end

-- Icon for melee rows, which have no spellId to look an icon up from.
CL.MELEE_ICON = "Interface\\Icons\\Ability_MeleeDamage"

-- Class icon atlas coordinates (img/classicons.tga, 4x3 grid). Kept
-- locally since CLASS_ICON_TCOORDS isn't guaranteed on this client.
CL.CLASS_ICON_TCOORDS = {
    WARRIOR = { 0, 0.25, 0, 0.25 },
    MAGE = { 0.25, 0.49609375, 0, 0.25 },
    ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
    DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
    HUNTER = { 0, 0.25, 0.25, 0.5 },
    SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 },
    WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
    PALADIN = { 0, 0.25, 0.5, 0.75 },
}

-- spellId -> icon texture via the spell DBC, so it works for any spell
-- seen in combat, not only the player's own spellbook.
function CL.GetSpellIcon(spellId)
    if not spellId then return nil end
    if type(GetSpellRecField) ~= "function" or type(GetSpellIconTexture) ~= "function" then return nil end
    local okId, iconId = pcall(GetSpellRecField, spellId, "spellIconID")
    if not okId or not iconId or iconId <= 0 then return nil end
    local okTex, tex = pcall(GetSpellIconTexture, iconId)
    if okTex and type(tex) == "string" and tex ~= "" then
        return tex
    end
    return nil
end


-- Addon accent color (epic purple).
CL.ACCENT_HEX = "a335ee"
CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B = 0.64, 0.21, 0.93

-- Theme color for window chrome and titles: the player's class color,
-- or the accent if that can't be read. Returns r, g, b, hex.
function CL.GetThemeColor()
    local ok, _, classToken = pcall(UnitClass, "player")
    if ok and classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b, string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B, CL.ACCENT_HEX
end

-- Announce channels. "auto" resolves at announce time: raid, else
-- party, else say.
-- Choices for the automatic Overall reset rules.
CL.RESET_MODES = {
    { key = "off", label = "Off" },
    { key = "ask", label = "Ask" },
    { key = "always", label = "Always" },
}

CL.ANNOUNCE_CHANNELS = {
    { key = "auto", label = "Auto (raid/party)" },
    { key = "say", label = "Say" },
    { key = "party", label = "Party" },
    { key = "raid", label = "Raid" },
    { key = "guild", label = "Guild" },
}

function CL.ResolveAnnounceChannel()
    local key = CL.GetSetting("announceChannel") or "auto"
    if key == "auto" then
        if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
        if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
        return "SAY"
    end
    return string.upper(key)
end

-- Bounds for Options' "Saved fights" (setting maxEncounters) - see
-- History.lua's trim-oldest cap.
CL.MIN_SAVED_FIGHTS, CL.MAX_SAVED_FIGHTS, CL.SAVED_FIGHTS_STEP = 5, 50, 5

function CL.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff" .. CL.ACCENT_HEX .. "CombatLedger:|r " .. msg)
end

--------------------------------------------------------------------------
-- Diagnostics (shown by /cl status)
--
-- Event handlers and OnUpdate ticks run under pcall and report failures
-- here instead of letting one bad event break a handler for the session.
-- Each error tag is announced in chat once; repeats are only counted.
--------------------------------------------------------------------------

CL.Diagnostics = {
    eventCounts = {}, -- [eventName] = times received this session
    errorCounts = {}, -- [tag] = errors caught this session
    lastErrors = {},  -- [tag] = most recent error message
}

function CL.CountEvent(name)
    local counts = CL.Diagnostics.eventCounts
    counts[name] = (counts[name] or 0) + 1
end

function CL.RecordError(tag, err)
    tag = tostring(tag)
    local d = CL.Diagnostics
    local first = d.errorCounts[tag] == nil
    d.errorCounts[tag] = (d.errorCounts[tag] or 0) + 1
    d.lastErrors[tag] = tostring(err)
    if first then
        CL.Print("|cffff4040error|r in " .. tag .. ": " .. tostring(err) .. " (further ones are counted in /cl status)")
    end
    if CL.debug then CL.LogLine("[ERROR] " .. tag .. ": " .. tostring(err)) end
end

-- Debug logging to CL.LOG_FILENAME (/cl debug). Off by default.
CL.debug = false

-- The persisted debug flag is restored on PLAYER_ENTERING_WORLD
-- (SavedVariables aren't loaded yet when this file runs). Core loads
-- first, so this handler runs before any other file's handler for the
-- same event and debug output covers login too.
local debugRestoreFrame = CreateFrame("Frame")
debugRestoreFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
debugRestoreFrame:SetScript("OnEvent", function()
    CL.debug = (CombatLedgerDB.settings.debug == true)
end)

-- Test mode (session only): windows show fabricated data for previewing
-- appearance (Aggregator.GetTestEncounter).
CL.testMode = false

-- Number of keys in any table (table.getn only counts the array part).
function CL.TableCount(t)
    local n = 0
    local _
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Is the single power-of-two `bit` set in `value`? Lua 5.0 has no
-- bitwise operators, so this is floor(value / bit) mod 2 == 1.
function CL.HasBit(value, bit)
    if not value then return false end
    return math.mod(math.floor(value / bit), 2) == 1
end

-- hitInfo bits. AUTO_ATTACK_* and SPELL_DAMAGE_EVENT_* use different
-- bitfields: on auto-attacks (the MaNGOS HITINFO_* enum) 0x02 is set on
-- every landed swing, on spell damage 0x02 means crit.
CL.AUTO_ATTACK_HITFLAG_CRIT = 128
CL.AUTO_ATTACK_HITFLAG_GLANCING = 16384
CL.AUTO_ATTACK_HITFLAG_CRUSHING = 32768
CL.AUTO_ATTACK_HITFLAG_OFFHAND = 4
CL.SPELL_DAMAGE_HITFLAG_CRIT = 2

-- AUTO_ATTACK victimState values (MaNGOS VICTIMSTATE_*). An avoided
-- swing arrives as a 0-damage AUTO_ATTACK with one of these.
CL.VICTIMSTATE_MISS = 0
CL.VICTIMSTATE_NORMAL = 1
CL.VICTIMSTATE_DODGE = 2
CL.VICTIMSTATE_PARRY = 3
CL.VICTIMSTATE_INTERRUPT = 4
CL.VICTIMSTATE_BLOCK = 5
CL.VICTIMSTATE_EVADE = 6
CL.VICTIMSTATE_IMMUNE = 7
CL.VICTIMSTATE_DEFLECT = 8

--------------------------------------------------------------------------
-- File-based debug log (WriteCustomFile, Nampower v3.2+)
--------------------------------------------------------------------------

CL.LOG_FILENAME = "CombatLedger_debug.log"

local logBuffer = {}
local loggedThisSession = false -- first flush of a session overwrites (fresh file per test), later ones append

-- LogLine only buffers; FlushLog (once a second from Events.lua, and at
-- encounter end) writes the batch, so combat doesn't cost a file write
-- per event. The first flush of a session overwrites the file.
function CL.LogLine(line)
    table.insert(logBuffer, line)
end

function CL.FlushLog()
    if table.getn(logBuffer) == 0 then return end
    if not WriteCustomFile then
        -- Nothing can ever write it out - don't let it grow forever.
        logBuffer = {}
        return
    end

    local content = table.concat(logBuffer, "\n") .. "\n"
    local mode = loggedThisSession and "a" or "w"
    local ok = pcall(WriteCustomFile, CL.LOG_FILENAME, content, mode)
    if ok then
        loggedThisSession = true
        logBuffer = {}
    end
    -- On failure the buffer is kept and retried on the next flush.
end

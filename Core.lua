--[[
    CombatLedger v0.3.0

    A combat meter built on Nampower's structured combat events
    (AUTO_ATTACK_SELF/OTHER, SPELL_DAMAGE_EVENT_SELF/OTHER, SPELL_HEAL_BY_*,
    SPELL_DISPEL_*, AURA_CAST_ON_*/DEBUFF_ADDED_*) instead of parsing
    CHAT_MSG_COMBAT_* text like most vanilla meters - real numeric fields
    (damage amount, spell ID, hit type) instead of regexing a localized
    string.

    Tracks Damage/Healing/Damage Taken/Dispels/Debuffs Given/Deaths, each
    with a click-through per-ability/per-target breakdown, across any
    number of independent meter windows (see UI_MainWindow.lua), plus
    Current Fight/Overall/saved History segments and a death recap. Set
    CL.debug = true (or /cl debug) to log every raw event to
    CL.LOG_FILENAME via LogLine/FlushLog below - chat gets unreadable fast
    under real combat event volume, so verification goes to a plain file
    instead.
]]

-- Shared namespace table - every other file attaches its own pieces to
-- this (CL.GuidCache, CL.Aggregator, ...) since plain `local`s don't
-- cross file boundaries the way they do in LootLedger's single-file
-- layout. Each file starts with `local CL = CombatLedger`.
CombatLedger = CombatLedger or {}
local CL = CombatLedger

CombatLedgerDB = CombatLedgerDB or { encounters = {} }
CombatLedgerDB.encounters = CombatLedgerDB.encounters or {}
CombatLedgerDB.settings = CombatLedgerDB.settings or {}
CL.db = CombatLedgerDB

-- Encounter-end timing - deliberately NOT a user setting (no Options
-- control, no /cl set). Combat dropping (PLAYER_REGEN_ENABLED) IS the
-- end of an encounter, immediately, no tolerance window - see Events.lua.
-- This is the one remaining fallback: some targets (training dummies on
-- at least this server) never toggle the regen flag at all, so an
-- encounter against one would otherwise never end. No combat event of
-- any kind for this long force-ends it regardless of regen state.
CL.IDLE_SECONDS = 12

-- Tunable settings, saved-variable-backed so they survive /reload and
-- exposed in the Options window - see UI_Options.lua.
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
    windowOpacityPct = 85, -- background alpha, as a percent - ignored while matchPfui is on
    autoShowInCombat = true,
    autoHideOutOfCombat = false,
    announcePulls = true, -- "Pull: X (spell)" chat print at the start of a boss/elite encounter - see Aggregator.lua's RecordDamage
}

-- Defensive rather than relying purely on the load-time "or {}" above:
-- this client restores saved variables from disk AFTER Core.lua's own
-- init line runs, and that restore REPLACES CombatLedgerDB wholesale -
-- an existing save from before .settings existed wipes it back to nil.
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

-- Per-window size/position, saved-variable-backed same as settings
-- above (same defensive EnsureX pattern, same reason - this client
-- replaces CombatLedgerDB wholesale on restore, after Core.lua's own
-- init line runs). `key` is a short per-window id ("main", "breakdown",
-- "deathRecap", "history").
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

-- Applies a saved layout if one exists (returns true), otherwise leaves
-- the frame's already-set default width/height/point alone (false).
-- minW/minH/maxW/maxH are optional - clamps a saved size into a
-- window's current bounds, since a size saved under an earlier layout
-- (before a resize/redesign changed that window's min size) could
-- otherwise restore smaller than the new layout can actually fit,
-- leaving elements overlapping instead of properly stacked.
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

-- Multi-window support: which extra meter windows (beyond the always-
-- present "main") should exist, and each window's own mode/segment
-- choice - same defensive EnsureX/wholesale-replace reasoning as
-- settings/layout above. Presence of a non-"main" key is what makes
-- UI_MainWindow.lua's UI.RestoreExtraWindows() recreate that window on
-- login; UI.CloseExtraWindow removes its key so it doesn't come back.
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

-- Shared by every StatusBar-based window (UI_MainWindow, UI_Breakdown,
-- UI_DeathRecap) so the meter's bars actually match pfUI's own bars
-- instead of looking like a different addon. pfUI.media["img:bar"] is
-- the exact texture pfUI itself uses for every one of its bars (and
-- what it applies when it skins other addons' status bars too - see
-- pfUI/modules/thirdparty-vanilla.lua).
function CL.HasPfui()
    return pfUI ~= nil
end

-- "Match pfUI" (default on) mirrors pfUI's own bar texture/font exactly,
-- same as this addon's bars did before Options existed. Turning it off
-- unlocks the manual barTexture/fontKey/fontSize choices below - the
-- Options window greys those controls out while this is on, since
-- they'd have no visible effect.
function CL.IsMatchPfui()
    return CL.HasPfui() and (CL.GetSetting("matchPfui") ~= false)
end

-- "Flat" is pfUI's own default bar look (img/bar.tga), bundled directly
-- in this addon's own img/ folder (MIT-licensed from pfUI - see
-- README) so it's available and looks identical whether or not pfUI is
-- actually installed - this used to be exclusive to pfUI users via
-- "Match pfUI", which only helps if you already run pfUI. It's the
-- default (see CL.defaultSettings) - Blizzard/Smooth Gradient are still
-- here for anyone who wants the classic look back. The remaining pfUI_*
-- entries stay pfUI-sourced (elvui/gradient/striped/tukui skins aren't
-- bundled, only pfUI's default) - `pfui` is the pfUI.media key (see
-- pfUI.lua's img: path resolution) for those.
CL.BAR_TEXTURES = {
    { key = "flat", label = "Flat (default)" },
    { key = "blizzard", label = "Blizzard Default" },
    { key = "raid", label = "Smooth Gradient" },
    { key = "pfui_elvui", label = "ElvUI Style", pfui = "img:bar_elvui" },
    { key = "pfui_gradient", label = "pfUI Gradient", pfui = "img:bar_gradient" },
    { key = "pfui_striped", label = "Striped", pfui = "img:bar_striped" },
    { key = "pfui_tukui", label = "TukUI Style", pfui = "img:bar_tukui" },
}

-- Filters out the pfUI-sourced entries when pfUI isn't installed (those
-- files live inside pfUI's own addon folder) - safe to call any time
-- after full addon load, which every caller of this does (Options only
-- opens well after that).
function CL.GetAvailableBarTextures()
    if CL.HasPfui() then return CL.BAR_TEXTURES end
    local list = {}
    local i
    for i = 1, table.getn(CL.BAR_TEXTURES) do
        if not CL.BAR_TEXTURES[i].pfui then
            table.insert(list, CL.BAR_TEXTURES[i])
        end
    end
    return list
end

function CL.GetBarTexture()
    if CL.IsMatchPfui() and pfUI.media and pfUI.media["img:bar"] then
        return pfUI.media["img:bar"]
    end
    local key = CL.GetSetting("barTexture") or "flat"
    if key == "flat" then
        return "Interface\\AddOns\\CombatLedger\\img\\bar"
    end
    if key == "raid" then
        return "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"
    end
    if key ~= "blizzard" then
        local i
        for i = 1, table.getn(CL.BAR_TEXTURES) do
            local t = CL.BAR_TEXTURES[i]
            if t.key == key and t.pfui and CL.HasPfui() and pfUI.media then
                return pfUI.media[t.pfui]
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

-- Applies the current font CHOICE to any FontString - call at creation
-- and again from an appearance-changed listener (see below) so already-
-- created FontStrings pick up a change without a /reload.
--
-- `size` is optional - pass CL.GetFontSize() explicitly for bar text
-- (the one thing the "Font size" Options slider is meant to control).
-- Everywhere else, omit it: the font FAMILY should apply everywhere
-- (title bars, labels, Options controls, ...), but a title shouldn't
-- shrink down to bar-text size just because the family changed, so
-- this preserves whatever size the FontString already had (its
-- template's size, e.g. GameFontNormalLarge vs GameFontHighlightSmall).
function CL.ApplyFont(fontString, size)
    if not fontString then return end
    if not size then
        local _, curSize = fontString:GetFont()
        size = curSize or CL.GetFontSize()
    end
    fontString:SetFont(CL.GetFontPath(), size, "OUTLINE")
end

-- Walks a frame and every descendant, applying the font CHOICE (native
-- size preserved, same as a bare CL.ApplyFont call) to every FontString
-- found - covers titles/headers/checkbox labels/stepper values/etc
-- without having to hand-instrument each one at creation time. Safe to
-- call on a whole window; a caller that wants specific elements (bar
-- text) at CL.GetFontSize() should call CL.ApplyFont on those AFTER
-- this, since this only ever preserves native size.
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

-- Bar height is per-window by default (each meter window has its own
-- sensible built-in constant) but Options can override all of them at
-- once - `default` is that window's own constant, used when no override
-- is set.
function CL.GetBarHeight(default)
    return CL.GetSetting("barHeight") or default
end

-- Background alpha for every window's backdrop - only applied while
-- "Match pfUI" is off (pfUI's own skin governs backdrop appearance
-- otherwise, so this would have no visible effect and Options greys the
-- control out).
function CL.GetWindowOpacity()
    return (CL.GetSetting("windowOpacityPct") or 85) / 100
end

-- `fallback` is a window's own original backdrop alpha, used while
-- "Match pfUI" is on (pfUI's skin governs the look then, so the manual
-- opacity setting would have no visible effect anyway).
function CL.GetBackdropAlpha(fallback)
    if CL.IsMatchPfui() then return fallback end
    return CL.GetWindowOpacity()
end

CL.WINDOW_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- Applies pfUI's own skin to a window's backdrop when "Match pfUI" is on
-- (and pfUI is loaded), otherwise (re)applies this addon's own plain
-- backdrop at the chosen opacity - called both at window creation and
-- from the appearance-changed listener, so toggling the setting at
-- runtime actually changes the window's look instead of only whichever
-- one was true at creation time sticking forever. `borderR/G/B` is the
-- border color to use either way.
--
-- pfUI.api.CreateBackdrop does NOT skin `f` directly - it blanks f's own
-- backdrop (SetBackdrop(nil)) and parks its skin on a separate child
-- frame (f.backdrop, plus f.backdrop_shadow from CreateBackdropShadow),
-- and only creates that child once (later calls just reposition/re-skin
-- the existing one). Switching to manual mode has to explicitly Hide()
-- those children (they don't go away on their own) and restore f's own
-- backdrop; switching back to pfUI mode has to explicitly null f's own
-- backdrop again (CreateBackdrop only does that the very first time) -
-- otherwise toggling the setting either leaves an orphaned pfUI border/
-- shadow behind, or leaves our manual backdrop fighting with pfUI's.
function CL.ApplyWindowSkin(f, borderR, borderG, borderB, opacityFallback)
    if CL.IsMatchPfui() and pfUI.api then
        local ok = pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
        end)
        if ok and f.backdrop then
            f:SetBackdrop(nil)
            f.backdrop:Show()
            -- Deliberately NOT re-tinting the border to theme color here
            -- - "Match pfUI" means look like pfUI, full stop; only text
            -- (title, bar names, ...) stays class-colored.
            if f.backdrop_shadow then f.backdrop_shadow:Show() end
            return
        end
    end
    if f.backdrop then f.backdrop:Hide() end
    if f.backdrop_shadow then f.backdrop_shadow:Hide() end
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(opacityFallback))
    -- ShaguDPS-style borderless option - just the edge line goes
    -- transparent, background/bars are unaffected. Independent of
    -- matchPfui (only applies in this manual-skin branch; pfUI's own
    -- skin bakes its border into one texture, not selectively hideable).
    if CL.GetSetting("hideBorder") then
        f:SetBackdropBorderColor(0, 0, 0, 0)
    else
        f:SetBackdropBorderColor(borderR, borderG, borderB, 1)
    end
end

-- Skins a small manually-built button (CreateHeaderButton-style: own
-- backdrop already set, hover/tooltip already wired via SetScript
-- before this runs) with pfUI's look while Match pfUI is on, otherwise
-- just asserts the theme border color. Unlike CreateBackdrop, pfUI's
-- SkinButton sets the backdrop directly on the button itself (no child
-- frame), so there's no orphaned-frame cleanup needed here.
--
-- "Match pfUI" means look like pfUI, full stop - border color is left
-- to pfUI's own skin (not re-tinted to theme), and pfUI's own hover
-- highlight is left enabled (SetButtonTooltip's own border-highlight
-- self-disables via CL.IsMatchPfui() so the two don't fight over the
-- same border on hover).
function CL.ApplyButtonSkin(btn, borderR, borderG, borderB)
    if CL.IsMatchPfui() and pfUI.api then
        local ok = pcall(pfUI.api.SkinButton, btn)
        if ok then return end
    end
    btn:SetBackdropBorderColor(borderR, borderG, borderB, 1)
end

function CL.IsSmoothBars()
    local v = CL.GetSetting("smoothBars")
    if v == nil then return true end
    return v
end

function CL.GetBarSpeed()
    return CL.GetSetting("barSpeed") or 8
end

-- Repositions a pooled bar list (StatusBar frames anchored TOPLEFT/
-- TOPRIGHT to their own parent, stacked by index - the pattern every
-- bar pool in this addon uses) after a bar-height change, since each
-- bar's Y offset was computed from the height at creation time.
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

-- Number formatting - shared so every window's numbers change together
-- from one Options setting instead of each having its own baked-in
-- k/m-abbreviation logic.
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

-- "253 DPS" instead of "253/s" - mode-aware (HPS for healing, DTPS for
-- damage taken) rather than blindly always saying DPS, since that would
-- be wrong while looking at Healing Done.
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

-- Appearance-changed pub/sub - each UI file registers a listener that
-- re-applies font/texture/bar-height/number-format to its own pooled
-- bars; Options fires this once after any change so every open window
-- updates immediately instead of needing a /reload.
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

-- Generic icon for melee entries (Auto Attack/Off-Hand have no spellId
-- to look an icon up from).
CL.MELEE_ICON = "Interface\\Icons\\Ability_MeleeDamage"

-- spellId -> icon texture path. GetSpellRecField's "spellIconID" field
-- gives a numeric icon id, which GetSpellIconTexture resolves to a real
-- texture path - covers any spellId seen in combat, not just ones in
-- the player's own spellbook (GetSpellTexture only works for that,
-- useless for other units' abilities).
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


-- WoW's own epic-quality purple hex, used for visual consistency with
-- the author's other addons.
CL.ACCENT_HEX = "a335ee"
CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B = 0.64, 0.21, 0.93

-- Window chrome (borders, buttons, non-unit-specific titles) themes
-- itself to the player's own class color rather than the fixed purple
-- accent above - per-unit content (bars, breakdown/recap titles) still
-- colors by whichever unit it's showing, which is a different, correct
-- thing. Falls back to the purple accent if class lookup ever fails.
function CL.GetThemeColor()
    local ok, _, classToken = pcall(UnitClass, "player")
    if ok and classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b, string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B, CL.ACCENT_HEX
end

-- "auto" resolves to whichever of these the player is actually in
-- (raid > party), falling back to Say if solo - chosen at announce time,
-- not stored, since group status can change between one announce and
-- the next.
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

CL.MAX_ENCOUNTERS = 50 -- same trim-oldest cap pattern as LootLedger's MAX_HISTORY_ENTRIES

function CL.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff" .. CL.ACCENT_HEX .. "CombatLedger:|r " .. msg)
end

-- Debug event/aggregation logging, off by default - toggle with /cl
-- debug when troubleshooting. Goes to a file (LogLine/FlushLog), not
-- chat - see the file-header note.
CL.debug = false

-- Session-only (not saved) - fills every meter window with fabricated
-- data so appearance settings can be previewed without needing to
-- actually fight something. See Aggregator.lua's GetTestEncounter and
-- UI_Options.lua's toggle.
CL.testMode = false

-- table.getn/pairs-based count - Lua 5.0 has no # operator.
function CL.TableCount(t)
    local n = 0
    local _
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Lua 5.0 has no bitwise operators (and no guaranteed `bit` library on
-- this client) - checks whether a single power-of-two bit is set in
-- value by hand: floor(value/bit) mod 2 == 1. `bit` must itself be a
-- power of two (128, 16384, ...), not a combined mask.
function CL.HasBit(value, bit)
    if not value then return false end
    return math.mod(math.floor(value / bit), 2) == 1
end

-- AUTO_ATTACK_SELF/OTHER's hitInfo and SPELL_DAMAGE_EVENT_SELF/OTHER's
-- hitInfo are different bitfields, not the same convention reused -
-- 0x02 means "normal swing landed" (present on every auto-attack hit)
-- for the former, but means "critical hit" for the latter. The
-- auto-attack side matches the well-known MaNGOS/TrinityCore HITINFO_*
-- enum.
CL.AUTO_ATTACK_HITFLAG_CRIT = 128
CL.AUTO_ATTACK_HITFLAG_GLANCING = 16384
CL.AUTO_ATTACK_HITFLAG_CRUSHING = 32768
CL.AUTO_ATTACK_HITFLAG_OFFHAND = 4
CL.SPELL_DAMAGE_HITFLAG_CRIT = 2

-- dodge/parry/miss on this server do not arrive as separate
-- SPELL_MISS_* events - they arrive as a dmg=0 AUTO_ATTACK with one of
-- these victimState values instead. block/evade/immune/deflect are the
-- standard MaNGOS-family VICTIMSTATE_* values, kept here for forward
-- compatibility rather than folding them into "other".
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

-- LogLine buffers rather than writing immediately - combat events can
-- fire many times a second, and a WriteCustomFile call per line would be
-- a lot of disk I/O during a real fight. FlushLog (called periodically
-- from Events.lua's OnUpdate, and on the grace-window encounter-end)
-- batches the buffer into one write.
function CL.LogLine(line)
    table.insert(logBuffer, line)
end

function CL.FlushLog()
    if table.getn(logBuffer) == 0 then return end
    if not WriteCustomFile then return end

    local content = table.concat(logBuffer, "\n") .. "\n"
    local mode = loggedThisSession and "a" or "w"
    local ok = pcall(WriteCustomFile, CL.LOG_FILENAME, content, mode)
    if ok then
        loggedThisSession = true
        logBuffer = {}
    end
    -- on failure, leave the buffer intact and retry on the next flush
    -- rather than silently dropping data
end

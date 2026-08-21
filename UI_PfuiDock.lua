--[[
    UI_PfuiDock - optional integration that docks the main meter window
    into pfUI's right-side chat panel, toggled by the same ">" button
    other third-party meters (TWThreat, SW_Stats, KTM) already use there
    - pfUI.thirdparty.meters:RegisterMeter is pfUI's own, real API for
    this (see pfUI/modules/thirdparty.lua and thirdparty-vanilla.lua for
    reference - GreedMeter's own pfUI dock support follows the same
    contract). Purely additive: CombatLedger works completely normally
    without this, and without pfUI installed at all - opt-in via
    Options, off by default, since docking moves/resizes the window.

    Contract: RegisterMeter(side, data) where side is "damage" or
    "threat" (pfUI only has two dock slots, first addon to claim a side
    wins - CombatLedger only ever claims "damage"), and data is
    { configKey, addonName, frameNameOrRef, single, dual, show, hide }.
    single() lays out full width (the other slot unclaimed); dual() lays
    out half width (both slots claimed, by anyone - not necessarily two
    CombatLedger windows). pfUI calls show/hide when the whole dock
    panel toggles via the chat button.
]]

local CL = CombatLedger

local function HasDockAPI()
    return CL.HasPfui() and pfUI.thirdparty and pfUI.thirdparty.meters and pfUI.thirdparty.meters.RegisterMeter
end

local function GetMainFrame()
    return CL.UIWindows and CL.UIWindows["main"] and CL.UIWindows["main"].frame
end

-- Re-lays out bars/content for the new width - CL.UI.Refresh() already
-- does exactly this for the main window on every normal resize (see
-- the resize grip in UI_MainWindow.lua), reused here rather than
-- duplicating that logic.
local function RelayoutDocked()
    if CL.UI and CL.UI.Refresh then CL.UI.Refresh() end
end

local function DockSingle()
    local f = GetMainFrame()
    if not f or not pfUI or not pfUI.chat or not pfUI.chat.right then return end
    f:ClearAllPoints()
    f:SetAllPoints(pfUI.chat.right)
    f:SetWidth(pfUI.chat.right:GetWidth())
    RelayoutDocked()
end

local function DockDual()
    local f = GetMainFrame()
    if not f or not pfUI or not pfUI.chat or not pfUI.chat.right then return end
    -- Right half - matches where pfUI's own third-party addons put a
    -- "damage"-slot meter when a "threat"-slot one is also docked.
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", pfUI.chat.right, "TOP", 0, 0)
    f:SetPoint("BOTTOMRIGHT", pfUI.chat.right, "BOTTOMRIGHT", 0, 0)
    f:SetWidth(pfUI.chat.right:GetWidth() / 2)
    RelayoutDocked()
end

local function DockShow()
    local f = GetMainFrame()
    if f then f:Show() end
end

local function DockHide()
    local f = GetMainFrame()
    if f then f:Hide() end
end

-- pfUI's own third-party config lives in the pfUI_config SavedVariable
-- (aliased as a bare `C` only inside pfUI's own module environment -
-- not a real global outside it, so this addon has to go through
-- pfUI_config directly). RegisterMeter only actually claims the dock
-- slot when C.thirdparty[configKey].dock == "1", so this has to be set
-- before calling it.
local function EnsurePfuiConfig()
    if not pfUI_config then return false end
    pfUI_config.thirdparty = pfUI_config.thirdparty or {}
    if not pfUI_config.thirdparty.combatledger then
        pfUI_config.thirdparty.combatledger = { dock = "1", skin = "1" }
    else
        pfUI_config.thirdparty.combatledger.dock = "1"
        if pfUI_config.thirdparty.combatledger.skin == nil then
            pfUI_config.thirdparty.combatledger.skin = "1"
        end
    end
    return true
end

local registered = false

function CL.TryRegisterPfuiDock()
    if registered then return true end
    if not CL.GetSetting("pfuiDock") then return false end
    if not HasDockAPI() then return false end
    if not GetMainFrame() then return false end
    if not EnsurePfuiConfig() then return false end

    if pfUI.thirdparty.meters.damage then
        CL.Print("pfUI's damage dock slot is already taken by another addon.")
        return false
    end

    local docktable = {
        "combatledger",
        "CombatLedger",
        "CombatLedgerMainWindow",
        DockSingle,
        DockDual,
        DockShow,
        DockHide,
    }
    pfUI.thirdparty.meters:RegisterMeter("damage", docktable)
    registered = true
    CL.Print("Docked into pfUI's right chat panel - use the > button there to toggle it.")
    if pfUI.thirdparty.meters.Resize then pfUI.thirdparty.meters:Resize() end
    return true
end

-- Undoing a live registration isn't supported by pfUI's own API (there's
-- no UnregisterMeter) - same limitation GreedMeter's own integration
-- has, hence its "/reload to fully clear dock slots" messaging. This
-- just restores the window to a normal floating frame; the dock slot
-- itself stays claimed until the next reload.
function CL.UndockFromPfui()
    local f = GetMainFrame()
    if f then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        f:Show()
        RelayoutDocked()
    end
    if registered then
        CL.Print("Undocked - the window is floating again. Fully re-enabling later needs a /reload.")
    end
end

-- Same delayed-retry shape as GreedMeter's own integration - pfUI's
-- chat panel (pfUI.chat.right) may not exist yet the instant this file
-- executes, even once IsAddOnLoaded("pfUI") is already true.
local delayFrame = CreateFrame("Frame")
local elapsed = 0
delayFrame:SetScript("OnUpdate", function()
    elapsed = elapsed + arg1
    if elapsed > 2 then
        delayFrame:SetScript("OnUpdate", nil)
        CL.TryRegisterPfuiDock()
    end
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function()
    CL.TryRegisterPfuiDock()
end)

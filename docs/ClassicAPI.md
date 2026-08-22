# ClassicAPI Reference for CombatLedger

**Repository:** [brues-code/ClassicAPI](https://github.com/brues-code/ClassicAPI)

ClassicAPI is a lightweight DLL modification for the World of Warcraft 1.12.1 client (used by Turtle WoW / Octo WoW). It hooks directly into the `FrameScript` engine at boot, exposing a large collection of modern Blizzard Lua functions that were introduced in later expansions (like 3.3.5+). 

By using ClassicAPI, CombatLedger avoids writing slow, hacky polyfills for missing functions and can instead use modern WoW Lua paradigms.

## Core Capabilities

No companion addon is required for ClassicAPI; it registers its extensions natively. 

### Key Modules and Functions

*   **Lua Core Enhancements (`Lua`)**:
    *   Adds `string.gmatch`, `string.match`, `strsplit`, `strjoin`, `strreplace`.
    *   Adds table utilities like `table.wipe`, `table.count`, and `math.modf`.
    *   Provides `hooksecurefunc` for safe function detouring without tainting.
*   **Frame & UI Improvements (`Frame`, `GameTooltip`)**:
    *   `frame:SetShown(bool)`, `region:SetSize(w, h)`, `frame:SetAttribute`.
    *   `fontstring:SetMaxLines`, `fontstring:IsTruncated`.
    *   `GameTooltip:SetSpellByID`, `GameTooltip:SetItemByID`, `GameTooltip:GetUnitGUID`.
*   **Modern Unit & Item APIs (`Item`, `Container`, `Creature`)**:
    *   `C_Item.GetItemInfo`, `C_Item.GetItemCount`, `C_Item.GetItemIcon`.
    *   `C_Container.GetContainerItemInfo`, `C_Container.GetContainerNumFreeSlots`.
    *   `C_CreatureInfo.GetCreatureID`.
*   **Nameplates & Faction**:
    *   `C_NamePlate.GetNamePlateForGUID`, `C_NamePlate.GetNamePlateForUnit`.

## Development Guidelines

1.  **Assume Modern Tools**: If you need to manipulate strings or tables, check if ClassicAPI has ported the standard modern Lua functions (`strsplit`, `table.wipe`) before writing a custom helper.
2.  **UI Construction**: Use `SetShown` instead of `if show then frame:Show() else frame:Hide() end`. 
3.  **Hooks**: Always use `hooksecurefunc(table, "functionName", hookFunc)` instead of manually overriding functions where possible to prevent UI taint.
4.  **No Fallbacks Needed**: Since CombatLedger requires these client mods, you do not need to wrap ClassicAPI calls in `if C_Item then ... else ... end` checks. Assume the API is present.

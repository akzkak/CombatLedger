# CombatLedger Development Guide

Welcome to the development guide for **CombatLedger**. This document outlines the technical foundation of the addon and how to leverage the specialized client modifications available on Octo WoW / Turtle WoW (1.12.1 client).

Because we are building for a highly modified 1.12 client ecosystem, we have access to powerful tools that bypass the traditional limitations of Vanilla WoW addon development.

## Core Dependencies and APIs

CombatLedger relies heavily on client modifications rather than standard 1.12 Blizzard API features. Understanding these three pillars is crucial for contributing:

### 1. Nampower (The Event Engine)
**Nampower** is a DLL injection mod that primarily addresses spell-casting latency, but it also exposes highly structured, server-accurate combat events to the Lua environment. 
*   **Why we use it:** Instead of parsing localized strings from `CHAT_MSG_COMBAT_*` (which is lossy, locale-dependent, and lacks unique unit identity), we listen to Nampower's custom events.
*   **Key Events:**
    *   `AUTO_ATTACK_SELF` / `AUTO_ATTACK_OTHER`
    *   `SPELL_DAMAGE_EVENT_SELF` / `SPELL_DAMAGE_EVENT_OTHER`
    *   `SPELL_HEAL_BY_*`
    *   `SPELL_DISPEL_BY_*`
*   **Data Payload:** These events provide exact metrics—source/target GUIDs, raw spell IDs, exact damage/heal amounts, and bitfields for hit types (crit, glancing, etc.).

### 2. ClassicAPI (Modern API Backport)
**ClassicAPI** bridges the gap between the outdated 1.12.1 Lua API and modern Blizzard APIs (e.g., 3.3.5+). It registers new Lua functions directly into the `FrameScript` engine.
*   **Why we use it:** It allows us to write cleaner, more modern Lua code without reinventing basic utility functions or relying on clunky Vanilla workarounds.
*   **What it provides:** Expect access to modern WoW API functions, string utilities, table helpers, and frame templates that didn't exist in 2006. If you find yourself needing a function from WotLK or Retail, check if ClassicAPI provides it before writing a polyfill.

### 3. SuperWoW API (Client Capability Expansion)
**SuperWoW** is another DLL mod that fundamentally expands what the 1.12 client engine can do. It is often interfaced via the `SuperAPI` companion addon.
*   **Why we use it:** It solves the biggest limitation of 1.12: the lack of unique unit identification.
*   **Key Capabilities:**
    *   **GUID Tracking:** The ability to fetch and track unique `GUID`s for units (e.g., distinguishing between two mobs named "Skeleton"). This is essential for accurate DPS and Threat attribution.
    *   **Enhanced Combat Log:** It can provide destination GUIDs in combat events.
    *   **Threat API:** Enables advanced capabilities like `UnitDetailedThreatSituation` (via server addon messages) to build accurate, live threat meters instead of estimating threat from damage dealt.

## Development Workflow

When adding new features or modules to CombatLedger, follow these architectural principles:

1.  **Never parse chat text.** If a combat action happens, there is almost certainly a Nampower or SuperWoW event for it. If not, investigate if the server sends an addon message we can intercept.
2.  **Use GUIDs for identity.** Never use `unitName` as a primary key in tracking tables. Always use the GUID provided by Nampower events or SuperWoW's `UnitGUID()`-equivalent functions.
3.  **Assume Modern Tools.** Rely on ClassicAPI for UI construction and data manipulation where applicable.

## Architecture Overview

*   **`Core.lua`**: Initialization and core addon lifecycle.
*   **`Events.lua`**: The routing layer. This is where we subscribe to Nampower and SuperWoW events and dispatch them to the tracking modules.
*   **`History.lua` / `Aggregator.lua`**: Data processing and storage of combat encounters.
*   **`GuidCache.lua`**: Resolving names/classes from the GUIDs we receive from the APIs.
*   **`Threat.lua`**: Live threat calculations utilizing the specialized threat API.
*   **`UI_*.lua`**: The display layer. 

## Best Practices

*   **Performance:** Combat events fire hundreds of times per second in a raid. Event handlers in `Events.lua` must be extremely lean. Defer UI updates to `OnUpdate` or throttled ticks rather than updating the UI on every combat event.
*   **Testing:** Due to the reliance on client-side DLLs (Nampower, SuperWoW, ClassicAPI), this addon **cannot** be effectively tested on a standard, unmodified 1.12 Vanilla client. You must run the Octo/Turtle WoW client with the required mods enabled.

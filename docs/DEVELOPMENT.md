# CombatLedger Development Guide

Welcome to the development guide for **CombatLedger**. This document outlines the technical foundation of the addon and how to leverage the specialized client modifications available on Octo WoW / Turtle WoW (1.12.1 client).

Because we are building for a highly modified 1.12 client ecosystem, we have access to powerful tools that bypass the traditional limitations of Vanilla WoW addon development.

## Core Dependencies and APIs

CombatLedger relies heavily on client modifications rather than standard 1.12 Blizzard API features. Understanding these three pillars is crucial for contributing. 

Please review the dedicated documentation for each technology to understand their specific capabilities and limitations:

1.  **[Nampower Reference](Nampower.md)**: The client hook layer providing structured, server-accurate combat events (e.g., `SPELL_DAMAGE_EVENT_OTHER`) to bypass lossy chat-log parsing.
2.  **[ClassicAPI Reference](ClassicAPI.md)**: A bridge that backports modern WoW Lua functions (from newer expansions) into the 1.12 engine, saving us from writing tedious polyfills for basic utilities.
3.  **[SuperWoW Reference](SuperWoW.md)**: A client capability expansion that provides essential features like GUID tracking (`UnitGUID()`) and accurate threat APIs.

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

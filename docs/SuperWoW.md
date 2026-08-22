# SuperWoW Reference for CombatLedger

**Repository:** [balakethelock/SuperWoW](https://github.com/balakethelock/SuperWoW)

SuperWoW is a closed-source DLL injection launcher/mod designed to fix client bugs and expand the Lua API for the 1.12.1 client. While originally built to recreate functionalities for Hermes Proxy users, it provides foundational features that CombatLedger relies on heavily.

## Core Capabilities

SuperWoW alters the process's memory to change variables and instructions, allowing for deeper access to the game engine than the standard API permits.

### 1. GUID Support (Critical for Ledger)
The standard 1.12 client relies entirely on `UnitName()` for identification, which breaks down when multiple units share the same name. 
*   **What it does:** SuperWoW exposes unique Global Unique Identifiers (GUIDs) for all units.
*   **Usage in CombatLedger:** All data tables and tracking must use GUIDs as primary keys, never unit names. This ensures exact attribution for damage, healing, and threat, even in encounters with duplicate mobs.

### 2. Enhanced Combat Log
*   **What it does:** Expands the data available during combat events, most notably adding **destination GUIDs** to events that previously only provided source or lacked distinct targeting info.
*   **Usage in CombatLedger:** Enables accurate target-by-target breakdowns and dispel tracking.

### 3. Live Threat API
*   **What it does:** Intercepts server addon messages to provide the modern `UnitDetailedThreatSituation` API.
*   **Usage in CombatLedger:** Instead of attempting to calculate threat by tracking damage and applying stance modifiers, we read the exact threat values directly from the server. This provides 100% accurate threat meters, including "pull aggro" thresholds.

## Development Guidelines

1.  **Companion Addon**: While SuperWoW is a DLL, its Lua API is often surfaced via the `SuperAPI` companion addon. Ensure you understand how the specific functions are namespaced.
2.  **GUIDs over Names**: Never build features that rely on entity names. Always utilize the SuperWoW API to fetch and track by GUID.
3.  **Threat**: Use the exposed `UnitDetailedThreatSituation` for any threat-related UI or logic rather than calculating it manually.

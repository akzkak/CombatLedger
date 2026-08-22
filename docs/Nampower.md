# Nampower Reference for CombatLedger

**Repository:** [namreeb/nampower](https://github.com/namreeb/nampower)

Nampower is a DLL injection tool for World of Warcraft 1.12.1 (for Windows) originally designed to fix a design flaw where players couldn't cast a second spell until the client received server acknowledgment of the first. However, its most important contribution to CombatLedger is its **custom combat event pipeline**.

## The Custom Event Pipeline

Standard Vanilla WoW combat parsing requires listening to `CHAT_MSG_COMBAT_*` events and reverse-engineering localized strings (e.g., "Your Sinister Strike hits Bob for 214."). This is lossy, heavily throttled, and impossible to track accurately without unique unit identifiers.

Nampower bypasses this by intercepting server packets and surfacing exact, structured events directly to Lua.

### Nampower Combat Events
CombatLedger subscribes to the following custom events exposed by Nampower:

*   `AUTO_ATTACK_SELF` / `AUTO_ATTACK_OTHER`
*   `SPELL_DAMAGE_EVENT_SELF` / `SPELL_DAMAGE_EVENT_OTHER`
*   `SPELL_HEAL_BY_SELF` / `SPELL_HEAL_BY_OTHER`
*   `SPELL_DISPEL_BY_SELF` / `SPELL_DISPEL_BY_OTHER`
*   Aura tracking events used for linking casts to debuffs.

### Data Payload Capabilities
When a Nampower event fires, it provides the following exact fields:
1.  **Source and Destination GUIDs**: Accurate tracking regardless of name duplication.
2.  **Raw Spell ID**: Exact identification of the ability used, avoiding localization issues.
3.  **Exact Values**: Raw damage or healing numbers, unaffected by UI throttling.
4.  **Hit Type Bitfields**: Precise data on crits, glancing blows, blocks, and resists without needing to parse the words from chat.

## Development Guidelines

1.  **No Chat Parsing**: Under no circumstances should `CHAT_MSG_COMBAT` be used for combat metric tracking in this addon. If you need new combat data, look for a Nampower event.
2.  **Event Routing**: All Nampower events are ingested through `Events.lua`. If you are building a new tracking module (like CC breaks or interrupts), subscribe to the relevant Nampower event within the core router and pass the payload down to your module.
3.  **Debuff Attribution**: Nampower provides aura-cast and debuff-added pairs. We use these in tandem to guarantee a debuff actually landed on the target before attributing it.

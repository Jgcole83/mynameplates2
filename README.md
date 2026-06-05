# MyNamePlates

A small WoW addon that gives you **a tab per nameplate category**, with a master toggle, scale slider, opacity slider, and a per-NPC checkbox list for every category that contains player-summoned units (totems, guardians, minions, minor, and pets).

## Settings layout

`Game Menu → Options → AddOns → MyNamePlates`

```
MyNamePlates                       (root: global CVars)
├── Friendly Players               master toggle + scale + alpha
├── Friendly NPCs                  master toggle + scale + alpha
├── Friendly Pets                  + per-NPC list
├── Friendly Guardians             + per-NPC list
├── Friendly Totems                + per-NPC list
├── Friendly Minions               + per-NPC list
├── Enemy Players & NPCs           master toggle + scale + alpha
├── Enemy Pets                     + per-NPC list
├── Enemy Guardians                + per-NPC list
├── Enemy Totems                   + per-NPC list
├── Enemy Minions                  + per-NPC list
└── Enemy Minor (Minus)            + per-NPC list
```

Open it in chat with `/mnp`, `/mynp`, or `/mynameplates`.

## Per-NPC unit lists

Six categories — Pets, Guardians, Totems, Minions, Minor (and the friendly mirrors) — show a list of player-summoned NPCs:

- **Hand-curated starter list** in `NpcData.lua` (Capacitor Totem, Psyfiend, Wild Imp, Earth Elemental, Demonic Tyrant, Statue of the Black Ox, etc.).
- **Auto-discovery** adds anything new on first sight: as soon as a friend or enemy summons a unit you haven't seen before, the addon classifies it (`UnitCreatureType` / `UnitClassification` / GUID prefix) and drops it into the right list.
- **Manual override**: target or mouseover a unit in-game and click **"Add Target / Mouseover"** (also `/mnp add`). Useful for fixing a category if auto-classification put a summon in the wrong bucket.

Each entry has a checkbox (untick = hide that specific NPC's nameplate while keeping the master toggle on) and an `X` button to remove it from the list.

## How visibility, scale, and alpha actually work

| Control | Mechanism |
| --- | --- |
| Master toggle (per category) | Sets the matching Blizzard CVar (`nameplateShowEnemyTotems`, etc.) |
| Per-category scale | After each nameplate spawns we call `nameplate:SetScale(value)` |
| Per-category alpha | Same, via `nameplate:SetAlpha(value)` |
| Per-NPC hide | `nameplate.UnitFrame:Hide()` for that specific spawn |
| Global scale/alpha | Standard Blizzard CVars (no per-plate hooking needed) |

All CVar writes are combat-safe: anything you change in combat is queued and applied on `PLAYER_REGEN_ENABLED`.

## Slash commands

| Command | What it does |
| --- | --- |
| `/mnp` | Open the settings panel |
| `/mnp add` | Add the current target/mouseover NPC to its category |
| `/mnp reset` | Reset every option to its default |

## Files

```
MyNamePlates/
├── MyNamePlates.toc      manifest + load order
├── CVars.lua             "General" page data tables (global CVars + plate W/H)
├── Categories.lua        the 13 subcategory definitions (kind/cvar/hostile/summonType)
├── NpcData.lua           hand-curated starter list of player-summoned NPCs
├── Core.lua              DB defaults, event handler, combat queue, ApplyAll/ResetAll
├── Discovery.lua         NAME_PLATE_UNIT_ADDED hook: classify, record, apply overrides
├── UI.lua                root canvas + 12 subcategory pages + slash commands
└── README.md
```

## Compatibility

Built against Interface `120005` (WoW Midnight). NPC IDs in `NpcData.lua` may need patch-by-patch adjustment; auto-discovery and the manual add button cover any drift.

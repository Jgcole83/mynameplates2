-- Categories.lua
-- The list of subcategories that appear under "MyNamePlates" in the Settings panel.
-- Each one becomes its own page with a master toggle + size slider + alpha slider,
-- and (where `kind == "list"`) a list of player-summoned NPCs with per-unit toggles.

local _, ns = ...

-- kinds:
--   "global"  = the General page (no master CVar; just the global sliders)
--   "master"  = master toggle only (no per-unit list)
--   "list"    = master toggle + per-unit list of player-summoned NPCs
--
-- summonType (only on "list" categories) tells Discovery.lua which type of summon
-- belongs in this list when auto-classifying a brand-new nameplate.
ns.CATEGORIES = {
    { id = "general",
      label = "General",
      kind = "global" },

    -- ── Friendly ──────────────────────────────────────────────────────────
    { id = "friendlyPlayers",     label = "Friendly Players",
      kind = "master", cvar = "nameplateShowFriends",
      hostile = false, defaultEnabled = "0" },

    { id = "friendlyNPCs",        label = "Friendly NPCs",
      kind = "master", cvar = "nameplateShowFriendlyNPCs",
      hostile = false, defaultEnabled = "1" },

    { id = "friendlyPets",        label = "Friendly Pets (master)",
      kind = "master", cvar = "nameplateShowFriendlyPets",
      hostile = false, defaultEnabled = "0", cvarOnly = true,
      blurb = "Master visibility toggle for ALL controllable pets. Per-class tabs below give scale, opacity, highlights, and per-NPC control." },

    { id = "friendlyHunterPets",  label = "Friendly Hunter Pets",
      kind = "list",   cvar = nil,
      hostile = false, summonType = "pet_hunter", defaultEnabled = "1",
      blurb = "Hunter pets only (every family/skin)." },

    { id = "friendlyWarlockPets", label = "Friendly Warlock Pets",
      kind = "list",   cvar = nil,
      hostile = false, summonType = "pet_warlock", defaultEnabled = "1",
      blurb = "Warlock primary demons (Imp, Felhunter, Voidwalker, Succubus, Felguard, etc.)." },

    { id = "friendlyDKPets",      label = "Friendly Death Knight Pets",
      kind = "list",   cvar = nil,
      hostile = false, summonType = "pet_dk", defaultEnabled = "1",
      blurb = "Unholy Death Knight Risen Ghoul." },

    { id = "friendlyMagePets",    label = "Friendly Mage Pets",
      kind = "list",   cvar = nil,
      hostile = false, summonType = "pet_mage", defaultEnabled = "1",
      blurb = "Frost Mage Water Elemental." },

    { id = "friendlyGuardians",   label = "Friendly Guardians",
      kind = "list",   cvar = "nameplateShowFriendlyGuardians",
      hostile = false, summonType = "guardian", defaultEnabled = "0",
      blurb = "Larger semi-controllable summons (Earth Elemental, Infernal, etc.)." },

    { id = "friendlyTotems",      label = "Friendly Totems",
      kind = "list",   cvar = "nameplateShowFriendlyTotems",
      hostile = false, summonType = "totem",    defaultEnabled = "0",
      blurb = "Totems and totem-like stationary summons (Statues, etc.). Psyfiend has its own tab." },

    { id = "friendlyPsyfiend",    label = "Friendly Psyfiend",
      kind = "list",   cvar = nil,
      hostile = false, summonType = "psyfiend", defaultEnabled = "1",
      blurb = "Priest Psyfiend (the constant fear-spamming target you usually want to highlight)." },

    { id = "friendlyMinions",     label = "Friendly Minions",
      kind = "list",   cvar = "nameplateShowFriendlyMinions",
      hostile = false, summonType = "minion",   defaultEnabled = "0",
      blurb = "Smaller summoned units (Wild Imps, Dreadstalkers, Observers, etc.)." },

    -- ── Enemy ─────────────────────────────────────────────────────────────
    { id = "enemyPlayers",        label = "Enemy Players & NPCs",
      kind = "master", cvar = "nameplateShowEnemies",
      hostile = true,  defaultEnabled = "1" },

    { id = "enemyPets",           label = "Enemy Pets (master)",
      kind = "master", cvar = "nameplateShowEnemyPets",
      hostile = true,  defaultEnabled = "1", cvarOnly = true,
      blurb = "Master visibility toggle for ALL controllable enemy pets. Per-class tabs below give scale, opacity, highlights, and per-NPC control." },

    { id = "enemyHunterPets",     label = "Enemy Hunter Pets",
      kind = "list",   cvar = nil,
      hostile = true,  summonType = "pet_hunter", defaultEnabled = "1",
      blurb = "Enemy Hunter pets only." },

    { id = "enemyWarlockPets",    label = "Enemy Warlock Pets",
      kind = "list",   cvar = nil,
      hostile = true,  summonType = "pet_warlock", defaultEnabled = "1",
      blurb = "Enemy Warlock primary demons." },

    { id = "enemyDKPets",         label = "Enemy Death Knight Pets",
      kind = "list",   cvar = nil,
      hostile = true,  summonType = "pet_dk", defaultEnabled = "1",
      blurb = "Enemy Unholy Death Knight Risen Ghoul." },

    { id = "enemyMagePets",       label = "Enemy Mage Pets",
      kind = "list",   cvar = nil,
      hostile = true,  summonType = "pet_mage", defaultEnabled = "1",
      blurb = "Enemy Frost Mage Water Elemental." },

    { id = "enemyGuardians",      label = "Enemy Guardians",
      kind = "list",   cvar = "nameplateShowEnemyGuardians",
      hostile = true,  summonType = "guardian", defaultEnabled = "1",
      blurb = "Larger enemy summons (Earth Elemental, Infernal, Demonic Tyrant, etc.)." },

    { id = "enemyTotems",         label = "Enemy Totems",
      kind = "list",   cvar = "nameplateShowEnemyTotems",
      hostile = true,  summonType = "totem",    defaultEnabled = "1",
      blurb = "Enemy totems and Statues. Psyfiend has its own tab." },

    { id = "enemyPsyfiend",       label = "Enemy Psyfiend",
      kind = "list",   cvar = nil,
      hostile = true,  summonType = "psyfiend", defaultEnabled = "1",
      blurb = "Priority kill target — drop opacity slider to make it stand out, or scale it up. Pre-seeded with bright red highlight." },

    { id = "enemyMinions",        label = "Enemy Minions",
      kind = "list",   cvar = "nameplateShowEnemyMinions",
      hostile = true,  summonType = "minion",   defaultEnabled = "1",
      blurb = "Smaller enemy summons (Wild Imps, Dreadstalkers, etc.)." },

    { id = "enemyMinor",          label = "Enemy Minor (Minus)",
      kind = "list",   cvar = "nameplateShowEnemyMinus",
      hostile = true,  summonType = "minor",    defaultEnabled = "1",
      blurb = "Tiny low-HP summons (Imp variants, Felguard adds, etc.)." },
}

-- Quick lookup: id -> definition
ns.CATEGORY_BY_ID = {}
for _, c in ipairs(ns.CATEGORIES) do
    ns.CATEGORY_BY_ID[c.id] = c
end

-- Pick the right list-category for a (summonType, hostile) combination.
-- Returns the category id or nil.
function ns:CategoryForSummon(summonType, hostile)
    for _, c in ipairs(ns.CATEGORIES) do
        if c.kind == "list" and c.summonType == summonType and c.hostile == hostile then
            return c.id
        end
    end
    return nil
end

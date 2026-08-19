-- NpcData.lua
-- Hand-curated starter list of player-summoned NPCs that show up as nameplates.
-- Auto-discovery (Discovery.lua) adds anything missing the moment you encounter it.
--
-- Schema:
--   ns.NPC_DATA[npcID] = {
--       name      = "...",
--       type      = "totem|psyfiend|guardian|minion|minor|pet_*",
--       spellID   = <spellID>,   -- optional; used to derive the canonical
--                                --   icon via C_Spell.GetSpellTexture.
--                                --   Preferred over hardcoding texture
--                                --   paths since icons update with patches
--                                --   and localise correctly.
--       important = true,        -- optional; if set, the totem indicator
--                                --   treats this NPC as "arena-critical"
--                                --   (glow + pulse animation + magenta
--                                --   important color, respects the user's
--                                --   colorHealthBar / colorName toggles).
--                                --   Reserve for totems that are priority
--                                --   kicks/kills (Grounding, Capacitor,
--                                --   Psyfiend, Tremor, Static Field,
--                                --   Healing Tide, Spirit Link, etc.).
--                                --   Non-critical totems (Skyfury,
--                                --   Cloudburst, Wind Rush, etc.) leave
--                                --   this off — they still get the
--                                --   canonical icon but use the neutral
--                                --   "generic totem" color.
--   }
--
-- Type guidance (matches Blizzard's nameplate CVars):
--   totem    -> stationary summons (nameplateShowFriendlyTotems / EnemyTotems)
--   psyfiend -> priest Psyfiend specifically (dedicated tab)
--   guardian -> larger semi-controllable summons (Elemental, Infernal, Tyrant, ...)
--   minion   -> smaller summoned helpers (Wild Imp, Dreadstalker, Treant, ...)
--   minor    -> tiny "minus" units
--   pet_*    -> primary controllable pets, per-class buckets
--
-- IDs may drift between patches; if a totem appears under the wrong category in
-- game, target it and run /mnp add to recategorise it (or just edit this file).

local _, ns = ...

ns.NPC_DATA = {

    -- ────────────────────────────────────────────────────────────────────
    -- SHAMAN TOTEMS
    -- `spellID` gives us the canonical icon (via C_Spell.GetSpellTexture).
    -- `important = true` marks arena-critical totems that must be visually
    -- distinguished — they get the important-magenta color + glow + pulse.
    -- Non-important totems still get their real icon but use the neutral
    -- "generic totem" color so the plate reads as "a totem" without
    -- competing for attention with the priority kicks/kills.
    -- ────────────────────────────────────────────────────────────────────
    [3527]   = { name = "Healing Stream Totem",         type = "totem", spellID = 5394   },
    [61255]  = { name = "Healing Stream Totem (Resto)", type = "totem", spellID = 5394   },
    [2630]   = { name = "Earthbind Totem",              type = "totem", spellID = 2484   },
    [5913]   = { name = "Tremor Totem",                 type = "totem", spellID = 8143,   important = true },
    [5925]   = { name = "Grounding Totem",              type = "totem", spellID = 204336, important = true },
    [61245]  = { name = "Capacitor Totem",              type = "totem", spellID = 192058, important = true },
    [59764]  = { name = "Healing Tide Totem",           type = "totem", spellID = 108280, important = true },
    [98007]  = { name = "Spirit Link Totem",            type = "totem", spellID = 98008,  important = true },
    [60561]  = { name = "Earthgrab Totem",              type = "totem", spellID = 51485,  important = true },
    [97369]  = { name = "Liquid Magma Totem",           type = "totem", spellID = 192222 },
    [100943] = { name = "Earthen Wall Totem",           type = "totem", spellID = 198838 },
    [105427] = { name = "Skyfury Totem",                type = "totem", spellID = 208963 },
    [114896] = { name = "Wind Rush Totem",              type = "totem", spellID = 192077 },
    [207399] = { name = "Ancestral Protection Totem",   type = "totem", spellID = 207399, important = true },
    [78001]  = { name = "Cloudburst Totem",             type = "totem", spellID = 157153 },
    [105451] = { name = "Counterstrike Totem",          type = "totem", spellID = 208997, important = true },
    [196488] = { name = "Voodoo Totem",                 type = "totem", spellID = 196932, important = true },
    [73900]  = { name = "Mana Tide Totem",              type = "totem", spellID = 16190  },
    [188616] = { name = "Static Field Totem",           type = "totem", spellID = 355580, important = true },
    [222329] = { name = "Surging Totem",                type = "totem", spellID = 455591 },
    [197211] = { name = "Lightning Surge Totem",        type = "totem", spellID = 210714, important = true },
    [157929] = { name = "Resonance Totem",              type = "totem", spellID = 202192 },
    [108270] = { name = "Stone Bulwark Totem",          type = "totem", spellID = 108270 },
    [79931]  = { name = "Stoneskin Totem",              type = "totem", spellID = 8071   },
    [29142]  = { name = "Greater Earthbind Totem",      type = "totem", spellID = 2484   },
    [29144]  = { name = "Cleansing Totem",              type = "totem", spellID = 8170   },
    [4589]   = { name = "Stoneclaw Totem",              type = "totem", spellID = 5730   },
    [10467]  = { name = "Mana Spring Totem",            type = "totem", spellID = 5675   },
    [99691]  = { name = "Surging Totem (alt)",          type = "totem", spellID = 455591 },
    [192058] = { name = "Capacitor Totem (PvP alt)",    type = "totem", spellID = 192058, important = true },

    -- ────────────────────────────────────────────────────────────────────
    -- SHAMAN GUARDIANS (Elementals)
    -- ────────────────────────────────────────────────────────────────────
    [95061]  = { name = "Greater Earth Elemental",     type = "guardian", spellID = 198103 },
    [95072]  = { name = "Greater Fire Elemental",      type = "guardian", spellID = 198067 },
    [199729] = { name = "Fire Elemental",              type = "guardian", spellID = 198067 },
    [77942]  = { name = "Storm Elemental",             type = "guardian", spellID = 192249 },
    [205495] = { name = "Storm Elemental (Primal)",    type = "guardian", spellID = 192249 },
    [15352]  = { name = "Earth Elemental",             type = "guardian", spellID = 198103 },
    [15438]  = { name = "Fire Elemental (legacy)",     type = "guardian", spellID = 198067 },
    -- Enhancement Feral Spirit + Greater Storm Elemental from BBP
    -- secondaryPets (BetterBlizzPlates/midnight/BetterBlizzPlates.lua:3374-3377).
    -- Spirit Wolf is a proper "minion" per Blizzard's nameplate CVar
    -- classification (nameplateShowFriendlyMinions); Greater Storm
    -- Elemental is the Elemental spec 30s cooldown, filed alongside
    -- our other elementals as a guardian.
    [29264]  = { name = "Spirit Wolf",                 type = "minion",   spellID = 51533  },
    [77936]  = { name = "Greater Storm Elemental",     type = "guardian", spellID = 192249 },

    -- ────────────────────────────────────────────────────────────────────
    -- PRIEST
    -- Psyfiend is arena-critical (channels Psychic Terror = 5s fear).
    -- Icon uses the Psyfiend summon spell so it matches BBP's fallback.
    -- ────────────────────────────────────────────────────────────────────
    [101398] = { name = "Psyfiend",                    type = "psyfiend", spellID = 199824, important = true },
    [19668]  = { name = "Shadowfiend",                 type = "guardian", spellID = 34433 },
    [62982]  = { name = "Mindbender",                  type = "guardian", spellID = 200174 },
    [224466] = { name = "Voidwraith",                  type = "guardian", spellID = 451235 },

    -- ────────────────────────────────────────────────────────────────────
    -- MAGE
    -- ────────────────────────────────────────────────────────────────────
    [78116]  = { name = "Water Elemental",             type = "pet_mage", spellID = 31687 },
    [37994]  = { name = "Water Elemental (legacy)",    type = "pet_mage", spellID = 31687 },
    [510]    = { name = "Water Elemental (Conjure)",   type = "minion",   spellID = 31687 },
    [253759] = { name = "Mirror Image (Midnight)",     type = "minion",   spellID = 55342 },
    [175313] = { name = "Mirror Image (Shadowlands)",  type = "minion",   spellID = 55342 },
    [31216]  = { name = "Mirror Image (legacy)",       type = "minion",   spellID = 55342 },
    [99319]  = { name = "Mirror Image (alt)",          type = "minion",   spellID = 55342 },
    [198706] = { name = "Mirror Image (alt 2)",        type = "minion",   spellID = 55342 },
    [98659]  = { name = "Prismatic Crystal",           type = "totem", spellID = 155147 },

    -- ────────────────────────────────────────────────────────────────────
    -- WARLOCK PETS  (the main controllable demon)
    -- spellIDs point to the Summon spell for each pet so the totem
    -- indicator icon shows the recognizable "Summon Imp" / "Summon
    -- Voidwalker" etc. face rather than falling to the shaman totem-
    -- recall generic.  Legion Grimoire of Supremacy variants (Fel Imp,
    -- Voidlord, Shivarra, Observer, Wrathguard) use their Grimoire
    -- summon spell IDs (112866-112870).
    -- ────────────────────────────────────────────────────────────────────
    [416]    = { name = "Imp",                         type = "pet_warlock", spellID = 688    },
    [417]    = { name = "Felhunter",                   type = "pet_warlock", spellID = 691    },
    [1860]   = { name = "Voidwalker",                  type = "pet_warlock", spellID = 697    },
    [1863]   = { name = "Succubus",                    type = "pet_warlock", spellID = 712    },
    [17252]  = { name = "Felguard",                    type = "pet_warlock", spellID = 30146  },
    [115748] = { name = "Fel Imp",                     type = "pet_warlock", spellID = 112866 },
    [115772] = { name = "Voidlord",                    type = "pet_warlock", spellID = 112867 },
    [115778] = { name = "Shivarra",                    type = "pet_warlock", spellID = 112868 },
    [115781] = { name = "Observer",                    type = "pet_warlock", spellID = 112869 },
    [115782] = { name = "Wrathguard",                  type = "pet_warlock", spellID = 112870 },
    [184600] = { name = "Incubus",                     type = "pet_warlock", spellID = 712    },

    -- ────────────────────────────────────────────────────────────────────
    -- WARLOCK SUMMONS — every Warlock-summoned unit (Affliction / Demo /
    -- Destruction primary pets, Demo's swarm summons, Destro's Infernal,
    -- the big cooldown summons) is filed under pet_warlock so the
    -- "Warlock Pets" tab is the single point of control for the whole
    -- class.  This is friendlier than spreading them across Pets /
    -- Minions / Guardians / Minor — even though Blizzard internally
    -- classifies them differently, you almost never want different
    -- treatment for "Felguard" vs "Wild Imp".
    -- ────────────────────────────────────────────────────────────────────
    [89]     = { name = "Infernal",                    type = "pet_warlock", spellID = 1122   },
    [11859]  = { name = "Doomguard",                   type = "pet_warlock", spellID = 18540  },
    [135002] = { name = "Demonic Tyrant",              type = "pet_warlock", spellID = 265187 },
    [196111] = { name = "Pit Lord",                    type = "pet_warlock", spellID = 267171 },
    [55659]  = { name = "Wild Imp",                    type = "pet_warlock", spellID = 104317 },
    [230873] = { name = "Wild Imp (modern)",           type = "pet_warlock", spellID = 104317 },
    [143622] = { name = "Wild Imp (alt)",              type = "pet_warlock", spellID = 104317 },
    [98035]  = { name = "Dreadstalker",                type = "pet_warlock", spellID = 104316 },
    [93616]  = { name = "Dreadstalker (alt)",          type = "pet_warlock", spellID = 104316 },
    [117177] = { name = "Dreadstalker (alt 2)",        type = "pet_warlock", spellID = 104316 },
    [231037] = { name = "Dreadstalker (modern)",       type = "pet_warlock", spellID = 104316 },
    [108503] = { name = "Grimoire: Felguard",          type = "pet_warlock", spellID = 111898 },
    [99737]  = { name = "Vilefiend",                   type = "pet_warlock", spellID = 264119 },
    [221008] = { name = "Doomfiend",                   type = "pet_warlock" },
    [221012] = { name = "Charhound",                   type = "pet_warlock" },
    [4277]   = { name = "Eye of Kilrogg",              type = "pet_warlock" },
    [221001] = { name = "Inner Demon",                 type = "pet_warlock" },
    -- Additional Warlock summon IDs seeded from BBP secondaryPets
    -- (BetterBlizzPlates/midnight/BetterBlizzPlates.lua:3354-3369).
    -- Covers Diabolist / Hellcaller / older Legion demons that our
    -- curated list didn't have — auto-discovery would still catch
    -- these on first sight, but pre-seeding avoids the one-time miss
    -- and keeps them under the pet_warlock master tab.
    [226268] = { name = "Gloomhound",                  type = "pet_warlock" },
    [226269] = { name = "Charhound (alt)",             type = "pet_warlock" },
    [136408] = { name = "Darkhound",                   type = "pet_warlock" },
    [136398] = { name = "Illidari Satyr",              type = "pet_warlock" },
    [136403] = { name = "Void Terror",                 type = "pet_warlock" },
    [198757] = { name = "Void Lasher",                 type = "pet_warlock" },
    [228574] = { name = "Pit Lord (Midnight)",         type = "pet_warlock" },
    [228576] = { name = "Mother of Chaos",             type = "pet_warlock" },
    [217429] = { name = "Overfiend",                   type = "pet_warlock" },
    [225493] = { name = "Doomguard (Midnight)",        type = "pet_warlock" },

    -- ────────────────────────────────────────────────────────────────────
    -- DRUID
    -- ────────────────────────────────────────────────────────────────────
    [54983]  = { name = "Treant (Force of Nature)",    type = "minion",   spellID = 205636 },
    [29608]  = { name = "Treant",                      type = "minion",   spellID = 205636 },
    [1964]   = { name = "Treant (legacy)",             type = "minion",   spellID = 33831  },

    -- ────────────────────────────────────────────────────────────────────
    -- DEATH KNIGHT
    -- ────────────────────────────────────────────────────────────────────
    [26125]  = { name = "Risen Ghoul",                 type = "pet_dk",   spellID = 46584  },
    [27893]  = { name = "Risen Ghoul (alt)",           type = "pet_dk",   spellID = 46584  },
    [148020] = { name = "Risen Ghoul (modern)",        type = "pet_dk",   spellID = 46584  },
    [24207]  = { name = "Army of the Dead Ghoul",      type = "minion",   spellID = 42650  },
    [193758] = { name = "Risen Skulker",               type = "minion",   spellID = 212423 },
    [27829]  = { name = "Gargoyle",                    type = "guardian", spellID = 49206  },
    [49206]  = { name = "Gargoyle (alt)",              type = "guardian", spellID = 49206  },
    [99541]  = { name = "Apocalypse Ghoul",            type = "minion",   spellID = 275699 },
    [163366] = { name = "Magus of the Dead",           type = "minion",   spellID = 288853 },
    [192337] = { name = "Abomination",                 type = "pet_dk",   spellID = 288853 },
    [171557] = { name = "Bloodworm",                   type = "minor",    spellID = 195679 },
    -- Sanlayn Riders of the Apocalypse (San'layn hero tree).  Sourced
    -- from BetterBlizzPlates/midnight/BetterBlizzPlates.lua:3346-3350.
    -- Filed as "minion" to match Army-of-the-Dead siblings — they're
    -- short-lived summons rather than the primary controllable ghoul.
    [149555] = { name = "Raise Abomination",           type = "minion"   },
    [221632] = { name = "Highlord Darion Mograine",    type = "minion"   },
    [221633] = { name = "High Inquisitor Whitemane",   type = "minion"   },
    [221634] = { name = "General Nazgrim",             type = "minion"   },
    [221635] = { name = "King Thoras Trollbane",       type = "minion"   },

    -- ────────────────────────────────────────────────────────────────────
    -- MONK
    -- ────────────────────────────────────────────────────────────────────
    [60849]  = { name = "Statue of the Jade Serpent",  type = "totem",    spellID = 115313 },
    [61146]  = { name = "Statue of the Black Ox",      type = "totem",    spellID = 115315 },
    [63508]  = { name = "Xuen, the White Tiger",       type = "guardian", spellID = 123904 },
    [73967]  = { name = "Niuzao, the Black Ox",        type = "guardian", spellID = 132578 },
    [73855]  = { name = "Chi-Ji, the Red Crane",       type = "guardian", spellID = 325197 },
    [165554] = { name = "Storm Spirit",                type = "minion"   },
    [165555] = { name = "Earth Spirit",                type = "minion"   },
    [165556] = { name = "Fire Spirit",                 type = "minion"   },

    -- ────────────────────────────────────────────────────────────────────
    -- HUNTER
    -- Hunter pet IDs vary by family/skin (thousands of variants).  Auto-
    -- discovery handles them on first sight; uncurated "pet"-shaped units
    -- default to pet_hunter so they land in the dedicated Hunter Pets tab.
    -- ────────────────────────────────────────────────────────────────────
    [165189] = { name = "Animal Companion (secondary)", type = "pet_hunter" },
    -- Hunter secondary pets seeded from BBP secondaryPets
    -- (BetterBlizzPlates/midnight/BetterBlizzPlates.lua:3387-3393).
    -- Beast Mastery hero-tree summons + Beast Cleave companions.
    -- Auto-discovery would default any pet-GUID unit to pet_hunter,
    -- but seeding gives us the proper display name up front.
    [62005]  = { name = "Beast",                       type = "pet_hunter" },
    [105419] = { name = "Dire Basilisk",               type = "pet_hunter" },
    [217228] = { name = "Blood Beast",                 type = "pet_hunter" },
    [225190] = { name = "Dark Hound",                  type = "pet_hunter" },
    [228224] = { name = "Fenryr",                      type = "pet_hunter" },
    [228226] = { name = "Hati",                        type = "pet_hunter" },
    [234018] = { name = "Bear Pack Leader",            type = "pet_hunter" },

    -- ────────────────────────────────────────────────────────────────────
    -- EVOKER
    -- ────────────────────────────────────────────────────────────────────
    [193105] = { name = "Ebon Might Bronze Drake",     type = "minion"   },
}

ns.TYPE_LABEL = {
    totem    = "Totem",
    guardian = "Guardian",
    minion   = "Minion",
    minor    = "Minor",
    pet      = "Pet",
}

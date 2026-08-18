-- NpcData.lua
-- Hand-curated starter list of player-summoned NPCs that show up as nameplates.
-- Auto-discovery (Discovery.lua) adds anything missing the moment you encounter it.
--
-- Schema:
--   ns.NPC_DATA[npcID] = { name = "...", type = "totem|guardian|minion|minor|pet" }
--
-- Type guidance (matches Blizzard's nameplate CVars):
--   totem    -> stationary summons (nameplateShowFriendlyTotems / EnemyTotems)
--   guardian -> larger semi-controllable summons (Elemental, Infernal, Tyrant, ...)
--   minion   -> smaller summoned helpers (Wild Imp, Dreadstalker, Treant, ...)
--   minor    -> tiny "minus" units
--   pet      -> the player's primary controllable pet
--
-- IDs may drift between patches; if a totem appears under the wrong category in
-- game, target it and run /mnp add to recategorise it (or just edit this file).

local _, ns = ...

ns.NPC_DATA = {

    -- ────────────────────────────────────────────────────────────────────
    -- SHAMAN TOTEMS
    -- Uncheck the boring ones (Healing Stream, Skyfury, Wind Rush, Cloudburst,
    -- Earthen Wall, Mana Tide); leave gameplay-critical ones visible
    -- (Capacitor, Tremor, Grounding, Spirit Link, Earthgrab, Healing Tide,
    -- Static Field, Lightning Surge, Earthbind).
    -- ────────────────────────────────────────────────────────────────────
    [3527]   = { name = "Healing Stream Totem",        type = "totem"    },
    [61255]  = { name = "Healing Stream Totem (Resto)", type = "totem"   },
    [2630]   = { name = "Earthbind Totem",             type = "totem"    },
    [5913]   = { name = "Tremor Totem",                type = "totem"    },
    [5925]   = { name = "Grounding Totem",             type = "totem"    },
    [61245]  = { name = "Capacitor Totem",             type = "totem"    },
    [59764]  = { name = "Healing Tide Totem",          type = "totem"    },
    [98007]  = { name = "Spirit Link Totem",           type = "totem"    },
    [60561]  = { name = "Earthgrab Totem",             type = "totem"    },
    [97369]  = { name = "Liquid Magma Totem",          type = "totem"    },
    [100943] = { name = "Earthen Wall Totem",          type = "totem"    },
    [105427] = { name = "Skyfury Totem",               type = "totem"    },
    [114896] = { name = "Wind Rush Totem",             type = "totem"    },
    [207399] = { name = "Ancestral Protection Totem",  type = "totem"    },
    [78001]  = { name = "Cloudburst Totem",            type = "totem"    },
    [105451] = { name = "Counterstrike Totem",         type = "totem"    },
    [196488] = { name = "Voodoo Totem",                type = "totem"    },
    [73900]  = { name = "Mana Tide Totem",             type = "totem"    },
    [188616] = { name = "Static Field Totem",          type = "totem"    },
    [222329] = { name = "Surging Totem",               type = "totem"    },
    [197211] = { name = "Lightning Surge Totem",       type = "totem"    },
    [157929] = { name = "Resonance Totem",             type = "totem"    },
    [108270] = { name = "Stone Bulwark Totem",         type = "totem"    },
    [79931]  = { name = "Stoneskin Totem",             type = "totem"    },
    [29142]  = { name = "Greater Earthbind Totem",     type = "totem"    },
    [29144]  = { name = "Cleansing Totem",             type = "totem"    },
    [4589]   = { name = "Stoneclaw Totem",             type = "totem"    },
    [10467]  = { name = "Mana Spring Totem",           type = "totem"    },
    [99691]  = { name = "Surging Totem (alt)",         type = "totem"    },
    [192058] = { name = "Capacitor Totem (PvP alt)",   type = "totem"    },

    -- ────────────────────────────────────────────────────────────────────
    -- SHAMAN GUARDIANS (Elementals)
    -- ────────────────────────────────────────────────────────────────────
    [95061]  = { name = "Greater Earth Elemental",     type = "guardian" },
    [95072]  = { name = "Greater Fire Elemental",      type = "guardian" },
    [199729] = { name = "Fire Elemental",              type = "guardian" },
    [77942]  = { name = "Storm Elemental",             type = "guardian" },
    [205495] = { name = "Storm Elemental (Primal)",    type = "guardian" },
    [15352]  = { name = "Earth Elemental",             type = "guardian" },
    [15438]  = { name = "Fire Elemental (legacy)",     type = "guardian" },
    -- Enhancement Feral Spirit + Greater Storm Elemental from BBP
    -- secondaryPets (BetterBlizzPlates/midnight/BetterBlizzPlates.lua:3374-3377).
    -- Spirit Wolf is a proper "minion" per Blizzard's nameplate CVar
    -- classification (nameplateShowFriendlyMinions); Greater Storm
    -- Elemental is the Elemental spec 30s cooldown, filed alongside
    -- our other elementals as a guardian.
    [29264]  = { name = "Spirit Wolf",                 type = "minion"   },
    [77936]  = { name = "Greater Storm Elemental",     type = "guardian" },

    -- ────────────────────────────────────────────────────────────────────
    -- PRIEST
    -- ────────────────────────────────────────────────────────────────────
    [101398] = { name = "Psyfiend",                    type = "psyfiend" },
    [19668]  = { name = "Shadowfiend",                 type = "guardian" },
    [62982]  = { name = "Mindbender",                  type = "guardian" },
    [224466] = { name = "Voidwraith",                  type = "guardian" },

    -- ────────────────────────────────────────────────────────────────────
    -- MAGE
    -- ────────────────────────────────────────────────────────────────────
    [78116]  = { name = "Water Elemental",             type = "pet_mage" },
    [37994]  = { name = "Water Elemental (legacy)",    type = "pet_mage" },
    [510]    = { name = "Water Elemental (Conjure)",   type = "minion"   },
    [253759] = { name = "Mirror Image (Midnight)",     type = "minion"   },
    [175313] = { name = "Mirror Image (Shadowlands)",  type = "minion"   },
    [31216]  = { name = "Mirror Image (legacy)",       type = "minion"   },
    [99319]  = { name = "Mirror Image (alt)",          type = "minion"   },
    [198706] = { name = "Mirror Image (alt 2)",        type = "minion"   },
    [98659]  = { name = "Prismatic Crystal",           type = "totem"    },

    -- ────────────────────────────────────────────────────────────────────
    -- WARLOCK PETS  (the main controllable demon)
    -- ────────────────────────────────────────────────────────────────────
    [416]    = { name = "Imp",                         type = "pet_warlock" },
    [417]    = { name = "Felhunter",                   type = "pet_warlock" },
    [1860]   = { name = "Voidwalker",                  type = "pet_warlock" },
    [1863]   = { name = "Succubus",                    type = "pet_warlock" },
    [17252]  = { name = "Felguard",                    type = "pet_warlock" },
    [115748] = { name = "Fel Imp",                     type = "pet_warlock" },
    [115772] = { name = "Voidlord",                    type = "pet_warlock" },
    [115778] = { name = "Shivarra",                    type = "pet_warlock" },
    [115781] = { name = "Observer",                    type = "pet_warlock" },
    [115782] = { name = "Wrathguard",                  type = "pet_warlock" },
    [184600] = { name = "Incubus",                     type = "pet_warlock" },

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
    [89]     = { name = "Infernal",                    type = "pet_warlock" },
    [11859]  = { name = "Doomguard",                   type = "pet_warlock" },
    [135002] = { name = "Demonic Tyrant",              type = "pet_warlock" },
    [196111] = { name = "Pit Lord",                    type = "pet_warlock" },
    [55659]  = { name = "Wild Imp",                    type = "pet_warlock" },
    [230873] = { name = "Wild Imp (modern)",           type = "pet_warlock" },
    [143622] = { name = "Wild Imp (alt)",              type = "pet_warlock" },
    [98035]  = { name = "Dreadstalker",                type = "pet_warlock" },
    [93616]  = { name = "Dreadstalker (alt)",          type = "pet_warlock" },
    [117177] = { name = "Dreadstalker (alt 2)",        type = "pet_warlock" },
    [231037] = { name = "Dreadstalker (modern)",       type = "pet_warlock" },
    [108503] = { name = "Grimoire: Felguard",          type = "pet_warlock" },
    [99737]  = { name = "Vilefiend",                   type = "pet_warlock" },
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
    [54983]  = { name = "Treant (Force of Nature)",    type = "minion"   },
    [29608]  = { name = "Treant",                      type = "minion"   },
    [1964]   = { name = "Treant (legacy)",             type = "minion"   },

    -- ────────────────────────────────────────────────────────────────────
    -- DEATH KNIGHT
    -- ────────────────────────────────────────────────────────────────────
    [26125]  = { name = "Risen Ghoul",                 type = "pet_dk"   },
    [27893]  = { name = "Risen Ghoul (alt)",           type = "pet_dk"   },
    [148020] = { name = "Risen Ghoul (modern)",        type = "pet_dk"   },
    [24207]  = { name = "Army of the Dead Ghoul",      type = "minion"   },
    [193758] = { name = "Risen Skulker",               type = "minion"   },
    [27829]  = { name = "Gargoyle",                    type = "guardian" },
    [49206]  = { name = "Gargoyle (alt)",              type = "guardian" },
    [99541]  = { name = "Apocalypse Ghoul",            type = "minion"   },
    [163366] = { name = "Magus of the Dead",           type = "minion"   },
    [192337] = { name = "Abomination",                 type = "pet_dk"   },
    [171557] = { name = "Bloodworm",                   type = "minor"    },
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
    [60849]  = { name = "Statue of the Jade Serpent",  type = "totem"    },
    [61146]  = { name = "Statue of the Black Ox",      type = "totem"    },
    [63508]  = { name = "Xuen, the White Tiger",       type = "guardian" },
    [73967]  = { name = "Niuzao, the Black Ox",        type = "guardian" },
    [73855]  = { name = "Chi-Ji, the Red Crane",       type = "guardian" },
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

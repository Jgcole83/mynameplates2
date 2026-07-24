-- SpecSpells.lua
-- Combat-log-based enemy spec detection.
--
-- WHY THIS FILE EXISTS
-- --------------------
-- In retail Midnight 12.x, Blizzard anonymises every API that could
-- give addons a BG enemy's spec:
--   * UnitGUID(unit)        -> secret-string value
--   * UnitClass(unit)        -> secret-string value
--   * UnitCreatureType(unit) -> secret-string value
--   * C_TooltipInfo on non-target enemy plates -> secret line text
--   * C_PvP.GetScoreInfo(i).talentSpec -> secret-string value
--   * C_PvP.GetScoreInfoByPlayerGuid(guid) -> rejects secret GUIDs
--   * No GetBGOpponentSpec(name) API (arena has one, BG doesn't)
--
-- BUT combat log events (`COMBAT_LOG_EVENT_UNFILTERED`) are NOT
-- secret-tagged.  `sourceName`, `sourceGUID`, and `spellID` come
-- through as plain values that we can compare, hash, and use as
-- table keys.  So when an enemy casts a spec-unique spell, we
-- learn their spec deterministically.  This is the same trick
-- sArena / Gladdy / ArenaCore use for early arena spec detection
-- (before ARENA_PREP_OPPONENT_SPECIALIZATIONS fires) and for
-- inspect-blocked BG enemies.
--
-- The table below lists "signature" spells per spec — spells that
-- are EITHER exclusive to one spec OR overwhelmingly characteristic
-- of it (e.g. Mortal Strike is technically learnable by other warrior
-- specs but almost never cast outside Arms in PvP).  Once we see a
-- match, we cache the spec by sourceName and don't downgrade — the
-- first hit wins.
--
-- TABLE FORMAT: SPEC_BY_SPELL[spellID] = specID
-- specID is the standard retail spec ID returned by
-- GetSpecializationInfoForClassID — we feed it back into
-- GetSpecializationInfoByID(specID) to get the localized spec name
-- ("Frost", "Devastation", etc.) which IS a plain non-secret string
-- (static data, never anonymised), suitable for FontString:SetText.
--
-- Maintenance: if a spec ID changes between expansions or a new
-- signature spell appears, update entries here.  Multiple spells
-- per spec is fine and recommended (covers different talent builds).

local _, ns = ...

ns.SPEC_BY_SPELL = {
    -- ─────────────────────────────────────────────────────────────
    -- WARRIOR  (Arms=71, Fury=72, Protection=73)
    -- ─────────────────────────────────────────────────────────────
    [12294]  = 71,   -- Mortal Strike
    [262161] = 71,   -- Warbreaker (Arms talent)
    [167105] = 71,   -- Colossus Smash
    [772]    = 71,   -- Rend (Arms-flavored in modern)
    [23881]  = 72,   -- Bloodthirst
    [184367] = 72,   -- Rampage
    [85288]  = 72,   -- Raging Blow
    [23922]  = 73,   -- Shield Slam
    [6572]   = 73,   -- Revenge (Prot mostly)
    [2565]   = 73,   -- Shield Block

    -- ─────────────────────────────────────────────────────────────
    -- PALADIN  (Holy=65, Protection=66, Retribution=70)
    -- ─────────────────────────────────────────────────────────────
    [20473]  = 65,   -- Holy Shock
    [82326]  = 65,   -- Holy Light
    [82327]  = 65,   -- Holy Radiance / similar
    [31935]  = 66,   -- Avenger's Shield
    [53595]  = 66,   -- Hammer of the Righteous
    [53600]  = 66,   -- Shield of the Righteous
    [184575] = 70,   -- Blade of Justice
    [85256]  = 70,   -- Templar's Verdict
    [255937] = 70,   -- Wake of Ashes
    [383328] = 70,   -- Final Verdict
    [35395]  = 70,   -- Crusader Strike (Ret mostly in modern)

    -- ─────────────────────────────────────────────────────────────
    -- HUNTER  (BM=253, MM=254, SV=255)
    -- ─────────────────────────────────────────────────────────────
    [34026]  = 253,  -- Kill Command (BM)
    [19574]  = 253,  -- Bestial Wrath
    [217200] = 253,  -- Barbed Shot
    [19434]  = 254,  -- Aimed Shot
    [257044] = 254,  -- Rapid Fire
    [212431] = 254,  -- Multi-Shot (MM-heavy)
    [288613] = 254,  -- Trueshot
    [259495] = 255,  -- Wildfire Bomb
    [186270] = 255,  -- Raptor Strike
    [259489] = 255,  -- Kill Command (SV version)
    [266779] = 255,  -- Coordinated Assault

    -- ─────────────────────────────────────────────────────────────
    -- ROGUE  (Assassination=259, Outlaw=260, Subtlety=261)
    -- ─────────────────────────────────────────────────────────────
    [1329]   = 259,  -- Mutilate
    [32645]  = 259,  -- Envenom
    [196819] = 259,  -- Garrote (talent in modern, mainly Assn)
    [193315] = 260,  -- Sinister Strike (Outlaw in modern)
    [185763] = 260,  -- Pistol Shot
    [13877]  = 260,  -- Blade Flurry
    [315341] = 260,  -- Between the Eyes
    [195457] = 260,  -- Grappling Hook
    [185438] = 261,  -- Shadowstrike
    [185313] = 261,  -- Shadow Dance
    [212283] = 261,  -- Symbols of Death
    [280719] = 261,  -- Secret Technique

    -- ─────────────────────────────────────────────────────────────
    -- PRIEST  (Discipline=256, Holy=257, Shadow=258)
    -- ─────────────────────────────────────────────────────────────
    [47540]  = 256,  -- Penance (offensive form)
    [47666]  = 256,  -- Penance (heal form)
    [194509] = 256,  -- Power Word: Radiance
    [33206]  = 256,  -- Pain Suppression
    [62618]  = 256,  -- Power Word: Barrier
    [2050]   = 257,  -- Holy Word: Serenity
    [34861]  = 257,  -- Holy Word: Sanctify
    [88625]  = 257,  -- Holy Word: Chastise
    [64843]  = 257,  -- Divine Hymn
    [8092]   = 258,  -- Mind Blast (Shadow primary)
    [34914]  = 258,  -- Vampiric Touch
    [15407]  = 258,  -- Mind Flay
    [335467] = 258,  -- Devouring Plague
    [228260] = 258,  -- Void Eruption

    -- ─────────────────────────────────────────────────────────────
    -- DEATH KNIGHT  (Blood=250, Frost=251, Unholy=252)
    -- ─────────────────────────────────────────────────────────────
    [206930] = 250,  -- Heart Strike
    [195182] = 250,  -- Marrowrend
    [50842]  = 250,  -- Blood Boil
    [194679] = 250,  -- Rune Tap
    [49184]  = 251,  -- Howling Blast
    [49020]  = 251,  -- Obliterate
    [196770] = 251,  -- Remorseless Winter
    [51271]  = 251,  -- Pillar of Frost
    [85948]  = 252,  -- Festering Strike
    [55090]  = 252,  -- Scourge Strike
    [207311] = 252,  -- Clawing Shadows
    [275699] = 252,  -- Apocalypse
    [42650]  = 252,  -- Army of the Dead

    -- ─────────────────────────────────────────────────────────────
    -- SHAMAN  (Elemental=262, Enhancement=263, Restoration=264)
    -- ─────────────────────────────────────────────────────────────
    [8042]   = 262,  -- Earth Shock
    [51505]  = 262,  -- Lava Burst (Ele mostly)
    [188196] = 262,  -- Lightning Bolt (modern Ele)
    [61882]  = 262,  -- Earthquake
    [192249] = 262,  -- Storm Elemental
    [17364]  = 263,  -- Stormstrike
    [60103]  = 263,  -- Lava Lash
    [187874] = 263,  -- Crash Lightning
    [115356] = 263,  -- Windstrike
    [196884] = 263,  -- Feral Spirit (modern)
    [61295]  = 264,  -- Riptide
    [77472]  = 264,  -- Healing Wave
    [73920]  = 264,  -- Healing Rain
    [98008]  = 264,  -- Spirit Link Totem

    -- ─────────────────────────────────────────────────────────────
    -- MAGE  (Arcane=62, Fire=63, Frost=64)
    -- ─────────────────────────────────────────────────────────────
    [30451]  = 62,   -- Arcane Blast
    [44425]  = 62,   -- Arcane Barrage
    [5143]   = 62,   -- Arcane Missiles
    [12042]  = 62,   -- Arcane Power / Surge
    [365350] = 62,   -- Arcane Surge
    [11366]  = 63,   -- Pyroblast
    [133]    = 63,   -- Fireball (Fire-tilted)
    [2948]   = 63,   -- Scorch
    [108853] = 63,   -- Fire Blast (instant Fire signature)
    [190319] = 63,   -- Combustion
    [116]    = 64,   -- Frostbolt (Mage version)
    [30455]  = 64,   -- Ice Lance
    [84714]  = 64,   -- Frozen Orb
    [12472]  = 64,   -- Icy Veins
    [44572]  = 64,   -- Deep Freeze (legacy / talent)

    -- ─────────────────────────────────────────────────────────────
    -- WARLOCK  (Affliction=265, Demonology=266, Destruction=267)
    -- ─────────────────────────────────────────────────────────────
    [316099] = 265,  -- Unstable Affliction
    [324536] = 265,  -- Malefic Rapture
    [980]    = 265,  -- Agony
    [146739] = 265,  -- Corruption (Aff-tilted in modern)
    [27243]  = 265,  -- Seed of Corruption
    [105174] = 266,  -- Hand of Gul'dan
    [196277] = 266,  -- Implosion
    [264178] = 266,  -- Demonbolt (talent)
    [265187] = 266,  -- Summon Demonic Tyrant
    [111898] = 266,  -- Grimoire: Felguard
    [116858] = 267,  -- Chaos Bolt
    [17962]  = 267,  -- Conflagrate
    [29722]  = 267,  -- Incinerate (Destro-tilted)
    [348]    = 267,  -- Immolate
    [1122]   = 267,  -- Summon Infernal

    -- ─────────────────────────────────────────────────────────────
    -- MONK  (Brewmaster=268, Windwalker=269, Mistweaver=270)
    -- ─────────────────────────────────────────────────────────────
    [121253] = 268,  -- Keg Smash
    [115181] = 268,  -- Breath of Fire
    [115308] = 268,  -- Elusive Brew (older) / Purifying Brew (322507)
    [322507] = 268,  -- Celestial Brew
    [115151] = 270,  -- Renewing Mist
    [115175] = 270,  -- Soothing Mist
    [116680] = 270,  -- Thunder Focus Tea
    [124682] = 270,  -- Enveloping Mist
    [197908] = 270,  -- Mana Tea
    [107428] = 269,  -- Rising Sun Kick (Windwalker primary)
    [113656] = 269,  -- Fists of Fury
    [101545] = 269,  -- Flying Serpent Kick
    [137639] = 269,  -- Storm, Earth, and Fire
    [392983] = 269,  -- Strike of the Windlord

    -- ─────────────────────────────────────────────────────────────
    -- DRUID  (Balance=102, Feral=103, Guardian=104, Restoration=105)
    -- ─────────────────────────────────────────────────────────────
    [78674]  = 102,  -- Starsurge
    [194153] = 102,  -- Starfire (Balance form)
    [191034] = 102,  -- Starfall
    [202770] = 102,  -- Fury of Elune
    [197626] = 102,  -- Starlord-related (older) / Solar Beam (78675)
    [78675]  = 102,  -- Solar Beam
    [5221]   = 103,  -- Shred
    [1079]   = 103,  -- Rip
    [22568]  = 103,  -- Ferocious Bite
    [202028] = 103,  -- Brutal Slash (talent)
    [106951] = 103,  -- Berserk (Feral)
    [33917]  = 104,  -- Mangle (Guardian primary)
    [6807]   = 104,  -- Maul
    [192081] = 104,  -- Ironfur
    [22842]  = 104,  -- Frenzied Regeneration
    [102558] = 104,  -- Incarnation: Guardian of Ursoc
    [774]    = 105,  -- Rejuvenation
    [48438]  = 105,  -- Wild Growth
    [33763]  = 105,  -- Lifebloom
    [102342] = 105,  -- Ironbark
    [740]    = 105,  -- Tranquility

    -- ─────────────────────────────────────────────────────────────
    -- DEMON HUNTER  (Havoc=577, Vengeance=581)
    -- ─────────────────────────────────────────────────────────────
    [188499] = 577,  -- Blade Dance
    [198013] = 577,  -- Eye Beam
    [162794] = 577,  -- Chaos Strike
    [191427] = 577,  -- Metamorphosis (Havoc form)
    [258920] = 577,  -- Immolation Aura (Havoc-tilted, but multi)
    [228477] = 581,  -- Soul Cleave
    [203720] = 581,  -- Demon Spikes
    [263648] = 581,  -- Soul Barrier (talent legacy)
    [187827] = 581,  -- Metamorphosis (Vengeance form)
    [204021] = 581,  -- Fiery Brand
    [263642] = 581,  -- Fracture

    -- ─────────────────────────────────────────────────────────────
    -- EVOKER  (Devastation=1467, Preservation=1468, Augmentation=1473)
    -- ─────────────────────────────────────────────────────────────
    [356995] = 1467, -- Disintegrate
    [357211] = 1467, -- Pyre
    [357210] = 1467, -- Deep Breath
    [369536] = 1467, -- Soar (movement, Dev-tilted)
    [382266] = 1467, -- Firestorm
    [364343] = 1468, -- Echo
    [366155] = 1468, -- Reversion
    [355936] = 1468, -- Dream Breath
    [367226] = 1468, -- Spiritbloom
    [357170] = 1468, -- Time Dilation
    [395152] = 1473, -- Ebon Might
    [409311] = 1473, -- Prescience
    [395160] = 1473, -- Eruption
    [403631] = 1473, -- Breath of Eons
    [413984] = 1473, -- Sands of Time (related)
}

----------------------------------------------------------------------
-- Spec name cache.  Keyed by sourceName (non-secret in combat log).
-- Wiped on PLAYER_ENTERING_WORLD so a fresh BG / arena starts clean.
----------------------------------------------------------------------
ns.SPEC_BY_NAME = {}     -- name -> localized specName ("Frost", etc.)

local function _ResolveSpecName(specID)
    if not (specID and GetSpecializationInfoByID) then return nil end
    local _, specName = GetSpecializationInfoByID(specID)
    -- GetSpecializationInfoByID returns static Blizzard data — never
    -- secret-tagged.  We can use it freely for SetText.
    if specName and specName ~= "" then return specName end
    return nil
end

-- Public hook used by Labels.lua _GetSpecByScore as a fallback.
function ns:GetSpecByCombatLog(playerName)
    if not playerName then return nil end
    if issecretvalue and issecretvalue(playerName) then return nil end
    return ns.SPEC_BY_NAME[playerName]
end

-- 1.34.1: cache-size introspection for /mnp mem.
function ns:CountSpecByCombatLog()
    if not ns.SPEC_BY_NAME then return 0 end
    local n = 0
    for _ in pairs(ns.SPEC_BY_NAME) do n = n + 1 end
    return n
end

----------------------------------------------------------------------
-- Combat log listener
--
-- DISABLED in 1.28.3 — see disable comment below.
--
-- The user reported the hard "MyNamePlates has been blocked from an
-- action only available to the Blizzard UI" popup starting exactly
-- at 1.28.0, the version that introduced this combat-log handler.
-- We added issecretvalue guards on every payload field in 1.28.1+
-- and fixed three OTHER taint vectors in Discovery.lua's hooks in
-- 1.28.2 — but the hard block kept firing.  The remaining hypothesis
-- is that subscribing to COMBAT_LOG_EVENT_UNFILTERED in a 12.x BG
-- with anonymised enemies is itself enough to trigger Blizzard's
-- secure-execution checker (the firehose of events brushes against
-- some secret-tagged value Blizzard's protection considers fatal,
-- even if our explicit checks miss it by milliseconds).
--
-- Until we can prove the exact taint source, OFF is safer than
-- "mostly works".  The user keeps the class-name fallback from
-- _GetSpecByScore (the localized class shows on enemy plates),
-- they just don't get the spec-via-combat-log upgrade.  When we
-- find a reproducer for the remaining taint, re-enable this block.
----------------------------------------------------------------------
local f = CreateFrame("Frame")
-- Intentionally NOT subscribing to COMBAT_LOG_EVENT_UNFILTERED.
-- See big comment above.  PVP_MATCH_ACTIVE / PLAYER_ENTERING_WORLD
-- still register so the cache wipes between matches if it ever
-- happens to be populated by a future re-enable.
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PVP_MATCH_ACTIVE")

-- Combat log flag bits used to gate to ENEMY PLAYER sources only.
-- (Avoids polluting the cache with our own / friendly casts.)
local AFFILIATION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
local TYPE_PLAYER          = COMBATLOG_OBJECT_TYPE_PLAYER       or 0x400

-- Per-payload secret-string audit.  In retail Midnight 12.x ANY
-- combat-log payload field — sourceName, sourceFlags, subevent,
-- spellID — can be secret-tagged when the source is an anonymised
-- BG enemy.  Comparing, concatenating, hashing, or indexing with
-- ANY of them taints our execution context and produces "Action
-- blocked by Blizzard" on the next secure operation we touch.
-- So before doing ANYTHING with a field we must issecretvalue-
-- guard it.  This is the same rule as every other unit-derived
-- value in the addon — we just hadn't applied it inside combat
-- log handling yet.
local function _isSecret(v)
    return v ~= nil and issecretvalue and issecretvalue(v)
end

f:SetScript("OnEvent", function(_, event)
    if event ~= "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Reset cache on instance / match transitions.
        wipe(ns.SPEC_BY_NAME)
        return
    end

    -- Pull combat log payload positionally.
    local _, subevent, _, _, sourceName, sourceFlags, _, _, _, _, _, spellID =
        CombatLogGetCurrentEventInfo()

    -- Guard EVERY field used downstream.  Bail on secret/nil for
    -- any of them — no comparison, no bit.band, no table index
    -- before this gate passes.
    if not spellID    or _isSecret(spellID)    then return end
    if not sourceName or _isSecret(sourceName) then return end
    if not subevent   or _isSecret(subevent)   then return end
    if not sourceFlags or _isSecret(sourceFlags) then return end

    -- Cache hit short-circuit (first hit wins so a shared spell
    -- like Frostbolt doesn't ping-pong us between Frost Mage and
    -- Frost DK for the same name).
    if ns.SPEC_BY_NAME[sourceName] then return end

    -- Hostile player filter — once sourceFlags has passed the
    -- secret guard, the bitwise ops are safe.
    if not (bit and bit.band) then return end
    local isHostile = bit.band(sourceFlags, AFFILIATION_HOSTILE) ~= 0
    if not isHostile then return end
    local isPlayer  = bit.band(sourceFlags, TYPE_PLAYER) ~= 0
    if not isPlayer then return end

    -- Subevent filter — only the events that actually carry the
    -- spec-defining signal.
    if subevent ~= "SPELL_CAST_SUCCESS"
       and subevent ~= "SPELL_CAST_START"
       and subevent ~= "SPELL_AURA_APPLIED"
       and subevent ~= "SPELL_DAMAGE"
       and subevent ~= "SPELL_HEAL"
    then
        return
    end

    -- Now safe to index our spell→spec table.
    local specID = ns.SPEC_BY_SPELL[spellID]
    if not specID then return end

    local specName = _ResolveSpecName(specID)
    if not specName then return end

    ns.SPEC_BY_NAME[sourceName] = specName

    -- Kick the label pipeline so the new spec lands on the plate
    -- immediately.  pcall — never let a label refresh error abort
    -- combat-log processing.
    if ns.RefreshAllLabels then pcall(ns.RefreshAllLabels, ns) end
end)

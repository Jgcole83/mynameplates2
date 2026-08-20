-- Labels.lua
-- Three independent label paths, each with its own widget strategy:
--
--   1. Player / regular-NPC NAME (`L.name`)
--      Reposition Blizzard's existing `uf.name` FontString via a
--      hooksecurefunc on its :SetPoint, following BBP's pattern
--      (midnight/BetterBlizzPlates.lua, BBP.RepositionName ~line 5318).
--      Reliable for plates that don't get the engine's aggressive
--      alpha clamp (player & NPC plates do not, in any context).
--
--   2. Summon NAME (`L.petTotemName`)  — pets, totems, guardians,
--      minions, minor, psyfiend.
--      CUSTOM FontString (`plate.MyNP_SummonName`), identical pattern
--      to Spec below.  We don't reuse Blizzard's `uf.name` here
--      because in retail Midnight arenas the engine fades AND
--      re-anchors `uf.name` on non-target summons via
--      CompactUnitFrame_UpdateName — `SetIgnoreParentAlpha(true)`
--      blocks parent alpha inheritance but not the engine's direct
--      SetAlpha writes, so the totem/pet text still disappeared off-
--      target.  A custom FontString sidesteps the engine entirely
--      and mirrors how Spec already works flawlessly in arena.
--      To prevent double-text in the open world (where Blizzard's
--      uf.name renders fine by default), we move uf.name far off-
--      screen via SetPoint (see _SuppressUFName).  SetPoint is the
--      ONLY safe primitive for this — SetText / SetAlpha / Show /
--      Hide all propagate addon taint up the secure nameplate
--      chain and produce "Interface action failed because of an
--      AddOn" cascades.  The SetPoint hook (_HookName) keeps the
--      off-screen anchor sticky against engine UpdateAnchors
--      re-anchors during target swaps and faction changes.
--
--   3. SPEC (`L.spec`)
--      Custom FontString (`plate.MyNP_SpecText`) since Blizzard
--      doesn't render a spec line at all.  Spec resolution chain:
--      self -> ArenaMap canonical token -> tooltip scan (with
--      secret-GUID guard).  Spec stays player-only by design.
--
-- Friendly vs enemy gating is per-block via applyFriendly /
-- applyEnemy checkboxes; UnitIsFriend correctly classifies non-
-- player units (a friendly totem returns true, an enemy totem
-- returns false).
--
-- The per-summon-type filter on the petTotemName block lets the
-- user cherry-pick which summon kinds get the always-visible label
-- (totems & psyfiend ON by default, pets / minions / etc. OFF) so
-- arena doesn't get cluttered with Wild Imp / Dreadstalker spam.

local _, ns = ...

----------------------------------------------------------------------
-- Forbidden-frame guard.  Match BBP exactly (BetterBlizzPlates.lua
-- ~line 5349): check ONLY the UnitFrame's forbidden status, not the
-- top-level nameplate's.  In retail Midnight, arena pet & totem
-- plates can have a forbidden top-level plate but a NON-forbidden
-- UnitFrame — and modifying uf.name (a child of the non-forbidden
-- uf) is safe in that case.  Earlier "check both" behaviour caused
-- the Pet & Totem Name offsets not to apply on arena summon plates
-- because the top-level plate flag was sticky.  Operations that
-- target the top-level plate directly (Discovery's plate:SetAlpha
-- in ApplyOverrides) silently no-op on a forbidden plate, so they
-- don't need the extra guard.
----------------------------------------------------------------------
local function _IsForbidden(plate, uf)
    if uf and uf.IsForbidden and uf:IsForbidden() then return true end
    return false
end

----------------------------------------------------------------------
-- Totem icon overlay (BBP-style; retail Midnight 12.x arena fallback).
--
-- Mirrors BBP midnight/modules/totem.lua's rendering strategy: a small
-- icon + color at a configurable position on any plate classified as a
-- summon.  Runs alongside the petTotemName TEXT overlay above — text
-- works where UnitName is resolvable (world / BG / after target-capture),
-- icon works everywhere including anonymised arena enemy plates where
-- the name path is fundamentally blocked by Blizzard's anonymisation
-- (see BBP CHANGELOG 2.0.4: "Best that can be done atm.").
--
-- Detection heuristic (BBP pattern):
--   1. UnitCastingInfo(unit)      → Capacitor Totem  (orange, cap icon)
--   2. UnitChannelInfo(unit)      → Psyfiend         (purple, psy icon)
--   3. First HELPFUL aura +
--      C_Spell.IsSpellImportant   → aura icon        (magenta if important
--                                                     else brown)
--   4. otherwise                  → generic totem    (brown)
--
-- Membership is decided by ns:IsSummonPlate / _summonByPlate cache +
-- the petTotemName per-type filter — same gating as the text overlay,
-- so friendly/enemy + per-type checkboxes on the UI apply uniformly.
----------------------------------------------------------------------
local TOTEM_ICON_GENERIC   = "Interface\\Icons\\Spell_shaman_totemrecall"
local TOTEM_ICON_IMPORTANT = "Interface\\Icons\\Spell_Nature_Groundingtotem"
local TOTEM_ICON_CAP       = C_Spell and C_Spell.GetSpellTexture
                             and C_Spell.GetSpellTexture(192058)
                             or "Interface\\Icons\\Spell_Nature_Skinofearth"
local TOTEM_ICON_PSYFIEND  = C_Spell and C_Spell.GetSpellTexture
                             and C_Spell.GetSpellTexture(199824)
                             or "Interface\\Icons\\Ability_Priest_Psyfiend"

local TOTEM_COLOR_GENERIC  = { 0.40, 0.34, 0.21 }   -- neutral brown
local TOTEM_COLOR_IMPORTANT= { 1.00, 0.00, 1.00 }   -- magenta (Grounding-class)
local TOTEM_COLOR_CAP      = { 1.00, 0.69, 0.00 }   -- orange
local TOTEM_COLOR_PSYFIEND = { 0.49, 0.00, 1.00 }   -- purple

-- 1.36.26: per-summonType fallback icons + colors.  Prior to this,
-- every summon whose classifier fell through to Step 4 got the generic
-- totem-recall icon in brown — including warlock Observers, DK Ghouls,
-- Water Elementals, non-channeling Psyfiends, etc.  A warlock pet
-- plate wearing the shaman totem-recall icon reads as broken.
--
-- Now Step 4 indexes into ICON_BY_TYPE by the plate's resolved
-- summonType (from _TotemIconType) and uses a class-appropriate
-- generic instead.  Users who target/mouseover a summon (or see it
-- classified via NPC_DATA) get an icon that at minimum communicates
-- "this is a warlock pet" / "this is a Psyfiend" / "this is a
-- guardian" rather than "this is an unknown totem".
--
-- Users still get the exact right icon (Grounding icon on Grounding,
-- etc.) whenever _ClassifyTotem Step 1 succeeds — i.e. whenever the
-- npcID resolves and NPC_DATA has a spellID.  This table is purely
-- the last-resort fallback for un-curated or fully-anonymised plates.
--
-- COLOR_BY_TYPE mirrors the same idea for the healthbar + name
-- recolor path.  Class colors chosen from Blizzard's canonical
-- RAID_CLASS_COLORS values.
local TOTEM_ICON_PET_WARLOCK = C_Spell and C_Spell.GetSpellTexture
                               and C_Spell.GetSpellTexture(30146)      -- Summon Felguard
                               or "Interface\\Icons\\Spell_Shadow_SummonFelguard"
local TOTEM_ICON_PET_HUNTER  = C_Spell and C_Spell.GetSpellTexture
                               and C_Spell.GetSpellTexture(883)        -- Call Pet 1
                               or "Interface\\Icons\\Ability_Hunter_BeastCall"
local TOTEM_ICON_PET_DK      = C_Spell and C_Spell.GetSpellTexture
                               and C_Spell.GetSpellTexture(46584)      -- Raise Dead
                               or "Interface\\Icons\\Spell_Shadow_AnimateDead"
local TOTEM_ICON_PET_MAGE    = C_Spell and C_Spell.GetSpellTexture
                               and C_Spell.GetSpellTexture(31687)      -- Summon Water Elemental
                               or "Interface\\Icons\\Spell_Frost_SummonWaterElemental"
local TOTEM_ICON_GUARDIAN    = C_Spell and C_Spell.GetSpellTexture
                               and C_Spell.GetSpellTexture(1122)       -- Summon Infernal
                               or "Interface\\Icons\\Spell_Shadow_SummonInfernal"
local TOTEM_ICON_MINION      = C_Spell and C_Spell.GetSpellTexture
                               and C_Spell.GetSpellTexture(104316)     -- Call Dreadstalkers
                               or "Interface\\Icons\\Spell_Warlock_Calldreadstalkers"

local ICON_BY_TYPE = {
    totem       = TOTEM_ICON_GENERIC,
    psyfiend    = TOTEM_ICON_PSYFIEND,
    pet_warlock = TOTEM_ICON_PET_WARLOCK,
    pet_hunter  = TOTEM_ICON_PET_HUNTER,
    pet_dk      = TOTEM_ICON_PET_DK,
    pet_mage    = TOTEM_ICON_PET_MAGE,
    guardian    = TOTEM_ICON_GUARDIAN,
    minion      = TOTEM_ICON_MINION,
    minor       = TOTEM_ICON_MINION,
}

-- Class colors from RAID_CLASS_COLORS; brown fallback for uncertain
-- types like generic guardians/minions (any class can summon those).
local COLOR_BY_TYPE = {
    totem       = TOTEM_COLOR_GENERIC,             -- brown (user-configurable via genericColor)
    psyfiend    = TOTEM_COLOR_PSYFIEND,            -- purple
    pet_warlock = { 0.58, 0.51, 0.79 },            -- warlock purple
    pet_hunter  = { 0.67, 0.83, 0.45 },            -- hunter green
    pet_dk      = { 0.77, 0.12, 0.23 },            -- DK red
    pet_mage    = { 0.25, 0.78, 0.92 },            -- mage light-blue
    guardian    = TOTEM_COLOR_GENERIC,             -- unknown owner class
    minion      = TOTEM_COLOR_GENERIC,             -- unknown owner class
    minor       = TOTEM_COLOR_GENERIC,             -- unknown owner class
}

-- Read the user-configurable generic totem color (BBP parity —
-- BetterBlizzPlatesDB.totemIndicatorTotemColor).  Falls back to the
-- hardcoded neutral brown when the DB isn't ready yet.  Returns three
-- values so callers can use it in multi-return classification without
-- allocating a table.
local function _GenericColorRGB()
    local L = MyNamePlatesDB and MyNamePlatesDB.labels
    local c = L and L.petTotemName and L.petTotemName.genericColor
    if type(c) == "table" and c[1] and c[2] and c[3] then
        return c[1], c[2], c[3]
    end
    return TOTEM_COLOR_GENERIC[1], TOTEM_COLOR_GENERIC[2], TOTEM_COLOR_GENERIC[3]
end

-- Resolve the npcID for a plate/unit pair.  Consults, in priority order:
--   1. The Discovery-managed active[] entry (populated at
--      NAME_PLATE_UNIT_ADDED with the fresh GUID split).
--   2. The per-plate summon capture cache (populated at
--      PLAYER_TARGET_CHANGED / UPDATE_MOUSEOVER_UNIT from the non-secret
--      target/mouseover token).
--   3. A direct UnitGUID re-parse, secret-safe.
-- Returns nil when every path fails (fully anonymised plate).  Called
-- from _ClassifyTotem below to promote NPC_DATA-driven icon + importance
-- above the cast/channel/aura heuristics.
local function _ResolvePlateNpcID(plate, unit)
    if plate and ns.GetSummonNpcIDByPlate then
        local n = ns:GetSummonNpcIDByPlate(plate)
        if n then return n end
    end
    if unit then
        if not (issecretvalue and issecretvalue(unit)) then
            if ns.GetSummonInfoForUnit then
                local info = ns:GetSummonInfoForUnit(unit)
                if info and info.npcID then return info.npcID end
            end
            local okG, guid = pcall(UnitGUID, unit)
            if okG and guid and not (issecretvalue and issecretvalue(guid)) then
                local k, _, _, _, _, n = strsplit("-", guid)
                if k and not (issecretvalue and issecretvalue(k))
                   and (k == "Creature" or k == "Pet" or k == "Vehicle") then
                    return tonumber(n)
                end
            end
        end
    end
    return nil
end

-- Look up the curated record for an npcID.  Prefers the live user-
-- editable table (MyNamePlatesDB.npcs) so runtime `/mnp add` and
-- auto-discovery writes take effect immediately, falls back to the
-- shipped NPC_DATA table.  Guards against secret-tagged fields on
-- the record (unlikely but cheap to enforce).
local function _NpcRecord(npcID)
    if not npcID then return nil end
    local rec
    if MyNamePlatesDB and MyNamePlatesDB.npcs and MyNamePlatesDB.npcs[npcID] then
        rec = MyNamePlatesDB.npcs[npcID]
    elseif ns.NPC_DATA and ns.NPC_DATA[npcID] then
        rec = ns.NPC_DATA[npcID]
    end
    return rec
end

-- Classify a totem-plate's visual treatment.  Priority order (highest
-- confidence first):
--
--   1. NPC_DATA record for the plate's npcID (v1.36.1).  When we know
--      exactly which totem this is (Grounding, Tremor, Healing Tide,
--      etc.), use its canonical spellID for the icon and honour the
--      curated `important = true` flag for arena-critical totems.  This
--      is the "matches the right totem" path — Grounding shows the
--      Grounding icon in magenta, Tremor shows the Tremor icon in
--      magenta, etc.
--   2. UnitChannelInfo → Psyfiend (BBP pattern for anonymised plates
--      where npcID is unresolvable but channel state is still visible).
--   3. UnitCastingInfo → Capacitor Totem (same rationale).
--   4. First HELPFUL aura icon (fallback for un-curated totems).
--   5. Generic totem icon + generic color.
--
-- Signature returns (icon, r, g, b, isImportant, isImportantAura,
-- duration, hasAura) — same shape as before so the caller
-- (_ApplyTotemIcon) doesn't need signature changes.
--
-- The plate argument is used only to resolve npcID; classification
-- still works if plate is nil (older call sites) but skips path #1.
local function _ClassifyTotem(unit, plate, summonType)
    -- Icon-selection strategy (in order of confidence, restructured in
    -- 1.36.10 to make sure "correct icon" wins over "generic icon" as
    -- often as possible for arena-critical totems):
    --
    --   Step 1 — NPC_DATA icon.  If we know exactly which totem this is
    --            (by npcID) and NPC_DATA has a spellID / icon override,
    --            render it.  Best signal — exact match to the totem.
    --   Step 2 — Cast / channel icon.  Psyfiend channels Psychic Fear;
    --            Capacitor Totem casts Static Charge.  Both are useful
    --            for anonymised arena plates where npcID isn't resolvable
    --            but the cast/channel state still leaks through.
    --   Step 3 — Helpful aura icon.  Every totem worth caring about
    --            emits a HELPFUL aura visible via C_UnitAuras.  This is
    --            the same signal BBP falls back to.  Prefer NPC_DATA's
    --            `important` flag when we have one; otherwise use
    --            C_Spell.IsSpellImportant on the aura's spellID.
    --            1.36.26: only fires for totem / psyfiend summonType.
    --            For warlock/hunter/DK/mage pets and guardians, the
    --            first HELPFUL aura is a random buff (Prowl, various
    --            demon buffs) that doesn't visually identify the pet
    --            and often reads worse than the type-specific fallback.
    --   Step 4 — Type-specific generic icon.  Was totem-recall for
    --            everything pre-1.36.26; now indexed into ICON_BY_TYPE
    --            by summonType so a warlock Observer gets a demon-
    --            summon icon, a DK Ghoul gets Raise Dead, a mage
    --            Water Elemental gets its summon icon, etc.  Preserves
    --            NPC_DATA's `important` flag by returning magenta color
    --            so the plate still gets the arena classification cue
    --            (glow + pulse + magenta) even if we couldn't nail the
    --            exact spellbook icon.
    --
    -- summonType parameter (1.36.26): the plate's resolved summon
    -- type from _TotemIconType (pet_warlock, psyfiend, totem, guardian,
    -- minion, minor, pet_hunter, pet_dk, pet_mage).  Used to pick the
    -- Step 4 fallback and to gate Step 3.  Optional — nil-safe (falls
    -- back to totem-recall + generic color, same as pre-1.36.26).
    local npcID = _ResolvePlateNpcID(plate, unit)
    local rec   = npcID and _NpcRecord(npcID) or nil
    local recImportant = rec and rec.important or false

    -- ── Step 1: NPC_DATA-driven icon ──────────────────────────────────
    local npcDataIcon
    if rec then
        -- Primary: C_Spell.GetSpellTexture(spellID).  Fast path.
        if rec.spellID and C_Spell and C_Spell.GetSpellTexture then
            local okI, tex = pcall(C_Spell.GetSpellTexture, rec.spellID)
            if okI and tex and not (issecretvalue and issecretvalue(tex)) then
                npcDataIcon = tex
            end
        end
        -- Fallback: C_Spell.GetSpellInfo(spellID).iconID.  Some PvP-
        -- talent totem spellIDs (Static Field, Counterstrike, Voodoo,
        -- Lightning Surge, etc.) return nil from GetSpellTexture when
        -- the local player isn't a shaman with the talent selected but
        -- succeed via GetSpellInfo which reads a broader spell table.
        if not npcDataIcon and rec.spellID and C_Spell and C_Spell.GetSpellInfo then
            local okS, spellInfo = pcall(C_Spell.GetSpellInfo, rec.spellID)
            if okS and type(spellInfo) == "table" and spellInfo.iconID
               and not (issecretvalue and issecretvalue(spellInfo.iconID)) then
                npcDataIcon = spellInfo.iconID
            end
        end
        -- rec.icon = explicit texture path override (rare).
        if not npcDataIcon and rec.icon then npcDataIcon = rec.icon end
    end
    if npcDataIcon then
        if recImportant then
            return npcDataIcon,
                   TOTEM_COLOR_IMPORTANT[1], TOTEM_COLOR_IMPORTANT[2], TOTEM_COLOR_IMPORTANT[3],
                   true, false, nil, false
        end
        local gr, gg, gb = _GenericColorRGB()
        return npcDataIcon, gr, gg, gb, false, false, nil, false
    end

    -- ── Step 2: Cast / channel icon ───────────────────────────────────
    -- Wrap every Unit* call in pcall — on rare edge cases (unit token
    -- flips secret mid-frame) these can throw and we don't want the
    -- whole label pipeline to fault.
    if unit then
        local ok1, channeling = pcall(UnitChannelInfo, unit)
        if ok1 and channeling then
            return TOTEM_ICON_PSYFIEND,
                   TOTEM_COLOR_PSYFIEND[1], TOTEM_COLOR_PSYFIEND[2], TOTEM_COLOR_PSYFIEND[3],
                   true, false, 12, false
        end
        local ok2, casting = pcall(UnitCastingInfo, unit)
        if ok2 and casting then
            return TOTEM_ICON_CAP,
                   TOTEM_COLOR_CAP[1], TOTEM_COLOR_CAP[2], TOTEM_COLOR_CAP[3],
                   true, false, 2, false
        end
    end

    -- ── Step 3: Helpful aura icon (totem / psyfiend only) ─────────────
    -- 1.36.26: gate on summonType.  Helpful auras are a good totem
    -- signal (Grounding, Tremor, Earthbind, Healing Tide all emit
    -- HELPFUL auras).  For pets/guardians/minions the first helpful
    -- aura is a random buff (Prowl, minor combat buffs, demon
    -- self-buffs) that visually looks like a random spell — worse
    -- than the type-specific fallback in Step 4.
    local auraEligible = (not summonType) or summonType == "totem"
                                            or summonType == "psyfiend"
    if auraEligible and unit and C_UnitAuras and C_UnitAuras.GetUnitAuras then
        local ok3, auras = pcall(C_UnitAuras.GetUnitAuras, unit, "HELPFUL")
        if ok3 and type(auras) == "table" and auras[1] then
            local a = auras[1]
            if a and a.icon and not (issecretvalue and issecretvalue(a.icon)) then
                -- NPC_DATA importance wins over IsSpellImportant heuristic.
                if recImportant then
                    return a.icon,
                           TOTEM_COLOR_IMPORTANT[1], TOTEM_COLOR_IMPORTANT[2], TOTEM_COLOR_IMPORTANT[3],
                           true, false, nil, true
                end
                local imp = false
                if C_Spell and C_Spell.IsSpellImportant and a.spellId then
                    local ok4, v = pcall(C_Spell.IsSpellImportant, a.spellId)
                    if ok4 and v then imp = true end
                end
                if imp then
                    return a.icon,
                           TOTEM_COLOR_IMPORTANT[1], TOTEM_COLOR_IMPORTANT[2], TOTEM_COLOR_IMPORTANT[3],
                           false, true, nil, true
                end
                local gr, gg, gb = _GenericColorRGB()
                return a.icon, gr, gg, gb, false, false, nil, true
            end
        end
    end

    -- ── Step 4: Type-specific generic icon (last resort) ──────────────
    -- 1.36.26: was hardcoded TOTEM_ICON_GENERIC (shaman totem-recall)
    -- for every summon type; now indexed by summonType so warlock
    -- pets get a demon icon, DK Ghouls get Raise Dead, Water
    -- Elementals get their summon icon, non-channeling Psyfiends get
    -- the Psyfiend icon, etc.  Falls through to totem-recall for
    -- unknown summonType (matches pre-1.36.26 behavior).
    --
    -- Preserve NPC_DATA's `important` flag so the plate still gets
    -- magenta + glow + pulse — better a wrong icon than a lost
    -- arena classification cue.
    local fallbackIcon = ICON_BY_TYPE[summonType or "totem"] or TOTEM_ICON_GENERIC
    if recImportant then
        return fallbackIcon,
               TOTEM_COLOR_IMPORTANT[1], TOTEM_COLOR_IMPORTANT[2], TOTEM_COLOR_IMPORTANT[3],
               true, false, nil, false
    end
    -- Color also indexed by summonType so a warlock pet plate reads
    -- as purple (warlock class color), DK Ghoul as red, etc.  Falls
    -- back to the user-configurable generic brown for unknown types
    -- and for totems / guardians / minions where the summoner class
    -- can't be determined from summonType alone.
    local col = COLOR_BY_TYPE[summonType or "totem"] or TOTEM_COLOR_GENERIC
    local r, g, b
    if col == TOTEM_COLOR_GENERIC then
        r, g, b = _GenericColorRGB()
    else
        r, g, b = col[1], col[2], col[3]
    end
    return fallbackIcon, r, g, b, false, false, nil, false
end

-- Lazy per-plate icon widget.  Same forbidden-check pattern as
-- _GetSpecText / _GetIcon (Auras.lua) — parenting a texture on a
-- forbidden UnitFrame propagates addon taint, so we bail on those
-- plates rather than render the icon (matches BBP's own defensive
-- posture on forbidden arena frames).
--
-- 1.35.0: full BBP frame hierarchy — icon + glow (with mask) +
-- cooldown swipe + pulse animation group.  Mirrors BBP's
-- CreateTotemComponents + ApplyGlow so the visual result is identical.
--
-- Structure:
--   frame  (Frame,       HIGH strata,     parent = uf)
--     tex          (Texture, OVERLAY,     :SetAllPoints(frame))
--     mask         (MaskTexture,          :SetAllPoints(tex))  -- only added to tex when glow shows
--     glow         (Texture, OVERLAY-7,   ADD blend, atlas "clickcast-highlight-spellbook", desaturated)
--     cd           (Cooldown, "CooldownFrameTemplate", reverse swipe, inset 1px)
--     anim         (AnimationGroup, pulse Scale 1.1 <-> 0.9091, 0.5s each, REPEAT)
local function _GetTotemIcon(plate)
    if plate.MyNP_TotemIcon then return plate.MyNP_TotemIcon end
    local uf = plate.UnitFrame
    if not uf then return nil end
    if _IsForbidden(plate, uf) then return nil end

    local frame = CreateFrame("Frame", nil, uf)
    frame:SetFrameStrata("HIGH")
    frame:Hide()

    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(frame)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim default icon border
    frame.tex = tex

    -- Decouple from parent alpha so the icon stays crisp on faded
    -- non-target arena plates.  Same trick as the Spec FontString —
    -- the engine drives the plate alpha aggressively in arena and
    -- without this the icon would fade with the plate.
    if frame.SetIgnoreParentAlpha then
        pcall(frame.SetIgnoreParentAlpha, frame, true)
    end

    -- Glow layer (BBP ApplyGlow pattern).  Lives at OVERLAY layer 7 so
    -- it stacks on top of the icon.  ADD blend + desaturated makes the
    -- atlas render as a colored halo rather than the raw pink/purple
    -- of the source texture.  Hidden by default; _ApplyTotemIcon
    -- decides whether to show + which color per refresh.
    frame.glow = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    frame.glow:SetBlendMode("ADD")
    if frame.glow.SetAtlas then
        pcall(frame.glow.SetAtlas, frame.glow, "clickcast-highlight-spellbook")
    end
    frame.glow:SetDesaturated(true)
    frame.glow:Hide()

    -- Mask for the glow (BBP pattern) — softens the icon's square
    -- corners so the halo blends into a rounded highlight rather than
    -- clipping at the icon rectangle.  Only wired to the icon texture
    -- when the glow is actually showing (see _ApplyTotemIcon), so the
    -- icon stays crisp/square when no glow is applied.
    frame.mask = frame:CreateMaskTexture()
    pcall(frame.mask.SetTexture, frame.mask,
        "Interface\\TalentFrame\\talentsmasknodechoiceflyout",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    frame.mask:SetAllPoints(tex)
    frame.maskAttached = false

    -- Cooldown swipe (BBP pattern) — reverse-fill so the sweep
    -- represents time REMAINING, not time elapsed.  Inset 1px on
    -- every side so the swipe doesn't clip the icon border.
    -- Started/stopped by _ApplyTotemIcon based on classification
    -- (Cap = 2s, Psyfiend = 12s, others = no swipe).
    frame.cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    frame.cd:SetPoint("TOPLEFT",     frame, "TOPLEFT",     1, -1)
    frame.cd:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    if frame.cd.SetReverse then pcall(frame.cd.SetReverse, frame.cd, true) end
    frame.cd:Hide()

    -- Pulse animation group (BBP SetupUnifiedAnimation).  Two Scale
    -- animations in sequence — 0.5s grow to 1.1x, 0.5s shrink to
    -- 0.9091x — looping REPEAT indefinitely once :Play() is called.
    -- Only played on important totems (Cap/Psyfiend/Grounding) so the
    -- eye is naturally drawn to the plates that matter.
    local ag = frame:CreateAnimationGroup()
    local grow = ag:CreateAnimation("Scale")
    if grow.SetOrder    then grow:SetOrder(1) end
    if grow.SetScale    then grow:SetScale(1.1, 1.1) end
    if grow.SetDuration then grow:SetDuration(0.5) end
    local shrink = ag:CreateAnimation("Scale")
    if shrink.SetOrder    then shrink:SetOrder(2) end
    if shrink.SetScale    then shrink:SetScale(0.9091, 0.9091) end
    if shrink.SetDuration then shrink:SetDuration(0.5) end
    if ag.SetLooping then ag:SetLooping("REPEAT") end
    frame.anim = ag

    plate.MyNP_TotemIcon = frame
    return frame
end

-- Attach / detach the mask on the icon texture.  Kept as a helper
-- because it's called from two branches inside _ApplyTotemIcon
-- (show-with-glow and hide-glow) and BBP's own code does the same
-- add/remove dance to keep the icon crisp when no glow is present.
local function _SetMaskAttached(frame, attached)
    if not (frame and frame.tex and frame.mask) then return end
    if attached and not frame.maskAttached then
        if frame.tex.AddMaskTexture then
            pcall(frame.tex.AddMaskTexture, frame.tex, frame.mask)
        end
        frame.maskAttached = true
    elseif (not attached) and frame.maskAttached then
        if frame.tex.RemoveMaskTexture then
            pcall(frame.tex.RemoveMaskTexture, frame.tex, frame.mask)
        end
        frame.maskAttached = false
    end
end

-- Decide whether this plate is a candidate for the totem icon.  Uses
-- the same summon-classification pipeline as _PickNameConfig — so the
-- icon and the text overlay travel together.  Returns nil (no icon)
-- OR the effective summonType so callers can honour the per-type
-- filter without re-deriving it.
local function _TotemIconType(plate, unit)
    if not (plate and unit) then return nil end
    -- Test-mode: force ON for tuning.
    if ns.testMode and ns.testMode.petTotemName then
        return "totem"
    end
    local isSummon = ns.IsSummonPlate and ns:IsSummonPlate(plate, unit)
    if not isSummon then return nil end
    -- Prefer the per-plate captured type (accurate even on secret units).
    local st = ns.GetSummonTypeByPlate and ns:GetSummonTypeByPlate(plate)
    if not st then
        local info = ns.GetSummonInfoForUnit and ns:GetSummonInfoForUnit(unit)
        st = info and info.summonType
    end
    -- 1.36.9: fall back to NpcData's authoritative type BEFORE defaulting
    -- to "totem".  Fixes a bug where anonymised arena pets whose summon-
    -- type capture was empty (common on Warlock Observer / Felguard,
    -- Hunter pets, etc.) would default to "totem" and get the totem
    -- icon treatment applied on top of them.  With this lookup, an
    -- Observer plate returns "pet_warlock" and gets correctly filtered
    -- out by the default cfg.types.pet_warlock = false gate — no
    -- more Observer plates wearing the generic totem-recall icon.
    if not st then
        local npcID = _ResolvePlateNpcID(plate, unit)
        if npcID then
            local rec = _NpcRecord(npcID)
            if rec and rec.type then
                st = rec.type
            end
        end
    end
    return st or "totem"   -- unknown-type summons default to "totem" for gating
end

-- 1.34.1 / 1.35.0: shared apply-state upvalue for the pcall'd inner
-- body.  Reused across every _ApplyTotemIcon call to avoid closure
-- allocation on the 10 Hz refresh path.  Only one _ApplyTotemIcon
-- call is in flight at any given time (single-threaded game loop),
-- so a shared state buffer is safe.
--
-- 1.35.0: extended with the full BBP classification result
-- (isImportant / isImportantAura / duration / hasAura) plus the
-- resolved isFriend flag so the inner body has everything it needs
-- to drive glow / cd / anim / recolor / hide gates.
local _totemIconApplyState = {
    frame = nil, uf = nil, cfg = nil,
    icon = nil, r = 0, g = 0, b = 0,
    isImportant = false, isImportantAura = false,
    duration = nil, hasAura = false,
    isFriend = false, plate = nil, unit = nil,
}

-- Apply healthbar recolor for a classified totem.  Sets a persistent
-- `uf.MyNP_totemColor` marker + drives an immediate SetStatusBarColor.
-- The persistent marker is read by our CompactUnitFrame_UpdateHealthColor
-- hook so Blizzard's UNIT_HEALTH-driven class-color resets don't
-- flash back through — mirrors BBP's `needsRecolor` sentinel.
local function _ApplyTotemHealthColor(uf, cfg, isImportant, isImportantAura,
                                      hasAura, r, g, b)
    if not (uf and uf.healthBar) then return end
    -- Decide whether we're recoloring at all.  BBP splits into two
    -- gates: important totems use `colorHealthBar`, generic totems
    -- use `colorHealthBarOthers`.  Both default cascading into the
    -- "recolor" branch below via _totemColor markers.
    local isImp = isImportant or isImportantAura
    local shouldColor = (isImp and cfg.colorHealthBar)
                     or ((not isImp) and cfg.colorHealthBarOthers)
    if not shouldColor then
        -- Not coloring — clear any previous marker so the hook lets
        -- Blizzard's class color take over again next update.
        uf.MyNP_totemColor = nil
        return
    end
    -- Persistent marker for the UpdateHealthColor hook.  Reused table
    -- lives on the uf itself — no shared upvalue needed because it's
    -- per-frame state, and the hook needs to find it by frame lookup.
    local mk = uf.MyNP_totemColor
    if not mk then
        mk = { 0, 0, 0 }
        uf.MyNP_totemColor = mk
    end
    mk[1], mk[2], mk[3] = r, g, b
    -- Apply immediately so the user sees the color THIS frame instead
    -- of waiting for the next UpdateHealthColor cycle.
    pcall(uf.healthBar.SetStatusBarColor, uf.healthBar, r, g, b)
end

-- Apply name text recolor / hide for a classified totem.  Also sets
-- a persistent `uf.MyNP_totemNameColor` + `uf.MyNP_totemHideName`
-- markers read by our CompactUnitFrame_UpdateName hook so Blizzard's
-- own name-update path (fires on target change, aggro change, etc.)
-- can't flash the plate name back to the default color/text.
local function _ApplyTotemNameStyle(uf, cfg, isImportant, isImportantAura,
                                    hasAura, r, g, b)
    if not (uf and uf.name) then return end
    local isImp = isImportant or isImportantAura
    local shouldColor = (isImp and cfg.colorName)
                     or ((not isImp) and cfg.colorNameOthers)
    if shouldColor then
        local mk = uf.MyNP_totemNameColor
        if not mk then
            mk = { 0, 0, 0 }
            uf.MyNP_totemNameColor = mk
        end
        mk[1], mk[2], mk[3] = r, g, b
        pcall(uf.name.SetVertexColor, uf.name, r, g, b)
    else
        uf.MyNP_totemNameColor = nil
    end
    -- Hide-name gate.  When on, we mark the plate so the
    -- CompactUnitFrame_UpdateName hook clears the text after Blizzard
    -- writes it — otherwise Blizzard's own updates paste the name
    -- back a frame later.
    if cfg.hideName then
        uf.MyNP_totemHideName = true
        pcall(uf.name.SetText, uf.name, "")
    else
        uf.MyNP_totemHideName = nil
    end
end

-- Clamp a user-configurable alpha to [0, 1].  Falls back to 1.0 for
-- non-numeric input.  Reused for healthBarAlpha and any future
-- alpha-slider settings on the totem indicator block.
local function _ClampAlpha(v, default)
    v = tonumber(v)
    if not v then return default or 1.0 end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Apply healthbar opacity for a classified totem.  Combines TWO
-- settings into a single effective alpha:
--
--   * cfg.healthBarAlpha (0.0-1.0)  — user's base opacity for every
--                                     totem healthbar.  Default 1.0.
--   * cfg.hideHealthBar (bool)      — when on, forces alpha to 0
--                                     whenever the totem is NOT the
--                                     current target (BBP behavior);
--                                     targeted totems still use the
--                                     base opacity so the user can
--                                     see HP while burning them down.
--
-- Stores the effective alpha on uf.MyNP_totemHbAlpha so the Discovery
-- SetAlpha reassert hook (v1.36.4) can re-apply it after Blizzard's
-- own writes.  Without that hook, Blizzard's plate-fade / target-swap
-- alpha writes on the container would fight our 10 Hz reassert and
-- produce visible flicker.  Marker is cleared entirely (nil) when we
-- decide NOT to manage the alpha (both settings default) so recycled
-- plates don't inherit a previous totem's opacity state.
--
-- Selection highlight is driven from the same effective alpha so the
-- target-outline glow visibility follows the healthbar visibility.
local function _ApplyTotemHealthBarOpacity(uf, cfg, unit)
    -- Container lookup is defensive — different Blizzard nameplate
    -- templates use different names, and forbidden plates would throw.
    local hbc = uf.HealthBarsContainer or uf.healthBar
    if not hbc then return end

    local base = _ClampAlpha(cfg.healthBarAlpha, 1.0)
    local hide = cfg.hideHealthBar and true or false

    -- Fast path: user hasn't opted into either behavior — clear any
    -- previous marker so Blizzard's own alpha runs freely, and pop
    -- the container back to 1 if we previously zeroed / dimmed it.
    if base >= 0.999 and not hide then
        if uf.MyNP_totemHbAlpha ~= nil then
            pcall(hbc.SetAlpha, hbc, 1)
            if uf.selectionHighlight then
                pcall(uf.selectionHighlight.SetAlpha, uf.selectionHighlight, 1)
            end
            uf.MyNP_totemHbAlpha = nil
        end
        -- Legacy marker (pre-1.36.4) — clear on the same path so any
        -- users upgrading from 1.35 don't get stuck with a stale flag.
        uf.MyNP_totemHidHealth = nil
        return
    end

    -- Determine target-ness safely.  On secret arena tokens we can't
    -- call UnitIsUnit without tainting; assume "not the target" in
    -- that case (safe default — hides / dims the plate).
    local isTarget = false
    if unit and not (issecretvalue and issecretvalue(unit)) then
        local ok, v = pcall(UnitIsUnit, unit, "target")
        if ok then isTarget = v and true or false end
    end

    -- Effective alpha (write once, persist for the reassert hook).
    local eff
    if hide and not isTarget then
        eff = 0
    else
        eff = base
    end
    uf.MyNP_totemHbAlpha = eff
    -- Legacy flag kept in-sync for anyone reading it externally.
    uf.MyNP_totemHidHealth = (eff < 0.999) and true or nil

    pcall(hbc.SetAlpha, hbc, eff)
    if uf.selectionHighlight then
        -- Match BBP: targeted totems get a dim outline (0.22), non-
        -- targeted ones follow the effective alpha directly so the
        -- highlight doesn't linger over a hidden healthbar.
        local hi = (hide and not isTarget) and 0 or (isTarget and 0.22 or eff)
        pcall(uf.selectionHighlight.SetAlpha, uf.selectionHighlight, hi)
    end
end

local function _ApplyTotemIconInner()
    local s = _totemIconApplyState
    local frame, uf, cfg = s.frame, s.uf, s.cfg
    if not (frame and uf and cfg) then return end

    -- Position + size (kept configurable per user's choice — BBP uses
    -- a fixed 30x30, we let the user tune via iconSize slider).
    -- 1.36.1: bumped fallback 26 -> 30 for BBP parity with the shipped
    -- default in Core.lua and the UI slider default in UI.lua.  Users
    -- who explicitly set a value keep whatever they configured.
    local size = tonumber(cfg.iconSize) or 30
    frame:SetSize(size, size)
    frame:ClearAllPoints()
    local anchor = uf.healthBar or uf
    frame:SetPoint("CENTER", anchor,
        cfg.iconAnchor or "TOP",
        tonumber(cfg.iconXOffset) or 0,
        tonumber(cfg.iconYOffset) or 22)

    -- "Show other icons" gate (BBP totemIndicatorShowOtherIcons).
    -- Important totems (Cap / Psyfiend / Grounding-class aura) always
    -- show an icon; unimportant totems only show if the user opted in.
    local isImp = s.isImportant or s.isImportantAura
    if not isImp and not cfg.showOtherIcons then
        frame:Hide()
        if frame.cd    then frame.cd:Hide() end
        if frame.glow  then frame.glow:Hide() end
        if frame.anim  then pcall(frame.anim.Stop, frame.anim) end
        _SetMaskAttached(frame, false)
        return
    end

    -- Icon texture + optional tint (1.36.3).
    --
    -- The default tint path multiplies every pixel of the icon by the
    -- totem color — for the dark generic brown (0.40, 0.34, 0.21)
    -- that produces a "faded black" wash that's hard to read.  The
    -- new `tintIcon` toggle (default OFF) lets the icon render in its
    -- natural spellbook colors while the healthbar / name still show
    -- the totem color for classification cues.  `iconAlpha` (0.10 -
    -- 1.00) is a straight opacity multiplier the user can dial for
    -- fine visual control.  BBP-parity strict-tint behavior is one
    -- checkbox click away for users who want it.
    if frame.tex then
        frame.tex:SetTexture(s.icon or TOTEM_ICON_GENERIC)
        local ia = tonumber(cfg.iconAlpha) or 1.0
        if ia < 0.10 then ia = 0.10 elseif ia > 1.0 then ia = 1.0 end
        if cfg.tintIcon then
            frame.tex:SetVertexColor(s.r, s.g, s.b, ia)
        else
            frame.tex:SetVertexColor(1, 1, 1, ia)
        end
    end

    -- Cooldown swipe (BBP showTotemIndicatorCooldownSwipe).  Only
    -- shown on important totems that have a known duration
    -- (classification returned 12 for Psyfiend, 2 for Capacitor).
    if s.duration and cfg.showCooldownSwipe and frame.cd then
        pcall(frame.cd.SetCooldown, frame.cd, GetTime(), s.duration)
        pcall(frame.cd.Show, frame.cd)
        -- Also honour the sub-toggles that BBP exposes for consistency:
        -- SetDrawSwipe/Edge = true (default) draws the fill; a future
        -- setting could disable them without hiding the frame entirely.
        if frame.cd.SetDrawSwipe then pcall(frame.cd.SetDrawSwipe, frame.cd, true) end
        if frame.cd.SetDrawEdge  then pcall(frame.cd.SetDrawEdge,  frame.cd, true) end
    elseif frame.cd then
        pcall(frame.cd.Hide, frame.cd)
    end

    -- Glow + pulse animation (BBP ApplyGlow).  Only for important
    -- totems, and only when noGlow is off.  For aura-important totems
    -- (Grounding-class) glow uses the important magenta; for
    -- cast/channel-important totems (Cap/Psyfiend) glow uses the
    -- totem's own color; for generic aura totems the glow stays
    -- shown but tinted with the generic color at full alpha so the
    -- icon still "pops" a bit even without important status.
    local wantGlow = false
    if isImp and not cfg.noGlow then
        wantGlow = true
    elseif s.hasAura and not cfg.noGlow then
        -- BBP renders the glow for any aura totem too, but sets
        -- alpha=0 for non-important — visually equivalent to no
        -- glow but keeps the mask attached to soften the icon.
        wantGlow = true
    end

    if wantGlow and frame.glow then
        local offset = size * 0.41
        frame.glow:ClearAllPoints()
        frame.glow:SetPoint("TOPLEFT",     frame, "TOPLEFT",     -offset,  offset)
        frame.glow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",  offset, -offset)
        if s.hasAura and not s.isImportantAura then
            -- Aura totem but not important: dim glow to match BBP
            -- behavior (they SetAlphaFromBoolean isImportant, 1, 0).
            frame.glow:SetVertexColor(s.r, s.g, s.b, 1)
            frame.glow:SetAlpha(0)
        else
            frame.glow:SetVertexColor(s.r, s.g, s.b, 1)
            frame.glow:SetAlpha(1)
        end
        frame.glow:Show()
        _SetMaskAttached(frame, true)
        -- Play animation unless the user opted out.  Only start it
        -- if it isn't already playing so we don't reset the pulse
        -- phase every 10 Hz refresh (visual jitter).
        if frame.anim and not cfg.noAnimation then
            if frame.anim.IsPlaying and not frame.anim:IsPlaying() then
                pcall(frame.anim.Play, frame.anim)
            elseif not frame.anim.IsPlaying then
                pcall(frame.anim.Play, frame.anim)
            end
        elseif frame.anim then
            pcall(frame.anim.Stop, frame.anim)
        end
    else
        if frame.glow then frame.glow:Hide() end
        if frame.anim then pcall(frame.anim.Stop, frame.anim) end
        _SetMaskAttached(frame, false)
    end

    frame:Show()

    -- HP color / name style / hide-HP — apply AFTER the icon so a
    -- failure here still leaves the icon rendered correctly.  These
    -- write persistent markers on the uf that the CompactUnitFrame_*
    -- hooks re-assert against Blizzard's own updates.
    _ApplyTotemHealthColor(uf, cfg, s.isImportant, s.isImportantAura,
                           s.hasAura, s.r, s.g, s.b)
    _ApplyTotemNameStyle(uf, cfg, s.isImportant, s.isImportantAura,
                         s.hasAura, s.r, s.g, s.b)
    _ApplyTotemHealthBarOpacity(uf, cfg, s.unit)
end

-- Clear only the visual overlays (glow / cd / anim) without touching
-- the persistent HP-color / name-color markers.  Used by "hide"
-- branches inside _ApplyTotemIcon when the plate briefly falls out of
-- the summon set but we don't want to fully reset (e.g. per-type
-- filter toggling mid-frame).
local function _HideTotemIconOverlays(plate)
    local frame = plate and plate.MyNP_TotemIcon
    if not frame then return end
    pcall(frame.Hide, frame)
    if frame.cd    then pcall(frame.cd.Hide, frame.cd) end
    if frame.glow  then pcall(frame.glow.Hide, frame.glow) end
    if frame.anim  then pcall(frame.anim.Stop, frame.anim) end
    _SetMaskAttached(frame, false)
end

-- Full clear — hides the icon AND restores the healthbar / name /
-- container alphas by dropping the persistent markers so Blizzard's
-- next update cycle can run its normal path.  Called from the
-- ClearTotemIconForPlate public entrypoint (Discovery invokes it on
-- NAME_PLATE_UNIT_REMOVED) so a recycled plate doesn't inherit the
-- previous totem's recolor / hidden-hp state.
local function _FullClearTotemState(plate)
    if not plate then return end
    _HideTotemIconOverlays(plate)
    local uf = plate.UnitFrame
    if not uf then return end
    -- Drop persistent markers.
    uf.MyNP_totemColor     = nil
    uf.MyNP_totemNameColor = nil
    uf.MyNP_totemHideName  = nil
    -- If we dimmed / hid the healthbar, restore alpha before dropping
    -- the markers — otherwise the recycled plate stays invisible / dim.
    -- Checks BOTH the 1.36.4 marker (MyNP_totemHbAlpha) AND the legacy
    -- 1.35.x flag (MyNP_totemHidHealth) so upgraded users don't have
    -- stuck plates from a stale flag.
    if uf.MyNP_totemHbAlpha ~= nil or uf.MyNP_totemHidHealth then
        local hbc = uf.HealthBarsContainer or uf.healthBar
        if hbc then pcall(hbc.SetAlpha, hbc, 1) end
        if uf.selectionHighlight then
            pcall(uf.selectionHighlight.SetAlpha, uf.selectionHighlight, 1)
        end
        uf.MyNP_totemHbAlpha   = nil
        uf.MyNP_totemHidHealth = nil
    end
end

-- 1.35.0: Psyfiend spawn-race workaround (BBP CHANGELOG 2.0.6).
-- Psyfiends appear on a plate for a brief window BEFORE they start
-- channeling — during that window our classifier can't detect them
-- and they render as generic totems.  BBP schedules a 250ms
-- re-classify to catch the channel start.  We do the same, guarded
-- by a per-plate timer flag so 10 Hz refresh doesn't queue multiple
-- pending re-classifies for the same plate.
local _ApplyTotemIcon   -- fwd for the timer body
local function _SchedulePsyfiendRecheck(plate)
    if not plate then return end
    if plate.MyNP_totemRecheckPending then return end
    plate.MyNP_totemRecheckPending = true
    C_Timer.After(0.25, function()
        plate.MyNP_totemRecheckPending = nil
        if not plate then return end
        local uf = plate.UnitFrame
        if not uf then return end
        local u = uf.unit or uf.displayedUnit
        if not u then return end
        -- Only re-classify if a channel actually started in the
        -- meantime (matches BBP's exact gate).
        local ok, ch = pcall(UnitChannelInfo, u)
        if ok and ch and _ApplyTotemIcon then
            _ApplyTotemIcon(plate, u, nil)
        end
    end)
end

-- Apply / update / hide the icon overlay for a plate.  Idempotent and
-- pcall-wrapped so it can't destabilise the outer refresh loop.
_ApplyTotemIcon = function(plate, unit, isFriend)
    if not plate then return end
    local uf = plate.UnitFrame
    if not uf then return end
    if _IsForbidden(plate, uf) then return end

    local L   = MyNamePlatesDB and MyNamePlatesDB.labels
    local cfg = L and L.petTotemName

    -- 1.36.2: test-mode bypasses `enabled` and `showIcon` so the Test
    -- Totems button on the UI works even when the user has the block
    -- switched off in their DB.  Without this, clicking Test on a
    -- fresh install with enabled="0" would produce no visible change
    -- and look broken.  The gate is checked once here and re-used
    -- below to skip the per-type filter and friend gates too.
    local testing = ns.testMode and ns.testMode.petTotemName
    if not testing then
        if not (cfg and cfg.enabled == "1" and cfg.showIcon) then
            return _FullClearTotemState(plate)
        end
    else
        -- Test mode still needs a cfg table (we read iconSize / anchor
        -- / offsets / colors from it).  Every path below assumes cfg
        -- exists, so if the block was never merged into the DB for
        -- some reason (shouldn't happen with the defaults merger, but
        -- be defensive), bail rather than nil-deref.
        if not cfg then return _FullClearTotemState(plate) end
    end

    -- Per-summon-type filter for the ICON overlay.  Since 1.36.28 the
    -- icon has its own filter table (`iconTypes`) separate from the
    -- NAME overlay's `types` — see Core.lua defaults and the "Summon
    -- Icons & Names" UI tab.  On pre-1.36.28 DBs iconTypes has been
    -- migrated to mirror `types`, so behavior is unchanged for existing
    -- users; new installs default iconTypes = all true.  Fall back to
    -- `types` if iconTypes is somehow missing (defensive).
    local st = _TotemIconType(plate, unit)
    if not st then return _FullClearTotemState(plate) end
    -- Skip the per-type filter when testing so target dummies (which
    -- classify as "totem" in test mode via _TotemIconType) render
    -- regardless of whether the user has the totem type checkbox on.
    if not testing then
        local iconGate = cfg.iconTypes or cfg.types
        if iconGate and iconGate[st] == false then
            return _FullClearTotemState(plate)
        end
    end

    -- 1.36.29: per-NPC-ID icon gate.  Users can flip off a specific
    -- important totem's icon (e.g. hide Grounding icons, keep
    -- Capacitor icons) from the "Important Totems" grid on the
    -- Summon Icons & Names UI tab.  Only fires when we can resolve
    -- the plate's npcID -- anonymised arena tokens (secret unit,
    -- no capture yet) fall through to normal type-level rendering.
    -- Missing / true keys count as ON; only an explicit `false`
    -- value suppresses this totem's icon.
    if not testing then
        local npcID = _ResolvePlateNpcID(plate, unit)
        if npcID and cfg.iconByNpcID
           and cfg.iconByNpcID[npcID] == false then
            return _FullClearTotemState(plate)
        end
    end

    -- Friend / enemy gate.  Reuse the resolved isFriend from caller —
    -- caller already handled secret-unit safety when deriving it.
    if isFriend == nil then
        if issecretvalue and issecretvalue(unit) then
            local cf = ns.GetSummonFriendByPlate and ns:GetSummonFriendByPlate(plate)
            isFriend = cf == true
        else
            local ok, f = pcall(UnitIsFriend, "player", unit)
            isFriend = ok and f or false
        end
    end
    -- Skip applyFriendly / applyEnemy / enemiesOnly gates in test mode
    -- so target dummies work regardless of faction (friendly training
    -- dummies in capital cities AND hostile ones both work).
    if not testing then
        if isFriend and not cfg.applyFriendly then return _FullClearTotemState(plate) end
        if (not isFriend) and not cfg.applyEnemy then return _FullClearTotemState(plate) end

        -- 1.35.0: enemies-only gate (BBP totemIndicatorEnemyOnly).
        if cfg.enemiesOnly and isFriend then
            return _FullClearTotemState(plate)
        end
    end

    -- Skip the classifier entirely on secret unit tokens (Unit*Info calls
    -- on a secret string can taint us) — render the type-appropriate
    -- generic icon and colour without probing the unit.  BBP does
    -- effectively the same when their heuristics come up empty.
    --
    -- 1.36.26: even on secret tokens we know summonType (from the
    -- _summonByPlate capture or NPC_DATA lookup done above in
    -- _TotemIconType).  So a secret warlock Observer plate still
    -- reads as "warlock pet" visually instead of getting the shaman
    -- totem-recall icon.
    local icon, r, g, b, isImportant, isImportantAura, duration, hasAura
    if issecretvalue and issecretvalue(unit) then
        icon = ICON_BY_TYPE[st or "totem"] or TOTEM_ICON_GENERIC
        local col = COLOR_BY_TYPE[st or "totem"] or TOTEM_COLOR_GENERIC
        if col == TOTEM_COLOR_GENERIC then
            r, g, b = _GenericColorRGB()
        else
            r, g, b = col[1], col[2], col[3]
        end
        isImportant, isImportantAura, duration, hasAura = false, false, nil, false
    else
        -- 1.36.1: pass plate so _ClassifyTotem can consult NPC_DATA via
        -- _ResolvePlateNpcID.  When we know the npcID, we render the
        -- canonical icon (Grounding icon on Grounding Totem, etc.) and
        -- honour the curated `important` flag instead of guessing via
        -- cast/channel/aura state.
        -- 1.36.26: also pass st (resolved summonType) so the classifier's
        -- Step 4 fallback picks a type-appropriate icon + color instead
        -- of always the shaman totem-recall in brown.
        icon, r, g, b, isImportant, isImportantAura, duration, hasAura =
            _ClassifyTotem(unit, plate, st)
        -- Psyfiend spawn-race: no channel yet but plate qualifies —
        -- schedule a 250ms re-classify.  Only worth it when this
        -- plate is actually a summon by classification (which it is
        -- if we got past the earlier gates).
        if not isImportant and not hasAura then
            _SchedulePsyfiendRecheck(plate)
        end
    end

    local frame = _GetTotemIcon(plate)
    if not frame then return end   -- forbidden UF

    -- 1.34.1: apply via a pre-declared upvalue instead of a fresh
    -- pcall(function()...) closure per call.  RefreshAllLabels calls
    -- this per plate every 10 Hz — the previous closure was ~1 KB/sec
    -- of pure garbage in a full arena.
    local s = _totemIconApplyState
    s.frame           = frame
    s.uf              = uf
    s.cfg             = cfg
    s.icon            = icon
    s.r               = r
    s.g               = g
    s.b               = b
    s.isImportant     = isImportant
    s.isImportantAura = isImportantAura
    s.duration        = duration
    s.hasAura         = hasAura
    s.isFriend        = isFriend
    s.plate           = plate
    s.unit            = unit
    pcall(_ApplyTotemIconInner)
end

-- Public: clear the icon on a plate (called from Discovery.lua on
-- NAME_PLATE_UNIT_REMOVED so recycled plate frames don't inherit the
-- previous unit's icon).  1.35.0: now also clears persistent HP/name
-- markers so recycled plates don't stay recolored / hidden.
function ns:ClearTotemIconForPlate(plate)
    _FullClearTotemState(plate)
end

----------------------------------------------------------------------
-- Custom spec FontString (one per plate, lazy)
----------------------------------------------------------------------
local function _GetSpecText(plate)
    if plate.MyNP_SpecText then return plate.MyNP_SpecText end
    local uf = plate.UnitFrame
    if not uf then return nil end
    -- Skip forbidden frames — creating a FontString as a child of a
    -- forbidden parent propagates addon taint.  We can't render spec
    -- text on the secure widget chain, but the spec NAME resolution
    -- via ArenaMap (GetArenaOpponentSpec) keeps working separately.
    if _IsForbidden(plate, uf) then return nil end
    local fs = uf:CreateFontString(nil, "OVERLAY", "SystemFont_Shadow_Small")
    fs:SetText("")
    fs:Hide()
    if fs.SetIgnoreParentAlpha then
        pcall(fs.SetIgnoreParentAlpha, fs, true)
    end
    plate.MyNP_SpecText = fs
    return fs
end

local function _SafeAnchor(plate)
    local uf = plate and plate.UnitFrame
    if not uf then return nil end
    return uf.healthBar or uf
end

----------------------------------------------------------------------
-- All-spec localized lookup table for tooltip scanning.
-- Lazy-initialized; rebuilt on locale-affecting events.
----------------------------------------------------------------------
ns.ALL_SPEC_NAMES = nil
local function _BuildAllSpecNames()
    if ns.ALL_SPEC_NAMES then return end
    local names = {}
    if not (GetNumClasses and GetClassInfo
            and GetNumSpecializationsForClassID
            and GetSpecializationInfoForClassID) then
        ns.ALL_SPEC_NAMES = names
        return
    end
    -- Add BOTH orderings ("Frost Mage" and "Mage Frost") so the
    -- tooltip scan succeeds regardless of how Blizzard composes the
    -- line for a given locale/context.  Friendly party-member
    -- tooltips emit "Spec Class" in en-US, but enemy BG tooltips
    -- have been observed using "Class Spec" on some locales — we
    -- saw friendlies work in BG and enemies miss exactly because
    -- of this one-sided mapping.  (BBP does the same — see
    -- midnight/BetterBlizzPlates.lua AddSpec near line 5909.)
    local function addBoth(spec, class, specID)
        if spec and class and specID then
            names[spec  .. " " .. class] = specID
            names[class .. " " .. spec ] = specID
        end
    end
    local numClasses = GetNumClasses()
    for classID = 1, numClasses do
        local className, classFile = GetClassInfo(classID)
        if classFile then
            local male   = LOCALIZED_CLASS_NAMES_MALE   and LOCALIZED_CLASS_NAMES_MALE[classFile]
            local female = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classFile]
            local n = GetNumSpecializationsForClassID(classID) or 0
            for specIndex = 1, n do
                local ok, specID, specName = pcall(
                    GetSpecializationInfoForClassID, classID, specIndex)
                if ok and specID and specName and specName ~= "" then
                    addBoth(specName, male, specID)
                    if female and female ~= male then
                        addBoth(specName, female, specID)
                    end
                    if className and className ~= male and className ~= female then
                        addBoth(specName, className, specID)
                    end
                end
            end
        end
    end
    ns.ALL_SPEC_NAMES = names
end

----------------------------------------------------------------------
-- Tooltip-based spec name lookup.  Cached by GUID; bails for
-- "secret value" GUIDs (forbidden anonymized arena tokens) since
-- those collide across plates and would mis-attribute results.
----------------------------------------------------------------------
local specNameCache = {}

-- ============================================================
-- IMPORTANT (12.x taint regression — fixed 1.32.2)
-- We previously created a hidden GameTooltipTemplate frame
-- (MyNamePlatesScanTooltip) and called tt:SetUnit(unit) to
-- force-populate the tooltip data cache on enemy plates.  In
-- retail Midnight 12.x the data-rules pipeline invokes
-- `StatusBar:SetWatch("name", value)` on the tooltip's child
-- StatusBar as part of every SetUnit — and because that call
-- originates inside our addon's execution context, the entire
-- chain gets logged as
--     Lua Taint: MyNamePlates / SetWatch / ("name", value)
-- once per plate per refresh tick (Count rapidly climbs into
-- the hundreds in BG).  The status bar's SetWatch then touches
-- a secure attribute path that taints downstream nameplate
-- and tooltip code, which is the root cause of the persistent
-- "Interface action failed" cascade we kept chasing.
--
-- C_TooltipInfo.GetUnit is the data-only API Blizzard ships
-- precisely so addons don't need to drive the UI tooltip.  It
-- doesn't dispatch StatusBar rules and doesn't taint.  When
-- the player targets or mouseovers a unit, Blizzard's own UI
-- tooltip runs (because the target frame / cursor IS over the
-- unit) and primes the underlying data cache; our
-- _CaptureSpecFromToken then reads from that primed cache
-- via C_TooltipInfo.GetUnit on the same token.  That's the
-- mechanism that produced your working friendly Dgkx capture.
-- ============================================================
local function _GetSpecByTooltip(unit)
    if not unit then return nil end
    -- Defensive: caller (RefreshAllLabels) filters secret unit
    -- tokens already, but _GetSpecName could also be hit from a
    -- diagnostic / future caller, so guard here too.  Calling
    -- UnitGUID with a secret-string token can itself taint.
    if issecretvalue and issecretvalue(unit) then return nil end

    local guid = UnitGUID(unit)
    -- IMPORTANT: a secret-tagged GUID is NOT a reason to abort the
    -- tooltip scan.  GUID is only used as a CACHE KEY here.  In
    -- retail Midnight 12.x, target/mouseover tokens for anonymised
    -- players return secret GUIDs even though tooltip data on those
    -- tokens can still contain non-secret spec lines.  The earlier
    -- "return nil if guid is secret" check killed the whole scan
    -- and made _CaptureSpecFromToken bail — which is why your
    -- /mnp labels probe showed `cache: spec=nil` even after you
    -- targeted enemies.  Now we just disable caching when guid is
    -- secret, and continue with the scan.
    local guidCacheable = guid and not (issecretvalue and issecretvalue(guid))
    if guidCacheable and specNameCache[guid] then
        return specNameCache[guid]
    end

    _BuildAllSpecNames()
    local lookup = ns.ALL_SPEC_NAMES or {}

    -- Resolve a tooltip text fragment to a specID.  Exact match
    -- first (the typical "Devastation Evoker" / "Frost Mage" line
    -- on friendly + targeted enemy tooltips), then a contains-
    -- substring fallback for lines that bundle additional info
    -- (e.g. "Level 80 Frost Mage" on some non-engaged enemy plates).
    -- find with the 4th arg true does plain-text search so spec
    -- names with hyphens / accents don't get treated as regex.
    --
    -- CRITICAL: issecretvalue(txt) MUST come before any compare /
    -- index / :find on txt.  Tooltip data on anonymised arena enemy
    -- units can put secret-string values into line.leftText /
    -- line.rightText.  Doing `txt == ""` or `lookup[txt]` or
    -- `txt:find(...)` on a secret-string value taints our entire
    -- execution context — same cascade that wiped specs+totems via
    -- the _SafeUnitName regression.
    local function _Resolve(txt)
        if txt == nil then return nil end
        if issecretvalue and issecretvalue(txt) then return nil end
        if txt == "" then return nil end
        local sid = lookup[txt]
        if sid then return sid end
        for phrase, pid in pairs(lookup) do
            if txt:find(phrase, 1, true) then return pid end
        end
        return nil
    end

    local function _ResolveSpecFromLines(lines)
        if not lines then return nil end
        for _, line in ipairs(lines) do
            if line then
                local sid = _Resolve(line.leftText) or _Resolve(line.rightText)
                if sid and GetSpecializationInfoByID then
                    local _, sName = GetSpecializationInfoByID(sid)
                    if sName and sName ~= "" then return sName end
                end
            end
        end
        return nil
    end

    -- Data-only API.  Cheap, no UI frame, no SetWatch taint.
    -- Returns whatever lines Blizzard has cached for this unit;
    -- when the player has just targeted / mouseovered the unit
    -- the cache contains the full spec line.  When the unit has
    -- never been interacted with (passive enemy plate in BG)
    -- the cache is empty for that token and we return nil — the
    -- per-plate spec cache covers the "already seen" case.
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local data = C_TooltipInfo.GetUnit(unit)
        local sName = data and _ResolveSpecFromLines(data.lines)
        if sName then
            if guidCacheable then specNameCache[guid] = sName end
            return sName
        end
    end
    return nil
end

local specCacheWiper = CreateFrame("Frame")
specCacheWiper:RegisterEvent("PLAYER_ENTERING_WORLD")
specCacheWiper:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
specCacheWiper:RegisterEvent("GROUP_ROSTER_UPDATE")
specCacheWiper:RegisterEvent("PVP_MATCH_ACTIVE")
specCacheWiper:SetScript("OnEvent", function(_, event)
    wipe(specNameCache)
    if _scoreboardByName      then wipe(_scoreboardByName)      end
    if _scoreboardClassByName then wipe(_scoreboardClassByName) end
    _scoreboardSize      = 0
    _scoreboardLastBuilt = 0
    ns.ALL_SPEC_NAMES = nil

    -- Single, polite request when we enter a BG/arena instance.
    -- Don't spam — Blizzard auto-polls the scoreboard, and the
    -- UPDATE_BATTLEFIELD_SCORE handler in Discovery already
    -- triggers a rebuild whenever fresh data arrives.  The earlier
    -- "request at +0, +1, +3, +6s" cascade caused Details to hit
    -- the per-addon script time limit because UPDATE_BATTLEFIELD_SCORE
    -- fires for every requester.
    if event == "PLAYER_ENTERING_WORLD" or event == "PVP_MATCH_ACTIVE" then
        local inInstance, instType = IsInInstance()
        if inInstance and (instType == "pvp" or instType == "arena") then
            if RequestBattlefieldScoreData then
                pcall(RequestBattlefieldScoreData)
            end
        end
    end
end)

----------------------------------------------------------------------
-- Resolve spec NAME for a plate.
----------------------------------------------------------------------
-- Resolve spec NAME via the BG/rated-PvP scoreboard.
--
-- DESIGN: build a name → talentSpec map ONCE per UPDATE_BATTLEFIELD_SCORE
-- and serve all per-plate lookups out of that map.  This is critical
-- for performance: the naive "iterate the scoreboard inside every
-- _GetSpecByScore call" approach blows up to O(plates * scores) per
-- RefreshAllLabels — in a 40v40 epic BG that's ~1600 C_PvP calls per
-- refresh, fires on every nameplate event, and other addons (notably
-- Details) hit Blizzard's per-addon script time limit because of the
-- cascade of UPDATE_BATTLEFIELD_SCORE events we'd trigger.
--
-- WHY NAME-KEYED: in retail Midnight 12.x BGs, enemy player UnitGUID
-- returns a SECRET-STRING value (proven via /mnp pvp — the pcall came
-- back with "Secret values are only allowed during untainted execution
-- for this argument").  So C_PvP.GetScoreInfoByPlayerGuid is unusable.
-- UnitName remains non-secret, and C_PvP.GetScoreInfo(index) takes a
-- number so we can iterate the scoreboard without ever touching a
-- secret value.  Name collisions are possible cross-realm but
-- talentSpec is per-player; a real collision would just return one
-- of the two matching specs — acceptable degradation.
local _scoreboardByName      = {}   -- name -> talentSpec (string, may be secret-tagged)
local _scoreboardClassByName = {}   -- name -> classToken ("HUNTER" etc, non-secret)
local _scoreboardLastBuilt = 0   -- GetTime() of last successful rebuild
local _scoreboardSize      = 0   -- last known scoreboard row count

local function _ScoreCount()
    if C_PvP and C_PvP.GetNumScores then
        local ok, v = pcall(C_PvP.GetNumScores)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    if GetNumBattlefieldScores then
        local ok, v = pcall(GetNumBattlefieldScores)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- Fetch one score row.  Tries modern C_PvP.GetScoreInfo (returns a
-- table with named fields), then falls back to legacy
-- GetBattlefieldScore.  GetBattlefieldScore signature in retail
-- (per Details' parser.lua line 7776):
--   name, killingBlows, honorableKills, deaths, honorGained,
--   faction, race, class, classToken, damageDone, healingDone,
--   bgRating, ratingChange, preMatchMMR, mmrChange, talentSpec
-- = 16 returns.  In pcall-wrapped results table, talentSpec is at
-- index 17 (results[1] is the pcall ok flag, then 16 actual returns
-- at indices 2..17).  An earlier version used index 18 which was
-- one slot past the end — that's why /mnp scoreboard reported
-- talentSpec="269" (an MMR value) instead of the actual spec.
local function _ScoreRow(i)
    if C_PvP and C_PvP.GetScoreInfo then
        local ok, v = pcall(C_PvP.GetScoreInfo, i)
        if ok and type(v) == "table" and v.name then
            return v
        end
    end
    if GetBattlefieldScore then
        local results = { pcall(GetBattlefieldScore, i) }
        if results[1] then
            local name        = results[2]
            local faction     = results[7]
            local classToken  = results[10]
            local talentSpec  = results[17]
            if name then
                return {
                    name       = name,
                    classToken = classToken,
                    faction    = faction,
                    talentSpec = talentSpec,
                }
            end
        end
    end
    return nil
end

-- Rebuild the name → spec map from the current scoreboard.  Called
-- from the event handler on UPDATE_BATTLEFIELD_SCORE / PVP_MATCH_ACTIVE
-- and exactly ONCE from _GetSpecByScore when the map is empty (handles
-- the case where our first refresh runs before Blizzard pushes the
-- initial scoreboard snapshot).
--
-- CRITICAL: do NOT check issecretvalue(talentSpec) and bail on it.
-- C_PvP.GetScoreInfo flags enemy talentSpec returns as secret-string
-- values, but that does NOT mean we can't use them — secret values
-- can still be passed to Blizzard UI functions like FontString:SetText
-- (Blizzard does the rendering on its secure path).  What we can't
-- do is COMPARE, CONCAT, FIND, or use as table KEY — and we don't.
-- We just store the value, return it from the lookup, and pass it
-- straight to fs:SetText() which is the allowed path.
--
-- The earlier "issecretvalue then return nil" check on talentSpec
-- was overly defensive and rejected every enemy spec — that's why
-- /mnp scoreboard showed "size=30 cached entries=0".  With this
-- removed, all 30 rows now contribute to the map.
local function _BuildScoreboardMap()
    local n = _ScoreCount()
    if n <= 0 then return end
    wipe(_scoreboardByName)
    wipe(_scoreboardClassByName)
    for i = 1, n do
        local info = _ScoreRow(i)
        if info then
            local nm = info.name
            local sp = info.talentSpec
            local ct = info.classToken
            -- name MUST be non-secret + non-empty (we key the map by
            -- it, comparing it to "", and Lua table keys must be
            -- introspectable).
            if nm and not (issecretvalue and issecretvalue(nm))
               and nm ~= ""
            then
                -- spec may be secret — store it anyway, don't compare
                -- to "" or "None", just keep whatever Blizzard gave us.
                if sp then _scoreboardByName[nm] = sp end
                -- classToken is documented as a plain string ("HUNTER")
                -- and our diagnostic confirms it's non-secret.  Used by
                -- _ClassColor to color spec text on enemy plates.
                if ct then _scoreboardClassByName[nm] = ct end
            end
        end
    end
    _scoreboardLastBuilt = GetTime() or 0
    _scoreboardSize      = n
end

-- Public: events fire this from outside (Discovery's event handler
-- listens for UPDATE_BATTLEFIELD_SCORE etc., which is where the
-- rebuild belongs — NOT inside RefreshAllLabels).
function ns:RebuildPvPScoreMap()
    _BuildScoreboardMap()
end

-- Public: classToken (e.g. "HUNTER") lookup by player name.  Used
-- by _ClassColor to color spec text on enemy plates where UnitClass
-- returns a secret-string classFile (anonymised in 12.x BGs).
function ns:GetClassFromScoreboard(name)
    if not name then return nil end
    if issecretvalue and issecretvalue(name) then return nil end
    return _scoreboardClassByName[name]
end

-- Public: talentSpec lookup by player name.  Used only by the
-- diagnostic to reveal scoreboard hit/miss — production code
-- accesses _scoreboardByName directly from _GetSpecByScore.
function ns:GetSpecFromScoreboard(name)
    if not name then return nil end
    if issecretvalue and issecretvalue(name) then return nil end
    return _scoreboardByName[name]
end

----------------------------------------------------------------------
-- Per-plate spec cache (target/mouseover capture).
--
-- In retail Midnight 12.x BGs, EVERY name-bearing field on an enemy
-- plate's unit token is secret-tagged:
--   * UnitName(unit)
--   * UnitGUID(unit)
--   * UnitCreatureType(unit)
--   * uf.name:GetText()
-- That kills both the scoreboard lookup path AND the tooltip scan
-- path (no usable join key).
--
-- BUT: when the user TARGETS or MOUSEOVERS an enemy, the "target" /
-- "mouseover" unit tokens are non-secret, UnitName/UnitGUID/tooltip
-- on those tokens return real values, and _GetSpecByTooltip can
-- resolve a proper spec.  We capture that result and cache it by
-- PLATE REFERENCE (Lua table identity) — plates are pooled by
-- Blizzard but stable per assignment, so the cache stays valid
-- until the plate is recycled (NAME_PLATE_UNIT_REMOVED clears it).
--
-- The cache is keyed by the plate frame, not by any string, so it's
-- never tainted by secret strings.  Value is the localized spec
-- name from GetSpecializationInfoByID — always non-secret static
-- Blizzard data, safe for FontString:SetText.
local _specByPlate = {}

function ns:GetSpecByPlate(plate)
    return plate and _specByPlate[plate] or nil
end

-- 1.34.1: cache-size introspection for /mnp mem.
function ns:CountSpecByPlate()
    local n = 0
    for _ in pairs(_specByPlate) do n = n + 1 end
    return n
end
function ns:CountSpecNameCache()
    local n = 0
    for _ in pairs(specNameCache) do n = n + 1 end
    return n
end
function ns:CountScoreboard()
    local a, b = 0, 0
    for _ in pairs(_scoreboardByName) do a = a + 1 end
    for _ in pairs(_scoreboardClassByName) do b = b + 1 end
    return a, b
end

function ns:SetSpecByPlate(plate, specName)
    if not plate then return end
    if specName == nil then
        _specByPlate[plate] = nil
        return
    end
    -- Only store non-secret values — defensive in case a future
    -- code path tries to pass a secret spec.  If specName is a
    -- secret value, we don't cache it (would taint future lookups
    -- the first time something compares against the cached value).
    if issecretvalue and issecretvalue(specName) then return end
    if specName == "" then return end
    _specByPlate[plate] = specName
end

function ns:ClearSpecByPlate(plate)
    if plate then _specByPlate[plate] = nil end
end

-- 1.36.13: per-plate CLASS cache, keyed by plate frame identity.
-- Rationale: ArenaMap fingerprint matching (Indicators.lua) uses
-- class + race + sex + power to bind a plate to an arena1..3 slot.
-- In current retail Midnight 12.x, when two of the three arena
-- opponents share the same power type (e.g. both mana users) and
-- their class field is anonymised, ArenaMap cannot uniquely map
-- one of them and often mis-tags the "loser" plate (frequently the
-- last one to spawn, often the healer) to the OTHER caster's slot.
-- Every downstream lookup keyed on ArenaMap (spec label, class icon,
-- healer cross) then attributes the wrong slot's data to that plate.
--
-- Fix: when the user TARGETS or MOUSEOVERS an enemy player, the
-- "target" / "mouseover" tokens are canonical Blizzard tokens and
-- UnitClass on them returns a real, non-secret classFile.  Cache
-- that on the plate frame identity, and consult the cache FIRST
-- (ahead of ArenaMap) in _ClassColor / _GetClassFile.  Once the
-- user has interacted with a plate at least once, the wrong-arena-
-- slot binding can never contaminate its class again.
--
-- Cache is cleared alongside _specByPlate on NAME_PLATE_UNIT_REMOVED
-- (Discovery.lua handler) so recycled plate frames don't inherit
-- the previous unit's class.
local _classByPlate = {}

function ns:GetClassByPlate(plate)
    return plate and _classByPlate[plate] or nil
end

function ns:SetClassByPlate(plate, classFile)
    if not plate then return end
    if classFile == nil then
        _classByPlate[plate] = nil
        return
    end
    -- Only store non-secret uppercase class tokens (WARRIOR, PRIEST,
    -- etc. — canonical Blizzard values).  Defensive: a secret-tagged
    -- classFile passed through would taint the first == comparison
    -- against the cached value in downstream code.
    if issecretvalue and issecretvalue(classFile) then return end
    if classFile == "" then return end
    _classByPlate[plate] = classFile
end

function ns:ClearClassByPlate(plate)
    if plate then _classByPlate[plate] = nil end
end

function ns:CountClassByPlate()
    local n = 0
    for _ in pairs(_classByPlate) do n = n + 1 end
    return n
end

-- Resolve spec for the unit currently in the given token ("target"
-- or "mouseover"), and if successful, find that unit's plate and
-- cache the spec there.  Called from PLAYER_TARGET_CHANGED /
-- UPDATE_MOUSEOVER_UNIT handlers.
--
-- 1.36.13: ALSO cache the classFile on the same plate, so class-
-- color / class-icon / healer-cross lookups can bypass ArenaMap
-- when a direct target/mouseover capture is available.  The class
-- capture runs independently of the spec capture (a plate can have
-- a valid class but no spec if the tooltip cache was cold), so
-- neither one gates the other.
local function _CaptureSpecFromToken(token)
    if not token then return end
    if not UnitExists(token) then return end
    if not UnitIsPlayer(token) then return end
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
    local plate = C_NamePlate.GetNamePlateForUnit(token, true)
    if not plate then return end

    -- Class capture: UnitClass on target/mouseover tokens returns the
    -- real classFile on every patch we've seen, but pcall + issecret
    -- guards defend against a future patch that anonymises even
    -- these canonical tokens.
    local okC, _, classFile = pcall(UnitClass, token)
    if okC and classFile and not (issecretvalue and issecretvalue(classFile))
       and classFile ~= "" then
        ns:SetClassByPlate(plate, classFile)
    end

    -- Spec capture (existing behavior).  "target" / "mouseover"
    -- tokens themselves are NEVER secret — they're stable Blizzard
    -- tokens.  But UnitGUID/UnitName on them COULD be secret on
    -- some patches.  _GetSpecByTooltip handles its own internal
    -- guards.
    local specName = _GetSpecByTooltip(token)
    if specName then
        ns:SetSpecByPlate(plate, specName)
    end

    -- 1.36.15: DEFINITIVE ARENA LINKAGE.  If this token also happens
    -- to be one of arena1..3, we now KNOW plate <-> arenaN with 100%
    -- certainty (UnitIsUnit on target/focus/mouseover tokens returns
    -- a real boolean even for anonymised units).  Record the link
    -- and seed prep-derived spec + class into any empty per-plate
    -- caches.  This is how we escape the "user targeted the healer
    -- but tooltip was anonymised, so no spec cached" edge case and
    -- also fills class caches for plates we couldn't UnitClass.
    if ns.LinkPlateToArena and UnitIsUnit then
        for i = 1, 3 do
            local ok, match = pcall(UnitIsUnit, token, "arena" .. i)
            if ok and match then
                ns:LinkPlateToArena(plate, i)
                break
            end
        end
    end

    -- Immediate refresh so the spec + class land on the plate now,
    -- not on the next event-driven RefreshAllLabels.  Also kick
    -- indicators so class icon + healer cross re-evaluate with the
    -- fresh per-plate class cache.
    if ns.RefreshAllLabels     then pcall(ns.RefreshAllLabels,     ns) end
    if ns.RefreshAllIndicators then pcall(ns.RefreshAllIndicators, ns) end
end

local _targetCapture = CreateFrame("Frame")
_targetCapture:RegisterEvent("PLAYER_TARGET_CHANGED")
_targetCapture:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
_targetCapture:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_TARGET_CHANGED" then
        _CaptureSpecFromToken("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        _CaptureSpecFromToken("mouseover")
    end
end)

-- Diagnostic: dump every entry in the cached scoreboard map and
-- some metadata about the underlying API state.  /mnp scoreboard
-- calls this; useful when enemy SpecFS won't render so we can see
-- whether our score map is empty (Blizzard isn't populating the
-- scoreboard for this match type) or populated with names that
-- don't match the plate's UnitName.
function ns:DumpPvPScoreboard()
    local function p(s) print(s) end
    p("===== MyNamePlates PvP Scoreboard =====")
    p(("  built=%s (%.1fs ago)  size=%d  cached entries=%s"):format(
        _scoreboardLastBuilt > 0 and "yes" or "no",
        (GetTime() or 0) - _scoreboardLastBuilt,
        _scoreboardSize,
        tostring(_scoreboardByName and (function()
            local n = 0; for _ in pairs(_scoreboardByName) do n = n + 1 end; return n
        end)() or 0)))
    p(("  C_PvP.GetNumScores         = %s"):format(tostring(
        (C_PvP and C_PvP.GetNumScores) and C_PvP.GetNumScores() or "nil")))
    p(("  GetNumBattlefieldScores    = %s"):format(tostring(
        GetNumBattlefieldScores and GetNumBattlefieldScores() or "nil")))
    p(("  C_PvP.GetActiveMatchState  = %s"):format(tostring(
        (C_PvP and C_PvP.GetActiveMatchState) and C_PvP.GetActiveMatchState() or "nil")))
    local inst, instType = IsInInstance()
    p(("  IsInInstance               = %s / %s"):format(tostring(inst), tostring(instType)))

    -- Print a value safely without revealing secret-string contents.
    -- tostring / %q / .. on a secret string can taint our execution
    -- (the very cascade we're trying to escape).  Use this for any
    -- value sourced from a Unit API or PVPScoreInfo.
    local function _Safe(v)
        if v == nil then return "nil" end
        if issecretvalue and issecretvalue(v) then return "[secret]" end
        if type(v) == "string" then return v end
        return tostring(v)
    end

    -- Probe the first 3 score rows via BOTH APIs so we can see which
    -- one is actually returning usable data, and whether the fields
    -- we depend on (name / talentSpec) are non-secret strings.
    p("-- raw rows from C_PvP.GetScoreInfo (modern API):")
    for i = 1, math.min(3, _scoreboardSize) do
        local ok, v = pcall(function() return C_PvP and C_PvP.GetScoreInfo and C_PvP.GetScoreInfo(i) end)
        if not ok then
            p(("  [%d] error"):format(i))
        elseif type(v) ~= "table" then
            p(("  [%d] returned %s (%s)"):format(i, _Safe(v), type(v)))
        else
            p(("  [%d] name=%s talentSpec=%s classToken=%s"):format(
                i, _Safe(v.name), _Safe(v.talentSpec), _Safe(v.classToken)))
        end
    end

    p("-- raw rows from GetBattlefieldScore (legacy API):")
    for i = 1, math.min(3, _scoreboardSize) do
        if GetBattlefieldScore then
            local results = { pcall(GetBattlefieldScore, i) }
            if results[1] then
                -- Dump all positional returns so we can see exactly
                -- which slot has talentSpec (signature varies by patch).
                local parts = {}
                for slot = 2, math.min(20, #results) do
                    parts[#parts + 1] = ("[%d]=%s"):format(slot - 1, _Safe(results[slot]))
                end
                p(("  [%d] %s"):format(i, table.concat(parts, " ")))
            else
                p(("  [%d] pcall failed"):format(i))
            end
        end
    end

    p("-- name -> talentSpec map (post-build):")
    if _scoreboardByName then
        local keys = {}
        for k in pairs(_scoreboardByName) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            p(("  %-32s -> %s   (class=%s)"):format(
                k, _Safe(_scoreboardByName[k]),
                _Safe(_scoreboardClassByName[k])))
        end
        if #keys == 0 then
            p("  (empty — see raw rows above to see which API is missing data)")
        end
    end
    p("===== end =====")
end

-- Localized class name fallback.  In retail Midnight 12.x BGs the
-- scoreboard's talentSpec field is secret-tagged for every enemy
-- (confirmed via /mnp scoreboard — every row shows "[secret]").
-- FontString:SetText with a secret-string value appears to no-op
-- silently in 12.x — so even though the map has the data, nothing
-- renders.  Class name (from non-secret classToken) IS displayable
-- and gives the user useful identity info ("Hunter", "Mage") even
-- if we can't get the exact spec.
local function _ClassNameFromToken(classToken)
    if not classToken then return nil end
    if issecretvalue and issecretvalue(classToken) then return nil end
    -- Prefer the male localized form (Blizzard's standard) — these
    -- come from a static table built at addon load, never secret.
    local n = LOCALIZED_CLASS_NAMES_MALE
              and LOCALIZED_CLASS_NAMES_MALE[classToken]
    if n and n ~= "" then return n end
    -- Final fallback: the english token itself.
    return classToken
end

local function _GetSpecByScore(unit, plate)
    if not unit then return nil end
    if issecretvalue and issecretvalue(unit) then return nil end

    -- HIGHEST PRIORITY: per-plate cache populated by target/mouseover
    -- capture.  In retail Midnight 12.x BGs, every name-bearing field
    -- on enemy plates is secret-tagged (UnitName, UnitGUID,
    -- UnitCreatureType, uf.name:GetText() — all confirmed via /mnp
    -- labels) — so the scoreboard lookup paths below cannot key off
    -- anything for enemies.  The ONLY way to get spec for them is
    -- when the user has targeted or mouseovered the plate at some
    -- point — the "target" / "mouseover" tokens ARE non-secret and
    -- _GetSpecByTooltip succeeds against them.  We cache the result
    -- on the plate frame itself (Lua table key — never secret) and
    -- return it here.
    if plate then
        local cached = ns.GetSpecByPlate and ns:GetSpecByPlate(plate)
        if cached then return cached end
    end

    -- UnitName(unit) is anonymised for enemy plates in 12.x BG —
    -- returns secret or nil.  Use Discovery's robust resolver
    -- which falls back to uf.name:GetText().  For TRULY anonymised
    -- plates that fallback is also secret-tagged, but for friendly
    -- and non-anonymised contexts (friendly party, world NPCs,
    -- pre-12.x patches) UnitName works fine and this path lights up.
    local pname = ns.GetPlateName and ns:GetPlateName(unit, plate)
                  or UnitName(unit)
    if pname == nil then return nil end
    if issecretvalue and issecretvalue(pname) then return nil end
    if pname == "" then return nil end

    -- Cache lookup.
    local sp = _scoreboardByName[pname]

    -- Lazy first-build / retry if empty.  Rate-limited to one attempt
    -- per second so a long match without the user's plate being in
    -- the scoreboard doesn't keep churning C_PvP every refresh.
    if sp == nil then
        local now = GetTime() or 0
        if _scoreboardSize == 0 and (now - _scoreboardLastBuilt) >= 1 then
            _BuildScoreboardMap()
            sp = _scoreboardByName[pname]
        end
    end

    -- Prefer non-secret talentSpec (friendly players, certain match
    -- types, or pre-12.x patches).  Plain string we can compare,
    -- concatenate, and SetText reliably.
    if sp ~= nil and not (issecretvalue and issecretvalue(sp)) then
        if sp ~= "" then return sp end
    end

    -- Combat-log-derived spec for BG enemies.  When an enemy player
    -- has cast a spec-unique spell since match start (Mortal Strike,
    -- Howling Blast, Penance, etc.), SpecSpells.lua's listener has
    -- cached the localized spec name by sourceName.  This is the
    -- ONLY mechanism in retail Midnight 12.x that can produce a
    -- real spec name ("Frost", "Devastation") for a BG enemy —
    -- C_PvP.GetScoreInfo's talentSpec is secret-tagged so we can't
    -- use it directly.  Returned string is from static Blizzard
    -- data (GetSpecializationInfoByID), never secret.
    if ns.GetSpecByCombatLog then
        local cl = ns:GetSpecByCombatLog(pname)
        if cl then return cl end
    end

    -- Still no spec → fall back to the localized class name from
    -- classToken (non-secret).  Gives "Hunter" / "Mage" / etc.
    -- until the enemy casts something distinctive that the combat
    -- log listener can pick up.
    local ct = _scoreboardClassByName[pname]
    local cn = _ClassNameFromToken(ct)
    if cn then return cn end

    -- NO secret-string passthrough.  Passing a secret-tagged value
    -- to FontString:SetText triggers the HARD "MyNamePlates has
    -- been blocked from an action only available to the Blizzard
    -- UI" popup in retail Midnight 12.x — confirmed in BG testing.
    -- Better to render nothing than to risk hard-blocking the addon.
    return nil
end

local function _GetSpecName(plate, unit)
    if not unit then return nil end
    -- IMPORTANT: do NOT bail on issecretvalue(unit) here.  Earlier
    -- iterations had an `if issecretvalue(unit) then return nil end`
    -- guard at this point, which broke arena specs in partial
    -- lobbies (1v2, 2v3, 3-with-DC).  The ArenaMap path below is
    -- PLATE-keyed via GetArenaUnitForPlate(plate) → it gets back a
    -- canonical "arenaN" token, not the plate's per-unit token —
    -- so it doesn't care whether `unit` is secret.  Bailing here
    -- pre-empted the arena lookup and stripped spec text from
    -- exactly the case it was supposed to handle.
    --
    -- We still need to be careful inside the individual branches:
    -- the `UnitIsUnit(unit, "player")` self-check IS a comparison
    -- on `unit`, so issecretvalue-guard it locally; the arena
    -- path doesn't touch `unit` at all; and the BG/tooltip paths
    -- have their own internal guards in _GetSpecByScore /
    -- _GetSpecByTooltip.

    if UnitIsUnit and GetSpecialization and GetSpecializationInfo
       and not (issecretvalue and issecretvalue(unit)) then
        local ok, isSelf = pcall(UnitIsUnit, unit, "player")
        if ok and isSelf then
            local idx = GetSpecialization()
            if idx then
                local _, name = GetSpecializationInfo(idx)
                if name and name ~= "" then return name end
            end
        end
    end

    -- 1.36.13: PER-PLATE CACHE path (highest confidence).  This
    -- cache is populated by _CaptureSpecFromToken when the user
    -- targets or mouseovers a plate — reading the spec directly
    -- from the canonical target/mouseover tooltip, which is 100%
    -- reliable when it succeeds.  MUST come before the ArenaMap
    -- arena path: ArenaMap's fingerprint match can mis-tag a plate
    -- to the wrong arena1..3 slot when two opponents share power
    -- type and their class field is anonymised (2-caster teams,
    -- healer-and-caster-DPS teams).  When mis-tagged, the arena
    -- path below returns another opponent's spec (e.g. "Affliction"
    -- on the enemy healer's plate because the healer's plate got
    -- bound to arena1 = a Warlock's slot).  The per-plate cache
    -- bypasses that entirely — once the user targets the healer
    -- even once, the correct spec is cached against the plate
    -- frame itself and cannot be contaminated by ArenaMap.
    if plate and ns.GetSpecByPlate then
        local cached = ns:GetSpecByPlate(plate)
        if cached then return cached end
    end

    -- 1.36.15: DEFINITIVE ARENA LINKAGE path.  Populated only from
    -- target/focus/mouseover UnitIsUnit hits (never fingerprint), so
    -- 100% reliable when it lights up.  Returns the specName from
    -- the prep cache (from GetArenaOpponentSpec — canonical Blizzard
    -- data, always correct for the linked slot).  Runs before the
    -- ArenaMap path because ArenaMap can be wrong; this table cannot.
    if plate and ns.GetArenaByPlate then
        local idx = ns:GetArenaByPlate(plate)
        local prep = idx and ns.ARENA_PREP and ns.ARENA_PREP[idx]
        if prep and prep.specName and prep.specName ~= "" then
            return prep.specName
        end
    end

    -- ARENA path.  ArenaMap binds plate → arenaN canonical token;
    -- GetArenaOpponentSpec is the authoritative spec source when
    -- ArenaMap's plate → slot binding is correct.  This path uses
    -- ONLY `plate` as the lookup key and reads the spec via a
    -- canonical token (arenaN) — never touches `unit` — so it's
    -- safe regardless of whether `unit` is secret.  Runs AFTER
    -- the per-plate cache and the definitive linkage so a direct
    -- capture always wins.
    if ns.GetArenaUnitForPlate and plate then
        local _, idx = ns:GetArenaUnitForPlate(plate)
        if idx and GetArenaOpponentSpec then
            local specID = GetArenaOpponentSpec(idx)
            if specID and specID ~= 0 and GetSpecializationInfoByID then
                local _, name = GetSpecializationInfoByID(specID)
                if name and name ~= "" then return name end
            end
        end
    end

    -- BG / rated PvP path.  Same idea as arena — bypass per-plate
    -- secret-string returns by going through a canonical-data API.
    -- Internal issecretvalue-guards live inside _GetSpecByScore.
    local viaScore = _GetSpecByScore(unit, plate)
    if viaScore then return viaScore end

    -- Open-world / dummies / and any case the score API can't cover.
    -- _GetSpecByTooltip has its own internal secret-string guards.
    local viaTooltip = _GetSpecByTooltip(unit)
    if viaTooltip then return viaTooltip end

    return nil
end

----------------------------------------------------------------------
-- Class color helper.
----------------------------------------------------------------------
local function _ClassColor(unit, plate)
    -- Try direct UnitClass; for forbidden anonymized tokens use
    -- ArenaMap canonical token via the same helper Indicators use.
    local _, classFile = UnitClass(unit)
    -- UnitClass on a forbidden / anonymised unit returns a secret-
    -- string classFile even when the unit token itself is not secret.
    -- Treat secret returns as "no class info" so fallbacks run —
    -- without this guard, the RAID_CLASS_COLORS[classFile] index
    -- below taints our execution.
    if classFile and issecretvalue and issecretvalue(classFile) then
        classFile = nil
    end
    -- 1.36.13: PER-PLATE CACHE fallback (populated on target /
    -- mouseover capture — see _CaptureSpecFromToken).  Runs BEFORE
    -- ArenaMap because a direct-capture value cannot be wrong,
    -- whereas ArenaMap's plate → arena-slot fingerprint match can
    -- mis-tag a plate to a different opponent's slot in ambiguous
    -- teams and hand back the wrong class here.
    if (not classFile) and plate and ns.GetClassByPlate then
        classFile = ns:GetClassByPlate(plate)
    end
    -- 1.36.15: definitive arena linkage -> ARENA_PREP classFile.
    -- Same rationale: only set from target/focus/mouseover hits,
    -- so guaranteed correct when populated.
    if (not classFile) and plate and ns.GetArenaByPlate then
        local idx = ns:GetArenaByPlate(plate)
        local prep = idx and ns.ARENA_PREP and ns.ARENA_PREP[idx]
        if prep and prep.classFile then classFile = prep.classFile end
    end
    -- Fallback 1: ArenaMap canonical "arenaN" token (arenas).
    if (not classFile) and ns.GetArenaUnitForPlate and plate then
        local arenaUnit = ns:GetArenaUnitForPlate(plate)
        if arenaUnit then
            _, classFile = UnitClass(arenaUnit)
            if classFile and issecretvalue and issecretvalue(classFile) then
                classFile = nil
            end
        end
    end
    -- Fallback 2: BG scoreboard lookup by player name (BGs).
    -- classToken from C_PvP.GetScoreInfo is non-secret per our
    -- diagnostic, so this is the reliable color source for enemy
    -- player plates in 12.x BGs.
    if not classFile and unit then
        local nm = UnitName(unit)
        if nm and not (issecretvalue and issecretvalue(nm)) and nm ~= "" then
            classFile = ns.GetClassFromScoreboard and ns:GetClassFromScoreboard(nm)
        end
    end
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local c = RAID_CLASS_COLORS[classFile]
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

----------------------------------------------------------------------
-- Name reposition (BBP pattern).  Reposition Blizzard's frame.name
-- with the user's xOffset / yOffset / anchor.  A flag prevents the
-- hook from re-entering itself when WE call SetPoint.
----------------------------------------------------------------------
-- Picks the config for Blizzard's existing `uf.name` FontString.
-- Player + regular-NPC plates only — summons now go through the
-- custom `MyNP_SummonName` FontString path (see _ApplySummonName).
-- Returns nil if no block applies; caller restores defaults.
--
-- Test mode (ns.testMode[key]) is the live-preview mechanism shared
-- with indicators/auras: when active for a block, that block's config
-- is forced onto EVERY plate, ignoring both the per-block `enabled`
-- toggle AND the summon classification.  This lets the user click
-- "Test" and tune offsets/scale/font in the open world on whatever
-- they happen to be looking at.
-- petTotemName test mode is handled outside this picker (it drives
-- the custom FontString path), so this picker stays focused on
-- L.name only.
-- 1.32.8: REVERTED to baseline (1.24.0) name-handling model.
--
-- Previous iteration (1.25.x → 1.32.7) routed summon plates through
-- a custom MyNP_SummonName FontString and parked uf.name off-screen
-- via _SuppressUFName.  That approach had three problems users
-- repeatedly hit:
--
--   1. The overlay only rendered when we could resolve a non-secret
--      name from the unit token or the target/mouseover capture
--      cache.  In retail 12.x BG/arena UnitName is secret-tagged on
--      enemy summon plates until interaction, so the overlay stayed
--      empty AND we'd parked Blizzard's uf.name off-screen — net
--      result: no totem name visible until interaction, just
--      Blizzard's default centered text on click.
--   2. The forward-declaration / shadowing-local bug
--      (Labels.lua:907 attempt to call a nil value).
--   3. The mismatch between users' configured offset on the petTotemName
--      block (BOTTOM anchor, yOffset 41 — the screenshots) and what
--      they actually saw (Blizzard's centered name on click).
--
-- The baseline (1.24.0) approach is simpler and works: reposition
-- Blizzard's existing uf.name FontString with the user's offsets and
-- set IgnoreParentAlpha(true) so it doesn't fade with the plate's
-- alpha animation.  The same _PickNameConfig picker decides whether
-- to use the player/NPC `name` block or the summon `petTotemName`
-- block, and the per-summon-type filter (totem / pet_warlock /
-- psyfiend / etc.) gates which kinds of summons get the overlay.
--
-- This also obsoletes _SuppressUFName / _GetSummonNameFS /
-- _ApplySummonName / _HideSummonName.  The MyNP_SummonName FontString
-- (and the MyNP_summonNameActive flag) are no longer used; existing
-- saved plates harmlessly carry the field until the plate is
-- recycled.
local function _PickNameConfig(plate, unit)
    local L = MyNamePlatesDB and MyNamePlatesDB.labels
    if not L then return nil end

    if ns.testMode and ns.testMode.petTotemName and L.petTotemName then
        return L.petTotemName
    end
    if ns.testMode and ns.testMode.name and L.name then
        return L.name
    end

    local isSummon = ns.IsSummonPlate and ns:IsSummonPlate(plate, unit)
    if isSummon and L.petTotemName and L.petTotemName.enabled == "1" then
        -- Per-type filter: only apply the petTotemName cfg when this
        -- specific summon type is ticked on the Pet & Totem Name page.
        -- Types that are unticked fall through to nil (so the overlay
        -- stays off for filtered-out types like Wild Imps) rather than
        -- the regular `name` block.  Unknown summonType (race window
        -- before Discovery classifies) is treated as "show" — better
        -- to render something than to silently miss a Capacitor Totem
        -- because we haven't finished classifying yet.
        local types = L.petTotemName.types
        local cachedType = plate and ns.GetSummonTypeByPlate
                           and ns:GetSummonTypeByPlate(plate)
        local st
        if cachedType then
            -- Per-plate cache (populated by target/mouseover capture)
            -- — accurate type even when the unit token is anonymised.
            st = cachedType
        else
            local info = ns.GetSummonInfoForUnit
                         and ns:GetSummonInfoForUnit(unit)
            st = info and info.summonType
        end
        local typeAllowed = (not types) or (not st) or (types[st] ~= false)
        if typeAllowed then
            return L.petTotemName
        end
        return nil
    end

    if L.name and L.name.enabled == "1" then
        return L.name
    end
    return nil
end

-- 1.34.2: shared upvalue state + named pcall bodies for the two
-- hot paths below (_RestoreDefaultName, _RepositionName).  Same
-- pattern as _labelState below — RefreshAllLabels fires at 10 Hz
-- and drives _RepositionName once per plate, so anonymous closure
-- allocations here were among the top remaining garbage sources.
local _nameApplyState = { uf = nil, cfg = nil, plate = nil }

local function _RestoreDefaultNameInner()
    local uf = _nameApplyState.uf
    if not (uf and uf.name) then return end
    uf.name:ClearAllPoints()
    local anchor = uf.healthBar or uf
    uf.name:SetPoint("BOTTOM", anchor, "TOP", 0, 4)
    uf.name:SetScale(1.0)
    if uf.name.MyNP_ipa and uf.name.SetIgnoreParentAlpha then
        pcall(uf.name.SetIgnoreParentAlpha, uf.name, false)
        uf.name.MyNP_ipa = nil
    end
end

-- Restore the name FontString to Blizzard-equivalent defaults.  Only
-- called when no config applies but we'd previously moved the text
-- (so toggling Test off, or unticking Enabled, snaps the name back
-- to its native position instead of leaving it floating in space).
-- Skips forbidden frames — see _RepositionName for the rationale.
local function _RestoreDefaultName(plate, uf)
    if not (uf and uf.name) then return end
    if _IsForbidden(plate, uf) then return end
    if not uf.name.MyNP_moved then return end
    uf.name.MyNP_repositioning = true
    _nameApplyState.uf = uf
    pcall(_RestoreDefaultNameInner)
    uf.name.MyNP_repositioning = false
    uf.name.MyNP_moved      = nil
    uf.name.MyNP_suppressed = nil
end

local function _RepositionNameInner()
    local uf   = _nameApplyState.uf
    local cfg  = _nameApplyState.cfg
    local plate= _nameApplyState.plate
    if not (uf and uf.name and cfg) then return end
    local anchor = uf.healthBar or uf
    uf.name:ClearAllPoints()
    uf.name:SetPoint("CENTER", anchor,
        cfg.anchor or "BOTTOM",
        tonumber(cfg.xOffset) or 0,
        tonumber(cfg.yOffset) or -4)

    -- Summon-name override (BBP totem.lua:399 pattern).
    if plate and ns.GetSummonNameByPlate then
        local cachedName = ns:GetSummonNameByPlate(plate)
        if cachedName
           and not (issecretvalue and issecretvalue(cachedName))
           and cachedName ~= ""
           and uf.name.SetText then
            local cur = uf.name.GetText and uf.name:GetText()
            local curIsSecret = cur and issecretvalue and issecretvalue(cur)
            if curIsSecret or cur ~= cachedName then
                pcall(uf.name.SetText, uf.name, cachedName)
            end
        end
    end

    if (not uf.name.MyNP_ipa) and uf.name.SetIgnoreParentAlpha then
        pcall(uf.name.SetIgnoreParentAlpha, uf.name, true)
        uf.name.MyNP_ipa = true
    end

    uf.name:SetScale(tonumber(cfg.scale) or 1.0)

    local size = tonumber(cfg.fontSize) or 0
    if size > 0 and uf.name.GetFont and uf.name.SetFont then
        local font, _, flags = uf.name:GetFont()
        if font then
            uf.name:SetFont(font, size, flags or "")
        end
    end
end

local function _RepositionName(plate)
    local uf = plate and plate.UnitFrame
    if not uf or not uf.name then return end
    -- Skip forbidden frames entirely.  Touching a forbidden UnitFrame's
    -- name (SetPoint / SetAlpha / SetScale) propagates taint up the
    -- secure chain — next time the player tries to target/click that
    -- arena enemy, "Interface action failed because of an AddOn"
    -- fires.  We check both top-level plate and UnitFrame because
    -- which one carries the forbidden flag varies across patches.
    if _IsForbidden(plate, uf) then return end
    if uf.name.MyNP_repositioning then return end

    local unit = uf.unit or uf.displayedUnit
    if not unit then return end

    -- Retail Midnight 12.x tags anonymised arena enemy summon plates
    -- (totems, pets) with SECRET-STRING uf.unit tokens.  Comparing or
    -- hashing a secret string from inside our addon's execution
    -- context taints us — so we CANNOT call UnitIsFriend / any Unit*
    -- API on a secret unit here.
    --
    -- BUT: _CaptureSummonFromToken (Discovery.lua) captures the
    -- summon's name / type / isFriend from the NON-secret "target" /
    -- "mouseover" unit token when the user interacts with the plate,
    -- and caches those values keyed by plate frame reference (Lua
    -- table identity, never secret).  On secret-unit plates we
    -- render the name overlay entirely from that cache — no touching
    -- of the secret unit token — which is exactly what BBP does for
    -- its arena totem name overrides.
    --
    -- Two branches:
    --   * Non-secret unit — original code path.
    --   * Secret unit + cached summon name — cached-data-only path
    --     below.  If unit is secret and there's no cache, bail (we
    --     have no name to render and no way to safely resolve one).
    local unitSecret = issecretvalue and issecretvalue(unit)
    local cachedSummonName = plate and ns.GetSummonNameByPlate
                             and ns:GetSummonNameByPlate(plate)
    if unitSecret and not cachedSummonName then return end

    local cfg, isFriend
    if unitSecret then
        -- Secret unit + cache present.  Route directly through the
        -- petTotemName block (this IS a summon by construction — the
        -- cache is only populated by _CaptureSummonFromToken for
        -- classified summons) and use cached isFriend for the
        -- applyFriendly / applyEnemy gate.
        local L = MyNamePlatesDB and MyNamePlatesDB.labels
        cfg = L and L.petTotemName
        if not (cfg and cfg.enabled == "1") then return end

        -- Per-summon-type filter using the cached type.
        local cachedType = ns.GetSummonTypeByPlate
                           and ns:GetSummonTypeByPlate(plate)
        if cfg.types and cachedType and cfg.types[cachedType] == false then
            return
        end

        -- Cached isFriend from the non-secret capture token.
        -- Default to enemy when the cache doesn't have it (rare —
        -- capture always sets it, but be defensive).
        local cf = ns.GetSummonFriendByPlate
                   and ns:GetSummonFriendByPlate(plate)
        isFriend = cf == true
    else
        cfg = _PickNameConfig(plate, unit)
        if not cfg then
            _RestoreDefaultName(plate, uf)
            return
        end
        isFriend = UnitIsFriend("player", unit)
    end

    if isFriend and not cfg.applyFriendly then return end
    if (not isFriend) and not cfg.applyEnemy then return end

    -- Position + scale + (optional) font-size + SUMMON-NAME OVERRIDE.
    -- This mirrors what BBP does (see retail/modules/totem.lua:399
    --   `frame.name:SetText(npcData.name)`
    -- and midnight/BetterBlizzPlates.lua:6829
    --   `frame.name:SetText(UnitName(frame.unit))`
    -- ) — they reposition uf.name AND explicitly SetText it.  In
    -- retail Midnight 12.x Blizzard's CompactUnitFrame_UpdateName
    -- leaves uf.name's text empty for non-targeted enemy summon
    -- plates in arena/BG (the same anonymization layer that hides
    -- everything else).  Repositioning an empty FontString shows
    -- nothing — which is exactly the user-reported "totem only
    -- shows on click in Blizzard default position" symptom: on
    -- click Blizzard sets the text but our reposition either
    -- already ran with empty text or Blizzard's UpdateAnchors
    -- re-anchors after us.
    --
    -- The fix: pull the captured non-secret name from
    -- Discovery._summonByPlate (populated by _CaptureSummonFromToken
    -- when the user targets / mouseovers the totem) and SetText
    -- ourselves on every refresh.  This keeps the totem's name on
    -- screen at our offset for the rest of the plate's lifetime,
    -- even after the user un-targets it.  The cached name is a
    -- regular Lua string (never secret — we filter in
    -- _CaptureSummonFromToken), so SetText with it is taint-safe.
    --
    -- We deliberately do NOT call SetText for non-summons or for
    -- summons without a cached name:
    --   * Non-summons → leave Blizzard's text alone (it works fine
    --     for players via UnitName + the engine's pre-population).
    --   * Summons without cache → no name available; setting "" or
    --     a secret-string fallback would either hide the text we
    --     want or risk taint.  User just sees the same behavior
    --     they would in baseline until they interact once.
    uf.name.MyNP_repositioning = true
    uf.name.MyNP_moved = true
    -- 1.34.2: named function + shared upvalue instead of a fresh
    -- pcall(function()...) closure per plate per refresh.  See the
    -- _nameApplyState / _RepositionNameInner definitions above for
    -- full rationale.  Full comments about the SetText / alpha /
    -- scale / font semantics moved to _RepositionNameInner.
    _nameApplyState.uf    = uf
    _nameApplyState.cfg   = cfg
    _nameApplyState.plate = plate
    pcall(_RepositionNameInner)
    uf.name.MyNP_repositioning = false
end

-- Position-only hook (matches BBP exactly — see midnight/BetterBlizzPlates.lua
-- BBP.RepositionName ~line 5369-5374).  Hooking Hide / SetAlpha causes taint
-- on the nameplate UnitFrame: our insecure :Show()/:SetAlpha(1) replies to
-- Blizzard's secure :Hide()/:SetAlpha(0), the FontString and its parent then
-- inherit addon taint, and any later secure read of the plate (target
-- selection highlight, click handler, spec/class indicator parented to it)
-- throws "action blocked".  Hooking SetPoint is safe because moving a
-- widget doesn't pass through secure execution — BUT only on a non-
-- forbidden UnitFrame.  Forbidden arena enemy UnitFrames must be left
-- entirely alone or any modification propagates taint and breaks
-- targeting/click on those plates.
local function _HookName(plate)
    local uf = plate and plate.UnitFrame
    if not uf or not uf.name then return end
    if _IsForbidden(plate, uf) then return end
    if uf.name.MyNP_hooked then return end
    uf.name.MyNP_hooked = true
    pcall(hooksecurefunc, uf.name, "SetPoint", function()
        _RepositionName(plate)
    end)
end

----------------------------------------------------------------------
-- 1.32.10: BBP-pattern global hook on CompactUnitFrame_UpdateName.
--
-- BBP installs this same hook (midnight/BetterBlizzPlates.lua:7257
-- `hooksecurefunc("CompactUnitFrame_UpdateName", BBP.ConsolidatedUpdateName)`)
-- so its name-text overrides re-apply every time Blizzard updates a
-- nameplate's name FontString.  The per-frame SetPoint hook we
-- install in _HookName catches POSITION changes, but Blizzard's
-- CompactUnitFrame_UpdateName can also change the TEXT (and visibility,
-- color) WITHOUT calling SetPoint — so the SetPoint hook alone misses
-- the moment Blizzard sets the totem's text on first reveal.  That's
-- the "totem only at default position on click" symptom: Blizzard
-- runs UpdateName, sets text, never calls SetPoint, our reposition
-- never re-fires, text stays at whatever anchor it had last
-- (Blizzard default if we never touched it before).
--
-- This global hook fires AFTER Blizzard's CompactUnitFrame_UpdateName
-- finishes.  We re-run _RepositionName, which applies our offset AND
-- (1.32.9) overrides uf.name's text with the cached summon name when
-- one is available.  Net result: every text update by Blizzard is
-- immediately followed by our reposition + text override.
--
-- IMPORTANT: this hook fires for ALL frames that go through
-- CompactUnitFrame_UpdateName (party/raid frames too), so we gate
-- on `frame.unit:find("nameplate")` before doing nameplate work —
-- exactly what BBP does at ConsolidatedUpdateName line 7054.
-- 1.35.0: totem name recolor / hide-name post-processor.  Runs from
-- inside _OnCompactUpdateName after we've verified this is a nameplate
-- frame and past the secret / forbidden gates.  Reads persistent
-- markers set by _ApplyTotemNameStyle so Blizzard's own name-update
-- writes (target change, aggro change, faction flip) can't flash the
-- plate name back to default color / restored text.
local function _ApplyTotemNamePostHook(frame)
    if not (frame and frame.name) then return end
    if frame.MyNP_totemHideName then
        pcall(frame.name.SetText, frame.name, "")
        return
    end
    local mk = frame.MyNP_totemNameColor
    if mk and mk[1] then
        pcall(frame.name.SetVertexColor, frame.name, mk[1], mk[2], mk[3])
    end
end

local function _OnCompactUpdateName(frame)
    if not frame then return end
    -- Hooked function fires inside Blizzard's secure execution; any
    -- error we leak propagates as taint.  pcall the body so a
    -- regression here can't bubble up and block target/click/cast.
    pcall(function()
        if frame.IsForbidden and frame:IsForbidden() then return end
        if issecretvalue and issecretvalue(frame) then return end
        local unit = frame.unit
        if not unit then return end

        -- 1.32.14: don't bail on secret unit tokens here.  The
        -- summon cache lets _RepositionName render totem names on
        -- anonymised arena plates without ever touching the secret
        -- unit — see _RepositionName's cached-data branch.  If the
        -- plate has no cached summon and the unit is secret, then
        -- _RepositionName itself will bail; but we still need to
        -- get past this gate to give it the chance.
        local unitSecret = issecretvalue and issecretvalue(unit)
        if type(unit) ~= "string" then
            -- Secret unit tokens can be non-string; :find on them
            -- would taint us.  Only walk up to the plate via the
            -- back-pointer in that case.
            if not unitSecret then return end
        else
            if not unit:find("nameplate") then return end
        end

        -- frame here IS the UnitFrame (Blizzard passes the
        -- CompactUnitFrame, not the top-level NamePlate).  Walk up
        -- to the plate via the namePlateFrame back-pointer that
        -- NamePlateUnitFrameTemplate sets.  Prefer the back-pointer
        -- for secret-unit plates (calling GetNamePlateForUnit with
        -- a secret token would compare it against internals and
        -- risks taint).
        local plate = frame.namePlateFrame
        if not plate and not unitSecret
           and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
            plate = C_NamePlate.GetNamePlateForUnit(unit, true)
        end
        if not plate then return end

        -- For secret-unit plates, only proceed when we have a
        -- cached summon name (otherwise _RepositionName has
        -- nothing to render).
        if unitSecret then
            local hasCache = ns.GetSummonNameByPlate
                             and ns:GetSummonNameByPlate(plate) ~= nil
            if not hasCache then return end
        end

        _HookName(plate)
        _RepositionName(plate)

        -- 1.35.0: totem name post-processing (color / hide-name).
        -- Runs AFTER _RepositionName because that function calls
        -- SetText with the cached summon name — we then need to
        -- re-clear or recolor on top of that write.
        _ApplyTotemNamePostHook(frame)
    end)
end
pcall(hooksecurefunc, "CompactUnitFrame_UpdateName", _OnCompactUpdateName)

-- 1.35.0: CompactUnitFrame_UpdateHealthColor hook — BBP parity.
-- Blizzard fires UpdateHealthColor on UNIT_HEALTH, target change,
-- faction change, etc. and each call resets the healthbar to the
-- default class color.  For classified totems we've stashed a
-- persistent `uf.MyNP_totemColor = {r,g,b}` marker; if present we
-- re-apply immediately after Blizzard's reset so the totem color is
-- visible without waiting for the next 10 Hz refresh cycle.
--
-- SAFETY:
--   * pcall the whole body — this fires inside secure execution, any
--     leaked error propagates as taint (same rule as name hook).
--   * Skip forbidden / secret frames.
--   * Gate on the marker's presence — never touches non-totem plates.
--   * Calling SetStatusBarColor here re-fires the SetStatusBarColor
--     hook in Discovery.lua (friendlyColor override).  That hook is
--     gated on UnitIsFriend and only rewrites friendly plates, so
--     enemy totem plates (the primary use case) don't collide.
--     For friendly totems, friendly color wins — see Discovery.lua's
--     hook body for the co-existence check we add there.
local function _OnCompactUpdateHealthColor(frame)
    if not frame then return end
    pcall(function()
        if frame.IsForbidden and frame:IsForbidden() then return end
        if issecretvalue and issecretvalue(frame) then return end
        if not frame.healthBar then return end
        local mk = frame.MyNP_totemColor
        if not (mk and mk[1]) then return end
        pcall(frame.healthBar.SetStatusBarColor, frame.healthBar,
              mk[1], mk[2], mk[3])
    end)
end
pcall(hooksecurefunc, "CompactUnitFrame_UpdateHealthColor",
      _OnCompactUpdateHealthColor)

----------------------------------------------------------------------
-- Spec apply.
----------------------------------------------------------------------
local function _ApplySpec(plate, unit, cfg)
    local fs = _GetSpecText(plate)
    if not fs then return end
    if cfg.enabled ~= "1" then fs:Hide(); return end

    local specName = _GetSpecName(plate, unit)
    -- IMPORTANT: do NOT compare specName == "" here.  For enemy BG
    -- plates the spec value comes from C_PvP.GetScoreInfo as a
    -- secret-string value, and `==` on a secret string taints our
    -- execution context — the regression we hunted for a long time
    -- via /mnp scoreboard before realising secret values can be
    -- PASSED through to Blizzard UI APIs (like SetText below) but
    -- never COMPARED in addon code.  Nil-check only; an empty-string
    -- spec renders as no visible text, which is the same as hidden.
    if not specName then fs:Hide(); return end

    fs:SetText(specName)
    fs:ClearAllPoints()
    local anchor = _SafeAnchor(plate)
    if not anchor then fs:Hide(); return end
    fs:SetPoint("CENTER", anchor,
        cfg.anchor or "TOP",
        tonumber(cfg.xOffset) or 0,
        tonumber(cfg.yOffset) or 14)
    fs:SetScale(tonumber(cfg.scale) or 1.0)

    -- Optional explicit font-size override (0 = use the FontString's
    -- inherited size from SystemFont_Shadow_Small).
    local size = tonumber(cfg.fontSize) or 0
    if size > 0 and fs.GetFont and fs.SetFont then
        local font, _, flags = fs:GetFont()
        if font then
            fs:SetFont(font, size, flags or "")
        end
    end

    local r, g, b = _ClassColor(unit, plate)
    fs:SetTextColor(r, g, b, 1)
    fs:Show()
end

----------------------------------------------------------------------
-- 1.32.8: REMOVED — the custom MyNP_SummonName overlay, its
-- _SuppressUFName off-screen-park helper, _ApplySummonName /
-- _HideSummonName, the _SummonNameAllowed gate, and the
-- _SafeUnitName helper all existed to support that overlay.
-- With the revert to baseline name-handling (reposition uf.name
-- via _RepositionName), they're no longer reachable from any
-- live code path:
--
--   * _PickNameConfig now returns L.petTotemName for summons,
--     which routes them through _RepositionName like everything
--     else — no separate FontString to manage.
--   * Per-summon-type filter (totem/pet_warlock/etc.) is enforced
--     inside _PickNameConfig by reading the per-plate cache that
--     Discovery populates from target/mouseover capture.
--   * The cache (Discovery's _summonByPlate) is still useful for
--     category re-classification (1.32.4) and for resolving the
--     right summon TYPE in _PickNameConfig, so it stays.
--
-- Why the deletion is safe end-to-end:
--   * Nothing now calls _SuppressUFName / _ApplySummonName /
--     _HideSummonName / _GetSummonNameFS / _SafeUnitName /
--     _SummonNameAllowed (verified via grep before removal).
--   * MyNP_SummonName FontStrings created by earlier versions
--     stay attached to live plates but are no longer touched;
--     when the plate is recycled, the FontString goes with it.
--   * MyNP_summonNameActive flag on plates is no longer read or
--     written — it harmlessly persists on live plates until
--     recycle.
--
-- Keeping this "removed" comment block (instead of just deleting
-- silently) so future-me doesn't reach for the same overlay
-- approach again when "totem names in arena" looks tricky.
-- The lesson: in retail 12.x the simpler approach wins.  Don't
-- fight Blizzard's uf.name when you can just reposition it.
----------------------------------------------------------------------

----------------------------------------------------------------------
-- 1.34.2: shared apply-state for the pcall'd per-plate bodies below.
-- Same pattern as _totemIconApplyState — RefreshAllLabels iterates
-- every plate on each 10 Hz drain tick, so per-plate anonymous
-- closures were the top remaining garbage source after 1.34.1.
-- Reusing a single upvalue table across all plates keeps allocation
-- at zero.
--
-- Only one caller is in-flight at any given time (single-threaded
-- game loop), and the pcall'd bodies below finish before the next
-- plate iteration begins, so cross-plate state overwrite is safe.
----------------------------------------------------------------------
local _labelState = {
    plate     = nil,
    uf        = nil,
    unit      = nil,
    anyNameOn = false,
    specCfg   = nil,
    isPlayer  = nil,
    isFriend  = nil,
}

local function _ApplyNameForPlate()
    local plate     = _labelState.plate
    local uf        = _labelState.uf
    local anyNameOn = _labelState.anyNameOn
    if anyNameOn then
        _HookName(plate)
        _RepositionName(plate)
    elseif uf and uf.name and uf.name.MyNP_moved then
        _RepositionName(plate)
    end
end

local function _ApplySpecForPlate()
    local plate    = _labelState.plate
    local unit     = _labelState.unit
    local specCfg  = _labelState.specCfg
    local isPlayer = _labelState.isPlayer
    local isFriend = _labelState.isFriend
    local sfs = plate and plate.MyNP_SpecText
    if specCfg and specCfg.enabled == "1" and isPlayer
       and ((isFriend and specCfg.applyFriendly)
            or ((not isFriend) and specCfg.applyEnemy))
    then
        _ApplySpec(plate, unit, specCfg)
    else
        if sfs then sfs:Hide() end
    end
end

----------------------------------------------------------------------
-- Public refresh
----------------------------------------------------------------------
function ns:RefreshAllLabels()
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local L = MyNamePlatesDB.labels
    local nameCfg     = L.name
    local petNameCfg  = L.petTotemName
    local specCfg     = L.spec
    -- 1.32.8: `anyNameOn` is back to the BASELINE meaning — true if
    -- EITHER block is enabled (player/NPC `name` OR summon
    -- `petTotemName`).  Both share the _RepositionName path now;
    -- _PickNameConfig handles routing the plate to the right config
    -- block based on the summon classification and per-type filter.
    local anyNameOn   = (nameCfg    and nameCfg.enabled    == "1")
                     or (petNameCfg and petNameCfg.enabled == "1")
                     or (ns.testMode and (ns.testMode.name
                                       or ns.testMode.petTotemName))

    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        local uf = plate.UnitFrame
        local unit = uf and (uf.unit or uf.displayedUnit)
        if not unit then
            -- Nothing we can do without a unit token.
        else
            local unitSecret = issecretvalue and issecretvalue(unit)
            -- 1.32.14: even when uf.unit is a SECRET-STRING token
            -- (retail Midnight 12.x anonymised arena enemy summon
            -- plate), we still want to run the NAME path if the
            -- summon cache has data for this plate.  The cache is
            -- populated by _CaptureSummonFromToken (Discovery.lua)
            -- from a NON-secret target/mouseover token, and
            -- _RepositionName has its own cached-data branch that
            -- avoids touching the secret unit.  Previously this
            -- outer `if unit and not secret` guard skipped the
            -- whole plate, so target-capture correctly stashed the
            -- totem name but the label pipeline never applied it.
            --
            -- 1.34.0: broadened from `.name` presence to ANY cache
            -- entry (via GetSummonTypeByPlate).  The totem-icon
            -- overlay renders on secret-unit summon plates even when
            -- we haven't captured a usable name (e.g. UnitName on
            -- the target/mouseover token was itself secret), so the
            -- gate must let those plates through.
            local hasSummonCache = plate and ns.GetSummonTypeByPlate
                                   and ns:GetSummonTypeByPlate(plate) ~= nil

            if (not unitSecret) or hasSummonCache then
                -- SPEC block needs friend/enemy/player resolution.
                -- Do it only for non-secret units — spec doesn't
                -- render on cached-only secret plates because we
                -- don't have a per-plate spec cache in this branch.
                local isFriend, isPlayer
                if not unitSecret then
                    local ok1, f = pcall(UnitIsFriend, "player", unit)
                    if ok1 then isFriend = f end
                    local ok2, p = pcall(UnitIsPlayer, unit)
                    if ok2 then isPlayer = p end
                    if ns.GetArenaUnitForPlate
                       and ns:GetArenaUnitForPlate(plate)
                    then
                        isFriend = false
                        isPlayer = true
                    end
                end

                -- NAME — reposition Blizzard's existing uf.name.
                -- 1.34.2: uses a named function + shared state upvalue
                -- instead of an anonymous closure.  The previous
                -- pcall(function()...) built a fresh closure over
                -- (plate, uf, anyNameOn) per plate per refresh — at
                -- 10 Hz × 20 plates that's 200 closures/sec of pure
                -- garbage.  Named body + reused state buffer = zero
                -- allocation.
                _labelState.plate     = plate
                _labelState.uf        = uf
                _labelState.anyNameOn = anyNameOn
                pcall(_ApplyNameForPlate)

                -- TOTEM ICON — BBP-style overlay.  Runs on ALL plates
                -- (including secret-unit ones with cached summon data)
                -- because IsSummonPlate consults the per-plate cache
                -- populated by target/mouseover capture.  Own pcall so
                -- a fault here can't wipe the spec render below.
                pcall(_ApplyTotemIcon, plate, unit, unitSecret and nil or isFriend)

                -- SPEC — custom overlay.  Only for non-secret units.
                -- Same shared-state pattern as NAME above.
                if not unitSecret then
                    _labelState.plate    = plate
                    _labelState.unit     = unit
                    _labelState.specCfg  = specCfg
                    _labelState.isPlayer = isPlayer
                    _labelState.isFriend = isFriend
                    pcall(_ApplySpecForPlate)
                end
            else
                -- Non-summon secret plate with no cache — still make
                -- sure any previously-rendered totem icon on this
                -- recycled plate frame is hidden.  Cheap early-out
                -- when the icon widget doesn't exist yet.
                if plate.MyNP_TotemIcon then
                    pcall(plate.MyNP_TotemIcon.Hide, plate.MyNP_TotemIcon)
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- DB helpers used by the UI
----------------------------------------------------------------------
function ns:GetLabelsConfig(key)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return nil end
    if key then return MyNamePlatesDB.labels[key] end
    return MyNamePlatesDB.labels
end

function ns:SetLabelOption(key, field, value)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return end
    if key then
        local sub = MyNamePlatesDB.labels[key]
        if sub then sub[field] = value end
    else
        MyNamePlatesDB.labels[field] = value
    end
    if ns.RefreshAllLabels then ns:RefreshAllLabels() end
end

-- Per-summon-type toggles for the petTotemName block.  Used by the
-- per-type checkbox row added to the UI.
function ns:GetLabelType(key, summonType)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return nil end
    local sub = MyNamePlatesDB.labels[key]
    if not (sub and sub.types) then return nil end
    -- Treat nil as enabled so newly-added types default ON until the
    -- user explicitly disables them (existing saves don't have new
    -- entries and shouldn't suddenly hide their plates).
    local v = sub.types[summonType]
    if v == nil then return true end
    return v and true or false
end

function ns:SetLabelType(key, summonType, on)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return end
    local sub = MyNamePlatesDB.labels[key]
    if not sub then return end
    sub.types = sub.types or {}
    sub.types[summonType] = on and true or false
    if ns.RefreshAllLabels then ns:RefreshAllLabels() end
end

-- 1.36.28: mirror of GetLabelType/SetLabelType for the ICON gate.
-- The icon overlay reads `iconTypes` (Labels.lua line ~995) so users
-- can turn off the "Warlock Pet" icon without also silencing the
-- "Observer" text label (or vice-versa).  Missing keys default ON so
-- newly-added summon types show icons until explicitly muted.
function ns:GetLabelIconType(key, summonType)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return nil end
    local sub = MyNamePlatesDB.labels[key]
    if not sub then return nil end
    -- Prefer the new iconTypes table; fall back to `types` for DBs that
    -- somehow slipped past the 1.36.28 migration (defensive — should
    -- never happen but keeps this accessor robust).
    local t = sub.iconTypes or sub.types
    if not t then return true end
    local v = t[summonType]
    if v == nil then return true end
    return v and true or false
end

function ns:SetLabelIconType(key, summonType, on)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then return end
    local sub = MyNamePlatesDB.labels[key]
    if not sub then return end
    sub.iconTypes = sub.iconTypes or {}
    sub.iconTypes[summonType] = on and true or false
    if ns.RefreshAllLabels then ns:RefreshAllLabels() end
end

-- 1.36.28: expose the fallback ICON_BY_TYPE texture path so UI.lua can
-- render a live preview of each summon type's icon in the new "Summon
-- Icons & Names" tab.  Returns the exact texture used by the icon
-- pipeline when it falls back to type-based rendering (Step 4 in
-- _ClassifyTotem), so the preview matches what the plate will actually
-- draw for an anonymized-arena summon of that type.
function ns:GetIconForSummonType(summonType)
    return ICON_BY_TYPE[summonType or "totem"] or TOTEM_ICON_GENERIC
end

-- 1.36.29: per-NPC-ID icon toggle accessors.  Backing store is
-- MyNamePlatesDB.labels.petTotemName.iconByNpcID (a table of
-- [npcID] = false for muted totems; missing keys default ON so the
-- table stays compact even for users with hundreds of important
-- totems on).  The gate lives in _ApplyTotemIcon (Labels.lua ~line
-- 1010) and only fires when the plate's npcID resolves -- which is
-- true for named totems and any anonymised summon that our capture
-- pipeline (target / mouseover / group scan) has seen.
function ns:GetLabelIconForNpc(key, npcID)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels and npcID) then return true end
    local sub = MyNamePlatesDB.labels[key]
    if not (sub and sub.iconByNpcID) then return true end
    local v = sub.iconByNpcID[npcID]
    if v == nil then return true end
    return v and true or false
end

function ns:SetLabelIconForNpc(key, npcID, on)
    if not (MyNamePlatesDB and MyNamePlatesDB.labels and npcID) then return end
    local sub = MyNamePlatesDB.labels[key]
    if not sub then return end
    sub.iconByNpcID = sub.iconByNpcID or {}
    -- Store nil (default) for ON so the DB stays compact; only false
    -- for muted totems.  Users toggling back on won't leave stale
    -- true entries lingering across sessions.
    if on then
        sub.iconByNpcID[npcID] = nil
    else
        sub.iconByNpcID[npcID] = false
    end
    if ns.RefreshAllLabels then ns:RefreshAllLabels() end
end

-- 1.36.29: enumerate every important totem from NPC_DATA for the UI.
-- Dedupes by spellID so users don't see "Capacitor Totem" listed
-- twice (npcID 61245 + 192058 both point at spellID 192058); we keep
-- the first-encountered record and its npcID as the toggle key.  All
-- npcIDs that share the same spellID are collected in `aliasNpcIDs`
-- so the UI callback can flip every one of them together (otherwise
-- toggling "off" for Capacitor would only mute one of its two NPC
-- IDs).  Sorted alphabetically by display name.
function ns:GetImportantTotems()
    if not ns.NPC_DATA then return {} end
    local bySpell = {}
    for npcID, rec in pairs(ns.NPC_DATA) do
        if rec and rec.type == "totem" and rec.important and rec.spellID then
            local existing = bySpell[rec.spellID]
            if not existing then
                bySpell[rec.spellID] = {
                    npcID       = npcID,
                    name        = rec.name,
                    spellID     = rec.spellID,
                    aliasNpcIDs = { npcID },
                }
            else
                existing.aliasNpcIDs[#existing.aliasNpcIDs + 1] = npcID
                -- Prefer the shorter / cleaner name (drops "(PvP alt)"
                -- and "(alt)" duplicates so Capacitor reads as
                -- "Capacitor Totem" not "Capacitor Totem (PvP alt)").
                if rec.name and #rec.name < #existing.name then
                    existing.name  = rec.name
                    existing.npcID = npcID
                end
            end
        end
    end
    local list = {}
    for _, entry in pairs(bySpell) do list[#list + 1] = entry end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return list
end

----------------------------------------------------------------------
-- Diagnostic: dump per-plate label state.
-- For every visible plate prints exactly which gate decisions the
-- label pipeline made — which path was taken (player NAME vs summon
-- overlay vs none), the FontString text/shown state, and the saved
-- petTotemName cfg snapshot.  Use to figure out why an expected
-- overlay isn't appearing.
----------------------------------------------------------------------
function ns:DumpLabels()
    local function p(s) print(s) end
    p("===== MyNamePlates Labels Diagnostic =====")
    if not (MyNamePlatesDB and MyNamePlatesDB.labels) then
        p("  no labels DB"); return
    end
    local L = MyNamePlatesDB.labels
    local pet = L.petTotemName or {}
    p(("petTotemName: enabled=%s anchor=%s xO=%s yO=%s scale=%s font=%s applyF=%s applyE=%s"):format(
        tostring(pet.enabled), tostring(pet.anchor),
        tostring(pet.xOffset), tostring(pet.yOffset),
        tostring(pet.scale),   tostring(pet.fontSize),
        tostring(pet.applyFriendly), tostring(pet.applyEnemy)))
    if pet.types then
        local t = {}
        for k, v in pairs(pet.types) do t[#t+1] = ("%s=%s"):format(k, tostring(v)) end
        table.sort(t)
        p("  types: " .. table.concat(t, "  "))
    end
    local spec = L.spec or {}
    p(("spec:         enabled=%s anchor=%s xO=%s yO=%s applyF=%s applyE=%s"):format(
        tostring(spec.enabled), tostring(spec.anchor),
        tostring(spec.xOffset), tostring(spec.yOffset),
        tostring(spec.applyFriendly), tostring(spec.applyEnemy)))

    if not (C_NamePlate and C_NamePlate.GetNamePlates) then
        p("  C_NamePlate missing"); return
    end
    local plates = C_NamePlate.GetNamePlates(true) or {}
    p(("-- plates: %d --"):format(#plates))
    for i, plate in ipairs(plates) do
        local ok, err = pcall(function()
            local uf = plate.UnitFrame
            local unit = uf and (uf.unit or uf.displayedUnit)
            local forbiddenP = (plate.IsForbidden and plate:IsForbidden()) and "y" or "n"
            local forbiddenU = (uf and uf.IsForbidden and uf:IsForbidden()) and "y" or "n"

            -- Secret-string guard for THIS plate.  Without it, calling
            -- UnitIsFriend / UnitIsPlayer / UnitCreatureType on a
            -- secret token would taint the dump (and from the dump,
            -- everything else).  When the token is secret we still
            -- print a row — just with the unit-derived fields marked
            -- "?secret" so the user can see the plate was iterated.
            local secret = unit and issecretvalue and issecretvalue(unit)
            if secret then
                p(("[%d] (secret token) | unit=%s plateF=%s ufF=%s"):format(
                    i, tostring(unit), forbiddenP, forbiddenU))
                return
            end

            -- Inline-safe name lookup (we removed the shared
            -- _SafeUnitName helper along with the summon-overlay
            -- block; replicate the issecretvalue-before-compare
            -- guards here to keep the diagnostic taint-safe).
            local name = "?"
            if unit then
                local nok, nv = pcall(UnitName, unit)
                if nok and nv ~= nil
                   and not (issecretvalue and issecretvalue(nv))
                   and nv ~= "" then
                    name = nv
                end
            end
            local isFriend = "?"
            if unit then
                local ok1, f = pcall(UnitIsFriend, "player", unit)
                if ok1 then isFriend = f and "y" or "n" end
            end
            local isPlayer = "?"
            if unit then
                local ok2, p2 = pcall(UnitIsPlayer, unit)
                if ok2 then isPlayer = p2 and "y" or "n" end
            end
            local isSummon = (ns.IsSummonPlate and unit
                              and ns:IsSummonPlate(plate, unit)) and "y" or "n"
            -- UnitCreatureType can return a secret string on forbidden
            -- units even when the unit token itself is non-secret.
            -- Same issecretvalue-before-compare rule applies.
            local creature = "?"
            if unit and UnitCreatureType then
                local c = UnitCreatureType(unit)
                if c == nil then
                    creature = "nil"
                elseif issecretvalue and issecretvalue(c) then
                    creature = "?secret"
                else
                    creature = c
                end
            end
            -- GUID + npcID — critical for diagnosing the totem-overlay
            -- case where UnitCreatureType is secret but GUID-derived
            -- npcID is the only way to classify the unit as a summon.
            local guid = unit and UnitGUID and UnitGUID(unit)
            local guidShown, npcShown = "nil", "nil"
            if guid then
                if issecretvalue and issecretvalue(guid) then
                    guidShown = "?secret"
                else
                    guidShown = guid
                    local kind, _, _, _, _, npcid = strsplit("-", guid)
                    if kind and not (issecretvalue and issecretvalue(kind))
                       and (kind == "Creature" or kind == "Pet" or kind == "Vehicle") then
                        npcShown = tostring(tonumber(npcid) or npcid)
                    elseif kind then
                        npcShown = "(kind=" .. tostring(kind) .. ")"
                    end
                end
            end
            p(("[%d] %s | unit=%s plateF=%s ufF=%s friend=%s player=%s summon=%s creature=%s npc=%s"):format(
                i, name, tostring(unit), forbiddenP, forbiddenU,
                isFriend, isPlayer, isSummon, tostring(creature), tostring(npcShown)))
            if guidShown ~= "nil" then
                p(("   guid=%s"):format(guidShown))
            end

            -- Visual state probe.  This is the line that tells us
            -- whether the plate is being HIDDEN somewhere (alpha=0
            -- on plate or UnitFrame, healthBar not shown, etc.).
            -- The "totem hp bar gone" symptom traces here — if the
            -- numbers are 1.0 across the board, Blizzard's engine
            -- itself isn't rendering the bar (CVar problem); if
            -- something is 0, our ApplyOverrides hid it (category
            -- alpha override or hidden NPC list).
            do
                local pa = plate.GetAlpha and plate:GetAlpha() or 1
                local pe = plate.GetEffectiveAlpha and plate:GetEffectiveAlpha() or pa
                local ps = plate.GetScale and plate:GetScale() or 1
                local ua, us = 1, 1
                if uf and uf.GetAlpha then ua = uf:GetAlpha() or 1 end
                if uf and uf.GetScale then us = uf:GetScale() or 1 end
                local hb = uf and uf.healthBar
                local hbShown = hb and hb.IsShown and hb:IsShown() and "y" or "n"
                local hbAlpha = hb and hb.GetAlpha and hb:GetAlpha() or 0
                p(("   visual:   plate a=%.2f effA=%.2f s=%.2f  uf a=%.2f s=%.2f  hb shown=%s a=%.2f"):format(
                    pa, pe, ps, ua, us, hbShown, hbAlpha))
            end

            -- Active classification record probe.  Shows which
            -- category our addon assigned this plate, which is the
            -- key to deciding visual overrides.  An unexpected
            -- summonType (e.g. "guardian" or "minor" for a totem)
            -- means AutoClassify's HP heuristic kicked in instead
            -- of the NPC_DATA name match, and the user's per-cat
            -- alpha/hide setting for THAT category is what's
            -- removing the bar.
            do
                local info = ns.GetPlateInfo and unit and ns:GetPlateInfo(unit)
                if info then
                    local catLabel = "?"
                    if ns.CATEGORY_BY_ID and info.categoryID
                       and ns.CATEGORY_BY_ID[info.categoryID] then
                        catLabel = ns.CATEGORY_BY_ID[info.categoryID].label or info.categoryID
                    end
                    local cat = MyNamePlatesDB and MyNamePlatesDB.categories
                                and MyNamePlatesDB.categories[info.categoryID]
                    local catAlpha = cat and tonumber(cat.alpha) or 1
                    local catScale = cat and tonumber(cat.scale) or 1
                    local catEnab  = cat and cat.enabled or "?"
                    local catHide  = (cat and cat.hidden and info.npcID
                                     and cat.hidden[info.npcID]) and "y" or "n"
                    p(("   classify: cat=%s (id=%s) summonType=%s npcID=%s  cat.enabled=%s a=%.2f s=%.2f hidden=%s"):format(
                        catLabel, tostring(info.categoryID),
                        tostring(info.summonType), tostring(info.npcID),
                        tostring(catEnab), catAlpha, catScale, catHide))
                else
                    p("   classify: (no active record — plate not classified by our addon)")
                end
            end

            -- (1.32.8: MyNP_SummonName overlay removed; the
            --  diagnostic line below used to dump its IsShown / text /
            --  point / scale, but the FontString no longer exists in
            --  the live codepath.  uf.name state below is now the
            --  single source of truth for "what name is showing on
            --  this plate".)

            -- Blizzard uf.name state
            if uf and uf.name then
                p(("   uf.name:  text=%q moved=%s suppressed=%s ipa=%s hooked=%s"):format(
                    tostring(uf.name:GetText() or ""),
                    tostring(uf.name.MyNP_moved),
                    tostring(uf.name.MyNP_suppressed),
                    tostring(uf.name.MyNP_ipa),
                    tostring(uf.name.MyNP_hooked)))
            end
            -- Spec path state
            local spcFS = plate.MyNP_SpecText
            if spcFS then
                p(("   SpecFS:   shown=%s text=%q"):format(
                    tostring(spcFS:IsShown()),
                    tostring(spcFS:GetText() or "")))
            end

            -- Per-plate cache probe (target/mouseover capture).  Tells
            -- us whether the cache was populated for this plate when
            -- the user targeted/mouseovered it.  If cached values are
            -- nil after the user has interacted with the unit, the
            -- capture handler bailed early — and the rest of the
            -- probe below tells us why.
            local cachedSpec = ns.GetSpecByPlate and ns:GetSpecByPlate(plate)
            local cachedSummonType = ns.GetSummonTypeByPlate
                                     and ns:GetSummonTypeByPlate(plate)
            local cachedSummonName = ns.GetSummonNameByPlate
                                     and ns:GetSummonNameByPlate(plate)
            p(("   cache:    spec=%s summonType=%s summonName=%s"):format(
                cachedSpec and tostring(cachedSpec) or "nil",
                cachedSummonType and tostring(cachedSummonType) or "nil",
                cachedSummonName and tostring(cachedSummonName) or "nil"))

            -- Spec resolution probe (only for player plates where we'd
            -- expect spec to render).  Reveals exactly which path in
            -- the resolution chain succeeded / failed.
            if unit and isPlayer == "y" then
                -- 1. GetPlateName output (with secret check on the
                --    returned value to detect uf.name:GetText() being
                --    secret-tagged itself).
                local pn = ns.GetPlateName and ns:GetPlateName(unit, plate)
                local pnSec = (pn and issecretvalue and issecretvalue(pn)) and "y" or "n"
                p(("   probe:    GetPlateName=%s secret=%s"):format(
                    pn and tostring(pn) or "nil", pnSec))

                -- 2. Direct uf.name:GetText() inspection.
                if uf and uf.name and uf.name.GetText then
                    local ufText = uf.name:GetText()
                    local ufSec  = (ufText and issecretvalue and issecretvalue(ufText)) and "y" or "n"
                    p(("             uf.name:GetText()=%s secret=%s"):format(
                        ufText and tostring(ufText) or "nil", ufSec))
                end

                -- 3. Scoreboard hit/miss for this plate's name.  This
                --    is the join key for class/spec fallbacks.
                if pn and (not (issecretvalue and issecretvalue(pn))) then
                    -- Avoid the "?missing-helper" sentinel string in a
                    -- variable that might receive a secret value next.
                    -- Compare against constants only on non-secret values.
                    local hasSpecHelper  = ns.GetSpecFromScoreboard ~= nil
                    local hasClassHelper = ns.GetClassFromScoreboard ~= nil
                    local sbSpec  = hasSpecHelper  and ns:GetSpecFromScoreboard(pn)  or nil
                    local sbClass = hasClassHelper and ns:GetClassFromScoreboard(pn) or nil
                    -- issecretvalue check BEFORE any other comparison —
                    -- sbSpec is the secret-string field from the
                    -- scoreboard map and `sbSpec == "?missing-helper"`
                    -- would taint our diagnostic execution context.
                    local sbSpecState
                    if not hasSpecHelper then sbSpecState = "?missing-helper"
                    elseif sbSpec == nil then sbSpecState = "nil"
                    elseif issecretvalue and issecretvalue(sbSpec) then sbSpecState = "[secret]"
                    elseif type(sbSpec) == "string" then sbSpecState = sbSpec
                    else sbSpecState = tostring(sbSpec) end
                    local sbClassState
                    if not hasClassHelper then sbClassState = "?missing-helper"
                    elseif sbClass == nil then sbClassState = "nil"
                    elseif issecretvalue and issecretvalue(sbClass) then sbClassState = "[secret]"
                    elseif type(sbClass) == "string" then sbClassState = sbClass
                    else sbClassState = tostring(sbClass) end
                    p(("             scoreboard: spec=%s class=%s"):format(
                        sbSpecState, sbClassState))
                end
            end

            -- (1.32.8: summonGate probe removed — there's no
            --  longer a custom summon overlay to gate.  The
            --  per-type filter is now applied inside
            --  _PickNameConfig and visible via the cache:
            --  summonType=... + classify: cat=... lines above.)
        end)
        if not ok then p(("[%d] error: %s"):format(i, tostring(err))) end
    end
    p("===== end =====")
end

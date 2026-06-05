-- Discovery.lua
-- Hooks NAME_PLATE_UNIT_ADDED, classifies the unit (totem / guardian / minion /
-- minor / pet), records new player-summoned NPCs into the database, and
-- continuously re-applies per-category & per-NPC overrides (visibility / scale
-- / alpha) so that Blizzard's own nameplate updates can't undo them.

local _, ns = ...

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function GetNPCID(unit)
    local guid = UnitGUID(unit)
    if not guid then return nil, nil end
    -- A secret-string GUID would propagate taint through strsplit
    -- and into any downstream `kind == "Pet"` / `npcID == X` compare,
    -- so return early instead.  Callers already treat nil as "no GUID".
    if issecretvalue and issecretvalue(guid) then return nil, nil end
    local kind, _, _, _, _, npcID = strsplit("-", guid)
    -- Defensive: also verify the split components aren't secret —
    -- even on a non-secret GUID some patches have returned secret
    -- substrings.  Belt-and-suspenders.
    if kind and issecretvalue and issecretvalue(kind) then kind = nil end
    return tonumber(npcID), kind
end

-- Safe-read helpers: any Unit* API can return a "secret string value"
-- on anonymised / forbidden plates in retail Midnight 12.x (observed
-- on enemy totems, guardians like Earth Elemental, and many BG enemy
-- plates).  Comparing or concatenating a secret string taints our
-- execution context, which then cascades through every operation on
-- every plate (manifested as missing spec FontStrings, missing summon
-- overlays, and "Interface action failed because of an AddOn").
-- These helpers turn a secret return into nil so the call site can
-- treat it the same as "API not available" rather than crashing.
local function _SafeCT(unit)
    local v = UnitCreatureType and UnitCreatureType(unit)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function _SafeClassif(unit)
    local v = UnitClassification and UnitClassification(unit)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function _SafeName(unit)
    local v = UnitName and UnitName(unit)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    if v == "" then return nil end
    return v
end

-- Robust name resolution that falls back to Blizzard's rendered text
-- (uf.name:GetText) when UnitName returns secret or nil.  In retail
-- Midnight 12.x BGs, UnitName(unit) for enemy plates returns secret
-- or nil values — verified via /mnp labels showing "?" for enemy
-- rows while uf.name:GetText() showed the actual readable name like
-- "Primal Earth Elemental".  Blizzard's CompactUnitFrame_UpdateName
-- sets uf.name's text from a path that bypasses the anonymisation,
-- so the rendered FontString text is usable even when the raw
-- UnitName API is anonymised.
--
-- The plate argument is OPTIONAL — when not provided, this is just
-- equivalent to _SafeName(unit).  Callers in classification paths
-- (Discovery.lua) and scoreboard lookups (Labels.lua) thread the
-- plate through so the fallback is available.
function ns:GetPlateName(unit, plate)
    if not unit then return nil end
    if issecretvalue and issecretvalue(unit) then return nil end
    -- Primary: UnitName, when non-secret.  This is the fast path for
    -- friendlies, world NPCs, and any pre-12.x context.
    local v = _SafeName(unit)
    if v then return v end
    -- Fallback: uf.name:GetText, set by Blizzard for display.  The
    -- value may itself be secret-tagged on some patches — if so,
    -- bail (we can't use it as a table key).  Most observed cases
    -- in 12.x return a plain string here.
    if not plate then return nil end
    local uf = plate.UnitFrame
    if not (uf and uf.name and uf.name.GetText) then return nil end
    local text = uf.name:GetText()
    if text == nil then return nil end
    if issecretvalue and issecretvalue(text) then return nil end
    if text == "" then return nil end
    return text
end

-- NPC-ID-based summon lookup.  In retail Midnight 12.x, UnitCreatureType
-- returns secret-string values for enemy totems / guardians / minions in
-- BGs and arenas — _SafeCT bails out, so the "is this a Totem?" check
-- can't classify them.  We have two fallbacks:
--
--   1. npcID from UnitGUID(unit) → NPC_DATA[npcID].type
--      Works when the GUID is non-secret (the typical Creature-0-...
--      format for totems / guardians).
--
--   2. UnitName(unit) → reverse lookup in NPC_DATA by .name
--      Works even when UnitGUID is also secret (some 12.x patches
--      mark every enemy GUID as secret in BGs).  Slower (linear
--      scan of ~few-dozen NPC_DATA entries), so we cache the
--      reverse table after first build.
--
-- Either path classifies enemy totems / guardians correctly without
-- ever touching the secret UnitCreatureType.
local _nameToNpcType
local function _BuildNameToType()
    if _nameToNpcType then return end
    _nameToNpcType = {}
    if ns.NPC_DATA then
        for id, rec in pairs(ns.NPC_DATA) do
            if rec and rec.name and rec.type then
                _nameToNpcType[rec.name] = rec.type
            end
        end
    end
    -- Also include saved-discovered entries — user-added units
    -- get the same classification benefit.
    if MyNamePlatesDB and MyNamePlatesDB.npcs then
        for id, rec in pairs(MyNamePlatesDB.npcs) do
            if rec and rec.name and rec.type then
                _nameToNpcType[rec.name] = rec.type
            end
        end
    end
end

local function _NpcDataType(unit, plate)
    -- Path 1: npcID via GUID.
    local npcID = GetNPCID(unit)
    if npcID then
        local rec = MyNamePlatesDB and MyNamePlatesDB.npcs and MyNamePlatesDB.npcs[npcID]
                  or ns.NPC_DATA and ns.NPC_DATA[npcID]
        if rec and rec.type then return rec.type end
    end
    -- Path 2: name-based reverse lookup.  ns:GetPlateName falls back
    -- to uf.name:GetText() when UnitName(unit) is secret/nil (the
    -- common case for enemy totem plates in 12.x BGs — UnitName is
    -- anonymised but Blizzard renders the actual name "Earthbind
    -- Totem" / "Capacitor Totem" etc. via uf.name).  This is the
    -- ONLY classification path that survives both secret GUID AND
    -- secret CreatureType.
    local name = ns.GetPlateName and ns:GetPlateName(unit, plate)
    if name then
        _BuildNameToType()
        local t = _nameToNpcType and _nameToNpcType[name]
        if t then return t end
    end
    return nil
end

local function IsPlayerSummon(unit, guidKind, plate)
    if guidKind == "Pet" then return true end
    if UnitPlayerControlled and UnitPlayerControlled(unit) then return true end
    if UnitIsOtherPlayersPet and UnitIsOtherPlayersPet(unit) then return true end
    if _SafeCT(unit) == "Totem" then return true end
    -- NPC-ID + name fallback for secret UnitCreatureType (retail Midnight 12.x).
    -- plate threaded through so the name lookup can fall back to
    -- uf.name:GetText() when UnitName is anonymised.
    if _NpcDataType(unit, plate) then return true end
    return false
end

local function AutoClassify(unit, guidKind, plate)
    if _SafeCT(unit)     == "Totem" then return "totem" end
    if _SafeClassif(unit) == "minus" then return "minor" end
    -- Same NPC-ID + name fallback for the type itself.  If NPC_DATA
    -- tells us "this is a totem / psyfiend / guardian", trust it —
    -- the curated list is more reliable than the secret-tainted
    -- UnitCreatureType / UnitClassification APIs in 12.x.
    local npcType = _NpcDataType(unit, plate)
    if npcType then return npcType end

    -- Two-stage classification:
    --   1. HP-only filters at the extremes (definitely minor / definitely big)
    --   2. GUID-prefix tiebreaker in the middle (Pet-GUID with reasonable HP
    --      almost always means an actual controllable pet — Hunter pet,
    --      Warlock primary demon, Frost Mage Water Elemental).  Without this
    --      bias, Hunter pets at 80–130% of player HP would be classified as
    --      guardians, and Warlock minions like Wild Imp / Dreadstalker /
    --      Vilefiend (smaller HP) get caught earlier as `minion`.
    --
    -- CRITICAL: UnitHealthMax(unit) can return a SECRET-TAGGED number
    -- on anonymised plates in retail Midnight 12.x — even though it's
    -- a number, comparing it (hp > 0, hp / playerHp, ratio < 0.15) or
    -- using it in arithmetic taints our execution context.  Same rule
    -- as secret-string values: we can read, but we can't compare or
    -- use in math operations from addon code.  Guard hp before any
    -- numeric op.  Confirmed by /mnp labels triggering the error:
    -- "attempt to compare local 'hp' (a secret number value)".
    local hp       = UnitHealthMax(unit)     or 0
    local playerHp = UnitHealthMax("player") or 0
    local hpSafe       = hp       and not (issecretvalue and issecretvalue(hp))
    local playerHpSafe = playerHp and not (issecretvalue and issecretvalue(playerHp))
    if hpSafe and playerHpSafe and playerHp > 0 and hp > 0 then
        local ratio = hp / playerHp
        if ratio < 0.15 then return "minor"  end   -- tiny imps
        if ratio < 0.55 then return "minion" end   -- Wild Imp, Dreadstalker, Vilefiend
        if guidKind == "Pet" then return "pet" end -- Hunter pet, Warlock primary, Water Ele
        if ratio < 1.4 then return "pet"     end   -- non-Pet GUID but moderate HP
        return "guardian"                          -- Earth Ele, Infernal, Demonic Tyrant
    end

    if guidKind == "Pet" then return "pet" end

    -- NOTHING readable.  In retail Midnight 12.x BG/arena every
    -- identity field on enemy summon plates (CreatureType, GUID,
    -- HP, name) is secret-tagged until the player interacts.  We
    -- USED to default to "minion" here, which then catID-routed
    -- the plate into `enemyMinions` — and if the user had that
    -- category's alpha slider at 0 (a common "hide minion clutter"
    -- setting) the totem's UnitFrame was forced to alpha=0 and
    -- the health bar vanished.  The fix is to return nil instead:
    -- the caller (ClassifyPlate) then falls through to the
    -- generic `enemyPlayers` bucket, ApplyOverrides bails on the
    -- "no cat" path, and Blizzard's default render runs untouched.
    -- When the user mouseovers / targets the unit, the non-secret
    -- "target"/"mouseover" token lets us classify correctly and
    -- _CaptureSummonFromToken re-runs Manage with the real type.
    return nil
end

----------------------------------------------------------------------
-- DB lookup with curated data fallback
----------------------------------------------------------------------
local function GetNpcRecord(npcID)
    if not npcID then return nil end
    local db = MyNamePlatesDB and MyNamePlatesDB.npcs
    if db and db[npcID] then return db[npcID] end
    local seed = ns.NPC_DATA[npcID]
    if seed then return seed end
    return nil
end

local function RememberNpc(unit, npcID, summonType)
    if not (MyNamePlatesDB and MyNamePlatesDB.npcs) then return end
    local existing = MyNamePlatesDB.npcs[npcID]
    if existing and not existing.placeholder then return end
    MyNamePlatesDB.npcs[npcID] = {
        name       = _SafeName(unit) or (existing and existing.name) or ("NPC " .. npcID),
        type       = summonType,
        discovered = true,
    }
end

----------------------------------------------------------------------
-- Highlight border  (4-texture frame around the healthbar).  Lazily
-- attached to a plate's UnitFrame the first time it's needed.
----------------------------------------------------------------------
local HIGHLIGHT_THICKNESS = 2

local function EnsureHighlight(plate)
    if plate.MyNP_Highlight then return plate.MyNP_Highlight end
    local uf = plate.UnitFrame
    if not (uf and uf.healthBar) then return nil end
    -- Skip forbidden frames — CreateFrame as child of forbidden uf
    -- propagates addon taint up the secure chain.  Highlights just
    -- won't render on forbidden arena enemy plates; the per-NPC
    -- highlight feature is meant for summons (totems, pets) which
    -- are never forbidden anyway.
    if (plate.IsForbidden and plate:IsForbidden())
       or (uf.IsForbidden and uf:IsForbidden()) then return nil end

    local f = CreateFrame("Frame", nil, uf)
    f:SetAllPoints(uf.healthBar)
    f:SetFrameLevel(uf.healthBar:GetFrameLevel() + 5)

    local function strip(p1, x1, y1, p2, x2, y2, w, h)
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetPoint(p1, x1, y1)
        t:SetPoint(p2, x2, y2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        return t
    end

    local s = HIGHLIGHT_THICKNESS
    f.top    = strip("TOPLEFT",     -s,  s, "TOPRIGHT",     s,  s, nil, s)
    f.bottom = strip("BOTTOMLEFT",  -s, -s, "BOTTOMRIGHT",  s, -s, nil, s)
    f.left   = strip("TOPLEFT",     -s,  s, "BOTTOMLEFT",  -s, -s, s,   nil)
    f.right  = strip("TOPRIGHT",     s,  s, "BOTTOMRIGHT",  s, -s, s,   nil)

    plate.MyNP_Highlight = f
    return f
end

local function ApplyHighlight(plate, color)
    local h = EnsureHighlight(plate)
    if not h then return end
    local r = color[1] or 1
    local g = color[2] or 0
    local b = color[3] or 0
    local a = color[4] or 1
    h.top:SetVertexColor(r, g, b, a)
    h.bottom:SetVertexColor(r, g, b, a)
    h.left:SetVertexColor(r, g, b, a)
    h.right:SetVertexColor(r, g, b, a)
    h:Show()
end

local function HideHighlight(plate)
    if plate.MyNP_Highlight then plate.MyNP_Highlight:Hide() end
end

----------------------------------------------------------------------
-- Override application  (called every ~100ms while plate is alive)
-- The engine resets nameplate alpha & scale every frame, so we have to
-- reassert ours continuously.  We touch BOTH the outer NamePlateBase and
-- its UnitFrame because Blizzard writes to UnitFrame for selection alpha.
----------------------------------------------------------------------
local function ApplyOverrides(info)
    local plate = info.plate
    if not (plate and plate:IsShown()) then return end
    if plate.IsForbidden and plate:IsForbidden() then return end
    -- Recursion guard: ApplyOverrides itself calls SetAlpha/SetScale, which
    -- triggers our SetAlpha/SetScale hooks (set up in HookUnitFrame below).
    -- Without this flag the hooks would re-enter ApplyOverrides forever.
    if info._applying then return end
    info._applying = true

    -- Forbidden-frame bail.  Retail Midnight (TWW+) arena enemy plates have
    -- a forbidden UnitFrame that addons must not touch — every SetAlpha /
    -- SetScale / SetStatusBarColor we'd call on it (or its healthBar)
    -- propagates taint up the secure chain and produces the cumulative
    -- "Interface action failed because of an AddOn" error stack on every
    -- subsequent secure action against arena enemies.  In a 3v3 this can
    -- run into the dozens per match.  Check BOTH plate and UnitFrame
    -- because the forbidden flag can land on either depending on patch.
    local plate = info.plate
    local uf    = plate and plate.UnitFrame
    if (plate and plate.IsForbidden and plate:IsForbidden())
       or (uf and uf.IsForbidden and uf:IsForbidden()) then
        info._applying = nil
        return
    end

    local cat = MyNamePlatesDB and MyNamePlatesDB.categories
                  and MyNamePlatesDB.categories[info.categoryID]
    if not cat then info._applying = nil; return end

    local def    = ns.CATEGORY_BY_ID[info.categoryID]
    local alpha  = tonumber(cat.alpha) or 1.0
    local scale  = tonumber(cat.scale) or 1.0
    local hidden = cat.hidden and cat.hidden[info.npcID] == true

    -- 1.32.12: Master toggle off = hide the plate, for ALL categories
    -- (not just CVar-less ones).
    --
    -- Why we used to gate on `not def.cvar`: CVar-based categories
    -- (enemyGuardians, enemyMinions, enemyTotems, etc.) relied on
    -- Blizzard's nameplate engine to suppress spawn via the CVar, so
    -- we didn't need to enforce a per-plate hide here.
    --
    -- Why that broke in 1.32.4: when target/mouseover capture
    -- (_CaptureSummonFromToken) reclassifies a plate post-spawn from
    -- "enemyPlayers" (the anonymised-fallback catch-all) into its
    -- real summon category like "enemyGuardians", the plate is
    -- ALREADY VISIBLE.  The CVar only prevents future spawns; it
    -- doesn't despawn or hide an existing plate.  Without an
    -- alpha-0 enforcement, the user toggling "Enemy Guardians" off
    -- has no effect on an anonymised gargoyle whose true type we
    -- only learned after the user looked at it.
    --
    -- The fix: any plate whose category is currently disabled gets
    -- alpha-0'd here, regardless of whether the category has a CVar.
    -- For CVar categories this is belt-and-suspenders (CVar prevents
    -- spawn; we hide the rare leak); for CVar-less categories this
    -- is unchanged behaviour (the only enforcement mechanism).
    --
    -- Side effects considered:
    --   * Friendly* categories with default enabled="0": Blizzard's
    --     CVar already suppresses spawn, but if a plate somehow
    --     reaches ApplyOverrides we now hide it.  Same intent as
    --     the user's toggle.
    --   * Enemy* categories with default enabled="1": user almost
    --     never disables these; if they do, hiding is correct.
    if cat.enabled ~= "1" then
        hidden = true
    end

    -- Per-NPC hide: we only set alpha to 0.  We deliberately do NOT call
    -- plate.UnitFrame:Hide() / EnableMouse(false) — UnitFrame is a
    -- protected frame in TWW/Midnight (11.0+), and addon-level calls to
    -- protected methods *taint* the frame.  Once tainted, secure
    -- operations like click-to-target stop working AND the taint persists
    -- through combat.  Setting alpha to 0 makes the plate invisible
    -- without touching protected APIs; the unit can still technically be
    -- moused over but won't be visually present.
    if hidden then
        plate:SetAlpha(0)
        if plate.UnitFrame then
            plate.UnitFrame:SetAlpha(0)
        end
        HideHighlight(plate)
        info._applying = nil
        return
    end

    -- Highlight always applies regardless of target state.
    if cat.highlighted and info.npcID and cat.highlighted[info.npcID] then
        ApplyHighlight(plate, cat.highlightColor or { 1, 0.1, 0.1, 1 })
    else
        HideHighlight(plate)
    end

    -- "Target is the exception."  For non-summon categories, hand the
    -- player's current target back to the engine for full visibility +
    -- selected scale.  Summon categories always honour the user's setting.
    local isSummonCat = def and def.summonType ~= nil
    local isTarget    = info.unit and UnitIsUnit(info.unit, "target")

    if isTarget and not isSummonCat then
        plate:SetAlpha(1.0)
        if plate.UnitFrame then
            plate.UnitFrame:SetAlpha(1.0)
            -- Leave UnitFrame:SetScale alone so engine's nameplateSelectedScale
            -- still applies on the targeted plate.
        end
        info._applying = nil
        return
    end

    -- Apply user's category overrides to every non-target plate (and to
    -- every summon plate, regardless of target state).
    plate:SetAlpha(alpha)
    if plate.UnitFrame and alpha < 1.0 then
        plate.UnitFrame:SetAlpha(alpha)
    end
    if plate.UnitFrame and (isSummonCat or scale ~= 1.0) then
        plate.UnitFrame:SetScale(scale)
    end

    -- Cosmetic indicators (target arrow, healer cross) — live in
    -- Indicators.lua; safe to call even on plates we don't manage.
    if ns.UpdateIndicators and info.unit then
        pcall(ns.UpdateIndicators, ns, plate, info.unit)
    end

    -- Friendly healthbar color override (set on every refresh because
    -- Blizzard's CompactUnitFrame_UpdateHealthColor resets this back).
    if info.unit and plate.UnitFrame and plate.UnitFrame.healthBar then
        local fc = MyNamePlatesDB.friendlyColor
        if fc and fc.enabled == "1"
           and UnitIsFriend("player", info.unit) then
            local isPlayer = UnitIsPlayer(info.unit)
            local apply = isPlayer and fc.applyToPlayers
                          or (not isPlayer and fc.applyToNPCs)
            if apply then
                pcall(plate.UnitFrame.healthBar.SetStatusBarColor,
                      plate.UnitFrame.healthBar, fc.r or 0, fc.g or 1, fc.b or 0, fc.a or 1)
            end
        end
    end

    info._applying = nil
end

----------------------------------------------------------------------
-- Per-plate SetAlpha + SetScale hooks.
-- We hook only the unprotected methods (SetAlpha, SetScale) — never the
-- protected ones (Show/Hide/EnableMouse) which would taint the plate
-- and break click-targeting in TWW+.  These hooks fire AFTER any other
-- code (BBP, ElvUI, Plater, the engine itself) writes alpha/scale to a
-- plate, so our category overrides always have the last word.
----------------------------------------------------------------------
local function HookUnitFrame(plate)
    local uf = plate.UnitFrame
    if not uf or uf.MyNP_hooked then return end
    -- Never install hooks on a forbidden frame — hooksecurefunc itself
    -- on a forbidden frame can taint, and even if it didn't, the
    -- callback would run ApplyOverrides which then touches the
    -- forbidden uf.  Check BOTH plate and uf for the forbidden flag.
    if (plate and plate.IsForbidden and plate:IsForbidden())
       or (uf.IsForbidden and uf:IsForbidden()) then return end
    uf.MyNP_hooked = true

    local function reassert(self)
        -- pcall catches ERRORS but does NOT prevent TAINT propagation.
        -- We MUST issecretvalue-guard `unit` before indexing active[unit]
        -- — this hook fires every time SetAlpha/SetScale is called on
        -- the UnitFrame, which on BG enemy plates with secret unit tokens
        -- is many times per second.  Without the guard, every one of
        -- those table-indexes taints our execution context and produces
        -- the hard "MyNamePlates has been blocked from an action only
        -- available to the Blizzard UI" Blizzard popup.
        pcall(function()
            local unit = self.unit or self.displayedUnit
            if not unit then return end
            if issecretvalue and issecretvalue(unit) then return end
            local info = active[unit]
            if not info or info._applying then return end
            ApplyOverrides(info)
        end)
    end

    pcall(hooksecurefunc, uf, "SetAlpha", reassert)
    pcall(hooksecurefunc, uf, "SetScale", reassert)

    -- Hook the healthbar's SetStatusBarColor so our friendly-color
    -- override beats Blizzard's CompactUnitFrame_UpdateHealthColor
    -- (which fires on UNIT_HEALTH and resets to class color).  Without
    -- this hook the per-frame ApplyOverrides ticker eventually catches
    -- up, but you see a brief class-color flash between frames.  The
    -- "already our color" check prevents the hook from re-entering
    -- itself when WE call SetStatusBarColor.
    local hb = uf.healthBar
    if hb and not hb.MyNP_colorHooked then
        hb.MyNP_colorHooked = true
        pcall(hooksecurefunc, hb, "SetStatusBarColor",
            function(self, r, g, b)
                pcall(function()
                    local fc = MyNamePlatesDB and MyNamePlatesDB.friendlyColor
                    if not (fc and fc.enabled == "1") then return end
                    local u = uf.unit or uf.displayedUnit
                    if not u then return end
                    -- Secret-string guard for the unit token — without
                    -- this, UnitIsFriend("player", secret_unit) taints
                    -- our execution context.  This hook fires on every
                    -- health color update (multiple times per second
                    -- on BG enemy plates) so the taint would cascade
                    -- to the Blizzard hard-block popup.
                    if issecretvalue and issecretvalue(u) then return end
                    if not UnitIsFriend("player", u) then return end
                    local isPlayer = UnitIsPlayer(u)
                    local apply = (isPlayer and fc.applyToPlayers)
                               or ((not isPlayer) and fc.applyToNPCs)
                    if not apply then return end
                    local fr, fg, fb = fc.r or 0, fc.g or 1, fc.b or 0
                    if r and g and b
                       and math.abs(r - fr) < 0.01
                       and math.abs(g - fg) < 0.01
                       and math.abs(b - fb) < 0.01 then
                        return    -- already our color, don't loop
                    end
                    self:SetStatusBarColor(fr, fg, fb, fc.a or 1)
                end)
            end)
    end
end

local function ResetPlate(plate)
    if not plate then return end
    -- 1.32.7: Top-level NamePlate frame's SetScale is PROTECTED in
    -- retail Midnight 12.x.  Calling it from addon code (which
    -- ResetPlate did on every NAME_PLATE_UNIT_REMOVED via OnUnitRemoved
    -- → Unmanage → ResetPlate) produces ADDON_ACTION_BLOCKED:
    --   "AddOn 'MyNamePlates' tried to call the protected function
    --    'NamePlateN:SetScale()'"
    -- which BugSack/BugGrabber harvests as an error.  The TWW-era
    -- comment that "SetScale is unprotected" is no longer true.
    --
    -- Removing the call is safe:
    --   * ApplyOverrides only ever calls uf:SetScale(...), not
    --     plate:SetScale(...) — so we never elevated the top-level
    --     plate's scale above 1.0 to begin with.
    --   * NAME_PLATE_UNIT_REMOVED means Blizzard is recycling the
    --     plate; the engine resets per-plate state on next use.
    --   * For RescanAllPlates/OnUnitAdded fallthrough, ApplyOverrides
    --     on the new classification owns the visual state.
    --
    -- SetAlpha on the top-level plate is still permitted (no
    -- ADDON_ACTION_BLOCKED observed for it) — keep that to clear
    -- any prior alpha=0 we wrote for a hidden category.
    plate:SetAlpha(1.0)
    -- Skip the UnitFrame writes if forbidden — same taint vector as
    -- ApplyOverrides above.  UnitFrame's SetScale is NOT protected
    -- (different frame type, different inherited protection rules),
    -- so the uf branch stays as-is.
    local uf = plate.UnitFrame
    if uf
       and not (plate.IsForbidden and plate:IsForbidden())
       and not (uf.IsForbidden and uf:IsForbidden()) then
        uf:SetAlpha(1.0)
        uf:SetScale(1.0)
    end
    HideHighlight(plate)
end

----------------------------------------------------------------------
-- Live nameplate registry  (every visible plate, keyed by unitToken).
----------------------------------------------------------------------
local active = {}    -- [unit] = { plate, categoryID, npcID, summonType }

local function Manage(unit, plate, summonType, npcID, categoryID)
    active[unit] = {
        unit       = unit,
        plate      = plate,
        categoryID = categoryID,
        npcID      = npcID,
        summonType = summonType,
    }
    ApplyOverrides(active[unit])
end

local function Unmanage(unit)
    local info = active[unit]
    if not info then return end
    ResetPlate(info.plate)
    active[unit] = nil
end

----------------------------------------------------------------------
-- Public accessors  (used by Labels.lua to pick the right text config
-- for summon plates vs player/NPC plates).  active[] is keyed by unit
-- token, but Labels iterates by plate, so we offer both lookups.
----------------------------------------------------------------------
function ns:GetSummonInfoForUnit(unit)
    if not unit then return nil end
    -- Secret-string guard before indexing the active table — even
    -- though most callers already filter, defense in depth here
    -- prevents future callers from accidentally tainting via an
    -- active[secret_unit] lookup.
    if issecretvalue and issecretvalue(unit) then return nil end
    return active[unit]
end

----------------------------------------------------------------------
-- Per-plate summon-type cache (target/mouseover capture).
--
-- Mirrors Labels.lua's _specByPlate strategy but for SUMMON
-- classification.  In retail Midnight 12.x BGs / arenas, every
-- field that could identify an enemy plate as a summon
-- (UnitCreatureType, UnitGUID, UnitName, uf.name:GetText()) is
-- secret-tagged on non-targeted plates.  IsSummonPlate's regular
-- classification paths can't work because Lua compares / table
-- indexes against secret strings taint our execution.
--
-- BUT: when the user TARGETS or MOUSEOVERS a totem, the "target"
-- / "mouseover" unit tokens themselves are non-secret, and
-- UnitCreatureType / UnitName on those tokens return real values
-- ("Totem", "Earthbind Totem", etc.).  At that moment we classify
-- the plate and cache the summon type by PLATE FRAME REFERENCE
-- (Lua table identity, never secret, stable per assignment).
--
-- Cache is cleared on NAME_PLATE_UNIT_REMOVED so a recycled plate
-- frame doesn't inherit the previous unit's classification.
-- Cache entry shape: { type = "totem", isFriend = false, name = "Earthbind Totem" }
-- All three fields captured at the moment the user targeted/mouseovered
-- the unit, from non-secret tokens.  Keyed by plate frame reference.
local _summonByPlate = {}

function ns:GetSummonTypeByPlate(plate)
    local v = plate and _summonByPlate[plate]
    return v and v.type or nil
end

function ns:GetSummonFriendByPlate(plate)
    local v = plate and _summonByPlate[plate]
    if not v then return nil end
    return v.isFriend
end

function ns:GetSummonNameByPlate(plate)
    local v = plate and _summonByPlate[plate]
    return v and v.name or nil
end

function ns:ClearSummonTypeByPlate(plate)
    if plate then _summonByPlate[plate] = nil end
end

-- Capture summon classification from a non-secret token ("target" /
-- "mouseover"), find that unit's plate, and cache the summon type
-- on the plate.  Called from PLAYER_TARGET_CHANGED /
-- UPDATE_MOUSEOVER_UNIT — both deliver Blizzard's real (non-secret)
-- data for the inspected unit.
local function _CaptureSummonFromToken(token)
    if not token then return end
    if not UnitExists(token) then return end
    -- Skip players — they're never summons.  Cheap early-out.
    if UnitIsPlayer(token) then return end
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
    local plate = C_NamePlate.GetNamePlateForUnit(token, true)
    if not plate then return end

    -- Classify via the real (non-secret) APIs on the token.
    -- IsPlayerSummon / AutoClassify already do the work — they'll
    -- read UnitCreatureType / UnitClassification / GUID etc., and
    -- because the token is "target"/"mouseover" those return clean
    -- non-secret values.
    --
    -- 1.32.13: also extract npcID alongside guidKind.  Without
    -- this, the in-place reclassification below couldn't propagate
    -- npcID to active[unit].npcID, which broke the per-NPC hide
    -- list (cat.hidden[npcID]) for anonymised plates — once we
    -- reclassified them into enemyDKPets / enemyGuardians / etc.,
    -- the npcID stayed nil from the initial enemyPlayers fallback
    -- and `cat.hidden[nil]` always returned nil.
    local guid = UnitGUID(token)
    local guidKind
    local capturedNpcID
    if guid and not (issecretvalue and issecretvalue(guid)) then
        local k, _, _, _, _, npcid = strsplit("-", guid)
        if k and not (issecretvalue and issecretvalue(k)) then
            guidKind = k
            if (k == "Creature" or k == "Pet" or k == "Vehicle") and npcid then
                capturedNpcID = tonumber(npcid)
            end
        end
    end
    if not IsPlayerSummon(token, guidKind, plate) then return end

    local stype = AutoClassify(token, guidKind, plate)
    -- AutoClassify can return "pet" — normalise to pet_hunter (same
    -- mapping ClassifyPlate uses) so the per-type filter on the
    -- Pet & Totem Name block works correctly.
    if stype == "pet" then stype = "pet_hunter" end
    if not stype then return end

    -- Capture friend/enemy + display name from the non-secret
    -- target/mouseover token.  These get cached on the plate
    -- frame because the plate's own unit token has all of them
    -- secret-tagged in 12.x BG — without the cache, _SummonNameAllowed
    -- can't decide applyFriendly/applyEnemy, and _ApplySummonName
    -- can't read a display name to put on the overlay.
    local isFriend = false
    do
        local ok, f = pcall(UnitIsFriend, "player", token)
        if ok then isFriend = f and true or false end
    end
    local name = _SafeName(token)

    -- Sanity: don't pollute the cache with secret-tagged values.
    if name and issecretvalue and issecretvalue(name) then name = nil end
    if issecretvalue and issecretvalue(stype) then return end

    _summonByPlate[plate] = {
        type     = stype,
        isFriend = isFriend,
        name     = name,
        npcID    = capturedNpcID,
    }

    -- Re-classify the plate in the active[] table.
    --
    -- 1.32.5 SAFETY NOTE: we used to call Manage() here which in
    -- turn ran ApplyOverrides — but ApplyOverrides reads
    -- plate.UnitFrame.unit / writes SetAlpha+SetScale on the
    -- plate.  For FORBIDDEN arena enemy plates (handed to us
    -- because C_NamePlate.GetNamePlateForUnit(token, true) ignores
    -- secure mode), property reads on the forbidden UnitFrame can
    -- propagate taint into the secure click-to-target action that
    -- fires on the SAME PLAYER_TARGET_CHANGED event.  Caused 30+
    -- "Interface action failed" cascades per arena match.
    --
    -- The fix is to skip forbidden plates entirely AND to only
    -- update active[]'s in-place data fields (categoryID +
    -- summonType) without re-running ApplyOverrides.  Our existing
    -- SetAlpha/SetScale reassert hook (HookUnitFrame:reassert)
    -- will pick up the new categoryID on the next Blizzard alpha
    -- write — and Blizzard writes alpha on target change, threat
    -- change, and aura events constantly, so the visual update
    -- still snaps in ~immediately after the user interacts.
    if plate.IsForbidden and plate:IsForbidden() then return end
    local pUF = plate.UnitFrame
    if not pUF then return end
    if pUF.IsForbidden and pUF:IsForbidden() then return end

    local hostile = not isFriend
    local newCatID = ns.CategoryForSummon and ns:CategoryForSummon(stype, hostile)
    if newCatID then
        local pUnit = pUF.unit or pUF.displayedUnit
        if pUnit and not (issecretvalue and issecretvalue(pUnit)) then
            local info = active[pUnit]
            if info then
                -- In-place mutation only — no Manage(), no
                -- ApplyOverrides().  Cheap, no protected-frame
                -- writes, no secure-action taint.
                info.categoryID = newCatID
                info.summonType = stype
                -- 1.32.13: propagate npcID too so per-NPC hide
                -- (cat.hidden[npcID]) works after reclassification.
                -- Only overwrite if we extracted a real one from the
                -- non-secret target/mouseover GUID — don't blow
                -- away a previously-known npcID with nil.
                if capturedNpcID then info.npcID = capturedNpcID end
            end
        end
    end

    -- Kick the label pipeline so the overlay lands immediately.
    if ns.RefreshAllLabels then pcall(ns.RefreshAllLabels, ns) end
end

local _summonCapture = CreateFrame("Frame")
_summonCapture:RegisterEvent("PLAYER_TARGET_CHANGED")
_summonCapture:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
_summonCapture:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_TARGET_CHANGED" then
        _CaptureSummonFromToken("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        _CaptureSummonFromToken("mouseover")
    end
end)

function ns:IsSummonPlate(plate, unit)
    if not plate or not unit then return false end
    -- HIGHEST PRIORITY: per-plate cache populated by target/mouseover
    -- capture.  In retail Midnight 12.x BGs, every per-plate-unit
    -- identifier is secret-tagged for enemy summons — so the
    -- traditional classification paths below all fail and the
    -- overlay never fires.  The user has to target or mouseover the
    -- totem (or pet/guardian) once to populate this cache; after
    -- that, the plate stays classified for its lifetime.
    if _summonByPlate[plate] then return true end

    -- Bail BEFORE any string compare or table lookup if the unit token
    -- is itself a "secret string value".  Retail Midnight 12.x marks
    -- forbidden arena nameplate unit tokens as secret strings; using
    -- one as a table key (active[unit]) or in any == comparison
    -- (UnitCreatureType(unit) == "Totem") triggers
    -- "attempt to compare a secret string value (execution tainted)".
    -- Plates can be RECYCLED by Blizzard between unit assignments, so
    -- a plate that previously held a non-forbidden unit (and got our
    -- widgets attached) can later be re-bound to a forbidden token —
    -- this is why we have to guard at the unit-token level here, not
    -- just at the plate/uf-forbidden level upstream.
    if issecretvalue and issecretvalue(unit) then return false end

    -- Fast path: active[] holds an entry for EVERY classified plate,
    -- including enemy players and regular NPCs (Manage() is called
    -- for any non-nil categoryID so the per-category scale / alpha
    -- sliders for "Enemy Players & NPCs", "Friendly NPCs", etc. all
    -- work).  We only want plates whose category is a *summon* type
    -- (pet_*, totem, guardian, minion, minor, psyfiend) — those have
    -- a non-nil summonType set by ClassifyPlate.  Without this check,
    -- enemy player plates would get the Pet & Totem Name config too.
    local rec = active[unit]
    if rec and rec.summonType then return true end

    -- Narrow fallbacks for the brief race window before classification
    -- (and for plates we never classified, like friendly totems with
    -- their master toggle off).  Only conditions that are PRECISE go
    -- here — anything broader (e.g. UnitPlayerControlled) would
    -- misclassify enemy players, especially forbidden arena tokens
    -- where UnitIsPlayer() returns false but UnitPlayerControlled()
    -- returns true, causing Pet & Totem Name to bleed onto enemy
    -- player plates.
    --
    -- UnitCreatureType return value can also be a secret string for
    -- forbidden units, hence the issecretvalue guard around the
    -- comparison; same for the GUID kind.
    if UnitCreatureType then
        local ct = UnitCreatureType(unit)
        if ct and not (issecretvalue and issecretvalue(ct))
                and ct == "Totem" then
            return true
        end
    end
    -- NPC-ID fallback for secret UnitCreatureType.  Retail Midnight 12.x
    -- BGs return secret CTs for enemy totems / guardians, so the only
    -- way to recognise them as summons is to match GUID-extracted npcID
    -- against our NPC_DATA / saved-discovered table.  Without this, the
    -- overlay never renders on enemy totems in BGs — they get misrouted
    -- through the regular-NPC path of ClassifyPlate.
    -- Pass `plate` through so _NpcDataType's name fallback can use
    -- uf.name:GetText() when UnitName(unit) is anonymised — exactly
    -- the case for enemy totem plates in 12.x BGs.  Earlier version
    -- called _NpcDataType(unit) without plate, so the fallback chain
    -- dead-ended at the secret UnitName and totems never classified
    -- as summons → no overlay rendered.
    if _NpcDataType and _NpcDataType(unit, plate) then return true end
    local guid = UnitGUID and UnitGUID(unit)
    if guid and not (issecretvalue and issecretvalue(guid)) then
        local kind = strsplit("-", guid)
        if kind and not (issecretvalue and issecretvalue(kind))
               and kind == "Pet" then
            return true
        end
    end
    return false
end

----------------------------------------------------------------------
-- Plate -> Category classifier  (handles ALL nameplate units, not just
-- player summons, so the per-category opacity / scale sliders work for
-- every tab including "Enemy Players & NPCs" and "Friendly NPCs").
----------------------------------------------------------------------
local function ClassifyPlate(unit, guidKind, plate)
    local hostile = not UnitIsFriend("player", unit)

    if UnitIsPlayer(unit) then
        return hostile and "enemyPlayers" or "friendlyPlayers"
    end

    if IsPlayerSummon(unit, guidKind, plate) then
        local npcID = GetNPCID(unit)
        local rec = GetNpcRecord(npcID)
        local summonType, catID

        if rec then
            summonType = rec.type
            catID = summonType and ns:CategoryForSummon(summonType, hostile)
        end

        if not catID then
            local autoType = AutoClassify(unit, guidKind, plate)
            summonType = (autoType == "pet") and "pet_hunter" or autoType
            catID = summonType and ns:CategoryForSummon(summonType, hostile)
            if MyNamePlatesDB and MyNamePlatesDB.npcs and npcID and summonType then
                MyNamePlatesDB.npcs[npcID] = {
                    name       = (rec and rec.name)
                              or (ns.GetPlateName and ns:GetPlateName(unit, plate))
                              or ("NPC " .. npcID),
                    type       = summonType,
                    discovered = true,
                }
            end
        end

        if catID then return catID, summonType end
    end

    return hostile and "enemyPlayers" or "friendlyNPCs"
end

----------------------------------------------------------------------
-- Public API used by the UI
----------------------------------------------------------------------
function ns:AddUnitFromTarget()
    local unit
    if UnitExists("target") then
        unit = "target"
    elseif UnitExists("mouseover") then
        unit = "mouseover"
    else
        return nil, "No target or mouseover."
    end

    local npcID, guidKind = GetNPCID(unit)
    if not npcID then return nil, "Couldn't read NPC ID (player target?)." end

    local hostile = not UnitIsFriend("player", unit)
    local seed = ns.NPC_DATA[npcID]
    local summonType = (seed and seed.type) or AutoClassify(unit, guidKind)
    if not summonType then return nil, "Couldn't classify the unit." end

    local categoryID = ns:CategoryForSummon(summonType, hostile)
    if not categoryID then return nil, "No matching category." end

    RememberNpc(unit, npcID, summonType)
    return npcID, _SafeName(unit), categoryID
end

function ns:IterateNpcsForCategory(categoryID)
    local cat = ns.CATEGORY_BY_ID[categoryID]
    if not (cat and cat.summonType) then
        return function() end
    end
    local merged = {}
    for id, rec in pairs(ns.NPC_DATA) do merged[id] = rec end
    if MyNamePlatesDB and MyNamePlatesDB.npcs then
        for id, rec in pairs(MyNamePlatesDB.npcs) do merged[id] = rec end
    end
    local keys = {}
    for id, rec in pairs(merged) do
        if rec.type == cat.summonType then
            keys[#keys + 1] = id
        end
    end
    table.sort(keys, function(a, b)
        return (merged[a].name or "") < (merged[b].name or "")
    end)
    local i = 0
    return function()
        i = i + 1
        if keys[i] then return keys[i], merged[keys[i]] end
    end
end

-- Re-evaluate every active plate (called by Core after a setting change).
function ns:RefreshActiveNameplates()
    for _, info in pairs(active) do
        ApplyOverrides(info)
    end
end

-- Diagnostics
function ns:GetActiveCount()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

-- Returns the per-unit classification record (categoryID, npcID,
-- summonType, plate ref) populated by ClassifyPlate / OnUnitAdded.
-- Used by /mnp labels to surface "why is this plate alpha=0?".
-- Guards against secret unit tokens — indexing `active[secret]`
-- taints execution context.
function ns:GetPlateInfo(unit)
    if not unit then return nil end
    if issecretvalue and issecretvalue(unit) then return nil end
    return active[unit]
end

function ns:DumpActive()
    local lines = {}
    for unit, info in pairs(active) do
        local cat = ns.CATEGORY_BY_ID[info.categoryID]
        lines[#lines + 1] = string.format("    %s -> %s (npc %s)",
            unit, cat and cat.label or info.categoryID, tostring(info.npcID))
    end
    if #lines == 0 then
        print("  (no managed plates)")
    else
        for _, line in ipairs(lines) do print(line) end
    end
end

----------------------------------------------------------------------
-- Trace mode  ( /mnp trace )
-- When enabled, every alpha/scale write on a managed plate is logged
-- with the calling addon, so you can see exactly who is fighting us.
-- Throttled to 1 message per plate per 0.4s to avoid chat spam.
----------------------------------------------------------------------
local tracing = false
local traceLast = {}

local function _AddonFromStack(stack)
    if not stack then return "?" end
    for line in stack:gmatch("[^\n\r]+") do
        local a = line:match("[Aa]ddOns[/\\]([^/\\:]+)") or
                  line:match("Interface[/\\]AddOns[/\\]([^/\\:]+)")
        if a and a ~= "MyNamePlates" then
            return a
        end
    end
    -- Probably engine code or Blizzard UI
    if stack:find("FrameXML") or stack:find("Blizzard_") then return "Blizzard" end
    return "engine"
end

local function _TraceWrite(self, kind, value)
    if not tracing then return end
    local now = GetTime()
    local key = tostring(self) .. ":" .. kind
    if traceLast[key] and now - traceLast[key] < 0.4 then return end
    traceLast[key] = now

    local p = self:GetParent()
    local uf = p and p.UnitFrame
    local unit = (uf and (uf.unit or uf.displayedUnit)) or "?"
    local addon = _AddonFromStack(debugstack(3, 8, 0))
    print(string.format("|cff00c0ff[trace]|r %s -> %s(%s) by |cffffd200%s|r",
        unit, kind, tostring(value or "?"):sub(1, 6), addon))
end

local function _InstallTraceHooks(plate)
    local uf = plate.UnitFrame
    if not uf or uf.MyNP_traceHooked then return end
    -- Match the same forbidden bail used in HookUnitFrame above —
    -- trace hooks would otherwise taint forbidden arena enemy plates
    -- the moment tracing is turned on.
    if (plate.IsForbidden and plate:IsForbidden())
       or (uf.IsForbidden and uf:IsForbidden()) then return end
    uf.MyNP_traceHooked = true
    hooksecurefunc(uf, "SetAlpha", function(self, a) _TraceWrite(self, "SetAlpha", a) end)
    hooksecurefunc(uf, "SetScale", function(self, s) _TraceWrite(self, "SetScale", s) end)
end

function ns:StartTrace()
    tracing = true
    wipe(traceLast)
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates(issecure())) do
            _InstallTraceHooks(plate)
        end
    end
    -- Also hook plates added during tracing
    if not ns._traceAddHook then
        ns._traceAddHook = CreateFrame("Frame")
        ns._traceAddHook:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        ns._traceAddHook:SetScript("OnEvent", function(_, _, unit)
            if not tracing then return end
            local plate = C_NamePlate.GetNamePlateForUnit(unit, issecure())
            if plate then _InstallTraceHooks(plate) end
        end)
    end
    print("|cff00c0ffMyNamePlates|r: trace ON. Every alpha/scale write to a")
    print("  managed plate will print with the calling addon. /mnp trace again to stop.")
end

function ns:StopTrace()
    tracing = false
    wipe(traceLast)
    print("|cff00c0ffMyNamePlates|r: trace OFF.")
end

function ns:IsTracing() return tracing end

----------------------------------------------------------------------
-- Deep diagnostic.  Iterates every visible plate and dumps every layer:
-- Blizzard's data (GUID, name, HP), ours (active entry, classification,
-- saved category settings), and the live frame state (plate alpha,
-- UnitFrame alpha/scale, healthBar alpha, hooks installed).
-- Use in arena while pets / minions / etc. are visibly misbehaving.
----------------------------------------------------------------------
-- Helper: print one plate's diagnostic block.  Wrapped in pcall so any
-- single bad plate (forbidden errors, missing UnitFrame field, etc.)
-- doesn't abort the whole report.
local function _DumpOnePlate(p, i, plate)
    local forbidden = (plate.IsForbidden and plate:IsForbidden()) and true or false
    -- Skip plate.namePlateUnitToken entirely — it's a secret string in
    -- retail Midnight 12.0.5 and reading it taints us.
    local uf = plate.UnitFrame
    local unit = uf and (uf.unit or uf.displayedUnit)
    if not unit then
        p(("[%d] no unit | forbidden=%s name=%s"):format(
            i, tostring(forbidden),
            tostring(plate.GetName and plate:GetName() or "?")))
        return
    end

    local guid = UnitGUID(unit)
    if guid and issecretvalue and issecretvalue(guid) then guid = nil end
    local name = _SafeName(unit) or "?"

    local npcID, guidKind
    if guid then
        local k, _, _, _, _, n = strsplit("-", guid)
        if k and not (issecretvalue and issecretvalue(k)) then
            guidKind = k
            if k == "Creature" or k == "Pet" or k == "Vehicle" then
                npcID = tonumber(n)
            end
        end
    end

    p(("[%d] %s %s | forbidden=%s npc=%s kind=%s"):format(
        i, unit, name, tostring(forbidden), tostring(npcID), tostring(guidKind)))

    local info = active[unit]
    if info then
        local def = ns.CATEGORY_BY_ID[info.categoryID]
        local cat = MyNamePlatesDB and MyNamePlatesDB.categories
                      and MyNamePlatesDB.categories[info.categoryID]
        p(("   MANAGED -> %s (summon=%s)"):format(
            def and def.label or tostring(info.categoryID),
            tostring(info.summonType)))
        if cat then
            local hiddenF = cat.hidden and cat.hidden[info.npcID] == true
            p(("   cat: alpha=%s scale=%s enabled=%s hidden=%s"):format(
                tostring(cat.alpha), tostring(cat.scale),
                tostring(cat.enabled), tostring(hiddenF)))
        end
    else
        p("   NOT MANAGED")
    end

    local pa = plate.GetAlpha and plate:GetAlpha() or -1
    local ps = plate.GetScale and plate:GetScale() or -1
    p(("   plate alpha=%.2f scale=%.2f"):format(pa, ps))

    if uf then
        local ua = uf.GetAlpha and uf:GetAlpha() or -1
        local us = uf.GetScale and uf:GetScale() or -1
        p(("   UnitFrame alpha=%.2f scale=%.2f hooks=%s"):format(
            ua, us, tostring(uf.MyNP_hooked or false)))
    end

    -- API surface check: what info is actually accessible for this
    -- plate's unit token?  This is the make-or-break for forbidden
    -- arena plates — if UnitClass/UnitRace return nil and AuraUtil
    -- returns 0 auras, our indicators / auras can't possibly work
    -- and we know to use the ArenaMap canonical token instead.
    local _, classFile = UnitClass(unit)
    local _, raceFile  = UnitRace(unit)
    local sex          = UnitSex(unit)
    local powerType    = UnitPowerType(unit)
    local isPlayer     = UnitIsPlayer(unit) and "y" or "n"
    local isFriend     = UnitIsFriend("player", unit) and "y" or "n"
    local guidSecret   = (issecretvalue and guid and issecretvalue(guid)) and "y" or "n"
    p(("   APIs: class=%s race=%s sex=%s power=%s player=%s friend=%s guidSecret=%s"):format(
        tostring(classFile), tostring(raceFile),
        tostring(sex), tostring(powerType),
        isPlayer, isFriend, guidSecret))

    -- Aura sanity: count of any auras visible on this token (helpful
    -- vs harmful).  If both return 0 in arena we know AuraUtil won't
    -- surface immunities/defensives for the per-plate token and we
    -- need to scan via the canonical arenaN.
    if AuraUtil and AuraUtil.ForEachAura then
        local hC, hH = 0, 0
        pcall(AuraUtil.ForEachAura, unit, "HELPFUL", nil, function() hH = hH + 1 end, true)
        pcall(AuraUtil.ForEachAura, unit, "HARMFUL", nil, function() hC = hC + 1 end, true)
        p(("   AuraScan: helpful=%d harmful=%d"):format(hH, hC))
    end

    -- Indicator presence on the plate (what's actually attached).
    p(("   markers: target=%s healer=%s class=%s aura=%s"):format(
        tostring(plate.MyNP_TargetMarker ~= nil),
        tostring(plate.MyNP_HealerMarker ~= nil),
        tostring(plate.MyNP_ClassMarker  ~= nil),
        tostring(plate.MyNP_AuraIcon     ~= nil)))

    -- ArenaMap binding for THIS plate (and what arena slot if any).
    if ns.ArenaMap then
        local mapped = ns.ArenaMap.plateToIndex
                       and ns.ArenaMap.plateToIndex[plate]
        p(("   arenaSlot=%s"):format(tostring(mapped)))
    end
end

function ns:DeepDiag()
    local function p(s) print(s) end
    p("===== MyNamePlates Deep Diagnostic =====")
    local ver = "?"
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        ver = C_AddOns.GetAddOnMetadata("MyNamePlates", "Version") or "?"
    elseif GetAddOnMetadata then
        ver = GetAddOnMetadata("MyNamePlates", "Version") or "?"
    end
    local _, instType = IsInInstance()
    p(("ver=%s | combat=%s | inst=%s | arena=%s"):format(
        ver,
        tostring(InCombatLockdown()),
        tostring(instType),
        tostring(ns.IsInArena and ns:IsInArena() or false)))

    local activeCount = 0
    for _ in pairs(active) do activeCount = activeCount + 1 end
    p(("active table: %d"):format(activeCount))

    -- ArenaMap state — shows whether plates have been bound to
    -- arena1..3 slots.  If this is empty in arena, the auto-bind
    -- system isn't activating (commonly because forbidden plates
    -- don't surface enough fingerprint data to match).
    if ns.ArenaMap then
        local AM = ns.ArenaMap
        local bound = 0
        for _ in pairs(AM.plateToIndex) do bound = bound + 1 end
        local cached = 0
        for _ in pairs(AM.arenaCache) do cached = cached + 1 end
        p(("ArenaMap: %d cached, %d plates bound"):format(cached, bound))
        for i = 1, 3 do
            local au = "arena" .. i
            local exists = UnitExists(au) and "y" or "n"
            local _, cf = UnitClass(au)
            local _, rf = UnitRace(au)
            local plateLookup = C_NamePlate and C_NamePlate.GetNamePlateForUnit
                and (C_NamePlate.GetNamePlateForUnit(au, true) ~= nil and "y" or "n")
                or "?"
            local c = AM.arenaCache[i] or {}
            p(("  arena%d: exists=%s UnitClass=%s UnitRace=%s plateLookup=%s | cache: class=%s race=%s spec=%s bound=%s"):format(
                i, exists, tostring(cf), tostring(rf), plateLookup,
                tostring(c.class), tostring(c.race), tostring(c.spec),
                tostring(AM.indexToPlate[i] ~= nil)))
        end
    end

    if not C_NamePlate or not C_NamePlate.GetNamePlates then
        p("C_NamePlate API missing"); return
    end

    local platesNF = C_NamePlate.GetNamePlates(false) or {}
    local platesAll = C_NamePlate.GetNamePlates(true) or {}
    p(("plates non-forbidden=%d, all=%d"):format(#platesNF, #platesAll))

    for i, plate in ipairs(platesAll) do
        local ok, err = pcall(_DumpOnePlate, p, i, plate)
        if not ok then
            local msg = tostring(err) or ""
            if msg:find("secret string") then
                p(("[%d] arena-enemy plate (Blizzard secret-tainted, can't manage)"):format(i))
            else
                p(("[%d] error: %s"):format(i, msg))
            end
        end
    end

    p("-- categories with non-default settings --")
    if MyNamePlatesDB and MyNamePlatesDB.categories then
        for id, cat in pairs(MyNamePlatesDB.categories) do
            local def = ns.CATEGORY_BY_ID[id]
            local a = tonumber(cat.alpha) or 1.0
            local s = tonumber(cat.scale) or 1.0
            local hiddenN = 0
            if cat.hidden then for _ in pairs(cat.hidden) do hiddenN = hiddenN + 1 end end
            if a < 1.0 or s ~= 1.0 or hiddenN > 0 or cat.enabled == "0" then
                p(("  %s: alpha=%.2f scale=%.2f enabled=%s hidden=%d"):format(
                    def and def.label or tostring(id), a, s, tostring(cat.enabled), hiddenN))
            end
        end
    end
    p("===== end =====")
end

----------------------------------------------------------------------
-- Event handler
----------------------------------------------------------------------
local function OnUnitAdded(unit)
    if not MyNamePlatesDB then return end
    -- Bail early on secret-string unit tokens — using one as a key in
    -- active[] (via Manage) or in any string compare downstream would
    -- taint our addon execution context, which then cascades to ALL
    -- subsequent operations including non-forbidden plates.
    if issecretvalue and issecretvalue(unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit, issecure())
    if not plate then return end
    -- Skip forbidden plates entirely.  Even "safe" reads/writes can
    -- taint the addon ("execution tainted by 'MyNamePlates'").  Check
    -- both the top-level plate AND its UnitFrame because the
    -- forbidden flag can land on either depending on the patch.
    local uf = plate.UnitFrame
    if (plate.IsForbidden and plate:IsForbidden())
       or (uf and uf.IsForbidden and uf:IsForbidden()) then return end

    HookUnitFrame(plate)

    local npcID, guidKind = GetNPCID(unit)
    local categoryID, summonType = ClassifyPlate(unit, guidKind, plate)
    if not categoryID then ResetPlate(plate); return end

    -- Auto-discover player summons
    if summonType and npcID and IsPlayerSummon(unit, guidKind, plate) then
        local rec = GetNpcRecord(npcID)
        if not rec or rec.placeholder then
            RememberNpc(unit, npcID, summonType)
        end
    end

    -- 1.32.11: BBP-PATTERN PRIMARY name population.
    --
    -- BBP's primary totem-name flow is:
    --     guid  = UnitGUID(unit)               -- npcID extractable
    --     npcID = BBP.GetNPCIDFromGUID(guid)
    --     npcData = BetterBlizzPlatesDB.totemIndicatorNpcList[npcID]
    --     frame.name:SetText(npcData.name)     -- override Blizzard's text
    --
    -- Our equivalent: we just resolved npcID + summonType + (via
    -- GetNpcRecord) the curated NPC_DATA entry with its `name` field.
    -- Mirror BBP by stashing that name on the plate's _summonByPlate
    -- cache here — Labels._RepositionName picks it up and SetTexts
    -- uf.name with it on every refresh + every CompactUnitFrame_UpdateName
    -- hook fire.  This is the PRIMARY path (works the moment a totem
    -- spawns, no user interaction required) — _CaptureSummonFromToken
    -- on PLAYER_TARGET_CHANGED / UPDATE_MOUSEOVER_UNIT remains as the
    -- FALLBACK for plates where UnitGUID is secret-tagged (retail
    -- Midnight 12.x arena anonymisation) so the npcID extract fails.
    --
    -- Conditions to populate:
    --   * summonType is set (this is a recognized summon, not a
    --     regular NPC or player)
    --   * we have an npcID (GUID was non-secret and parseable)
    --   * we have a curated/discovered NPC_DATA record with a name
    --
    -- We pull the friend flag from UnitIsFriend on the live unit
    -- token (non-secret if we got here past the issecretvalue gate),
    -- mirroring _CaptureSummonFromToken's payload exactly so
    -- _PickNameConfig's per-type filter + applyFriendly / applyEnemy
    -- gating works identically whether the name came from the
    -- primary path here or the fallback capture.
    if summonType and npcID then
        local rec = GetNpcRecord(npcID)
        local resolvedName = rec and rec.name
        if resolvedName
           and not (issecretvalue and issecretvalue(resolvedName))
           and resolvedName ~= ""
           and not (resolvedName == ("NPC " .. tostring(npcID)))  -- placeholder, skip
        then
            local isFriend = false
            local okF, f = pcall(UnitIsFriend, "player", unit)
            if okF then isFriend = f and true or false end
            _summonByPlate[plate] = {
                type     = summonType,
                isFriend = isFriend,
                name     = resolvedName,
            }
        end
    end

    Manage(unit, plate, summonType, npcID, categoryID)
end

local function OnUnitRemoved(unit)
    Unmanage(unit)
end

-- Wipe and re-classify every visible nameplate.  Called on PLAYER_ENTERING_WORLD
-- (zone change, arena/BG entry) so we re-grab any plates Blizzard rebuilt.
function ns:RescanAllPlates()
    for unit, info in pairs(active) do
        ResetPlate(info.plate)
        active[unit] = nil
    end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates(issecure())) do
        -- DO NOT read plate.namePlateUnitToken — secret string in retail
        -- Midnight 12.0.5 that taints us.  Use UnitFrame.unit instead.
        local uf = plate.UnitFrame
        if not ((plate.IsForbidden and plate:IsForbidden())
                or (uf and uf.IsForbidden and uf:IsForbidden())) then
            local unit = uf and (uf.unit or uf.displayedUnit)
            if unit then OnUnitAdded(unit) end
        end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
-- Arena combat causes Blizzard to update nameplate alpha aggressively on
-- threat changes, target changes, and unit auras.  We re-apply on those
-- events so our pet/summon overrides win every transition.
f:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("PLAYER_FOCUS_CHANGED")
f:RegisterEvent("UNIT_FACTION")
-- BBP fires its NameplateTargetAlpha logic on these arena-specific events
-- via its own handlers; we re-apply on the same events so our values win.
f:RegisterEvent("ARENA_OPPONENT_UPDATE")
f:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("UNIT_AURA")
-- BG / rated PvP scoreboard updates.  We use C_PvP.GetScoreInfoByPlayerGuid
-- to resolve enemy specs in battlegrounds (the tooltip path can't see
-- spec lines on enemy plates in 12.x — UnitClass / UnitCreatureType / line
-- text all return secret-string values, see Labels.lua _GetSpecByScore).
-- The scoreboard data populates progressively as players join + engage,
-- so we refresh labels each time Blizzard fires a score update so newly-
-- available specs land on plates that were spec-less a moment ago.
f:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
f:RegisterEvent("PVP_MATCH_ACTIVE")
f:RegisterEvent("PVP_MATCH_STATE_CHANGED")
local function ReapplyAll()
    for _, info in pairs(active) do
        ApplyOverrides(info)
    end
end

f:SetScript("OnEvent", function(_, event, unit)
    pcall(function()
        -- Bail on secret-string unit tokens (forbidden arena anonymized
        -- tokens) BEFORE any active[unit] indexing or downstream work.
        -- Using a secret string as a table key triggers a string
        -- comparison ("attempt to compare a secret string value") that
        -- taints our entire addon execution context — once tainted,
        -- every subsequent operation on every plate cascades the error.
        if unit and issecretvalue and issecretvalue(unit) then return end
        -- BG scoreboard rebuild — done ONCE per event, then per-plate
        -- _GetSpecByScore lookups are O(1) against the cached map.
        -- Critical for performance: doing this inside RefreshAllLabels
        -- per-plate caused the Details-script-time-limit blowout.
        if (event == "UPDATE_BATTLEFIELD_SCORE"
            or event == "PVP_MATCH_ACTIVE"
            or event == "PVP_MATCH_STATE_CHANGED")
           and ns.RebuildPvPScoreMap
        then
            pcall(ns.RebuildPvPScoreMap, ns)
        end
        if event == "NAME_PLATE_UNIT_ADDED" then
            OnUnitAdded(unit)
            C_Timer.After(0.05, function()
                pcall(function()
                    if unit and issecretvalue and issecretvalue(unit) then return end
                    if active[unit] then ApplyOverrides(active[unit]) end
                    if ns.RefreshAllIndicators then ns:RefreshAllIndicators() end
                end)
            end)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            OnUnitRemoved(unit)
            -- Hide our cosmetic markers on the removed plate so they
            -- don't persist when the engine recycles the plate frame
            -- for a different unit (which is exactly when "wrong class
            -- on this plate" symptoms appear).  RefreshAllIndicators
            -- on the next event will re-stamp correct values; for the
            -- gap we just want a clean slate.
            pcall(function()
                local plate = C_NamePlate.GetNamePlateForUnit(unit, true)
                if not plate then return end
                if plate.MyNP_TargetMarker then
                    pcall(plate.MyNP_TargetMarker.Hide, plate.MyNP_TargetMarker)
                end
                if plate.MyNP_HealerMarker then
                    pcall(plate.MyNP_HealerMarker.Hide, plate.MyNP_HealerMarker)
                end
                if plate.MyNP_ClassMarker then
                    pcall(plate.MyNP_ClassMarker.Hide, plate.MyNP_ClassMarker)
                end
                if plate.MyNP_SpecText then
                    pcall(plate.MyNP_SpecText.SetText, plate.MyNP_SpecText, "")
                    pcall(plate.MyNP_SpecText.Hide,    plate.MyNP_SpecText)
                end
                if plate.MyNP_SummonName then
                    pcall(plate.MyNP_SummonName.SetText, plate.MyNP_SummonName, "")
                    pcall(plate.MyNP_SummonName.Hide,    plate.MyNP_SummonName)
                end
                -- Disarm the uf.name suppressor (per-plate flag) so
                -- the next unit to land on this recycled plate frame
                -- gets Blizzard's name back at default until our
                -- summon-name pipeline decides otherwise.
                plate.MyNP_summonNameActive = false
                -- Clear any cached spec captured for the previous
                -- unit on this plate.  Blizzard pools nameplate
                -- frames, so the next unit assigned here would
                -- inherit the prior spec if we didn't reset.
                if ns.ClearSpecByPlate then pcall(ns.ClearSpecByPlate, ns, plate) end
                -- Same for the per-plate summon-type cache (target/
                -- mouseover capture).  Without this reset, a totem's
                -- plate frame recycled into a player would still
                -- show the totem overlay until a fresh target.
                if ns.ClearSummonTypeByPlate then pcall(ns.ClearSummonTypeByPlate, ns, plate) end
                if plate.MyNP_AuraIcon then
                    pcall(plate.MyNP_AuraIcon.Hide, plate.MyNP_AuraIcon)
                end
            end)
        elseif event == "UNIT_AURA" or event == "UNIT_THREAT_LIST_UPDATE" or event == "UNIT_FACTION" then
            if unit and active[unit] then
                ApplyOverrides(active[unit])
            end
            -- Auras can change without touching alpha/scale, so update
            -- the watched-aura icon for the affected unit specifically.
            if event == "UNIT_AURA" and unit and ns.UpdateAurasForUnit then
                pcall(ns.UpdateAurasForUnit, ns, unit)
            end
        else
            -- PLAYER_TARGET_CHANGED, ARENA_*, GROUP_ROSTER_UPDATE, etc.
            ReapplyAll()
        end
        -- Indicators (target arrow + healer crosses) use direct unit-token
        -- lookups so they work on plates we don't manage normally (forbidden
        -- arena enemy plates).  Refresh on every event.
        if ns.RefreshAllIndicators then
            pcall(ns.RefreshAllIndicators, ns)
        end
        if ns.RefreshAllAuras then
            pcall(ns.RefreshAllAuras, ns)
        end
        if ns.RefreshAllLabels then
            pcall(ns.RefreshAllLabels, ns)
        end
    end)
end)

----------------------------------------------------------------------
-- Re-apply ticker.  Runs every frame for every active plate.  Cheap
-- because ApplyOverrides early-outs to a no-op SetAlpha(1.0) when the
-- category is at defaults.  Per-frame frequency is what lets MyNamePlates
-- beat Blizzard's "in-combat alpha boost" on close enemy plates and lets
-- other nameplate addons coexist on default-setting categories.
----------------------------------------------------------------------
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, dt)
    pcall(function()
        for unit, info in pairs(active) do
            if not UnitExists(unit) then
                ResetPlate(info.plate)
                active[unit] = nil
            else
                ApplyOverrides(info)
            end
        end
    end)
end)

----------------------------------------------------------------------
-- Hook Blizzard's nameplate update.  The engine's UpdateNamePlateOptions
-- re-asserts scale and other options on every plate (especially enemy
-- plates, which have an extra `nameplatePlayerLargerScale` multiplier).
-- The fixed-interval ticker isn't always fast enough to win against
-- this, so we hook the function and re-apply our overrides immediately
-- after Blizzard finishes.
----------------------------------------------------------------------
if NamePlateDriverFrame and NamePlateDriverFrame.UpdateNamePlateOptions then
    pcall(hooksecurefunc, NamePlateDriverFrame, "UpdateNamePlateOptions", function()
        pcall(function()
            for _, info in pairs(active) do
                ApplyOverrides(info)
            end
        end)
    end)
end

-- (CompactUnitFrame_UpdateAll / UpdateHealth hooks removed in v1.14.5 —
-- they were firing thousands of times in arena and any single error in
-- the callback was bubbling up as a UI error spam.  The per-frame ticker
-- and SetAlpha hooks already cover the same re-apply timing.)

----------------------------------------------------------------------
-- Plate-size lock.  When the user has customised plate width / height,
-- enforce it against any other addon (BBP, Plater, ElvUI) that calls
-- C_NamePlate.SetNamePlateFriendlySize / SetNamePlateEnemySize after us.
-- We only re-assert when the user has values away from the addon
-- default (110x45).  Skipping the default case avoids the click-area
-- bug we hit earlier where forcing 110x45 shrank the click box below
-- the visible plate (which is 154x64 on Large Nameplates).
----------------------------------------------------------------------
local function _customSize(which)
    local ps = MyNamePlatesDB and MyNamePlatesDB.plateSize
    if not ps then return nil end
    local w, h
    if which == "Friendly" then
        w, h = ps.friendlyWidth, ps.friendlyHeight
    else
        w, h = ps.enemyWidth, ps.enemyHeight
    end
    if not w or not h then return nil end
    -- Skip enforcement when at our default 110x45 — Blizzard's actual
    -- default depends on the Large Nameplates CVar and is what we want
    -- in the unconfigured case.
    if w == 110 and h == 45 then return nil end
    return w, h
end

local function HookSizeLock(funcName, which)
    if not (C_NamePlate and C_NamePlate[funcName]) then return end
    local guard = false
    hooksecurefunc(C_NamePlate, funcName, function(width, height)
        if guard then return end
        local wantW, wantH = _customSize(which)
        if not wantW then return end
        if width ~= wantW or height ~= wantH then
            guard = true
            pcall(C_NamePlate[funcName], wantW, wantH)
            guard = false
        end
    end)
end

HookSizeLock("SetNamePlateFriendlySize", "Friendly")
HookSizeLock("SetNamePlateEnemySize",    "Enemy")

if NamePlateDriverFrame and NamePlateDriverFrame.OnUnitFactionChanged then
    hooksecurefunc(NamePlateDriverFrame, "OnUnitFactionChanged", function(_, unit)
        if not unit then return end
        -- Secret-string guard before unit:find — :find on a secret
        -- token taints us, and faction-change events fire from secure
        -- nameplate code, so taint here cascades directly to the
        -- "MyNamePlates has been blocked" Blizzard popup.
        if issecretvalue and issecretvalue(unit) then return end
        if not unit:find("nameplate") then return end
        -- Faction flip: re-classify (friendly mob may have just become
        -- hostile, or vice-versa with mind control).
        OnUnitRemoved(unit)
        OnUnitAdded(unit)
        -- BBP pattern: retry once after a short delay because some unit
        -- attributes (UnitIsFriend, GUID-derived owner) take a frame or
        -- two to update after Mind Control / faction toggles.
        C_Timer.After(0.2, function()
            if UnitExists(unit) then
                OnUnitRemoved(unit)
                OnUnitAdded(unit)
            end
        end)
    end)
end

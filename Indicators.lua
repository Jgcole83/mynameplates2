-- Indicators.lua
-- Two cosmetic markers attached to nameplates:
--   • TARGET indicator   — an arrow above your current target's plate
--   • HEALER indicator   — a green cross on friendly healers,
--                          a red cross on enemy healers (PvP)
-- Pattern follows BetterBlizzPlates' target.lua / healer.lua.

local _, ns = ...

----------------------------------------------------------------------
-- Runtime-only test mode flags.  Not persisted to MyNamePlatesDB —
-- toggled from the Indicators panel "Test" buttons so you can see
-- markers in the open world while adjusting sliders.
----------------------------------------------------------------------
ns.testMode = {
    target         = false,
    healerFriendly = false,
    healerEnemy    = false,
    classFriendly  = false,
    classEnemy     = false,
    auras          = false,
    name           = false,   -- forces the player/NPC name block onto every plate
    petTotemName   = false,   -- forces the pet/totem name block onto every plate
}

----------------------------------------------------------------------
-- ArenaMap: plate -> arena index (1..3).
--
-- On retail Midnight, forbidden enemy arena plates have an anonymized
-- uf.unit token whose UnitClass / UnitAura / UnitGUID don't surface
-- meaningful data.  But UnitIsUnit between the forbidden token and
-- the player's target/focus/mouseover DOES work (the engine can
-- compare the underlying physical unit across tokens).
--
-- We maintain a {plate -> arenaIndex} map populated in two ways:
--   1. Direct check: UnitIsUnit(uf.unit, "arena"..i) — works on some
--      plates.
--   2. Intermediary learning: when target/focus/mouseover changes,
--      find the plate whose uf.unit matches the intermediary, then
--      check which arena1..3 the intermediary is.  This is the
--      reliable fallback for fully anonymized tokens.
--
-- Once a plate is tagged, callers can use UnitClass("arenaN"),
-- GetArenaOpponentSpec(N), and AuraUtil.ForEachAura("arenaN", ...)
-- to recover info that the per-plate token doesn't surface.
--
-- This is BBP's exact pattern (see arenaid.lua: tagPlate / Untag /
-- learnViaIntermediary / GetArenaIndexByFrame).
----------------------------------------------------------------------
ns.ArenaMap = {
    plateToIndex = {},
    indexToPlate = {},
    arenaCache   = {},   -- [1..3] = { class, race, sex, power, spec }
}
local AM = ns.ArenaMap

----------------------------------------------------------------------
-- Reliable arena detection.  IsActiveBattlefieldArena() is unreliable
-- on retail Midnight (often returns false even mid-arena).  BBP uses
-- IsInInstance() and checks instanceType == "arena" — that's the
-- canonical pattern.  We accept either as a positive signal so we
-- don't miss any case.
----------------------------------------------------------------------
local function _IsInArena()
    if IsInInstance then
        local inInstance, instanceType = IsInInstance()
        if inInstance and instanceType == "arena" then return true end
    end
    if IsActiveBattlefieldArena and IsActiveBattlefieldArena() then
        return true
    end
    return false
end
ns.IsInArena = _IsInArena

----------------------------------------------------------------------
-- Property fingerprint helpers (BBP arenaid.lua port)
----------------------------------------------------------------------
local function _safeVal(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function _readUnitProps(unit)
    local _, class = UnitClass(unit)
    local _, race  = UnitRace(unit)
    return {
        class = _safeVal(class),
        race  = _safeVal(race),
        sex   = _safeVal(UnitSex(unit)),
        power = _safeVal(UnitPowerType(unit)),
    }
end

-- Returns true if a plate's props are compatible with arenaCache[idx]
-- (every defined dimension agrees), nil if no comparison possible,
-- false if any defined dimension disagrees.
local function _propsMatch(plateProps, idx)
    local cached = AM.arenaCache[idx]
    if not cached then return nil end
    local checked = 0
    if plateProps.class and cached.class then
        if plateProps.class ~= cached.class then return false end
        checked = checked + 1
    end
    if plateProps.race and cached.race then
        if plateProps.race ~= cached.race then return false end
        checked = checked + 1
    end
    if plateProps.sex and cached.sex then
        if plateProps.sex ~= cached.sex then return false end
        checked = checked + 1
    end
    if plateProps.power and cached.power then
        if plateProps.power ~= cached.power then return false end
        checked = checked + 1
    end
    return checked > 0 and true or nil
end

-- Pick the unique compatible arena index for plateProps from the
-- given candidate list, narrowing by class > race > power > sex.
local function _resolveIndex(plateProps, candidates)
    if #candidates == 0 then return nil end
    if #candidates == 1 then
        local idx = candidates[1]
        local m = _propsMatch(plateProps, idx)
        if m == false then return nil end
        return idx
    end

    -- Drop candidates that contradict any dimension.
    local remaining = {}
    for _, idx in ipairs(candidates) do
        if _propsMatch(plateProps, idx) ~= false then
            remaining[#remaining + 1] = idx
        end
    end
    if #remaining == 0 then return nil end
    if #remaining == 1 then return remaining[1] end

    -- Narrow by each dimension that's defined on the plate.
    local function narrowBy(field)
        if plateProps[field] == nil then return end
        local n = {}
        for _, idx in ipairs(remaining) do
            local c = AM.arenaCache[idx]
            if not c[field] or c[field] == plateProps[field] then
                n[#n + 1] = idx
            end
        end
        if #n >= 1 then remaining = n end
    end
    narrowBy("class")
    if #remaining == 1 then return remaining[1] end
    narrowBy("race")
    if #remaining == 1 then return remaining[1] end
    narrowBy("power")
    if #remaining == 1 then return remaining[1] end
    narrowBy("sex")
    if #remaining == 1 then return remaining[1] end
    return nil
end

----------------------------------------------------------------------
-- Map mutators
----------------------------------------------------------------------
function AM:Tag(plate, idx)
    if not plate or not idx then return end
    local oldPlate = self.indexToPlate[idx]
    if oldPlate and oldPlate ~= plate then
        self.plateToIndex[oldPlate] = nil
    end
    local oldIdx = self.plateToIndex[plate]
    if oldIdx and oldIdx ~= idx then
        self.indexToPlate[oldIdx] = nil
    end
    self.plateToIndex[plate] = idx
    self.indexToPlate[idx]   = plate
end

function AM:Untag(plate)
    if not plate then return end
    local idx = self.plateToIndex[plate]
    if idx then self.indexToPlate[idx] = nil end
    self.plateToIndex[plate] = nil
end

function AM:GetIndex(plate)
    return plate and self.plateToIndex[plate] or nil
end

function AM:Wipe()
    wipe(self.plateToIndex)
    wipe(self.indexToPlate)
    wipe(self.arenaCache)
end

----------------------------------------------------------------------
-- Cache builder: read class/race/sex/power/spec from canonical
-- arena1..3 tokens (which always work, unlike the per-plate forbidden
-- tokens).  We use this cache to fingerprint-match unmapped plates.
----------------------------------------------------------------------
function AM:CacheIndex(idx)
    local arenaUnit = "arena" .. idx
    local entry = self.arenaCache[idx] or {}

    if UnitExists(arenaUnit) then
        local props = _readUnitProps(arenaUnit)
        for k, v in pairs(props) do
            if v then entry[k] = v end
        end
    end

    -- Spec API works during arena prep before arena units are visible.
    if GetArenaOpponentSpec then
        local specID = GetArenaOpponentSpec(idx)
        if specID and specID ~= 0 then
            entry.spec = specID
            if not entry.class and GetSpecializationInfoByID then
                -- 6th return of GetSpecializationInfoByID is classFile.
                local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
                if classFile then entry.class = classFile end
            end
        end
    end

    self.arenaCache[idx] = entry
end

function AM:BuildCache()
    if not _IsInArena() then return end
    for i = 1, 3 do self:CacheIndex(i) end
end

----------------------------------------------------------------------
-- Direct match — UnitIsUnit(uf.unit, "arenaN").  Works on plates
-- whose tokens aren't fully anonymized.
----------------------------------------------------------------------
function AM:RescanDirect()
    if not _IsInArena() then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if not self.plateToIndex[plate] then
            local uf = plate.UnitFrame
            local unit = uf and (uf.unit or uf.displayedUnit)
            if unit then
                for i = 1, 3 do
                    local ok, isUnit = pcall(UnitIsUnit, unit, "arena" .. i)
                    if ok and isUnit then
                        self:Tag(plate, i)
                        break
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Fingerprint match — for plates the direct check missed.  Reads
-- race/sex/power/class on the plate's uf.unit (these surface even on
-- forbidden anonymized plates; only UnitGUID is hidden), then matches
-- against the canonical arena1..3 cache.  Self-activates without
-- requiring user interaction.
----------------------------------------------------------------------
function AM:RescanFingerprint()
    if not _IsInArena() then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    self:BuildCache()   -- ensure cache is fresh

    -- Plates we need to map this pass.
    local plates = {}
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if not self.plateToIndex[plate] then
            local uf = plate.UnitFrame
            local unit = uf and (uf.unit or uf.displayedUnit)
            if unit then
                local props = _readUnitProps(unit)
                if props.class or props.race or props.sex or props.power then
                    plates[#plates + 1] = { plate = plate, props = props }
                end
            end
        end
    end

    if #plates == 0 then return end

    -- Try matching against ALL indices first (covers the typical
    -- single-match case), then narrow to untagged-only indices.
    local function tryMatch(candidatePool)
        for _, p in ipairs(plates) do
            if not self.plateToIndex[p.plate] then
                local idx = _resolveIndex(p.props, candidatePool)
                if idx and not self.indexToPlate[idx] then
                    self:Tag(p.plate, idx)
                end
            end
        end
    end

    local allIdx = {}
    for i = 1, 3 do
        if self.arenaCache[i] then allIdx[#allIdx + 1] = i end
    end
    tryMatch(allIdx)

    local untaggedIdx = {}
    for i = 1, 3 do
        if self.arenaCache[i] and not self.indexToPlate[i] then
            untaggedIdx[#untaggedIdx + 1] = i
        end
    end
    tryMatch(untaggedIdx)
end

----------------------------------------------------------------------
-- Intermediary learning: target/focus/mouseover that is arena1..3
-- gives us a definite plate->index binding.
----------------------------------------------------------------------
function AM:LearnFromIntermediary(intermediary)
    if not _IsInArena() then return end
    if not UnitExists(intermediary) then return end

    local matchedArena
    for i = 1, 3 do
        local ok, isUnit = pcall(UnitIsUnit, intermediary, "arena" .. i)
        if ok and isUnit then matchedArena = i; break end
    end
    if not matchedArena then return end

    local plate = C_NamePlate.GetNamePlateForUnit(intermediary, true)
    if not plate then
        for _, p in ipairs(C_NamePlate.GetNamePlates(true)) do
            local uf = p.UnitFrame
            local unit = uf and (uf.unit or uf.displayedUnit)
            if unit then
                local ok, same = pcall(UnitIsUnit, unit, intermediary)
                if ok and same then plate = p; break end
            end
        end
    end
    if plate then self:Tag(plate, matchedArena) end
end

----------------------------------------------------------------------
-- Drop bindings whose plates no longer match the cached fingerprint
-- for their slot.  Catches the "plate frame recycled for a different
-- arena slot" case — without this, the stale binding survives and
-- spec / class / aura lookups attribute the wrong arena slot's data.
----------------------------------------------------------------------
function AM:DropInvalidBindings()
    if not _IsInArena() then return end
    for plate, idx in pairs(self.plateToIndex) do
        local uf = plate.UnitFrame
        local unit = uf and (uf.unit or uf.displayedUnit)
        if not unit then
            self:Untag(plate)
        else
            local props = _readUnitProps(unit)
            -- Only drop on definite mismatch (false).  Inconclusive
            -- (nil — no fingerprint dimensions overlap with cache)
            -- keeps the binding.
            if _propsMatch(props, idx) == false then
                self:Untag(plate)
            end
        end
    end
end

----------------------------------------------------------------------
-- Combined re-scan: build the arena cache, drop invalid bindings,
-- then try direct match (cheap), then fingerprint match (covers
-- fully-anonymized plates).
----------------------------------------------------------------------
function AM:Refresh()
    self:BuildCache()
    self:DropInvalidBindings()
    self:RescanDirect()
    self:RescanFingerprint()
end

----------------------------------------------------------------------
-- Listener for arena lifecycle / intermediary events.
--
-- IMPORTANT: every event handler here defers its work via
-- C_Timer.After(0, ...) to break out of the in-flight secure call
-- chain.  Without this, calls like UnitClass / UnitIsUnit on
-- anonymized forbidden-plate tokens can propagate taint into the
-- secure code path that fired the event (e.g. PLAYER_TARGET_CHANGED
-- fires inside the engine's target-change operation; doing
-- forbidden-plate work synchronously taints the player's next
-- spellcast and you get "Interface actions failed because of an
-- AddOn").  Deferring runs our work on a fresh call stack outside
-- the secure operation, which is the standard mitigation.
--
-- We also intentionally do NOT register UPDATE_MOUSEOVER_UNIT here.
-- It fires far too often (every micro-mouse-move over a unit) and
-- the per-event work isn't worth the taint exposure.  Mouseover is
-- caught by the periodic re-learn inside RefreshAllIndicators
-- instead.
----------------------------------------------------------------------
local function _Defer(fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() pcall(fn) end)
    else
        pcall(fn)
    end
end

local AMListener = CreateFrame("Frame")
AMListener:RegisterEvent("PLAYER_TARGET_CHANGED")
AMListener:RegisterEvent("PLAYER_FOCUS_CHANGED")
AMListener:RegisterEvent("ARENA_OPPONENT_UPDATE")
AMListener:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
AMListener:RegisterEvent("PVP_MATCH_STATE_CHANGED")
AMListener:RegisterEvent("PVP_MATCH_ACTIVE")
AMListener:RegisterEvent("PLAYER_ENTERING_WORLD")
AMListener:RegisterEvent("NAME_PLATE_UNIT_ADDED")
AMListener:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
AMListener:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_ENTERING_WORLD"
       or event == "PVP_MATCH_ACTIVE"
       or event == "PVP_MATCH_STATE_CHANGED" then
        _Defer(function()
            AM:Wipe()
            C_Timer.After(0.5, function()
                AM:Refresh()
                if ns.RefreshAllIndicators then ns:RefreshAllIndicators() end
                if ns.RefreshAllAuras      then ns:RefreshAllAuras()      end
            end)
        end)
    elseif event == "ARENA_OPPONENT_UPDATE"
        or event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS"
        or event == "NAME_PLATE_UNIT_ADDED" then
        _Defer(function()
            AM:Refresh()
            -- Re-render now that bindings are fresh.  Without this,
            -- plates that just appeared get stamped before AM:Refresh
            -- finishes, so canonical-token paths (enemy spec / class
            -- icon / auras on forbidden plates) come back empty.
            if ns.RefreshAllIndicators then pcall(ns.RefreshAllIndicators, ns) end
            if ns.RefreshAllAuras      then pcall(ns.RefreshAllAuras,      ns) end
            if ns.RefreshAllLabels     then pcall(ns.RefreshAllLabels,     ns) end
        end)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        -- Untag synchronously.  It's a pure-Lua table mutation (no
        -- WoW API calls), so there's no taint risk, and synchronous
        -- untag avoids a race where an ADDED event for the next unit
        -- on this plate frame fires its deferred Refresh BEFORE our
        -- deferred Untag — leaving a stale plate->slot binding that
        -- causes the new unit's spec / class / aura to fail lookup.
        if arg1 then
            local plate = C_NamePlate.GetNamePlateForUnit(arg1, true)
            if plate then AM:Untag(plate) end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        _Defer(function()
            AM:LearnFromIntermediary("target")
            if ns.RefreshAllIndicators then pcall(ns.RefreshAllIndicators, ns) end
            if ns.RefreshAllAuras      then pcall(ns.RefreshAllAuras,      ns) end
            if ns.RefreshAllLabels     then pcall(ns.RefreshAllLabels,     ns) end
        end)
    elseif event == "PLAYER_FOCUS_CHANGED" then
        _Defer(function()
            AM:LearnFromIntermediary("focus")
            if ns.RefreshAllIndicators then pcall(ns.RefreshAllIndicators, ns) end
            if ns.RefreshAllAuras      then pcall(ns.RefreshAllAuras,      ns) end
            if ns.RefreshAllLabels     then pcall(ns.RefreshAllLabels,     ns) end
        end)
    end
end)

-- Public helper: returns the canonical arena unit token for a plate
-- if known, otherwise nil.  Use it as a hint for APIs that need a
-- "real" unit token (UnitClass, UnitAura, GetArenaOpponentSpec, ...).
function ns:GetArenaUnitForPlate(plate)
    local idx = AM:GetIndex(plate)
    if idx then return "arena" .. idx, idx end
    return nil
end

----------------------------------------------------------------------
-- Healer spec detection
----------------------------------------------------------------------
ns.HEALER_SPECS = {
    [105]  = true,   -- Restoration Druid
    [264]  = true,   -- Restoration Shaman
    [270]  = true,   -- Mistweaver Monk
    [257]  = true,   -- Holy Priest
    [256]  = true,   -- Discipline Priest
    [65]   = true,   -- Holy Paladin
    [1468] = true,   -- Preservation Evoker
}

-- Localized "{specName} {className}" -> specID, exactly the format
-- Blizzard tooltips use (e.g. "Restoration Druid", "Holy Paladin").
-- Built lazily on first call because GetSpecializationInfoByID isn't
-- guaranteed to be ready before PLAYER_LOGIN.  Pattern borrowed from
-- BBP's GetLocalizedSpecs.
ns.HEALER_SPEC_NAMES = nil
local function _BuildHealerSpecNames()
    if ns.HEALER_SPEC_NAMES then return end
    local names = {}
    if not GetSpecializationInfoByID then
        ns.HEALER_SPEC_NAMES = names
        return
    end
    for specID in pairs(ns.HEALER_SPECS) do
        local ok, _, specName, _, _, _, _, classFile =
            pcall(GetSpecializationInfoByID, specID)
        if ok and specName and classFile then
            local male   = LOCALIZED_CLASS_NAMES_MALE   and LOCALIZED_CLASS_NAMES_MALE[classFile]
            local female = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classFile]
            if male   then names[specName .. " " .. male]   = specID end
            if female and female ~= male then
                names[specName .. " " .. female] = specID
            end
        end
    end
    ns.HEALER_SPEC_NAMES = names
end

-- GUID -> bool cache so we don't tooltip-scan the same unit forever.
local healerCache = {}

local function _IsHealerByRole(unit)
    if not UnitGroupRolesAssigned then return false end
    return UnitGroupRolesAssigned(unit) == "HEALER"
end

local function _IsHealerByArenaSpec(unit)
    if not GetArenaOpponentSpec then return false end
    for i = 1, 3 do
        if UnitIsUnit(unit, "arena" .. i) then
            local specID = GetArenaOpponentSpec(i)
            if specID and ns.HEALER_SPECS[specID] then return true end
            return false
        end
    end
    return false
end

-- Tooltip scan — the most reliable method for enemy players in PvP.
-- C_TooltipInfo.GetUnit returns parsed tooltip lines including the
-- localized "specName className" line.  Filter by line.type == None so
-- we only check the spec/class line (matches BBP exactly).
local function _IsHealerByTooltip(unit)
    if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then return false end
    _BuildHealerSpecNames()
    local data = C_TooltipInfo.GetUnit(unit)
    if not (data and data.lines) then return false end
    local names = ns.HEALER_SPEC_NAMES or {}
    local NONE  = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.None or 0
    for _, line in ipairs(data.lines) do
        if line and line.type == NONE
           and line.leftText and line.leftText ~= ""
           and names[line.leftText] then
            return true
        end
    end
    return false
end

local function IsHealer(unit)
    if not unit then return false end
    if not UnitIsPlayer(unit) then return false end

    -- Forbidden arena plates return a "secret value" from UnitGUID that
    -- COLLIDES across multiple plates (it's not a real per-unit GUID,
    -- it's an anonymized placeholder).  Caching healer status by that
    -- value made one plate's healer status leak onto every other
    -- forbidden plate — which is exactly the "cross on random enemies"
    -- bug.  Detect secret values and skip caching for them; do the
    -- detection live every call instead.  BBP does the same.
    local guid = UnitGUID(unit)
    local cacheable = guid
        and not (issecretvalue and issecretvalue(guid))

    if cacheable and healerCache[guid] ~= nil then
        return healerCache[guid]
    end

    local result = false
    if _IsHealerByRole(unit) then
        result = true
    elseif _IsHealerByArenaSpec(unit) then
        result = true
    elseif _IsHealerByTooltip(unit) then
        result = true
    end

    if cacheable and result then
        healerCache[guid] = true
    end
    return result
end

-- Plate-aware healer detection.  Tries the per-plate unit first
-- (works on non-forbidden plates), then uses ArenaMap to look up the
-- canonical arenaN token for forbidden plates and check spec via
-- GetArenaOpponentSpec — the only reliable path for fully anonymized
-- arena enemy plates.
local function _IsHealerForPlate(plate, unit)
    if unit and IsHealer(unit) then return true end
    local arenaUnit, idx = plate and ns:GetArenaUnitForPlate(plate)
    if idx then
        local specID = GetArenaOpponentSpec and GetArenaOpponentSpec(idx)
        if specID and ns.HEALER_SPECS[specID] then return true end
        if arenaUnit and _IsHealerByTooltip(arenaUnit) then return true end
    end
    return false
end

-- Clear cache on PLAYER_ENTERING_WORLD (new arena, GUIDs may reuse)
local cacheClearer = CreateFrame("Frame")
cacheClearer:RegisterEvent("PLAYER_ENTERING_WORLD")
cacheClearer:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
cacheClearer:SetScript("OnEvent", function()
    wipe(healerCache)
    ns.HEALER_SPEC_NAMES = nil   -- rebuild on next call (locale safety)
end)

----------------------------------------------------------------------
-- Texture creation (lazy, once per plate)
--
-- v1.36.11: previously we bailed early whenever plate:IsForbidden() or
-- uf:IsForbidden() returned true, on the assumption that
-- CreateTexture on a forbidden frame would propagate taint and produce
-- "Interface action failed because of an AddOn" errors.  That's what
-- caused the enemy healer cross to never appear on arena enemy plates
-- (whose UnitFrames are flagged forbidden in retail Midnight 12.x).
--
-- BetterBlizzPlates creates textures directly on the same forbidden
-- arena plates (see retail/modules/healer.lua + BBP.lua bbpOverlay
-- creation) without any guard and works fine.  Blizzard's taint model
-- treats textures as non-secure widgets, so parenting one to a
-- forbidden frame does not taint it — only secure-write-through
-- operations do.  We wrap creation + configuration in pcall as
-- defensive belt-and-braces in case a future Midnight patch does
-- restrict certain plates entirely.
----------------------------------------------------------------------
local function _NewMarker(uf, atlas)
    local ok, tex = pcall(uf.CreateTexture, uf, nil, "OVERLAY", nil, 7)
    if not ok or not tex then return nil end
    pcall(tex.SetAtlas, tex, atlas)
    pcall(tex.Hide, tex)
    return tex
end

local function _GetTarget(plate)
    if plate.MyNP_TargetMarker then return plate.MyNP_TargetMarker end
    local uf = plate.UnitFrame
    if not uf then return nil end
    local tex = _NewMarker(uf, "Navigation-Tracked-Arrow")
    if not tex then return nil end
    pcall(tex.SetSize, tex, 14, 9)
    plate.MyNP_TargetMarker = tex
    return tex
end

local function _GetHealer(plate)
    if plate.MyNP_HealerMarker then return plate.MyNP_HealerMarker end
    local uf = plate.UnitFrame
    if not uf then return nil end
    local tex = _NewMarker(uf, "greencross")
    if not tex then return nil end
    pcall(tex.SetSize, tex, 14, 14)
    -- Trim away ugly white pixels around the atlas border.
    pcall(tex.SetTexCoord, tex, 0.1953125, 0.8046875, 0.1953125, 0.8046875)
    plate.MyNP_HealerMarker = tex
    return tex
end

----------------------------------------------------------------------
-- Class icon (lazy, once per plate).  Uses Blizzard's modern
-- "classicon-<classfile>" atlases (the same ones party frames, LFG,
-- and the character UI use).  This matches how BetterBlizzPlates does
-- it -- the legacy CLASS_ICON_TCOORDS / UI-Classes-Circles texture
-- doesn't cleanly cover modern classes (e.g. EVOKER), so atlases are
-- the right path on retail.
----------------------------------------------------------------------
local function _GetClassIcon(plate)
    if plate.MyNP_ClassMarker then return plate.MyNP_ClassMarker end
    local uf = plate.UnitFrame
    if not uf then return nil end
    -- v1.36.11: forbidden guard removed — see comment above _NewMarker.
    local ok, tex = pcall(uf.CreateTexture, uf, nil, "OVERLAY", nil, 7)
    if not ok or not tex then return nil end
    pcall(tex.SetSize, tex, 22, 22)   -- base size; user scale multiplies on top
    -- Decouple from the UnitFrame's alpha animations (target-fade,
    -- in-combat alpha, distance fade).  Without this, the engine's
    -- animator can briefly drive parent alpha to 0/intermediate values
    -- during target swaps and the icon flickers.  BBP does the same.
    if tex.SetIgnoreParentAlpha then
        pcall(tex.SetIgnoreParentAlpha, tex, true)
    end
    pcall(tex.Hide, tex)
    plate.MyNP_ClassMarker = tex
    return tex
end

-- Returns the english classFile ("WARRIOR", "MAGE", etc.).  Tries
-- the per-plate unit first (works on most plates), then the
-- ArenaMap canonical token for forbidden anonymized arena plates.
-- Strips secret-string returns (UnitClass on anonymised units in
-- retail Midnight 12.x returns secret values even when the unit
-- token itself is non-secret) — the caller does string.lower() on
-- this value, which taints if the input is secret.
local function _GetClassFile(plate, unit)
    if unit then
        local _, classFile = UnitClass(unit)
        if classFile and not (issecretvalue and issecretvalue(classFile)) then
            return classFile
        end
    end
    local arenaUnit = plate and ns:GetArenaUnitForPlate(plate)
    if arenaUnit then
        local _, cf = UnitClass(arenaUnit)
        if cf and not (issecretvalue and issecretvalue(cf)) then
            return cf
        end
    end
    return nil
end

local function _ApplyClassTex(tex, classFile)
    if not (tex and classFile) then return false end
    local atlas = "classicon-" .. string.lower(classFile)
    -- SetAtlas returns true on success (atlas exists).  We try-set and
    -- bail if it fails (e.g. a future class file we don't recognize).
    local ok = pcall(tex.SetAtlas, tex, atlas)
    if not ok then return false end
    -- Slightly extend so the round atlases don't show their faint
    -- background ring (matches BBP's offset).
    tex:SetTexCoord(-0.06, 1.05, -0.06, 1.05)
    return true
end

----------------------------------------------------------------------
-- Apply a marker's visual state from its config block
----------------------------------------------------------------------
local function _ApplyMarker(tex, anchorTo, cfg)
    if not (tex and anchorTo and cfg) then return end
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", anchorTo,
        cfg.anchor or "TOP",
        tonumber(cfg.xOffset) or 0,
        tonumber(cfg.yOffset) or 0)
    tex:SetScale(tonumber(cfg.scale) or 1.0)
end

----------------------------------------------------------------------
-- Public: update both markers on a plate
----------------------------------------------------------------------
----------------------------------------------------------------------
-- Direct-lookup mode: rather than wait for the per-plate ApplyOverrides
-- pass (which skips forbidden arena enemy plates), fetch the plate by a
-- known unit token (target / arena1..3 / party1..4 / partypet1..4) and
-- attach indicators directly.  This is how we get the target arrow and
-- enemy healer cross to land on arena plates that our active table
-- can't reach.
--
-- We parent each indicator to plate.UnitFrame.healthBar when possible
-- (matches BBP), but fall back to the outer NamePlateBase if UnitFrame
-- isn't available (forbidden plates may still allow textures on the
-- base frame).
----------------------------------------------------------------------
local function _SafeAnchorFor(plate)
    if not plate then return nil end
    local uf = plate.UnitFrame
    if uf and uf.healthBar then return uf.healthBar end
    if uf then return uf end
    return plate
end

local function _HideTargetMarkers()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if plate.MyNP_TargetMarker then
            pcall(plate.MyNP_TargetMarker.Hide, plate.MyNP_TargetMarker)
        end
    end
end

local function _HideHealerMarkers()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if plate.MyNP_HealerMarker then
            pcall(plate.MyNP_HealerMarker.Hide, plate.MyNP_HealerMarker)
        end
    end
end

local function _HideClassMarkers()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if plate.MyNP_ClassMarker then
            pcall(plate.MyNP_ClassMarker.Hide, plate.MyNP_ClassMarker)
        end
    end
end

local function _ApplyClassMarkerOnPlate(plate, classFile, cfg)
    if not plate or not cfg or cfg.enabled ~= "1" then return end
    if not classFile then return end
    pcall(function()
        local tex = _GetClassIcon(plate)
        if not tex then return end
        if not _ApplyClassTex(tex, classFile) then return end
        _ApplyMarker(tex, _SafeAnchorFor(plate), cfg)
        tex:SetVertexColor(1, 1, 1, 1)
        tex:Show()
    end)
end

----------------------------------------------------------------------
-- 1.34.2: shared upvalue state buffers for the per-plate pcall bodies
-- below.  RefreshTargetArrow / RefreshHealerCrosses / RefreshClassIcons
-- all run at 10 Hz from Discovery's refresh drainer.  In arena with
-- 20 plates each pcall(function()...) allocated a fresh closure per
-- plate per refresh; the shared-state + named-body pattern below
-- brings that to zero allocations.
--
-- All bodies are single-threaded and finish synchronously before the
-- next plate iteration, so cross-plate state overwrite is safe.
----------------------------------------------------------------------
local _targetState = { plate = nil, cfg = nil, useColor = false }
local function _ApplyTargetOnPlate()
    local plate = _targetState.plate
    local cfg   = _targetState.cfg
    local tex = _GetTarget(plate)
    if not tex then return end
    _ApplyMarker(tex, _SafeAnchorFor(plate), cfg)
    if _targetState.useColor then
        local c = cfg.color
        if c then
            tex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
        else
            tex:SetVertexColor(1, 1, 1, 1)
        end
    else
        tex:SetVertexColor(1, 1, 1, 1)
    end
    tex:Show()
end

function ns:RefreshTargetArrow()
    if not (MyNamePlatesDB and MyNamePlatesDB.indicators
            and MyNamePlatesDB.indicators.target) then return end
    local cfg = MyNamePlatesDB.indicators.target

    pcall(_HideTargetMarkers)

    -- Test mode: arrow over EVERY plate so user can position it.
    if ns.testMode and ns.testMode.target then
        if cfg.enabled ~= "1" then return end
        _targetState.cfg      = cfg
        _targetState.useColor = false
        for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
            _targetState.plate = plate
            pcall(_ApplyTargetOnPlate)
        end
        return
    end

    if cfg.enabled ~= "1" or not UnitExists("target") then return end

    local plate = C_NamePlate.GetNamePlateForUnit("target", true)
    if not plate then return end
    _targetState.plate    = plate
    _targetState.cfg      = cfg
    _targetState.useColor = true
    pcall(_ApplyTargetOnPlate)
end

local _healerApplyState = { plate = nil, isFriend = false, cfg = nil }
local function _ApplyHealerMarkerInner()
    local plate    = _healerApplyState.plate
    local isFriend = _healerApplyState.isFriend
    local cfg      = _healerApplyState.cfg
    local tex = _GetHealer(plate)
    if not tex then return end
    _ApplyMarker(tex, _SafeAnchorFor(plate), cfg)
    local c = cfg.color
    if c then
        tex:SetDesaturated(true)
        tex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
    else
        tex:SetDesaturated(not isFriend)
        if isFriend then
            tex:SetVertexColor(1, 1, 1, 1)
        else
            tex:SetVertexColor(1, 0.15, 0.15, 1)
        end
    end
    tex:Show()
end

local function _ApplyHealerMarkerOnPlate(plate, isFriend, cfg)
    if not plate or not cfg or cfg.enabled ~= "1" then return end
    _healerApplyState.plate    = plate
    _healerApplyState.isFriend = isFriend
    _healerApplyState.cfg      = cfg
    pcall(_ApplyHealerMarkerInner)
end

-- Shared state + named body for the two per-plate iterations inside
-- RefreshHealerCrosses (test-mode stamp + enemy-healer walk).  Passes
-- I.healerFriendly / I.healerEnemy via upvalue reload each iteration.
local _healerLoopState = { plate = nil, I = nil, testFriendly = false, testEnemy = false }

local function _HealerTestModeBody()
    local plate = _healerLoopState.plate
    local uf = plate and plate.UnitFrame
    local unit = uf and (uf.unit or uf.displayedUnit)
    if not unit then return end
    local isFriend = UnitIsFriend("player", unit)
    local I = _healerLoopState.I
    if isFriend and _healerLoopState.testFriendly then
        _ApplyHealerMarkerOnPlate(plate, true, I.healerFriendly)
    elseif (not isFriend) and _healerLoopState.testEnemy then
        _ApplyHealerMarkerOnPlate(plate, false, I.healerEnemy)
    end
end

local function _HealerEnemyBody()
    local plate = _healerLoopState.plate
    local I     = _healerLoopState.I
    local uf = plate and plate.UnitFrame
    local punit = uf and (uf.unit or uf.displayedUnit)
    local arenaUnit = ns:GetArenaUnitForPlate(plate)

    local isFriend, isPlayer
    if punit then
        local ok1, f = pcall(UnitIsFriend, "player", punit)
        if ok1 then isFriend = f end
        local ok2, p = pcall(UnitIsPlayer, punit)
        if ok2 then isPlayer = p end
    end
    if arenaUnit then
        isFriend = false
        isPlayer = true
    end
    if isFriend ~= false then return end
    if not isPlayer then return end

    if _IsHealerForPlate(plate, punit) then
        _ApplyHealerMarkerOnPlate(plate, false, I.healerEnemy)
    end
end

function ns:RefreshHealerCrosses()
    if not (MyNamePlatesDB and MyNamePlatesDB.indicators) then return end
    local I = MyNamePlatesDB.indicators
    pcall(_HideHealerMarkers)

    _healerLoopState.I = I

    -- Test mode: stamp every plate
    if ns.testMode and (ns.testMode.healerFriendly or ns.testMode.healerEnemy) then
        _healerLoopState.testFriendly = ns.testMode.healerFriendly or false
        _healerLoopState.testEnemy    = ns.testMode.healerEnemy    or false
        for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
            _healerLoopState.plate = plate
            pcall(_HealerTestModeBody)
        end
        return
    end

    -- Friendly healers: party1..party4 (+ player)
    for i = 0, 4 do
        local unit = (i == 0) and "player" or ("party" .. i)
        if UnitExists(unit) and IsHealer(unit) then
            local plate = C_NamePlate.GetNamePlateForUnit(unit, true)
            if plate then
                _ApplyHealerMarkerOnPlate(plate, true, I.healerFriendly)
            end
        end
    end

    -- Enemy healers — direct arena path FIRST.  In retail Midnight
    -- 12.x, enemy plates in arena are forbidden and their uf.unit is
    -- anonymized, which used to hide the cross entirely because
    -- (a) _GetHealer bailed on forbidden plates (fixed v1.36.11) and
    -- (b) the plate-walk relied on ArenaMap fingerprint matching to
    --     re-associate the anonymized plate with an arenaN token.
    -- The most direct path is to iterate arena1..3, check
    -- GetArenaOpponentSpec against the healer-spec table, then ask
    -- C_NamePlate.GetNamePlateForUnit("arenaN", true) for the plate.
    -- The `true` arg tells Blizzard to include forbidden plates in the
    -- lookup, and it uses UnitIsUnit internally so it handles the
    -- anonymized token transparently.  This runs BEFORE the plate-walk
    -- fallback so the direct hit lands first and doesn't need
    -- ArenaMap to have finished resolving yet.
    if I.healerEnemy and I.healerEnemy.enabled == "1"
       and C_NamePlate.GetNamePlates then
        if _IsInArena() and GetArenaOpponentSpec and C_NamePlate.GetNamePlateForUnit then
            for i = 1, 3 do
                local ok, specID = pcall(GetArenaOpponentSpec, i)
                if ok and specID and ns.HEALER_SPECS[specID] then
                    local arenaUnit = "arena" .. i
                    if UnitExists(arenaUnit) then
                        local plate = C_NamePlate.GetNamePlateForUnit(arenaUnit, true)
                        if plate then
                            _ApplyHealerMarkerOnPlate(plate, false, I.healerEnemy)
                        end
                    end
                end
            end
        end

        -- Plate-walk fallback for battlegrounds, world PvP, and any
        -- arena plate the direct path missed (e.g. arena unit exists
        -- but Blizzard's internal plate map hasn't linked it yet).
        for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
            _healerLoopState.plate = plate
            pcall(_HealerEnemyBody)
        end
    end
end

----------------------------------------------------------------------
-- Class icons — divides responsibility cleanly between two systems:
--
--   * UpdateIndicators (per-plate, called from ApplyOverrides every
--     frame via the OnUpdate ticker) is the sole authority for
--     non-forbidden plates.  It can read uf.unit safely and it runs
--     fast enough to win against any other addon's writes.
--
--   * RefreshClassIcons (this function, called on PLAYER_TARGET_CHANGED,
--     ARENA_OPPONENT_UPDATE, etc.) is the sole authority for FORBIDDEN
--     plates (arena enemies in retail) — UpdateIndicators can't read
--     their unit token without tainting, so we use canonical arena1..3
--     tokens directly.  It also handles test mode (preview on every
--     visible plate regardless of forbidden status).
--
-- The previous version of this function tried to manage every plate.
-- That fought UpdateIndicators on non-forbidden plates and produced
-- visible flicker on every event refresh, because RefreshClassIcons's
-- party/world walk didn't include random open-world friendly plates,
-- so it was hiding markers that UpdateIndicators had just stamped.
----------------------------------------------------------------------
-- 1.34.2: shared state + named bodies for the per-plate iterations
-- inside RefreshClassIcons.  In arena with forbidden enemy plates,
-- this was the single biggest closure allocator (~2 closures per
-- forbidden plate per refresh).  All state passed via _classLoopState.
local _classLoopState = {
    plate     = nil,
    cfg       = nil,
    classFile = nil,
    cf        = nil,
    ce        = nil,
    cfOn      = false,
    ceOn      = false,
    -- Test-mode inputs / outputs.
    testFriendly = false,
    testEnemy    = false,
    ownClass     = nil,
}

local function _ApplyClassStampInner()
    local plate     = _classLoopState.plate
    local cfg       = _classLoopState.cfg
    local classFile = _classLoopState.classFile
    local tex = _GetClassIcon(plate)
    if not tex then return end
    if not _ApplyClassTex(tex, classFile) then return end
    _ApplyMarker(tex, _SafeAnchorFor(plate), cfg)
    tex:SetVertexColor(1, 1, 1, 1)
    tex:Show()
end

local function _ClassTestBody()
    local plate = _classLoopState.plate
    local uf = plate and plate.UnitFrame
    local unit = uf and (uf.unit or uf.displayedUnit)
    local isFriend
    if unit then
        local ok, f = pcall(UnitIsFriend, "player", unit)
        if ok then isFriend = f end
    end
    if isFriend == nil and ns:GetArenaUnitForPlate(plate) then
        isFriend = false
    end
    if isFriend == nil then return end
    local classFile = _GetClassFile(plate, unit) or _classLoopState.ownClass
    local cfg
    if isFriend and _classLoopState.testFriendly then
        cfg = _classLoopState.cf
    elseif (not isFriend) and _classLoopState.testEnemy then
        cfg = _classLoopState.ce
    end
    if cfg and classFile then
        _classLoopState.cfg       = cfg
        _classLoopState.classFile = classFile
        pcall(_ApplyClassStampInner)
    end
end

-- Reused across both the classify + stamp pcalls in the forbidden-plate
-- branch.  Returned values live on _classLoopState (cfg + classFile);
-- caller checks those to decide whether to stamp or hide.
local function _ClassifyForbiddenBody()
    local plate = _classLoopState.plate
    local uf    = plate and plate.UnitFrame
    local unit  = uf and (uf.unit or uf.displayedUnit)

    local isFriend
    if unit then
        local ok, f = pcall(UnitIsFriend, "player", unit)
        if ok then isFriend = f end
    end
    if isFriend == nil and ns:GetArenaUnitForPlate(plate) then
        isFriend = false
    end
    if isFriend == nil then
        _classLoopState.cfg = nil
        _classLoopState.classFile = nil
        return
    end
    if isFriend and _classLoopState.cfOn then
        _classLoopState.cfg       = _classLoopState.cf
        _classLoopState.classFile = _GetClassFile(plate, unit)
    elseif (not isFriend) and _classLoopState.ceOn then
        _classLoopState.cfg       = _classLoopState.ce
        _classLoopState.classFile = _GetClassFile(plate, unit)
    else
        _classLoopState.cfg = nil
        _classLoopState.classFile = nil
    end
end

function ns:RefreshClassIcons()
    if not (MyNamePlatesDB and MyNamePlatesDB.indicators) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end

    local I = MyNamePlatesDB.indicators
    local cf, ce = I.classFriendly, I.classEnemy
    local cfOn = cf and cf.enabled == "1"
    local ceOn = ce and ce.enabled == "1"
    local testFriendly = ns.testMode and ns.testMode.classFriendly
    local testEnemy    = ns.testMode and ns.testMode.classEnemy
    local testOn = testFriendly or testEnemy

    -- All-off shortcut: hide every marker we own.
    if not cfOn and not ceOn and not testOn then
        pcall(_HideClassMarkers)
        return
    end

    _classLoopState.cf   = cf
    _classLoopState.ce   = ce
    _classLoopState.cfOn = cfOn
    _classLoopState.ceOn = ceOn

    -- Test mode: stamp every visible plate so the user can preview the
    -- placement / scale settings.  UpdateIndicators agrees on the same
    -- outcome (it also branches on testMode flags), so there's no
    -- conflict.
    if testOn then
        local _, ownClass = UnitClass("player")
        _classLoopState.ownClass     = ownClass
        _classLoopState.testFriendly = testFriendly and true or false
        _classLoopState.testEnemy    = testEnemy    and true or false
        for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
            _classLoopState.plate = plate
            pcall(_ClassTestBody)
        end
        return
    end

    -- Normal mode: ONLY touch forbidden plates.  In retail Midnight
    -- arenas, forbidden plates are enemy players.  Their uf.unit may
    -- be anonymized (UnitClass / UnitIsFriend / UnitIsPlayer return
    -- nothing useful), so we use the ArenaMap canonical arena token
    -- to recover class info.  Non-forbidden plates are managed
    -- exclusively by UpdateIndicators per-frame.
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if plate.IsForbidden and plate:IsForbidden() then
            _classLoopState.plate = plate
            pcall(_ClassifyForbiddenBody)
            local cfg       = _classLoopState.cfg
            local classFile = _classLoopState.classFile
            if cfg and classFile then
                pcall(_ApplyClassStampInner)
            else
                local m = plate.MyNP_ClassMarker
                if m and m:IsShown() then
                    pcall(m.Hide, m)
                end
            end
        end
    end
end

function ns:RefreshAllIndicators()
    -- Read-only of the existing ArenaMap state.  The actual map-update
    -- work (BuildCache / RescanDirect / RescanFingerprint / Learn*)
    -- runs only inside the deferred AMListener handler so it can
    -- never taint a secure call chain (RefreshAllIndicators is
    -- routinely invoked from PLAYER_TARGET_CHANGED / arena events).
    pcall(ns.RefreshTargetArrow,    ns)
    pcall(ns.RefreshHealerCrosses,  ns)
    pcall(ns.RefreshClassIcons,     ns)
end

----------------------------------------------------------------------
-- Per-plate update used by Discovery's ApplyOverrides path.  Still
-- handles healer detection for plates we manage normally (friendly
-- NPCs in open world, party members not in arena, etc.).  Doesn't run
-- on forbidden plates — for those, RefreshAllIndicators above does it.
----------------------------------------------------------------------
function ns:UpdateIndicators(plate, unit)
    if not (plate and unit and plate.UnitFrame) then return end
    if plate.IsForbidden and plate:IsForbidden() then return end
    if not (MyNamePlatesDB and MyNamePlatesDB.indicators) then return end

    local I = MyNamePlatesDB.indicators
    local anchorFrame = plate.UnitFrame.healthBar or plate.UnitFrame

    -- TARGET arrow ----------------------------------------------------
    local targetCfg = I.target
    local showTarget = targetCfg and targetCfg.enabled == "1"
        and (UnitIsUnit(unit, "target") or ns.testMode.target)
    if showTarget then
        local tex = _GetTarget(plate)
        if tex then
            _ApplyMarker(tex, anchorFrame, targetCfg)
            -- Tint
            local c = targetCfg.color
            if c then
                tex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
            else
                tex:SetVertexColor(1, 1, 1, 1)
            end
            tex:Show()
        end
    elseif plate.MyNP_TargetMarker then
        plate.MyNP_TargetMarker:Hide()
    end

    -- HEALER cross ----------------------------------------------------
    local healerCfg
    local isFriend = UnitIsFriend("player", unit)
    if isFriend then
        healerCfg = I.healerFriendly
    else
        healerCfg = I.healerEnemy
    end

    -- Pick the right test flag for THIS plate's faction (the previous
    -- single-line version had a precedence bug that caused the enemy
    -- test mode to also light up friendly plates).
    local healerTest
    if isFriend then
        healerTest = ns.testMode.healerFriendly
    else
        healerTest = ns.testMode.healerEnemy
    end

    if healerCfg and healerCfg.enabled == "1"
       and (IsHealer(unit) or healerTest) then
        local tex = _GetHealer(plate)
        if tex then
            _ApplyMarker(tex, anchorFrame, healerCfg)
            local c = healerCfg.color
            if c then
                tex:SetDesaturated(true)
                tex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
            else
                -- Default colours: friendly = native green, enemy = red
                tex:SetDesaturated(not isFriend)
                if isFriend then
                    tex:SetVertexColor(1, 1, 1, 1)
                else
                    tex:SetVertexColor(1, 0.15, 0.15, 1)
                end
            end
            tex:Show()
        end
    elseif plate.MyNP_HealerMarker then
        plate.MyNP_HealerMarker:Hide()
    end

    -- CLASS icon -----------------------------------------------------
    local classCfg = isFriend and I.classFriendly or I.classEnemy
    local classTest = isFriend and ns.testMode.classFriendly
                                or ns.testMode.classEnemy
    if classCfg and classCfg.enabled == "1"
       and (UnitIsPlayer(unit) or classTest) then
        local _, ownClass = UnitClass("player")
        local classFile = (UnitIsPlayer(unit) and _GetClassFile(plate, unit)) or ownClass
        local tex = _GetClassIcon(plate)
        if tex and classFile and _ApplyClassTex(tex, classFile) then
            _ApplyMarker(tex, anchorFrame, classCfg)
            tex:SetVertexColor(1, 1, 1, 1)
            tex:Show()
        elseif plate.MyNP_ClassMarker then
            plate.MyNP_ClassMarker:Hide()
        end
    elseif plate.MyNP_ClassMarker then
        plate.MyNP_ClassMarker:Hide()
    end
end

----------------------------------------------------------------------
-- Helper to read an indicator's saved config (used by the UI)
----------------------------------------------------------------------
function ns:GetIndicatorConfig(key)
    return MyNamePlatesDB and MyNamePlatesDB.indicators and MyNamePlatesDB.indicators[key]
end

function ns:SetIndicatorOption(key, field, value)
    if not (MyNamePlatesDB and MyNamePlatesDB.indicators) then return end
    local cfg = MyNamePlatesDB.indicators[key]
    if not cfg then return end
    cfg[field] = value
    -- Refresh both paths: the per-active-plate overrides AND the
    -- direct-lookup indicator paths (for forbidden arena plates).
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
    if ns.RefreshAllIndicators then ns:RefreshAllIndicators() end
end

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
-- 1.36.36: UnitIsProbablyUnit — name-based unit match.
--
-- Credit: adopted from BetterBlizzPlates (midnight/modules/arenaid.lua
-- ~line 100), whose author explicitly requested attribution in a
-- source comment.  Their pattern is the canonical retail-12.x way to
-- bind an anonymised nameplate token to an arena/party slot.
--
-- Why we need it:
--   In retail Midnight (12.x), Blizzard's anti-scripting layer makes
--   UnitIsUnit(nameplateToken, "arenaN") return FALSE at gate open —
--   even when the underlying physical unit is the same player.  The
--   token remains "anonymised" until the client learns the identity
--   through interaction (target / mouseover / focus).  This starves
--   every downstream binding (_LinkVisiblePlatesToArena,
--   AM:RescanDirect, AM:LearnFromIntermediary), which is why classes
--   and healer crosses only appeared after a mouseover before this
--   fix.
--
-- Why UnitName works when UnitIsUnit does not:
--   UnitName is exempt from the anti-scripting redaction because it's
--   used ubiquitously for combat-log display, nameplate labels, and
--   tooltip text.  Both nameplateN and arenaN tokens return the real
--   player name for the same physical unit at gate open — so a name
--   comparison reliably binds plate -> arena slot with zero user
--   interaction required.
--
-- Safety:
--   Read-only Unit API calls (UnitExists + UnitName), no state
--   mutation, no forbidden-frame contact, no taint surface.  Safe to
--   call from any context.
----------------------------------------------------------------------
local function _UnitIsProbablyUnit(unit1, unit2)
    if not unit1 or not unit2 then return false end
    if not UnitExists(unit1) or not UnitExists(unit2) then return false end
    local name1 = UnitName(unit1)
    local name2 = UnitName(unit2)
    if not name1 or not name2 then return false end
    -- 1.36.39: mirror BBP midnight's issecretvalue guard.  Without
    -- it, two anonymised tokens whose UnitName both return the SAME
    -- placeholder secret string collide equal — falsely matching a
    -- friendly plate to an arena opponent slot.  Symptom that
    -- surfaced this: friendly healer got the RED enemy cross in
    -- 1.36.38 because AM:RescanDirect / _LinkVisiblePlatesToArena
    -- tagged the friendly plate with an arena index, then
    -- _HealerEnemyBody's arenaUnit override forced isFriend=false.
    -- Verified against BetterBlizzPlates/midnight/modules/arenaid.lua
    -- line 100.
    if issecretvalue and (issecretvalue(name1) or issecretvalue(name2)) then
        return false
    end
    return name1 == name2
end
ns.UnitIsProbablyUnit = _UnitIsProbablyUnit

----------------------------------------------------------------------
-- 1.36.15: ARENA PREP CACHE (sArena-parity)
--
-- Blizzard fires `ARENA_PREP_OPPONENT_SPECIALIZATIONS` during the
-- gate/prep phase BEFORE any plate exists.  `GetArenaOpponentSpec(i)`
-- returns each opponent's specID at that point.  From the specID we
-- can derive spec name + class file + role via GetSpecializationInfoByID.
-- sArena caches this and never guesses again — it's the authoritative
-- source of truth for who each of the 3 arena slots is.
--
-- We adopt the same pattern here.  The prep cache is separate from
-- ArenaMap's `arenaCache` (which is a plate-matching fingerprint
-- keyed by class/race/sex/power) because we want the prep data
-- available even before any plate spawns, and we want it to survive
-- ArenaMap's periodic wipes.
--
-- Downstream consumers:
--   * RefreshHealerCrosses  -> iterate ARENA_PREP, find slots whose
--                              isHealer==true, look up their plate via
--                              _plateByArena, stamp the cross.
--   * Labels _GetSpecName   -> when _specByPlate is empty but ArenaMap
--                              has a definitive binding, fall through
--                              to ARENA_PREP[idx].specName.
--   * _CaptureSpecFromToken -> after target/mouseover capture, check
--                              UnitIsUnit(token, "arenaN") to establish
--                              _plateByArena[N] once, then seed the
--                              per-plate spec+class caches from prep
--                              data (which is authoritative and
--                              correct even when the tooltip is
--                              partially anonymised).
----------------------------------------------------------------------
ns.ARENA_PREP = {}  -- [1..3] = { specID, specName, classFile, className, isHealer }

function ns:RefreshArenaPrep()
    if not GetArenaOpponentSpec then return end
    if not GetSpecializationInfoByID then return end
    for i = 1, 3 do
        local ok, specID = pcall(GetArenaOpponentSpec, i)
        if ok and specID and specID ~= 0 then
            local ok2, _, sName, _, _, _, classFile, className =
                pcall(GetSpecializationInfoByID, specID)
            if ok2 and classFile then
                ns.ARENA_PREP[i] = {
                    specID    = specID,
                    specName  = sName,
                    classFile = classFile,
                    className = className,
                    isHealer  = (ns.HEALER_SPECS and ns.HEALER_SPECS[specID]) and true or false,
                }
            end
        else
            ns.ARENA_PREP[i] = nil
        end
    end
end

function ns:GetArenaPrepInfo(idx)
    return idx and ns.ARENA_PREP[idx] or nil
end

-- Definitive plate <-> arena-slot linkage.  Populated only from
-- authoritative signals (target / mouseover / focus UnitIsUnit hits),
-- NEVER from fingerprint match.  Separate from ArenaMap because
-- ArenaMap's binding can be wrong in ambiguous teams; this table is
-- only ever written when we KNOW the plate is a specific arenaN.
local _plateByArena = {}
local _arenaByPlate = {}

function ns:GetPlateByArena(idx)
    return idx and _plateByArena[idx] or nil
end

function ns:GetArenaByPlate(plate)
    return plate and _arenaByPlate[plate] or nil
end

-- Establish a definitive plate -> arena binding, and (as a side
-- effect) seed the per-plate spec + class caches from ARENA_PREP so
-- every downstream lookup (spec label, class icon, health-bar color,
-- healer cross) gets correct data immediately.  Safe to call
-- repeatedly — idempotent if the binding is unchanged.
function ns:LinkPlateToArena(plate, idx)
    if not (plate and idx and idx >= 1 and idx <= 3) then return end

    -- Displace any stale binding for this idx or plate.  If the
    -- same plate frame was previously bound to a different slot
    -- (arena roster rotation, plate frame recycled, etc.), we
    -- overwrite so the newest signal wins.
    local oldIdxForPlate = _arenaByPlate[plate]
    if oldIdxForPlate and oldIdxForPlate ~= idx then
        _plateByArena[oldIdxForPlate] = nil
    end
    local oldPlateForIdx = _plateByArena[idx]
    if oldPlateForIdx and oldPlateForIdx ~= plate then
        _arenaByPlate[oldPlateForIdx] = nil
    end
    _plateByArena[idx] = plate
    _arenaByPlate[plate] = idx

    -- Mirror the definitive binding into ArenaMap so ArenaMap-based
    -- consumers (spec fallback, class-file fallback, aura pipeline)
    -- also see the correct mapping — and so any prior mis-tag from
    -- fingerprint match gets displaced.
    if AM and AM.Tag then pcall(AM.Tag, AM, plate, idx) end

    -- Seed per-plate spec + class caches from prep data.  These are
    -- non-destructive: if the user's target/mouseover capture already
    -- stored a value, we don't overwrite.  Prep-data values are only
    -- filled in when the cache is empty.
    local prep = ns.ARENA_PREP[idx]
    if prep then
        if ns.GetSpecByPlate and ns.SetSpecByPlate then
            local existing = ns:GetSpecByPlate(plate)
            if (not existing) and prep.specName then
                ns:SetSpecByPlate(plate, prep.specName)
            end
        end
        if ns.GetClassByPlate and ns.SetClassByPlate then
            local existing = ns:GetClassByPlate(plate)
            if (not existing) and prep.classFile then
                ns:SetClassByPlate(plate, prep.classFile)
            end
        end
    end
end

function ns:UnlinkPlateFromArena(plate)
    if not plate then return end
    local idx = _arenaByPlate[plate]
    if idx then _plateByArena[idx] = nil end
    _arenaByPlate[plate] = nil
end

function ns:WipeArenaLinks()
    wipe(_plateByArena)
    wipe(_arenaByPlate)
end

-- Attempt to link every currently-visible plate to its arena slot.
-- Called whenever prep data lands or arena rosters change.  Iterates
-- all plates and asks Blizzard "which arena unit are you?" via
-- signals in order of confidence:
--   1. UnitIsUnit(uf.unit, "arenaN") — authoritative when it works.
--   2. UnitIsProbablyUnit(uf.unit, "arenaN") — 1.36.36 BBP-style
--      name match; the ONLY signal that works at gate open on retail
--      12.x anonymised plates, because UnitIsUnit is redacted by the
--      anti-scripting layer until first interaction.  Root fix for
--      the "have to mouseover for classes/healer cross" symptom.
--   3. C_NamePlate.GetNamePlateForUnit("arenaN") returned this plate.
-- On any hit, LinkPlateToArena cements the binding and seeds caches.
local function _LinkVisiblePlatesToArena()
    if not _IsInArena() then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    if not ns.LinkPlateToArena then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        if not (ns.GetArenaByPlate and ns:GetArenaByPlate(plate)) then
            local uf = plate.UnitFrame
            local unit = uf and (uf.unit or uf.displayedUnit)
            for i = 1, 3 do
                local matched
                if unit and UnitIsUnit then
                    local ok, r = pcall(UnitIsUnit, unit, "arena" .. i)
                    if ok and r then matched = true end
                end
                if (not matched) and unit then
                    -- 1.36.36: BBP-style name match.  This is the
                    -- key signal at gate open — UnitIsUnit returns
                    -- false for anonymised nameplate tokens even
                    -- against arena1..3 targets, but UnitName still
                    -- returns real names on both sides.
                    local ok, r = pcall(_UnitIsProbablyUnit, unit, "arena" .. i)
                    if ok and r then matched = true end
                end
                if (not matched) and C_NamePlate.GetNamePlateForUnit then
                    local ok, p = pcall(C_NamePlate.GetNamePlateForUnit,
                                        "arena" .. i, true)
                    if ok and p == plate then matched = true end
                end
                if matched then
                    pcall(ns.LinkPlateToArena, ns, plate, i)
                    break
                end
            end
        end
    end
end

-- Event listener for prep-phase data.  Runs synchronously (no defer)
-- because the calls we make (GetArenaOpponentSpec / GetSpecializationInfoByID)
-- are pure data-only APIs that don't touch secure state.
local ArenaPrepListener = CreateFrame("Frame")
ArenaPrepListener:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
ArenaPrepListener:RegisterEvent("ARENA_OPPONENT_UPDATE")
ArenaPrepListener:RegisterEvent("PVP_MATCH_ACTIVE")
ArenaPrepListener:RegisterEvent("PVP_MATCH_STATE_CHANGED")
ArenaPrepListener:RegisterEvent("PLAYER_ENTERING_WORLD")
ArenaPrepListener:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ArenaPrepListener:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        wipe(ns.ARENA_PREP)
        pcall(ns.WipeArenaLinks, ns)
    end
    pcall(ns.RefreshArenaPrep, ns)
    -- Try to link visible plates before kicking the refresh cascade.
    -- Deferred so we don't compete with AMListener's own defer for
    -- the same events — LinkVisiblePlates piggybacks on whatever
    -- state AMListener produces plus prep data.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            pcall(_LinkVisiblePlatesToArena)
            if ns.RefreshAllIndicators then pcall(ns.RefreshAllIndicators, ns) end
            if ns.RefreshAllLabels     then pcall(ns.RefreshAllLabels,     ns) end
        end)
    else
        pcall(_LinkVisiblePlatesToArena)
        if ns.RefreshAllIndicators then pcall(ns.RefreshAllIndicators, ns) end
        if ns.RefreshAllLabels     then pcall(ns.RefreshAllLabels,     ns) end
    end
end)

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
--
-- 1.36.36: added UnitIsProbablyUnit (name-based) fallback for retail
-- 12.x anonymised gate-open plates where UnitIsUnit returns false.
-- Same guarantee level as UnitIsUnit for our purposes: both plate and
-- arenaN return real names from UnitName, and player-name collisions
-- across three opposing arena slots aren't a real concern.
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
                    local matched
                    local ok, isUnit = pcall(UnitIsUnit, unit, "arena" .. i)
                    if ok and isUnit then matched = true end
                    if not matched then
                        -- 1.36.36: BBP-style name match rescues
                        -- anonymised gate-open plates that UnitIsUnit
                        -- refuses to compare.  Uses pcall for the
                        -- same defensive reason as the UnitIsUnit
                        -- call above (unknown API surface on some
                        -- token combinations).
                        local ok2, r = pcall(_UnitIsProbablyUnit, unit, "arena" .. i)
                        if ok2 and r then matched = true end
                    end
                    if matched then
                        self:Tag(plate, i)
                        -- 1.36.16: escalate to definitive linkage.
                        -- UnitIsUnit / UnitIsProbablyUnit are both
                        -- authoritative for this purpose — if either
                        -- says the plate IS arenaN, we know it with
                        -- high certainty (unlike fingerprint match,
                        -- which guesses from race/sex/power).
                        -- LinkPlateToArena will also seed the per-
                        -- plate spec + class caches from ARENA_PREP,
                        -- so the plate renders correct data on the
                        -- very first NAME_PLATE_UNIT_ADDED tick with
                        -- no user interaction required.
                        if ns.LinkPlateToArena then
                            pcall(ns.LinkPlateToArena, ns, plate, i)
                        end
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

    -- Identify which arena slot the intermediary IS.  UnitIsUnit is
    -- authoritative when it works; the 1.36.36 name-match fallback
    -- covers the rare case where the intermediary is one of the
    -- redacted tokens (e.g. `mouseover` referencing an anonymised
    -- arena plate) that UnitIsUnit still refuses to compare.
    local matchedArena
    for i = 1, 3 do
        local ok, isUnit = pcall(UnitIsUnit, intermediary, "arena" .. i)
        if ok and isUnit then matchedArena = i; break end
        local ok2, r = pcall(_UnitIsProbablyUnit, intermediary, "arena" .. i)
        if ok2 and r then matchedArena = i; break end
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
                -- 1.36.36: same name-based fallback for the reverse
                -- lookup — find the plate whose unit shares a name
                -- with the intermediary when UnitIsUnit refuses.
                local ok2, r = pcall(_UnitIsProbablyUnit, unit, intermediary)
                if ok2 and r then plate = p; break end
            end
        end
    end
    if plate then
        self:Tag(plate, matchedArena)
        -- 1.36.16: escalate to definitive linkage on any intermediary
        -- hit so the plate <-> arena binding survives ArenaMap wipes
        -- and downstream lookups (spec, class, healer cross) get the
        -- authoritative prep-data path.
        if ns.LinkPlateToArena then
            pcall(ns.LinkPlateToArena, ns, plate, matchedArena)
        end
    end
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
        --
        -- 1.36.40: also clear the sticky healer cache so a recycled
        -- plate frame doesn't inherit the previous unit's healer
        -- classification.
        -- 1.36.42: MyNP_KnownEnemyHealer removed (see _HealerEnemyBody
        -- for revert rationale).  MyNP_IsHealerCache from 1.36.40
        -- remains — that one is a strictly safer per-call cache set
        -- only from within _IsHealerForPlate's wrapper.
        if arg1 then
            local plate = C_NamePlate.GetNamePlateForUnit(arg1, true)
            if plate then
                plate.MyNP_IsHealerCache = nil
                AM:Untag(plate)
            end
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
-- 1.36.14: parallel set of just the localized spec NAMES ("Discipline",
-- "Restoration", "Holy", "Preservation", "Mistweaver") without the
-- appended class token.  Every one of these spec names is unique to
-- healer specs (Restoration is Druid+Shaman, both healers; Holy is
-- Priest+Paladin, both healers; the rest are class-unique).  Used to
-- classify a plate as a healer purely by the cached per-plate spec
-- name from Labels.lua's _specByPlate — which is what
-- _GetSpecByTooltip returns (spec name only, no class).  This lets
-- the healer cross ride the same authoritative signal as the spec
-- label, bypassing ArenaMap entirely.
ns.HEALER_SPEC_ONLY_NAMES = nil
local function _BuildHealerSpecNames()
    if ns.HEALER_SPEC_NAMES then return end
    local names = {}
    local specOnly = {}
    if not GetSpecializationInfoByID then
        ns.HEALER_SPEC_NAMES      = names
        ns.HEALER_SPEC_ONLY_NAMES = specOnly
        return
    end
    for specID in pairs(ns.HEALER_SPECS) do
        local ok, _, specName, _, _, _, _, classFile =
            pcall(GetSpecializationInfoByID, specID)
        if ok and specName and classFile then
            if specName ~= "" then specOnly[specName] = specID end
            local male   = LOCALIZED_CLASS_NAMES_MALE   and LOCALIZED_CLASS_NAMES_MALE[classFile]
            local female = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classFile]
            if male   then names[specName .. " " .. male]   = specID end
            if female and female ~= male then
                names[specName .. " " .. female] = specID
            end
        end
    end
    ns.HEALER_SPEC_NAMES      = names
    ns.HEALER_SPEC_ONLY_NAMES = specOnly
end
ns.BuildHealerSpecNames = _BuildHealerSpecNames

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
--
-- 1.36.38: added BBP-style inline UnitIsProbablyUnit probe as a
-- third fallback for the case where ArenaMap binding hasn't yet
-- resolved when the check runs.  This is a direct crib of BBP's
-- IsSpecHealer branch for issecretvalue(guid) plates
-- (BetterBlizzPlates.lua ~line 6584), verified against their
-- midnight retail branch.  Bypasses persistent binding entirely
-- and asks Blizzard on-demand which arena slot this plate is by
-- name — the ONLY path that reliably fires at the very first
-- refresh tick, BEFORE _LinkVisiblePlatesToArena has run its
-- deferred pass.
--
-- Why classes don't need this: _GetClassFile primary #1
-- (UnitClass(unit)) returns real class file even on anonymised
-- tokens in retail 12.x, so class icons render without any
-- binding.  Healer detection has no equivalent primary — role /
-- arena-spec via UnitIsUnit / tooltip all fail on anonymised —
-- so we absolutely need the inline arena-slot probe.
local function _IsHealerForPlate(plate, unit)
    if unit and IsHealer(unit) then return true end
    local arenaUnit, idx = plate and ns:GetArenaUnitForPlate(plate)
    if idx then
        local specID = GetArenaOpponentSpec and GetArenaOpponentSpec(idx)
        if specID and ns.HEALER_SPECS[specID] then return true end
        if arenaUnit and _IsHealerByTooltip(arenaUnit) then return true end
    end
    -- 1.36.39: skip the inline probe when unit is a confirmed
    -- friendly.  Party healer detection is already handled by
    -- IsHealer(unit) above (UnitGroupRolesAssigned works for
    -- teammates); running the arena probe on friendlies risks
    -- flipping non-healer friendly plates into HEALER territory
    -- if a name coincidentally matches an arena opponent slot
    -- (or if secret-secret name collision slips past the
    -- issecretvalue guard).
    if unit and _IsInArena() and GetArenaOpponentSpec then
        local okF, isFriendlyUnit = pcall(UnitIsFriend, "player", unit)
        if not (okF and isFriendlyUnit) then
            for i = 1, 3 do
                local ok, r = pcall(_UnitIsProbablyUnit, unit, "arena" .. i)
                if ok and r then
                    local specID = GetArenaOpponentSpec(i)
                    if specID and ns.HEALER_SPECS[specID] then return true end
                    break
                end
            end
        end
    end
    return false
end

----------------------------------------------------------------------
-- 1.36.40: sticky per-plate healer cache.
--
-- Retail 12.x anti-scripting can make UnitName / UnitIsUnit /
-- UnitGroupRolesAssigned / GetArenaOpponentSpec return valid data
-- one tick and secret-redacted the next.  Without stickiness this
-- causes the healer cross to FLICKER — one RefreshHealerCrosses
-- pass stamps the cross when the probe succeeds, then
-- UpdateIndicators fires 100 ms later, gets a false from
-- _IsHealerForPlate because a required API transiently returned
-- nothing, and hides the marker.
--
-- Fix: wrap _IsHealerForPlate in a sticky cache keyed on the plate
-- frame.  Once we successfully classify a plate as healer, keep
-- it classified until Blizzard recycles the plate for a new unit
-- (NAME_PLATE_UNIT_REMOVED, handled below in the AMListener).  A
-- plate never legitimately transitions from healer to non-healer
-- for the same unit — the only failure mode is transient API
-- unavailability, so stickiness is safe.
--
-- Mirrors BBP.SpecCache[guid] pattern (BetterBlizzPlates.lua
-- ~line 6620): cache the positive result to survive
-- Blizzard's data-availability jitter.
local _IsHealerForPlate_uncached = _IsHealerForPlate
_IsHealerForPlate = function(plate, unit)
    if plate and plate.MyNP_IsHealerCache then return true end
    local r = _IsHealerForPlate_uncached(plate, unit)
    if r and plate then plate.MyNP_IsHealerCache = true end
    return r
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
----------------------------------------------------------------------
local function _NewMarker(uf, atlas)
    local tex = uf:CreateTexture(nil, "OVERLAY", nil, 7)
    tex:SetAtlas(atlas)
    tex:Hide()
    return tex
end

-- Skip UnitFrames whose forbidden flag would taint CreateTexture.
--
-- 1.36.34: check ONLY the UnitFrame's forbidden status, not the
-- top-level nameplate's — matching BBP (BetterBlizzPlates.lua
-- ~5349), our own Labels._IsForbidden, and the explicit v1.24.0
-- rationale documented in Labels.lua:
--
--   In retail Midnight, arena pet & totem plates (and the arena
--   enemy player plates that carry anonymised unit tokens) can
--   have a forbidden top-level plate but a NON-forbidden
--   UnitFrame.  Modifying uf.name / creating textures on the
--   non-forbidden uf is safe in that case.  Earlier "check both"
--   behaviour blocked us from rendering on those plates — the
--   root cause of RefreshClassIcons walking forbidden plates but
--   _GetClassIcon refusing to create the icon there.
--
-- The taint vector is CreateTexture as a child of a forbidden
-- parent: it propagates the forbidden flag to the child, which
-- then propagates addon taint on subsequent secure actions.
-- Since we parent to `uf`, uf's forbidden status is what matters
-- — plate:IsForbidden() is orthogonal.
local function _IsForbidden(plate, uf)
    if uf and uf.IsForbidden and uf:IsForbidden() then return true end
    return false
end

local function _GetTarget(plate)
    if plate.MyNP_TargetMarker then return plate.MyNP_TargetMarker end
    local uf = plate.UnitFrame
    if not uf then return nil end
    if _IsForbidden(plate, uf) then return nil end
    -- Down-pointing tracking arrow (Blizzard atlas, same as BBP uses).
    local tex = _NewMarker(uf, "Navigation-Tracked-Arrow")
    tex:SetSize(14, 9)
    plate.MyNP_TargetMarker = tex
    return tex
end

local function _GetHealer(plate)
    if plate.MyNP_HealerMarker then return plate.MyNP_HealerMarker end
    local uf = plate.UnitFrame
    if not uf then return nil end
    -- 1.36.34: restore the _IsForbidden guard to match the v1.24.0
    -- working reference (Desktop\MyNamePlates\Indicators.lua line
    -- 662).  The 1.36.22 comment previously claimed v1.24.0 had no
    -- guard — that was a misread; v1.24.0 clearly guards.  Aligning
    -- back with the reference also aligns with _GetTarget and
    -- _GetClassIcon which have kept the guard the entire time.
    --
    -- _IsForbidden is uf-only as of 1.36.34, so this permits crosses
    -- on plates whose top-level is forbidden but whose UnitFrame is
    -- not — the shape retail Midnight 12.x uses for anonymised
    -- arena enemy plates.  Only truly uf-forbidden plates (rare)
    -- are skipped, which is the correct taint-safe behaviour.
    if _IsForbidden(plate, uf) then return nil end
    -- Direct uf:CreateTexture — same call sequence _GetTarget and
    -- _GetClassIcon use in this file, same one BBP uses for its
    -- healer cross once you strip the BBP-parity container Frame
    -- machinery (1.36.19-1.36.21 tried the container path and it
    -- was overengineered relative to what retail 12.x needs).
    -- Every setter is pcall-guarded so a plate that refuses a
    -- specific call fails soft rather than propagating the error.
    local tex = _NewMarker(uf, "greencross")
    if not tex then return nil end
    pcall(tex.SetSize, tex, 14, 14)
    -- Trim away ugly white pixels around the atlas border.
    pcall(tex.SetTexCoord, tex, 0.1953125, 0.8046875, 0.1953125, 0.8046875)
    -- 1.36.19 also introduced SetIgnoreParentAlpha to match the class
    -- icon's flicker immunity during target-fade / in-combat alpha
    -- ramps.  Keep that improvement — it doesn't affect the render
    -- path, only prevents the cross from following the UnitFrame's
    -- alpha animator.
    if tex.SetIgnoreParentAlpha then
        pcall(tex.SetIgnoreParentAlpha, tex, true)
    end
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
    if _IsForbidden(plate, uf) then return nil end
    local tex = uf:CreateTexture(nil, "OVERLAY", nil, 7)
    tex:SetSize(22, 22)        -- base size; user scale multiplies on top
    -- Decouple from the UnitFrame's alpha animations (target-fade,
    -- in-combat alpha, distance fade).  Without this, the engine's
    -- animator can briefly drive parent alpha to 0/intermediate values
    -- during target swaps and the icon flickers.  BBP does the same.
    if tex.SetIgnoreParentAlpha then
        pcall(tex.SetIgnoreParentAlpha, tex, true)
    end
    tex:Hide()
    plate.MyNP_ClassMarker = tex
    return tex
end

-- Returns the english classFile ("WARRIOR", "MAGE", etc.).
--
-- 1.36.35: primary paths are byte-for-byte the v1.24.0 working
-- reference (Desktop\MyNamePlates\Indicators.lua line 702-713):
-- direct UnitClass on the plate token, then UnitClass on the
-- ArenaMap canonical arenaN token, then nil.  No issecretvalue
-- guards, no reordering — literally the old code.
--
-- The additive fallbacks (per-plate class cache from Labels.lua
-- capture, and ARENA_PREP.classFile via definitive _arenaByPlate
-- linkage) run STRICTLY after both v1.24.0 paths return nil, so
-- they behave as pure fallback: they never preempt v1.24.0's
-- return contract.
--
-- Prior versions (1.36.33/34) had issecretvalue guards on the
-- primary paths to defend _ApplyClassTex's string.lower call
-- against tainted input.  That defense re-routed some retail
-- 12.x anonymised-plate cases through the additive fallbacks,
-- and if _arenaByPlate had any wrong-seeded binding the fallback
-- rendered the wrong slot's class icon at gate open ("sometimes
-- wrong class" symptom).  v1.24.0's behaviour on a secret
-- classFile is that _ApplyClassTex fails cleanly with no icon
-- — a better outcome than a wrong icon.
local function _GetClassFile(plate, unit)
    -- v1.24.0 PRIMARY #1 -- byte-identical to reference line 703-706.
    if unit then
        local _, classFile = UnitClass(unit)
        if classFile then return classFile end
    end
    -- v1.24.0 PRIMARY #2 -- byte-identical to reference line 707-711.
    local arenaUnit = plate and ns:GetArenaUnitForPlate(plate)
    if arenaUnit then
        local _, cf = UnitClass(arenaUnit)
        if cf then return cf end
    end
    -- 1.36.13 ADDITIVE FALLBACK: per-plate class cache populated
    -- by Labels.lua's _CaptureSpecFromToken on target/mouseover.
    -- Reached only when v1.24.0 paths both returned nil (unit is
    -- nil AND no ArenaMap binding).  Values are always correct
    -- when set — they come from non-secret target/mouseover
    -- tokens.
    if plate and ns.GetClassByPlate then
        local cached = ns:GetClassByPlate(plate)
        if cached then return cached end
    end
    -- 1.36.15 ADDITIVE FALLBACK: definitive arena linkage ->
    -- ARENA_PREP classFile.  _arenaByPlate is set only from
    -- definitive UnitIsUnit hits (target / focus / mouseover
    -- matching arena1..3, plus C_NamePlate.GetNamePlateForUnit
    -- ("arenaN") returning this plate), so guaranteed correct
    -- when populated.  Fills the gap when everything above
    -- returned nil.
    if plate and ns.GetArenaByPlate then
        local idx = ns:GetArenaByPlate(plate)
        local prep = idx and ns.ARENA_PREP and ns.ARENA_PREP[idx]
        if prep and prep.classFile then return prep.classFile end
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
    -- 1.36.22: _GetHealer returns a bare Texture again (v1.24.0 path).
    -- Direct Texture:SetDesaturated / SetVertexColor / Show — this is
    -- the exact call sequence the user's Desktop\MyNamePlates working
    -- reference uses.  Every call pcall-wrapped so a rare plate that
    -- refuses a specific method fails soft.
    local tex = _GetHealer(plate)
    if not tex then return end
    _ApplyMarker(tex, _SafeAnchorFor(plate), cfg)
    local c = cfg.color
    if c then
        pcall(tex.SetDesaturated, tex, true)
        pcall(tex.SetVertexColor, tex,
              c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
    else
        pcall(tex.SetDesaturated, tex, not isFriend)
        if isFriend then
            pcall(tex.SetVertexColor, tex, 1, 1, 1, 1)
        else
            pcall(tex.SetVertexColor, tex, 1, 0.15, 0.15, 1)
        end
    end
    pcall(tex.Show, tex)
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
    -- 1.36.42: reverted 1.36.41's MyNP_KnownEnemyHealer early re-stamp
    -- — it regressed detection ("Red cross on enemy healer is now not
    -- working").  The sticky flag idea was sound in principle
    -- (mirroring BBP's SpecCache[guid]), but pcall failure or forbidden-
    -- frame field-set semantics on retail Midnight 12.x anonymised
    -- plates was preventing the early return from firing, and the
    -- surrounding pcall in RefreshHealerCrosses's enemy-walk loop was
    -- silently swallowing the failure — leaving the plate un-stamped
    -- entirely.  1.36.40's wrapped _IsHealerForPlate cache remains in
    -- place; it's a strictly-safer per-call cache that only sticks
    -- once _IsHealerForPlate itself has been reached and returned true.
    local uf = plate and plate.UnitFrame
    local punit = uf and (uf.unit or uf.displayedUnit)
    local arenaUnit = ns:GetArenaUnitForPlate(plate)

    -- 1.36.38: BBP-style inline fallback when persistent ArenaMap
    -- binding hasn't yet resolved.  UnitIsProbablyUnit(punit,
    -- "arenaN") matches by name — the ONLY signal that reliably
    -- fires at the first refresh tick before
    -- _LinkVisiblePlatesToArena's deferred pass has run.
    --
    -- 1.36.39: only run the probe when punit is NOT confirmed
    -- friendly.  In 1.36.38 this fired on every plate whose
    -- ArenaMap binding hadn't resolved — including friendlies — and
    -- when _UnitIsProbablyUnit's missing issecretvalue guard let
    -- secret-secret names collide equal, we ended up tagging
    -- friendly plates with arena indices.  That in turn made the
    -- arenaUnit branch below force isFriend=false and stamp the
    -- red enemy cross on our own healer.
    if not arenaUnit and punit and _IsInArena() then
        local okF, isFriendlyPUnit = pcall(UnitIsFriend, "player", punit)
        if not (okF and isFriendlyPUnit) then
            for i = 1, 3 do
                local ok, r = pcall(_UnitIsProbablyUnit, punit, "arena" .. i)
                if ok and r then arenaUnit = "arena" .. i; break end
            end
        end
    end

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

-- 1.36.33: helper to detect an already-stamped healer marker so
-- additive fallback passes can skip plates the primary v1.24.0
-- walk already handled.  A double-stamp is technically idempotent
-- but skipping the extra work also prevents any future additive
-- path from over-writing a correct primary stamp with a wrong one.
local function _PlateHasHealerMark(plate)
    local m = plate and plate.MyNP_HealerMarker
    if not m then return false end
    local ok, shown = pcall(m.IsShown, m)
    return ok and shown and true or false
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

    -- ── Friendly healers ──────────────────────────────────────────
    -- Party1..4 (+ player).  Same as the v1.24.0 reference.  Non-
    -- forbidden plates so we can trust UnitIsUnit / GetNamePlateForUnit
    -- directly.
    for i = 0, 4 do
        local unit = (i == 0) and "player" or ("party" .. i)
        if UnitExists(unit) and IsHealer(unit) then
            local plate = C_NamePlate.GetNamePlateForUnit(unit, true)
            if plate then
                _ApplyHealerMarkerOnPlate(plate, true, I.healerFriendly)
            end
        end
    end

    if not (I.healerEnemy and I.healerEnemy.enabled == "1"
            and C_NamePlate.GetNamePlates) then
        return
    end

    -- ── v1.24.0 PRIMARY: enemy plate walk ────────────────────────
    -- The exact pattern from the user's working reference
    -- (`C:\Users\Jgcol\OneDrive\Desktop\MyNamePlates\Indicators.lua`,
    -- v1.24.0, and our own git tag v1.34.2 before the 1.36.11-
    -- 1.36.17 arena chain of experimental fixes).  For each
    -- visible plate:
    --   1. Read per-plate `unit` (or `displayedUnit`) if present.
    --   2. Resolve friend / player status via that unit, with an
    --      ArenaMap-binding override (arena enemies are, by
    --      definition, non-friend players even when the token is
    --      anonymised).
    --   3. Call _IsHealerForPlate(plate, unit) which uses:
    --        a. IsHealer(unit) → role / arena-spec / tooltip
    --        b. GetArenaOpponentSpec via ArenaMap.plateToIndex
    --        c. _IsHealerByTooltip on the canonical arenaN token
    -- This is the SOURCE OF TRUTH.  Everything below is additive
    -- and gated on _PlateHasHealerMark(plate) so it can only ADD
    -- crosses to plates the primary walk didn't handle.
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        _healerLoopState.plate = plate
        pcall(_HealerEnemyBody)
    end

    -- ── ADDITIVE #1: per-plate spec cache ─────────────────────────
    -- 1.36.14 gate-open path.  The per-plate spec name cache is
    -- populated by Labels.lua's _CaptureSpecFromToken from the
    -- non-secret target/mouseover tooltip.  When it says
    -- "Discipline" / "Restoration" / "Holy" / "Preservation" /
    -- "Mistweaver" (all unique to healers), the plate is
    -- unambiguously the healer.  This is ADDITIVE — it only
    -- stamps plates the primary walk missed (e.g. ArenaMap has
    -- no binding for the plate, so _IsHealerForPlate returned
    -- false).  Skip plates the primary already stamped.
    if ns.GetSpecByPlate then
        pcall(_BuildHealerSpecNames)
        local specOnly = ns.HEALER_SPEC_ONLY_NAMES
        if specOnly then
            for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
                if not _PlateHasHealerMark(plate) then
                    pcall(function()
                        local uf   = plate.UnitFrame
                        local unit = uf and (uf.unit or uf.displayedUnit)
                        -- Only enemies.  Friendly plates were
                        -- handled by the party loop above.
                        if unit then
                            local ok, f = pcall(UnitIsFriend, "player", unit)
                            if ok and f then return end
                        end
                        local cached = ns:GetSpecByPlate(plate)
                        if cached and specOnly[cached] then
                            _ApplyHealerMarkerOnPlate(plate, false, I.healerEnemy)
                        end
                    end)
                end
            end
        end
    end

    -- ── ADDITIVE #2: ARENA_PREP + definitive plate linkage ────────
    -- 1.36.15/17 gate-open path, RESTRICTED to trusted sources only.
    -- Iterate the prep cache (from Blizzard's authoritative
    -- GetArenaOpponentSpec) and for every slot flagged isHealer,
    -- look up the plate via `_plateByArena[i]` — which is set ONLY
    -- from definitive UnitIsUnit hits (target / focus / mouseover
    -- / C_NamePlate.GetNamePlateForUnit("arenaN") returning this
    -- plate).  When populated, it's 100% reliable.
    --
    -- 1.36.33: DROPPED the two untrusted fallbacks that made this
    -- pass mis-stamp:
    --   * `AM.indexToPlate[i]` (fingerprint-derived) — could bind
    --     the wrong plate to a slot in ambiguous teams (2 casters
    --     with same power type and anonymised class), so stamping
    --     via that binding put the cross on the wrong enemy.  The
    --     primary v1.24.0 walk above ALREADY consults ArenaMap
    --     via _IsHealerForPlate → GetArenaUnitForPlate, so if
    --     the fingerprint binding is correct the cross has already
    --     been stamped; if the fingerprint binding is wrong,
    --     stamping through AM.indexToPlate here would just
    --     compound the error.
    --   * Class-match walk (find any plate whose class matches
    --     prep.classFile and the class is unique in the enemy
    --     team) — depended on GetClassByPlate cache or UnitClass
    --     on the per-plate token, both of which can misfire when
    --     multiple opponents share a class (duplicate-class comps
    --     are legal in shuffle) or when the per-plate token is
    --     secret and the cache is empty.  This was the primary
    --     source of "wrong enemy has cross" at gate open.
    if _IsInArena() and ns.ARENA_PREP and ns.GetPlateByArena then
        for i = 1, 3 do
            local prep = ns.ARENA_PREP[i]
            if prep and prep.isHealer then
                local plate = ns:GetPlateByArena(i)
                if plate and not _PlateHasHealerMark(plate) then
                    _ApplyHealerMarkerOnPlate(plate, false, I.healerEnemy)
                end
            end
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
    -- 1.36.37: force isFriend=false for arena-bound anonymised plates
    -- so we always use I.healerEnemy config (red cross) instead of
    -- falling into the friendly branch when UnitIsFriend returns nil
    -- on a redacted token.  Arena enemies are, by definition,
    -- non-friend players — same rationale as _HealerEnemyBody and
    -- _ClassifyForbiddenBody's arena-override branches.
    --
    -- 1.36.39: narrow the override to isFriend == nil ONLY.  In
    -- 1.36.38 I used `isFriend ~= false`, which fires for truthy too
    -- — the block was then flipping GENUINELY FRIENDLY plates whose
    -- UnitIsFriend returned 1 to isFriend=false whenever the inline
    -- probe false-matched (secret-secret name collision).  Result
    -- the user saw: friendly healer wearing a red cross.
    --
    -- UnitIsFriend returns:
    --   * 1     -> definitely friendly (party / raid / arena team)
    --   * nil   -> unknown / redacted token (anonymised arena enemy)
    --   * false -> definitely enemy
    --
    -- Only the nil case needs disambiguation.  Both binding and
    -- inline probe are attempted; the inline probe now has the
    -- issecretvalue guard from BBP midnight so it won't false-match
    -- on double-anonymised names.
    if isFriend == nil then
        if ns.GetArenaUnitForPlate and ns:GetArenaUnitForPlate(plate) then
            isFriend = false
        elseif unit and _IsInArena() then
            for i = 1, 3 do
                local ok, r = pcall(_UnitIsProbablyUnit, unit, "arena" .. i)
                if ok and r then isFriend = false; break end
            end
        end
    end
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

    -- 1.36.37: use the plate-aware _IsHealerForPlate instead of raw
    -- IsHealer(unit).  On retail 12.x anonymised arena enemy plates,
    -- IsHealer(unit) always returns false (UnitGroupRolesAssigned
    -- returns "" for the opposing team, _IsHealerByArenaSpec's
    -- UnitIsUnit fails on redacted tokens, and the tooltip may not
    -- yet contain the spec/class line at gate open).  Without this
    -- change, RefreshHealerCrosses would correctly stamp the enemy
    -- cross via the ArenaMap-binding path, then UpdateIndicators
    -- would immediately HIDE it 100 ms later via the `elseif
    -- plate.MyNP_HealerMarker then plate.MyNP_HealerMarker:Hide()`
    -- branch below — because IsHealer(unit) returned false for the
    -- same anonymised token.
    --
    -- _IsHealerForPlate is a strict superset of IsHealer(unit): it
    -- tries IsHealer(unit) first (preserving friendly-party-healer
    -- detection), then falls through to ArenaMap-binding +
    -- GetArenaOpponentSpec — the same authoritative signal
    -- _HealerEnemyBody uses.  Class icons already use the analogous
    -- plate-aware helper (_GetClassFile) which is why classes
    -- survive UpdateIndicators's per-frame rewrite while the healer
    -- cross previously did not.
    -- 1.36.40: when isFriend can't be determined, skip the healer
    -- block entirely and let RefreshHealerCrosses be authoritative.
    -- This mirrors _ClassifyForbiddenBody's nil-bail for class
    -- icons (which is why class icons already survive the
    -- prep-phase data jitter that used to make the healer cross
    -- flicker or paint-wrong-color).
    --
    -- Before this bail:
    --   * Friendly party healer during arena prep -> UnitIsFriend
    --     briefly returned nil, isFriend fell through to enemy,
    --     UpdateIndicators repainted the cross RED for the split
    --     second before UnitIsFriend resolved.
    --   * Anonymised arena enemy where _IsHealerForPlate result
    --     jittered -> UpdateIndicators would Hide() the cross that
    --     RefreshHealerCrosses had just stamped, causing flicker.
    if isFriend ~= nil and healerCfg and healerCfg.enabled == "1"
       and (_IsHealerForPlate(plate, unit) or healerTest) then
        -- 1.36.22: bare Texture return from _GetHealer (v1.24.0 path),
        -- so SetDesaturated / SetVertexColor call directly on tex.
        local tex = _GetHealer(plate)
        if tex then
            _ApplyMarker(tex, anchorFrame, healerCfg)
            local c = healerCfg.color
            if c then
                pcall(tex.SetDesaturated, tex, true)
                pcall(tex.SetVertexColor, tex,
                      c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
            else
                -- Default colours: friendly = native green, enemy = red
                pcall(tex.SetDesaturated, tex, not isFriend)
                if isFriend then
                    pcall(tex.SetVertexColor, tex, 1, 1, 1, 1)
                else
                    pcall(tex.SetVertexColor, tex, 1, 0.15, 0.15, 1)
                end
            end
            pcall(tex.Show, tex)
        end
    elseif isFriend ~= nil and plate.MyNP_HealerMarker then
        -- Same nil-guard on hide: don't hide a marker that
        -- RefreshHealerCrosses may have just stamped just because
        -- _IsHealerForPlate transiently returned false while
        -- Blizzard's API data is jittering.  Sticky healer cache
        -- (MyNP_IsHealerCache) plus this guard together eliminate
        -- the flicker.
        pcall(plate.MyNP_HealerMarker.Hide, plate.MyNP_HealerMarker)
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

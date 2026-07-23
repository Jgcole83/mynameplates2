-- Auras.lua
-- Watched aura indicator: shows an icon over a nameplate whenever the
-- unit has one of the tracked auras active (immunities, big defensives,
-- external defensives, crowd-control).  Configurable position, scale,
-- and editable spell list.
--
-- 1.33.0 rewrite (2026-07-23):
--   * Switched scan engine from AuraUtil.ForEachAura to
--     C_UnitAuras.GetUnitAuras + Blizzard category filters
--     ("HARMFUL|CROWD_CONTROL", "HELPFUL|BIG_DEFENSIVE",
--     "HELPFUL|EXTERNAL_DEFENSIVE").  This picks up every CC / big /
--     external defensive Blizzard classifies WITHOUT requiring us to
--     maintain a per-patch spell-ID list -- adopted from MiniCC v4.6.2
--     (Core/UnitAuraWatcher.lua ~263-424) which is a proven
--     arena-in-retail-Midnight-12.x aura tracker.
--   * Curated AURA_LIST_DEFAULT + user's custom list still take
--     precedence over category detection so users keep their existing
--     priority ordering and can EXPLICITLY DISABLE any entry (e.g.
--     ignore Barkskin) even when Blizzard classifies it as defensive.
--   * Incremental UNIT_AURA path via updateInfo.addedAuras /
--     updatedAuraInstanceIDs / removedAuraInstanceIDs.  We cache the
--     currently-tracked auras per plate (plate.MyNP_ActiveTracked)
--     and apply deltas instead of full-rescanning on every event.
--     Falls back to full scan when updateInfo.isFullUpdate, when the
--     plate has never been scanned, or when the plate has been
--     recycled to a different unit.
--   * Secret-safe classification pattern (`issecretvalue(x) or x`)
--     applied to C_Spell.IsSpellCrowdControl and
--     C_UnitAuras.AuraIsBigDefensive: Blizzard sometimes returns
--     secret values from these classifiers on anonymised arena
--     units.  We treat "secret" as "yes, track" -- degrading toward
--     showing rather than hiding.
--
-- Pattern reference:
--   * MiniCC   -> Core/UnitAuraWatcher.lua (scan engine, incremental,
--                 secret-safe classification)
--   * BBP      -> retail/modules/totem.lua, midnight/modules/auras.lua
--                 (forbidden-frame handling, canonical arena token
--                  resolution -- see _ResolveUnitForPlate + ArenaMap)

local _, ns = ...

----------------------------------------------------------------------
-- Curated default list (PvP-relevant only).  Each entry:
--   { name = display, priority = sort key when multiple match }
-- Lower priority number = shown first when several auras match.
--
-- This list acts as the user's editable "always-track-with-this-
-- priority" override.  Even entries flagged { enabled = false } via
-- MyNamePlatesDB.auras.list[spellID] are EXPLICITLY suppressed --
-- category-detected auras with the same spellID are still hidden.
-- That way the user can permanently hide, e.g., their own Barkskin
-- from cluttering their druid's nameplate.
----------------------------------------------------------------------
ns.AURA_LIST_DEFAULT = {
    -- Immunities (priority 10)
    [642]    = { name = "Divine Shield",                  priority = 10 },
    [1022]   = { name = "Blessing of Protection",         priority = 10 },
    [204018] = { name = "Blessing of Spellwarding",       priority = 10 },
    [45438]  = { name = "Ice Block",                      priority = 10 },
    [414658] = { name = "Ice Cold",                       priority = 10 },
    [186265] = { name = "Aspect of the Turtle",           priority = 10 },
    [196555] = { name = "Netherwalk",                     priority = 10 },
    [710]    = { name = "Banish",                         priority = 10 },
    [33786]  = { name = "Cyclone",                        priority = 10 },

    -- Strong defensives (priority 20)
    [33206]  = { name = "Pain Suppression",               priority = 20 },
    [47788]  = { name = "Guardian Spirit",                priority = 20 },
    [116849] = { name = "Life Cocoon",                    priority = 20 },
    [102342] = { name = "Ironbark",                       priority = 20 },
    [6940]   = { name = "Blessing of Sacrifice",          priority = 20 },
    [357170] = { name = "Time Dilation",                  priority = 20 },

    -- Personal defensives (priority 30)
    [47585]  = { name = "Dispersion",                     priority = 30 },
    [22812]  = { name = "Barkskin",                       priority = 30 },
    [61336]  = { name = "Survival Instincts",             priority = 30 },
    [48707]  = { name = "Anti-Magic Shell",               priority = 30 },
    [48792]  = { name = "Icebound Fortitude",             priority = 30 },
    [1856]   = { name = "Vanish",                         priority = 30 },
    [31224]  = { name = "Cloak of Shadows",               priority = 30 },
    [5277]   = { name = "Evasion",                        priority = 30 },
    [871]    = { name = "Shield Wall",                    priority = 30 },
    [184364] = { name = "Enraged Regeneration",           priority = 30 },
    [104773] = { name = "Unending Resolve",               priority = 30 },
    [115203] = { name = "Fortifying Brew",                priority = 30 },
    [122470] = { name = "Touch of Karma",                 priority = 30 },
    [108271] = { name = "Astral Shift",                   priority = 30 },
    [363916] = { name = "Obsidian Scales",                priority = 30 },
    [374348] = { name = "Renewing Blaze",                 priority = 30 },
    [498]    = { name = "Divine Protection",              priority = 30 },
}

----------------------------------------------------------------------
-- Category defaults
--
-- Category detection kicks in when a live aura ISN'T in the user's
-- merged list.  Priorities are chosen so a curated-list entry
-- (usually priority 10-30) always beats a category-detected entry
-- (40+), and immunities (10) always beat everything.
--
-- The user can toggle categories on/off via
-- MyNamePlatesDB.auras.categories.<key> = true|false.  Defaults are
-- all-on out of the box so v1.33.0 renders MORE information than
-- v1.32.14, not less.
----------------------------------------------------------------------
local CATEGORY_PRIORITY = {
    bigDefensive      = 20,
    externalDefensive = 25,
    cc                = 40,
}

local DEFAULT_CATEGORIES = {
    bigDefensive      = true,
    externalDefensive = true,
    cc                = true,
}

----------------------------------------------------------------------
-- Resolve the BEST unit token for an aura scan on this plate.
--
-- Prefers the ArenaMap canonical token ("arena1..3") for forbidden
-- arena plates because API calls on the anonymised per-plate token
-- can return nothing / secret data on retail Midnight; the canonical
-- arena token is the one that reliably surfaces aura data.  Falls
-- back to uf.unit for non-forbidden plates.
--
-- IMPORTANT: this must be declared BEFORE any function that calls it
-- (e.g. UpdateAurasForUnit).  Lua binds local-function identifiers at
-- the point of the `local function` statement -- an earlier caller
-- would see it as a nil global and error silently inside the caller's
-- pcall wrapper.  1.32.13 had this bug: _ResolveUnitForPlate was
-- declared AFTER UpdateAurasForUnit, so every UNIT_AURA event on
-- arena/BG enemy plates threw "attempt to call a nil value" that got
-- swallowed by pcall -- auras only ever refreshed via the
-- RefreshAllAuras full-scan path, never per-unit.
----------------------------------------------------------------------
local function _ResolveUnitForPlate(plate)
    if ns.GetArenaUnitForPlate then
        local arenaUnit = ns:GetArenaUnitForPlate(plate)
        if arenaUnit then return arenaUnit end
    end
    local uf = plate and plate.UnitFrame
    if not uf then return nil end
    return uf.unit or uf.displayedUnit
end

----------------------------------------------------------------------
-- Format remaining seconds as a compact countdown string.
--   > 60s   -> "1m"  /  "2m"
--   > 10s   -> "12"  (whole seconds)
--   >  1s   -> "5.3" (one decimal)
--   <= 1s   -> "0.5" (red)
----------------------------------------------------------------------
local function _FormatTime(remaining)
    if not remaining or remaining <= 0 then return "" end
    if remaining >= 60 then
        return string.format("%dm", math.floor(remaining / 60 + 0.5))
    end
    if remaining >= 10 then
        return string.format("%d", math.floor(remaining + 0.5))
    end
    return string.format("%.1f", remaining)
end

local function _OnTimerUpdate(self, dt)
    self.elapsed = (self.elapsed or 0) + dt
    if self.elapsed < 0.1 then return end   -- 10 fps refresh
    self.elapsed = 0

    local exp = self.expirationTime
    if not exp then
        self.timer:SetText("")
        return
    end
    local remaining = exp - GetTime()
    if remaining <= 0 then
        self.timer:SetText("")
        self:SetScript("OnUpdate", nil)
        return
    end
    self.timer:SetText(_FormatTime(remaining))
    if remaining <= 1 then
        self.timer:SetTextColor(1, 0.2, 0.2, 1)
    elseif remaining <= 3 then
        self.timer:SetTextColor(1, 0.85, 0.2, 1)
    else
        self.timer:SetTextColor(1, 1, 1, 1)
    end
end

local function _GetIcon(plate)
    if plate.MyNP_AuraIcon then return plate.MyNP_AuraIcon end
    local uf = plate.UnitFrame
    if not uf then return nil end
    -- Match Labels.lua's forbidden-check pattern: only bail on
    -- `uf:IsForbidden()`, NOT on the top-level plate.  In retail
    -- Midnight 12.x, arena TOTEM / PET plates have a forbidden
    -- top-level plate BUT a NON-forbidden UnitFrame -- creating
    -- widgets as children of a non-forbidden uf is safe there
    -- (same rule that lets us reposition uf.name on those plates).
    -- Truly forbidden UnitFrames (arena enemy PLAYER plates on some
    -- patches) still bail here to avoid the taint cascade.
    if uf.IsForbidden and uf:IsForbidden() then return nil end

    local f = CreateFrame("Frame", nil, uf)
    f:SetSize(24, 24)
    f:SetFrameLevel((uf.healthBar and uf.healthBar:GetFrameLevel() or uf:GetFrameLevel()) + 6)
    f:Hide()

    f.tex = f:CreateTexture(nil, "OVERLAY")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.border = f:CreateTexture(nil, "ARTWORK")
    f.border:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.border:SetVertexColor(1, 1, 1, 1)
    f.border:SetPoint("TOPLEFT", -1, 1)
    f.border:SetPoint("BOTTOMRIGHT", 1, -1)
    f.border:SetDrawLayer("BACKGROUND", -1)

    f.cooldown = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cooldown:SetAllPoints()
    f.cooldown:SetDrawEdge(false)
    f.cooldown:SetHideCountdownNumbers(true)

    f.timer = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    f.timer:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.timer:SetShadowOffset(1, -1)
    f.timer:SetShadowColor(0, 0, 0, 1)
    f.timer:SetText("")

    plate.MyNP_AuraIcon = f
    return f
end

----------------------------------------------------------------------
-- Merged tracked-list (curated defaults + user overrides).
--
-- Explicit user disable (`entry.enabled == false`) is preserved --
-- Classify() rejects the aura entirely instead of falling through to
-- category detection.  This is intentional: the toggle in the UI is
-- how a user permanently silences a category-classified aura (e.g.
-- ignore your own Barkskin as noise).
----------------------------------------------------------------------
local function _MergedList()
    local merged = {}
    for id, entry in pairs(ns.AURA_LIST_DEFAULT) do
        merged[id] = entry
    end
    if MyNamePlatesDB and MyNamePlatesDB.auras and MyNamePlatesDB.auras.list then
        for id, entry in pairs(MyNamePlatesDB.auras.list) do
            merged[id] = entry
        end
    end
    return merged
end

----------------------------------------------------------------------
-- Secret-safe classifier -- MiniCC pattern
-- (Core/UnitAuraWatcher.lua ~328-329, 475-476).
--
-- Some spell classifiers return secret-string values on anonymised
-- arena units to prevent addons from leaking information.  We adopt
-- MiniCC's "secret-means-yes" pattern: if the classifier returned a
-- secret value, treat it as "match" so degradation is toward
-- showing rather than hiding.  On the specific taint concern of
-- storing a secret in a table: we never store the raw isCC / isBD
-- value itself -- we just gate on its truthiness.
----------------------------------------------------------------------
local function _SecretTruthy(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return true end
    return v and true or false
end

----------------------------------------------------------------------
-- Classify a single aura (post-scan or from updateInfo.addedAuras).
-- Returns (entry, priority) -- entry is the user/curated table when
-- the spellID is in the list, or a synthetic { name, priority }
-- table when category detection matches.  Returns nil, nil when the
-- aura should NOT be tracked (user disabled or no category match).
----------------------------------------------------------------------
local function _Classify(aura, db, list)
    if not aura then return nil, nil end
    local spellId = aura.spellId
    if not spellId then return nil, nil end

    -- User/curated list (highest priority, respects explicit disable)
    local userEntry = list[spellId]
    if userEntry then
        if userEntry.enabled == false then return nil, nil end
        return userEntry, userEntry.priority or 100
    end

    -- Category detection
    local cats = (db and db.categories) or DEFAULT_CATEGORIES
    local name = aura.name

    if aura.isHarmful then
        if cats.cc and C_Spell and C_Spell.IsSpellCrowdControl then
            local ok, isCC = pcall(C_Spell.IsSpellCrowdControl, spellId)
            if ok and _SecretTruthy(isCC) then
                local prio = CATEGORY_PRIORITY.cc
                return { name = name, priority = prio }, prio
            end
        end
        return nil, nil
    end

    -- HELPFUL
    if cats.bigDefensive and C_UnitAuras and C_UnitAuras.AuraIsBigDefensive then
        local ok, isBD = pcall(C_UnitAuras.AuraIsBigDefensive, spellId)
        if ok and _SecretTruthy(isBD) then
            local prio = CATEGORY_PRIORITY.bigDefensive
            return { name = name, priority = prio }, prio
        end
    end
    -- ExternalDefensive: no per-spell classifier API.  On a full
    -- rescan we get these via GetUnitAuras("HELPFUL|EXTERNAL_DEFENSIVE")
    -- and classify via `aura._mynpCategory = "externalDefensive"`
    -- (set at collect time).  On incremental adds we can't know --
    -- but almost every ED aura is in AURA_LIST_DEFAULT (Sac, PS, GS,
    -- Ironbark, Life Cocoon, Time Dilation) so we catch them via
    -- the user-list branch above.  Truly niche ED auras get picked
    -- up on next full refresh.
    if aura._mynpCategory then
        local prio = CATEGORY_PRIORITY[aura._mynpCategory]
        if prio then
            return { name = name, priority = prio }, prio
        end
    end
    return nil, nil
end

----------------------------------------------------------------------
-- Full scan for a unit.  Returns a table keyed by auraInstanceID:
--   { [instanceID] = { aura = <AuraData>, entry = <table>, priority = N } }
----------------------------------------------------------------------
local function _FullScan(unit, db, list)
    local tracked = {}
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuras) then return tracked end

    local function collect(filter, categoryTag)
        local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter, nil)
        if not ok or type(auras) ~= "table" then return end
        for _, aura in ipairs(auras) do
            if aura and aura.spellId and aura.auraInstanceID then
                if categoryTag then aura._mynpCategory = categoryTag end
                local entry, prio = _Classify(aura, db, list)
                if entry then
                    local existing = tracked[aura.auraInstanceID]
                    -- If already tracked, keep the higher-priority entry
                    -- (lower priority number).  User-list scan comes
                    -- first, so category scans can only upgrade a nil
                    -- slot -- but the guard is cheap and defensive.
                    if not existing or prio < existing.priority then
                        tracked[aura.auraInstanceID] = {
                            aura     = aura,
                            entry    = entry,
                            priority = prio,
                        }
                    end
                end
            end
        end
    end

    -- User/curated list scan -- full HELPFUL + HARMFUL to catch every
    -- spellID the user explicitly tracks (Divine Shield, Barkskin,
    -- Cyclone, Vanish, plus any custom-added entries).
    collect("HELPFUL")
    collect("HARMFUL")

    -- Category scans -- pick up anything not covered by the curated
    -- list.  Blizzard does the classification server-side so we get
    -- accurate results even when per-spell classifiers return secret.
    local cats = (db and db.categories) or DEFAULT_CATEGORIES
    if cats.bigDefensive      then collect("HELPFUL|BIG_DEFENSIVE",      "bigDefensive")      end
    if cats.externalDefensive then collect("HELPFUL|EXTERNAL_DEFENSIVE", "externalDefensive") end
    if cats.cc                then collect("HARMFUL|CROWD_CONTROL",     "cc")                end

    return tracked
end

----------------------------------------------------------------------
-- Pick the highest-priority tracked aura (lowest priority number).
----------------------------------------------------------------------
local function _PickBest(tracked)
    if not tracked then return nil end
    local bestID, bestPrio
    for id, item in pairs(tracked) do
        if not bestPrio or item.priority < bestPrio then
            bestID   = id
            bestPrio = item.priority
        end
    end
    return bestID and tracked[bestID] or nil
end

----------------------------------------------------------------------
-- Apply the current tracked set to the plate's icon.
----------------------------------------------------------------------
local function _SampleIconID()
    if C_Spell and C_Spell.GetSpellTexture then
        local t = C_Spell.GetSpellTexture(642)
        if t then return t end
    end
    return 135940
end

local function _Apply(plate, unit, db, tracked)
    if not plate then return end
    local icon = _GetIcon(plate)
    if not icon then return end

    if db.enabled ~= "1" then icon:Hide(); return end

    -- Friend/enemy filter.  Use a pcall in case the resolved unit is
    -- a canonical arena token that UnitIsFriend handles fine (it
    -- does) -- pcall is cheap insurance.
    local ok, isFriend = pcall(UnitIsFriend, "player", unit)
    if not ok then isFriend = false end

    local testing = ns.testMode and ns.testMode.auras
    if isFriend and db.showFriendly == false then icon:Hide(); return end
    if (not isFriend) and db.showEnemy == false then icon:Hide(); return end

    local best
    if not testing then
        best = _PickBest(tracked)
        if not best then icon:Hide(); return end
    end

    icon:ClearAllPoints()
    local anchorTo = plate.UnitFrame.healthBar or plate.UnitFrame
    icon:SetPoint("CENTER", anchorTo,
        db.anchor or "TOP",
        tonumber(db.xOffset) or 0,
        tonumber(db.yOffset) or 30)
    icon:SetScale(tonumber(db.scale) or 1.0)
    icon:SetSize(tonumber(db.iconSize) or 24, tonumber(db.iconSize) or 24)

    if testing then
        icon.tex:SetTexture(_SampleIconID())
        icon.cooldown:Clear()
        icon.cooldown:Hide()
        icon.expirationTime = nil
        icon.timer:SetText("8")
        icon.timer:SetTextColor(1, 1, 1, 1)
        icon:SetScript("OnUpdate", nil)
    else
        local aura = best.aura
        icon.tex:SetTexture(aura.icon or 0)
        if aura.duration and aura.duration > 0 and aura.expirationTime then
            icon.cooldown:SetCooldown(aura.expirationTime - aura.duration, aura.duration)
            icon.cooldown:Show()
            icon.expirationTime = aura.expirationTime
            icon.elapsed = 0
            icon:SetScript("OnUpdate", _OnTimerUpdate)
        else
            icon.cooldown:Clear()
            icon.cooldown:Hide()
            icon.expirationTime = nil
            icon.timer:SetText("")
            icon:SetScript("OnUpdate", nil)
        end
    end
    icon:Show()
end

----------------------------------------------------------------------
-- Apply an incremental UNIT_AURA updateInfo to the plate's cache.
--
-- Returns true if we successfully applied the delta, false if the
-- caller should fall back to a full rescan (e.g. plate has no
-- existing cache, updateInfo is missing, or updateInfo.isFullUpdate).
----------------------------------------------------------------------
local function _ApplyIncremental(plate, unit, db, list, updateInfo)
    if not (updateInfo and plate) then return false end
    if updateInfo.isFullUpdate then return false end
    local tracked = plate.MyNP_ActiveTracked
    if not tracked then return false end

    if updateInfo.removedAuraInstanceIDs then
        for _, instanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            tracked[instanceID] = nil
        end
    end

    if updateInfo.addedAuras then
        for _, aura in ipairs(updateInfo.addedAuras) do
            if aura and aura.auraInstanceID then
                local entry, prio = _Classify(aura, db, list)
                if entry then
                    tracked[aura.auraInstanceID] = {
                        aura     = aura,
                        entry    = entry,
                        priority = prio,
                    }
                end
            end
        end
    end

    if updateInfo.updatedAuraInstanceIDs then
        for _, instanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
            local item = tracked[instanceID]
            if item and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local ok, fresh = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, instanceID)
                if ok and fresh then
                    item.aura = fresh
                end
            end
        end
    end

    return true
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- UpdateAurasForUnit(unit, updateInfo)
-- Called from Discovery.lua's UNIT_AURA handler.  `updateInfo` is
-- the second arg Blizzard passes to the UNIT_AURA event since 10.x
-- (`AuraUpdateInfo` structure).  When non-nil and not a full update,
-- we apply deltas to the plate's cached tracked set; otherwise we
-- do a full rescan.
function ns:UpdateAurasForUnit(unit, updateInfo)
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    if not unit then return end
    -- Bail on secret unit token before any string.match -- see
    -- Discovery.lua for the taint rationale.
    if issecretvalue and issecretvalue(unit) then return end

    -- Resolve the plate for this unit token.
    local plate = C_NamePlate.GetNamePlateForUnit(unit, true)
    if not plate and ns.ArenaMap and ns.ArenaMap.indexToPlate then
        local idxStr = unit:match("^arena(%d)$")
        if idxStr then
            plate = ns.ArenaMap.indexToPlate[tonumber(idxStr)]
        end
    end
    if not plate then
        -- Last resort: walk plates and find via UnitIsUnit.  This
        -- handles the case where Blizzard has recycled a plate to a
        -- new unit and our forward map hasn't caught up yet.
        for _, p in ipairs(C_NamePlate.GetNamePlates(true)) do
            local uf = p.UnitFrame
            local pu = uf and (uf.unit or uf.displayedUnit)
            if pu then
                local ok, same = pcall(UnitIsUnit, pu, unit)
                if ok and same then plate = p; break end
            end
        end
    end
    if not plate then return end

    local scanUnit = _ResolveUnitForPlate(plate) or unit
    local db   = MyNamePlatesDB.auras
    local list = _MergedList()

    -- Detect plate recycled to a different unit -- force full rescan
    -- and wipe the cache so we don't leak stale instance IDs across
    -- unit changes.  Store the scanUnit (which might be arenaN)
    -- rather than the event's unit so recycles at the arena-index
    -- level also invalidate the cache.
    if plate.MyNP_AuraLastUnit ~= scanUnit then
        plate.MyNP_AuraLastUnit  = scanUnit
        plate.MyNP_ActiveTracked = nil
    end

    -- Try incremental first; on false, fall back to full rescan.
    local applied = _ApplyIncremental(plate, scanUnit, db, list, updateInfo)
    if not applied then
        plate.MyNP_ActiveTracked = _FullScan(scanUnit, db, list)
    end

    pcall(_Apply, plate, scanUnit, db, plate.MyNP_ActiveTracked)
end

-- RefreshAllAuras() -- full scan of every visible plate.  Called
-- when config changes, on PLAYER_ENTERING_WORLD, and from other
-- refresh triggers.  Also wipes per-plate caches so the next
-- incremental event applies against a clean baseline.
function ns:RefreshAllAuras()
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local db   = MyNamePlatesDB.auras
    local list = _MergedList()

    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        pcall(function()
            local unit = _ResolveUnitForPlate(plate)
            if not unit then return end
            plate.MyNP_AuraLastUnit  = unit
            plate.MyNP_ActiveTracked = _FullScan(unit, db, list)
            _Apply(plate, unit, db, plate.MyNP_ActiveTracked)
        end)
    end
end

-- Clear a plate's aura state.  Called from Discovery.lua's
-- NAME_PLATE_UNIT_REMOVED handler so recycled plates don't inherit
-- stale tracked auras when Blizzard reassigns them.
function ns:ClearAuraStateForPlate(plate)
    if not plate then return end
    plate.MyNP_ActiveTracked = nil
    plate.MyNP_AuraLastUnit  = nil
    if plate.MyNP_AuraIcon then
        pcall(plate.MyNP_AuraIcon.Hide, plate.MyNP_AuraIcon)
    end
end

----------------------------------------------------------------------
-- DB helpers used by the UI
----------------------------------------------------------------------
function ns:GetAurasConfig()
    return MyNamePlatesDB and MyNamePlatesDB.auras
end

function ns:SetAurasOption(field, value)
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return end
    MyNamePlatesDB.auras[field] = value
    if ns.RefreshAllAuras then ns:RefreshAllAuras() end
end

-- Category toggles (new in 1.33.0).
function ns:IsAuraCategoryEnabled(category)
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return false end
    local cats = MyNamePlatesDB.auras.categories
    if not cats then return DEFAULT_CATEGORIES[category] and true or false end
    if cats[category] == nil then
        return DEFAULT_CATEGORIES[category] and true or false
    end
    return cats[category] and true or false
end

function ns:SetAuraCategoryEnabled(category, on)
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return end
    MyNamePlatesDB.auras.categories = MyNamePlatesDB.auras.categories or {}
    MyNamePlatesDB.auras.categories[category] = on and true or false
    if ns.RefreshAllAuras then ns:RefreshAllAuras() end
end

-- Iterate merged tracked-list (curated + user) for the UI.
function ns:IterateAuras()
    local list = _MergedList()
    local keys = {}
    for id in pairs(list) do keys[#keys + 1] = id end
    table.sort(keys, function(a, b)
        return (list[a].name or "") < (list[b].name or "")
    end)
    local i = 0
    return function()
        i = i + 1
        if keys[i] then return keys[i], list[keys[i]] end
    end
end

function ns:SetAuraEnabled(spellID, on)
    if not MyNamePlatesDB.auras.list then MyNamePlatesDB.auras.list = {} end
    local existing = MyNamePlatesDB.auras.list[spellID]
    local seed = ns.AURA_LIST_DEFAULT[spellID]
    if not existing then
        existing = {
            name     = seed and seed.name or ("Spell " .. spellID),
            priority = seed and seed.priority or 50,
        }
        MyNamePlatesDB.auras.list[spellID] = existing
    end
    existing.enabled = on and true or false
    if ns.RefreshAllAuras then ns:RefreshAllAuras() end
end

function ns:IsAuraEnabled(spellID)
    local user = MyNamePlatesDB and MyNamePlatesDB.auras
                  and MyNamePlatesDB.auras.list and MyNamePlatesDB.auras.list[spellID]
    if user then return user.enabled ~= false end
    if ns.AURA_LIST_DEFAULT[spellID] then return true end
    return false
end

function ns:AddCustomAura(spellID)
    spellID = tonumber(spellID)
    if not spellID then return false, "Not a valid spell ID" end
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(spellID)
    end
    name = name or ("Spell " .. spellID)
    if not MyNamePlatesDB.auras.list then MyNamePlatesDB.auras.list = {} end
    MyNamePlatesDB.auras.list[spellID] = {
        name     = name,
        priority = 50,
        enabled  = true,
    }
    if ns.RefreshAllAuras then ns:RefreshAllAuras() end
    return true, name
end

function ns:RemoveCustomAura(spellID)
    if MyNamePlatesDB and MyNamePlatesDB.auras and MyNamePlatesDB.auras.list then
        MyNamePlatesDB.auras.list[spellID] = nil
    end
    if ns.RefreshAllAuras then ns:RefreshAllAuras() end
end

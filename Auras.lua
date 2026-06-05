-- Auras.lua
-- Watched aura indicator: shows an icon over a nameplate whenever the
-- unit has one of the tracked auras active (immunities, big defensives,
-- BoP, Ice Block, Bubble, etc.).  Configurable position, scale, and
-- editable spell list.  Pattern adapted from BBP's auras.lua and
-- MiniCC's NameplatesModule.
--
-- Implementation:
--   • Pre-seeded list of canonical PvP immunities + defensives by spellID
--   • UNIT_AURA event triggers a re-scan for the changed unit
--   • C_UnitAuras.GetPlayerAuraBySpellID-style iteration via AuraUtil
--   • Single-icon overlay per plate (highest-priority aura wins; we don't
--     stack to keep the UI clean — easy to add later)

local _, ns = ...

----------------------------------------------------------------------
-- Curated default list (PvP-relevant only).  Each entry:
--   { name = display, priority = sort key when multiple match }
-- Lower priority number = shown first when several auras match.
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
-- Per-plate icon overlay
----------------------------------------------------------------------
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
    -- Tint red in last second so you see immunity drop coming.
    if remaining <= 1 then
        self.timer:SetTextColor(1, 0.2, 0.2, 1)
    elseif remaining <= 3 then
        self.timer:SetTextColor(1, 0.85, 0.2, 1)   -- yellow under 3s
    else
        self.timer:SetTextColor(1, 1, 1, 1)
    end
end

local function _GetIcon(plate)
    if plate.MyNP_AuraIcon then return plate.MyNP_AuraIcon end
    local uf = plate.UnitFrame
    if not uf then return nil end
    -- Skip forbidden plates — CreateFrame as child of forbidden uf
    -- propagates addon taint up the secure chain ("Interface action
    -- failed because of an AddOn" on every secure action against
    -- arena enemies).  Aura icons just won't render on those plates;
    -- the watched-aura logic itself is unaffected for non-forbidden.
    if (plate.IsForbidden and plate:IsForbidden())
       or (uf.IsForbidden and uf:IsForbidden()) then return nil end

    local f = CreateFrame("Frame", nil, uf)
    f:SetSize(24, 24)
    f:SetFrameLevel((uf.healthBar and uf.healthBar:GetFrameLevel() or uf:GetFrameLevel()) + 6)
    f:Hide()

    f.tex = f:CreateTexture(nil, "OVERLAY")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim default Blizzard border

    f.border = f:CreateTexture(nil, "ARTWORK")
    f.border:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.border:SetVertexColor(1, 1, 1, 1)
    f.border:SetPoint("TOPLEFT", -1, 1)
    f.border:SetPoint("BOTTOMRIGHT", 1, -1)
    f.border:SetDrawLayer("BACKGROUND", -1)

    -- Cooldown swipe (visual sweep)
    f.cooldown = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cooldown:SetAllPoints()
    f.cooldown:SetDrawEdge(false)
    -- Hide the built-in numbers; we draw our own (more reliable; not
    -- subject to Blizzard's global countdown-numbers toggle).
    f.cooldown:SetHideCountdownNumbers(true)

    -- Custom countdown text on top of the icon.
    f.timer = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    f.timer:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.timer:SetShadowOffset(1, -1)
    f.timer:SetShadowColor(0, 0, 0, 1)
    f.timer:SetText("")

    plate.MyNP_AuraIcon = f
    return f
end

----------------------------------------------------------------------
-- Aura scan for a unit (returns the highest-priority matched aura)
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

local function _IsTracked(spellID, list)
    local entry = list[spellID]
    if not entry then return nil end
    if entry.enabled == false then return nil end
    return entry
end

local function _ScanUnit(unit, list)
    if not (AuraUtil and AuraUtil.ForEachAura) then return nil end
    local best, bestEntry, bestPriority

    local function consider(aura)
        if not aura then return end
        local entry = _IsTracked(aura.spellId, list)
        if not entry then return end
        local prio = entry.priority or 100
        if not bestPriority or prio < bestPriority then
            best = aura
            bestEntry = entry
            bestPriority = prio
        end
    end

    AuraUtil.ForEachAura(unit, "HELPFUL", nil, consider, true)
    AuraUtil.ForEachAura(unit, "HARMFUL", nil, consider, true)
    return best, bestEntry
end

----------------------------------------------------------------------
-- Apply the icon to the right plate based on settings
----------------------------------------------------------------------
-- Sample icon used in test mode (Divine Shield).  Falls back to the
-- generic shield texture if the spell icon API isn't available.
local function _SampleIconID()
    if C_Spell and C_Spell.GetSpellTexture then
        local t = C_Spell.GetSpellTexture(642)   -- Divine Shield
        if t then return t end
    end
    return 135940   -- Interface\\Icons\\Spell_Holy_DivineIntervention
end

local function _Apply(plate, unit, db, list)
    if not plate then return end
    -- Don't bail on forbidden plates here — we only call SetTexture,
    -- SetAlpha, SetScale, SetSize, SetPoint, SetCooldown on the icon
    -- frame we own.  None of those taint.  Same approach BBP / MiniCC
    -- use for arena enemy aura overlays.
    local icon = _GetIcon(plate)
    if not icon then return end

    if db.enabled ~= "1" then icon:Hide(); return end

    local isFriend = UnitIsFriend("player", unit)

    -- Test mode: stamp a placeholder icon on every plate that the
    -- friendly/enemy filter doesn't exclude, so the user can preview
    -- position/scale in the open world.
    local testing = ns.testMode and ns.testMode.auras
    if testing then
        if isFriend and db.showFriendly == false then icon:Hide(); return end
        if (not isFriend) and db.showEnemy == false then icon:Hide(); return end
    else
        if isFriend and db.showFriendly == false then icon:Hide(); return end
        if (not isFriend) and db.showEnemy == false then icon:Hide(); return end
    end

    local aura
    if not testing then
        aura = _ScanUnit(unit, list)
        if not aura then icon:Hide(); return end
    end

    -- Position / scale (same path for real auras and test mode)
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
        icon.timer:SetText("8")            -- placeholder
        icon.timer:SetTextColor(1, 1, 1, 1)
        icon:SetScript("OnUpdate", nil)
    else
        icon.tex:SetTexture(aura.icon or 0)
        if aura.duration and aura.duration > 0 and aura.expirationTime then
            icon.cooldown:SetCooldown(aura.expirationTime - aura.duration, aura.duration)
            icon.cooldown:Show()
            -- Drive the custom countdown text via OnUpdate.
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
-- Public API
----------------------------------------------------------------------
function ns:UpdateAurasForUnit(unit)
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    if not unit then return end
    -- Bail on secret-string unit tokens.  unit:match below would
    -- otherwise call string.match on a secret string and taint us.
    if issecretvalue and issecretvalue(unit) then return end

    -- Resolve the plate.  Direct lookup works for most tokens; for
    -- arena1..3 in retail Midnight (where insecure GetNamePlateForUnit
    -- can return nil for forbidden plates), fall back to ArenaMap's
    -- reverse map.
    local plate = C_NamePlate.GetNamePlateForUnit(unit, true)
    if not plate and ns.ArenaMap and ns.ArenaMap.indexToPlate then
        local idxStr = unit:match("^arena(%d)$")
        if idxStr then
            plate = ns.ArenaMap.indexToPlate[tonumber(idxStr)]
        end
    end
    if not plate then
        -- Last resort: walk plates and find via UnitIsUnit.
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

    -- Always scan via the BEST token for this plate — canonical
    -- arenaN if the plate is mapped, otherwise the unit we got.  This
    -- is what makes the per-event update work on forbidden plates
    -- whose own uf.unit is anonymized.
    local scanUnit = _ResolveUnitForPlate(plate) or unit
    pcall(_Apply, plate, scanUnit, MyNamePlatesDB.auras, _MergedList())
end

----------------------------------------------------------------------
-- Resolve the BEST unit token for an aura scan on this plate.
-- Prefers the ArenaMap canonical token ("arena1..3") for forbidden
-- arena plates because AuraUtil.ForEachAura on anonymized per-plate
-- tokens returns nothing on retail Midnight; the canonical token is
-- the only one that surfaces aura data for those plates.  Falls back
-- to uf.unit for non-forbidden plates.
----------------------------------------------------------------------
local function _ResolveUnitForPlate(plate)
    -- ArenaMap-tagged plates: prefer the canonical arena token.
    if ns.GetArenaUnitForPlate then
        local arenaUnit = ns:GetArenaUnitForPlate(plate)
        if arenaUnit then return arenaUnit end
    end
    local uf = plate and plate.UnitFrame
    if not uf then return nil end
    return uf.unit or uf.displayedUnit
end

function ns:RefreshAllAuras()
    if not (MyNamePlatesDB and MyNamePlatesDB.auras) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local db = MyNamePlatesDB.auras
    local list = _MergedList()

    -- BBP's pattern: walk every plate (including forbidden ones in
    -- retail Midnight arenas) and scan auras via the best available
    -- token.  Forbidden enemy arena plates use the ArenaMap canonical
    -- arenaN token (reliable for AuraUtil); everything else uses
    -- uf.unit per-plate (taint-safe per v1.14.3).
    for _, plate in ipairs(C_NamePlate.GetNamePlates(true)) do
        pcall(function()
            local unit = _ResolveUnitForPlate(plate)
            if not unit then return end
            _Apply(plate, unit, db, list)
        end)
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

-- Iterate merged tracked-list (curated + user) for the UI
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
        -- Snapshot the seed so the user's toggle is editable
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

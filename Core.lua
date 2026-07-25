-- Core.lua
-- Database, events, combat-safe CVar queue, ApplyAll().
-- Acts as the single point of mutation: every setter goes through here.

local addonName, ns = ...

----------------------------------------------------------------------
-- Defaults built from the data tables
----------------------------------------------------------------------
local function BuildDefaults()
    local d = {
        global    = {},
        plateSize = {},
        categories = {},
        npcs       = {},
        friendlyColor = {
            enabled = "0",
            r = 0.20, g = 0.85, b = 0.20, a = 1.0,
            applyToPlayers = true,
            applyToNPCs    = true,
        },
        auras = {
            enabled      = "1",
            anchor       = "TOP",
            xOffset      = 0,
            yOffset      = 36,
            scale        = 1.0,
            iconSize     = 26,
            showFriendly = true,
            showEnemy    = true,
            list         = {},      -- user-added entries; merged with AURA_LIST_DEFAULT
            -- 1.33.0: category-based detection via C_UnitAuras.GetUnitAuras
            -- filter strings.  Catches any CC / big defensive / external
            -- defensive Blizzard classifies, so users don't need to
            -- maintain a per-patch spell-ID list.  User's explicit
            -- disable in `list` still wins over category detection.
            categories = {
                bigDefensive      = true,
                externalDefensive = true,
                cc                = true,
            },
        },
        labels = {
            hideDefaultName = false,
            name = {
                enabled        = "0",          -- off by default; Blizzard's name shows otherwise
                anchor         = "BOTTOM",
                xOffset        = 0,
                yOffset        = -4,
                scale          = 1.0,
                fontSize       = 0,            -- 0 = use Blizzard's default size
                applyFriendly  = true,
                applyEnemy     = true,
            },
            -- Separate config for summon plates: pets, totems, guardians,
            -- minions, minor, psyfiend.  Defaults pull the name well above
            -- the plate (yOffset = 14) since totems are short and the
            -- whole point of having a separate block is to *not* have
            -- their text blend in with the healthbar.  When this block's
            -- `enabled = "0"`, summons fall through to using the regular
            -- `name` config (so the previous behavior is unchanged).
            --
            -- `types` is a per-summon-type filter so the user can pick
            -- which summon categories get the always-visible name label
            -- and which fall back to Blizzard default (fading on non-
            -- target).  Defaults are tuned for arena clutter: high-
            -- priority kill targets (totems + Psyfiend) ON, lower-
            -- priority noise (pets, minions, guardians, minor) OFF.
            petTotemName = {
                enabled        = "0",
                anchor         = "BOTTOM",
                xOffset        = 0,
                yOffset        = 14,
                scale          = 1.0,
                fontSize       = 0,
                applyFriendly  = true,
                applyEnemy     = true,
                -- Icon overlay (BBP-style fallback for retail Midnight 12.x
                -- arena).  In arena, Blizzard anonymises enemy totem unit
                -- tokens (uf.unit / UnitGUID / UnitName all return secret
                -- strings), so the name overlay above can't render totem
                -- names until the player targets or mouseovers the totem.
                -- BBP's midnight/modules/totem.lua sidesteps this by
                -- rendering a texture + color instead of the totem name —
                -- confirmed via their CHANGELOG (2.0.4: "Totem Indicator
                -- is kind of back... Best that can be done atm.").
                --
                -- We adopt the same pattern: a small icon at a configurable
                -- offset that renders whenever the plate qualifies as a
                -- summon.  Icon selection heuristic (from BBP):
                --   * UnitCastingInfo → Capacitor Totem  (orange)
                --   * UnitChannelInfo → Psyfiend          (purple)
                --   * First HELPFUL aura + IsSpellImportant → aura icon
                --     (magenta if important, brown otherwise)
                --   * Otherwise → generic totem-recall icon (brown)
                -- Defaults ON — the whole point is arena visibility.
                showIcon       = true,
                iconSize       = 26,
                iconAnchor     = "TOP",
                iconXOffset    = 0,
                iconYOffset    = 22,
                types = {
                    totem       = true,
                    psyfiend    = true,
                    guardian    = false,
                    pet_hunter  = false,
                    pet_warlock = false,
                    pet_dk      = false,
                    pet_mage    = false,
                    minion      = false,
                    minor       = false,
                },

                -- ---------------------------------------------------------
                -- 1.35.0: full BBP-style totem indicator parity.
                --
                -- Cross-referenced against BBP midnight/modules/totem.lua
                -- (ApplyTotemIconsAndColorNameplate + ApplyTotemAttributes)
                -- so this addon renders the same visual language as BBP:
                -- important totems (Capacitor / Psyfiend / Grounding-class
                -- auras) get a glow + cooldown swipe + pulse animation and
                -- optionally recolor the healthbar / name; unimportant
                -- totems fall back to a plain generic icon in the user's
                -- generic-totem color.  All behaviors are individually
                -- toggleable so users can opt into just the parts they
                -- want (e.g. glow-only, or color-only).
                --
                -- Defaults chosen to mirror BBP out of the box:
                --   * enemiesOnly OFF -> visible on friendly totems too
                --   * colorHealthBar / colorName ON -> important totems
                --     recolor the plate (matches BBP defaults)
                --   * *Others OFF -> generic totems don't recolor
                --   * showOtherIcons ON -> render an icon on unimportant
                --     totems too (the whole point of BBP's system)
                --   * showCooldownSwipe ON, noGlow / noAnimation OFF
                --   * hideHealthBar / hideName OFF (aggressive; opt-in)
                --   * genericColor = BBP's default brown {0.4, 0.34, 0.21}
                -- ---------------------------------------------------------
                enemiesOnly          = false,
                colorHealthBar       = true,
                colorHealthBarOthers = false,
                colorName            = true,
                colorNameOthers      = false,
                hideHealthBar        = false,
                hideName             = false,
                showOtherIcons       = true,
                showCooldownSwipe    = true,
                noGlow               = false,
                noAnimation          = false,
                genericColor         = { 0.40, 0.34, 0.21 },
            },
            spec = {
                enabled        = "1",          -- show spec by default
                anchor         = "TOP",
                xOffset        = 0,
                yOffset        = 14,
                scale          = 1.0,
                fontSize       = 0,            -- spec custom FontString uses scale only; size optional
                applyFriendly  = true,
                applyEnemy     = true,
            },
        },
        indicators = {
            target = {
                enabled = "1",
                anchor  = "TOP",
                xOffset = 0,
                yOffset = 12,
                scale   = 1.0,
                color   = nil,   -- nil = native white
            },
            healerFriendly = {
                enabled = "1",
                anchor  = "TOP",
                xOffset = 0,
                yOffset = 14,
                scale   = 1.0,
                color   = nil,   -- nil = native green-cross atlas colour
            },
            healerEnemy = {
                enabled = "1",
                anchor  = "TOP",
                xOffset = 0,
                yOffset = 14,
                scale   = 1.0,
                color   = nil,   -- nil = engine default (red, desaturated)
            },
            -- Class-icon markers (player class portrait above the plate).
            classFriendly = {
                enabled = "0",                 -- off by default
                anchor  = "TOP",
                xOffset = 0,
                yOffset = 30,                  -- sit above the healer cross
                scale   = 1.0,
            },
            classEnemy = {
                enabled = "1",                 -- on by default for PvP
                anchor  = "TOP",
                xOffset = 0,
                yOffset = 30,
                scale   = 1.0,
            },
        },
    }

    for _, e in ipairs(ns.GLOBAL) do
        d.global[e.key] = e.default
    end
    for _, e in ipairs(ns.PLATE_SIZE) do
        d.plateSize[e.key] = e.default
    end

    for _, c in ipairs(ns.CATEGORIES) do
        if c.kind ~= "global" then
            d.categories[c.id] = {
                enabled        = c.defaultEnabled or "0",
                scale          = 1.0,
                alpha          = 1.0,
                hidden         = {},
                highlighted    = {},
                highlightColor = { 1.0, 0.1, 0.1, 1.0 },   -- bright red
            }
        end
    end

    -- Pre-seed kill-priority targets so users get the visual cue out of the
    -- box without having to configure anything.
    local function flag(catID, npcIDs)
        local cat = d.categories[catID]
        if not cat then return end
        for _, id in ipairs(npcIDs) do cat.highlighted[id] = true end
    end
    flag("enemyTotems", {
        61245,     -- Capacitor Totem
        98007,     -- Spirit Link Totem
        59764,     -- Healing Tide Totem
        2630,      -- Earthbind Totem
        60561,     -- Earthgrab Totem
        188616,    -- Static Field Totem
        197211,    -- Lightning Surge Totem
        5913,      -- Tremor Totem
        5925,      -- Grounding Totem
        73900,     -- Mana Tide Totem
    })
    flag("enemyPsyfiend", { 101398 })   -- always highlighted by default
    return d
end

local function MergeDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            MergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

----------------------------------------------------------------------
-- Combat-safe CVar queue
----------------------------------------------------------------------
local pendingCVars = {}        -- [cvar] = stringValue
local pendingPlateSize = false

local function ApplyCVar(cvar, value)
    if InCombatLockdown() then
        pendingCVars[cvar] = tostring(value)
        return
    end
    C_CVar.SetCVar(cvar, tostring(value))
end

local function ApplyPlateSize()
    local ps = MyNamePlatesDB and MyNamePlatesDB.plateSize
    if not ps then return end
    if InCombatLockdown() then
        pendingPlateSize = true
        return
    end
    if C_NamePlate and C_NamePlate.SetNamePlateFriendlySize then
        C_NamePlate.SetNamePlateFriendlySize(ps.friendlyWidth, ps.friendlyHeight)
        C_NamePlate.SetNamePlateEnemySize(ps.enemyWidth, ps.enemyHeight)
    end
end

local function FlushPending()
    for cvar, value in pairs(pendingCVars) do
        C_CVar.SetCVar(cvar, value)
        pendingCVars[cvar] = nil
    end
    if pendingPlateSize then
        pendingPlateSize = false
        ApplyPlateSize()
    end
end

----------------------------------------------------------------------
-- Public getters / setters
----------------------------------------------------------------------
function ns:GetGlobal(key)    return MyNamePlatesDB.global[key]    end
function ns:GetPlateSize(key) return MyNamePlatesDB.plateSize[key] end

local function FindGlobalEntry(key)
    for _, e in ipairs(ns.GLOBAL) do
        if e.key == key then return e end
    end
end

function ns:SetGlobal(key, value)
    MyNamePlatesDB.global[key] = value
    local entry = FindGlobalEntry(key)
    if entry and entry.apply then
        -- Custom apply function (e.g. C_NamePlate.SetNamePlate*ClickThrough)
        entry.apply(value)
    else
        -- Default: the key is a Blizzard CVar name
        ApplyCVar(key, value)
    end
end

function ns:SetPlateSize(key, value)
    MyNamePlatesDB.plateSize[key] = value
    ApplyPlateSize()
end

----------------------------------------------------------------------
-- Friendly plate healthbar color override
----------------------------------------------------------------------
function ns:GetFriendlyColor() return MyNamePlatesDB.friendlyColor end

function ns:SetFriendlyColorEnabled(on)
    if not MyNamePlatesDB.friendlyColor then return end
    MyNamePlatesDB.friendlyColor.enabled = on and "1" or "0"
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:SetFriendlyColorRGB(r, g, b, a)
    if not MyNamePlatesDB.friendlyColor then return end
    local c = MyNamePlatesDB.friendlyColor
    c.r, c.g, c.b, c.a = r or c.r, g or c.g, b or c.b, a or c.a or 1.0
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:SetFriendlyColorTarget(targetType, on)
    if not MyNamePlatesDB.friendlyColor then return end
    if targetType == "players" then
        MyNamePlatesDB.friendlyColor.applyToPlayers = on and true or false
    elseif targetType == "npcs" then
        MyNamePlatesDB.friendlyColor.applyToNPCs = on and true or false
    end
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

----------------------------------------------------------------------
-- Categories (master toggle / per-category scale & alpha / hidden NPCs)
----------------------------------------------------------------------
function ns:GetCategory(id)
    return MyNamePlatesDB.categories[id]
end

function ns:SetCategoryEnabled(id, on)
    local cat = MyNamePlatesDB.categories[id]
    if not cat then return end
    cat.enabled = on and "1" or "0"
    local def = ns.CATEGORY_BY_ID[id]
    if def and def.cvar then
        ApplyCVar(def.cvar, cat.enabled)
    else
        -- CVar-less category (Hunter Pets etc.): the toggle becomes a
        -- per-plate hide; re-apply on every active plate.
        if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
    end
end

function ns:SetCategoryScale(id, value)
    local cat = MyNamePlatesDB.categories[id]
    if not cat then return end
    cat.scale = value
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:SetCategoryAlpha(id, value)
    local cat = MyNamePlatesDB.categories[id]
    if not cat then return end
    cat.alpha = value
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:SetNpcHidden(categoryID, npcID, hidden)
    local cat = MyNamePlatesDB.categories[categoryID]
    if not cat then return end
    cat.hidden = cat.hidden or {}
    cat.hidden[npcID] = hidden or nil
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:IsNpcHidden(categoryID, npcID)
    local cat = MyNamePlatesDB.categories[categoryID]
    return cat and cat.hidden and cat.hidden[npcID] == true
end

function ns:SetNpcHighlighted(categoryID, npcID, on)
    local cat = MyNamePlatesDB.categories[categoryID]
    if not cat then return end
    cat.highlighted = cat.highlighted or {}
    cat.highlighted[npcID] = on or nil
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:IsNpcHighlighted(categoryID, npcID)
    local cat = MyNamePlatesDB.categories[categoryID]
    return cat and cat.highlighted and cat.highlighted[npcID] == true
end

function ns:GetCategoryHighlightColor(categoryID)
    local cat = MyNamePlatesDB.categories[categoryID]
    return (cat and cat.highlightColor) or { 1.0, 0.1, 0.1, 1.0 }
end

function ns:SetCategoryHighlightColor(categoryID, r, g, b, a)
    local cat = MyNamePlatesDB.categories[categoryID]
    if not cat then return end
    cat.highlightColor = { r, g, b, a or 1.0 }
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

----------------------------------------------------------------------
-- Apply / Reset
----------------------------------------------------------------------
function ns:ApplyAll()
    -- Global options: most are CVars, but some call into the C_NamePlate
    -- API via their `apply` function.
    for _, e in ipairs(ns.GLOBAL) do
        local value = MyNamePlatesDB.global[e.key]
        if value ~= nil then
            if e.apply then
                e.apply(value)
            else
                ApplyCVar(e.key, value)
            end
        end
    end

    -- Plate size: skip when values are still at our addon defaults,
    -- otherwise we'd force Blizzard's *small* nameplate size (110x45)
    -- even when the player has Large Nameplates enabled (modern default,
    -- which uses 154x64).  Calling SetNamePlate*Size with the smaller
    -- value shrinks the click box below the visible plate and breaks
    -- click-targeting.  Only apply when the user has explicitly resized.
    local ps = MyNamePlatesDB.plateSize
    if ps and (ps.friendlyWidth ~= 110 or ps.friendlyHeight ~= 45
                or ps.enemyWidth ~= 110 or ps.enemyHeight ~= 45) then
        ApplyPlateSize()
    end

    -- Per-category master CVars (visibility toggles).  Skip CVar-less
    -- categories like Hunter Pets — their "enabled" flag is enforced by
    -- per-plate hide in Discovery.lua.
    for id, cat in pairs(MyNamePlatesDB.categories) do
        local def = ns.CATEGORY_BY_ID[id]
        if def and def.cvar and cat.enabled then
            ApplyCVar(def.cvar, cat.enabled)
        end
    end

    -- Re-apply per-nameplate overrides
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:ResetAll()
    MyNamePlatesDB = BuildDefaults()
    ns:ApplyAll()
    if ns.RefreshUI then ns:RefreshUI() end
end

----------------------------------------------------------------------
-- Event handler
----------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Bump this when the auto-classification logic changes meaningfully so that
-- stale `discovered` entries get wiped and re-classified on next plate spawn.
local CLASSIFIER_VERSION = 7

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        MyNamePlatesDB = MyNamePlatesDB or {}
        MergeDefaults(MyNamePlatesDB, BuildDefaults())
        if MyNamePlatesDB.classifierVersion ~= CLASSIFIER_VERSION then
            MyNamePlatesDB.npcs = {}
            MyNamePlatesDB.classifierVersion = CLASSIFIER_VERSION
        end
    elseif event == "PLAYER_LOGIN" then
        ns:ApplyAll()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Re-apply CVars and re-grab nameplates after every zone change
        -- (arena/BG entry, dungeon, etc.). Blizzard rebuilds the nameplate
        -- frames here and may reset CVars; without this, our settings
        -- don't take effect until next /reload.
        ns:ApplyAll()
        if ns.RescanAllPlates then ns:RescanAllPlates() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        FlushPending()
    end
end)

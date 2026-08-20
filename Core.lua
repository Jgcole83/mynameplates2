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
                iconSize       = 30,          -- BBP parity (their fixed size)
                iconAnchor     = "TOP",
                iconXOffset    = 0,
                iconYOffset    = 22,
                -- 1.36.3: icon appearance controls.
                --
                -- tintIcon: BBP applies the totem color as a multiplicative
                --   vertex-color tint on the icon texture — with a dark
                --   generic color (brown 0.40, 0.34, 0.21) this darkens
                --   every pixel to ~40% brightness and reads as a "faded
                --   black" wash on the plate.  Default OFF so the icon
                --   renders in its natural spellbook colors (bright and
                --   readable); the healthbar / name still get the totem
                --   color, so classification cues aren't lost.  Users who
                --   want strict BBP parity can turn this back on.
                --
                -- iconAlpha: opacity multiplier on the icon texture.  1.0
                --   = fully opaque (default), 0.10 = nearly transparent.
                --   Useful when the icon is visually competing with the
                --   healthbar or name text.
                tintIcon             = false,
                iconAlpha            = 1.0,

                -- 1.36.4: healthbar opacity.  Applied to the totem's
                -- HealthBarsContainer alpha via a persistent marker
                -- (uf.MyNP_totemHbAlpha) that our Discovery SetAlpha
                -- reassert hook re-applies whenever Blizzard writes a
                -- different value.  Multiplies with the category-level
                -- plate alpha (Enemy Totems opacity slider) — set both
                -- to 0.5 and you get 25% effective opacity.  Set this
                -- to 1.0 (default) to leave the healthbar untouched.
                -- Interacts with hideHealthBar: when hideHealthBar is
                -- on AND the totem is NOT the current target, the
                -- healthbar is hidden entirely (alpha=0) regardless of
                -- this setting; otherwise this value applies.
                healthBarAlpha       = 1.0,
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
                -- 1.36.28: split ICON gate from NAME gate.  Prior to this
                -- version, `types` above governed BOTH the text overlay AND
                -- the icon overlay — flipping "Warlock Pets" off silenced
                -- Observer's NAME *and* hid its icon.  Users asked for a
                -- dedicated "Summon Icons & Names" tab where the two can
                -- be controlled independently (see UI.lua).
                --
                -- New behavior: `types` still gates the text label (existing
                -- semantics preserved); `iconTypes` gates the icon overlay.
                -- Fresh installs default to ALL true here so users see every
                -- fallback icon out of the box and can toggle off what they
                -- don't want.  A one-shot migration below (_iconTypesMigrated)
                -- copies existing users' `types` values into `iconTypes` so
                -- pre-1.36.28 saves get identical behavior on first login.
                iconTypes = {
                    totem       = true,
                    psyfiend    = true,
                    guardian    = true,
                    pet_hunter  = true,
                    pet_warlock = true,
                    pet_dk      = true,
                    pet_mage    = true,
                    minion      = true,
                    minor       = true,
                },
                -- 1.36.29: per-NPC-ID icon toggle for individual totems.
                -- Empty by default (all totem icons on).  Users can flip
                -- a specific important totem's icon off from the "Summon
                -- Icons & Names" UI tab -- writes `false` at that npcID
                -- key; missing / true keys count as ON.  Applies only
                -- when we can resolve the plate's npcID; anonymised
                -- arena plates fall through to type-level rendering.
                --
                -- Kept separate from `iconTypes` because the type gate
                -- is coarse (all totems on/off) while this is granular
                -- (Grounding on, Capacitor off, etc.).  Semantics: BOTH
                -- gates must pass for the icon to render.
                iconByNpcID = {},

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

-- 1.36.6: two independent paths, one per dimension, because Blizzard's
-- SetNamePlateSize in Midnight 12.x only affects visible width — the
-- height parameter resizes the invisible click box while the visible
-- bar height is driven independently by their internal anchor logic.
--
--   * WIDTH is applied via C_NamePlate.SetNamePlateSize(width, BOX_H)
--     with BOX_H fixed at a click-box-friendly value so we don't shrink
--     the click box below the visible bar (which breaks click-targeting).
--
--   * HEIGHT is applied per-plate via HealthBarsContainer:SetHeight,
--     hooked inside NamePlateUnitFrameMixin:UpdateAnchors so Blizzard
--     can't overwrite it on the next anchor refresh.  See
--     ApplyBarHeight / _installBarHeightHook below.
--
-- Legacy clients (pre-Midnight retail / classic) still expose the split
-- friendly/enemy setters; we fall through to them so the width path
-- stays compatible with older client versions.
local NAMEPLATE_BOX_HEIGHT = 45      -- click-box height (invisible)

local function ApplyPlateSize()
    local ps = MyNamePlatesDB and MyNamePlatesDB.plateSize
    if not ps then return end
    if InCombatLockdown() then
        pendingPlateSize = true
        return
    end
    if not C_NamePlate then return end
    local w = tonumber(ps.width) or 110
    if C_NamePlate.SetNamePlateSize then
        pcall(C_NamePlate.SetNamePlateSize, w, NAMEPLATE_BOX_HEIGHT)
    elseif C_NamePlate.SetNamePlateFriendlySize then
        -- Legacy retail path — pre-Midnight clients still expose the
        -- split setters.  Apply the same value to both so behavior
        -- matches the unified path.
        pcall(C_NamePlate.SetNamePlateFriendlySize, w, NAMEPLATE_BOX_HEIGHT)
        pcall(C_NamePlate.SetNamePlateEnemySize,    w, NAMEPLATE_BOX_HEIGHT)
    end
end

-- 1.36.6: per-plate visible-bar-height enforcement.  Passing height to
-- C_NamePlate.SetNamePlateSize only resizes the click box in Midnight,
-- so the actual visible bar has to be resized on the HealthBarsContainer
-- directly.  Blizzard drives this height from NamePlateUnitFrameMixin:
-- UpdateAnchors every time it fires, which means a one-shot SetHeight
-- gets overwritten within a frame.  We hook UpdateAnchors and reassert
-- our value inside — the same technique BBP uses (midnight/BetterBlizz-
-- Plates.lua:9580 HookHealthbarHeight + line 2634 AdjustHealthBarHeight).
--
-- 1.36.27: extended to also enforce per-plate WIDTH.  Blizzard's
-- C_NamePlate.SetNamePlateSize applies width GLOBALLY; there is no
-- per-plate width API.  For categories that opt in (currently just
-- enemyNPCs, but the mechanism is category-agnostic) we override the
-- visible-bar width via HealthBarsContainer:SetWidth in the same
-- UpdateAnchors hook, keyed off a per-uf stash (uf.MyNP_dimsWidth /
-- uf.MyNP_dimsHeight) written by Discovery.lua's ApplyOverrides when
-- the plate is classified into a category with dims overrides.  Nil
-- stash = "inherit global" = current behavior unchanged.
--
-- Note: this affects only the VISIBLE bar.  Click-box size stays
-- global (there's no way around that on Blizzard's API), so a very
-- narrow per-cat width will still have the standard click box for
-- selection.  That's a fine trade-off for the intent (visual only).
local function _applyBarHeightToFrame(frame)
    if not frame then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    local hbc = frame.HealthBarsContainer
    if not hbc then return end

    -- Height: per-uf stash wins over global.  Global default falls back
    -- to MyNamePlatesDB.plateSize.height (the Plate Size tab).
    local h = tonumber(frame.MyNP_dimsHeight)
    if not h then
        h = tonumber(MyNamePlatesDB and MyNamePlatesDB.plateSize
                     and MyNamePlatesDB.plateSize.height)
    end
    if h then pcall(hbc.SetHeight, hbc, h) end

    -- Width: only applied when a per-plate override exists.  Global
    -- width is driven by C_NamePlate.SetNamePlateSize elsewhere and
    -- we don't want to fight it on plates that DON'T have an override.
    -- Blizzard's UpdateAnchors will restore the global width naturally
    -- when a plate transitions to a category without an override
    -- (Discovery.lua clears MyNP_dimsWidth in that case).
    local w = tonumber(frame.MyNP_dimsWidth)
    if w then pcall(hbc.SetWidth, hbc, w) end
end

local _barHeightHookInstalled = false
local function _installBarHeightHook()
    if _barHeightHookInstalled then return end
    if not (NamePlateUnitFrameMixin and NamePlateUnitFrameMixin.UpdateAnchors) then return end
    hooksecurefunc(NamePlateUnitFrameMixin, "UpdateAnchors", _applyBarHeightToFrame)
    _barHeightHookInstalled = true
end

local function ApplyBarHeight()
    _installBarHeightHook()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        _applyBarHeightToFrame(plate.UnitFrame)
    end
end

-- 1.36.27: expose _applyBarHeightToFrame under a name that reflects
-- its new dual-purpose role (width + height).  Discovery.lua calls
-- this after writing per-plate stashes so changes take effect
-- immediately instead of waiting for the next UpdateAnchors fire.
function ns:ApplyDimensionsToFrame(frame)
    _applyBarHeightToFrame(frame)
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
    if key == "height" then
        ApplyBarHeight()
    else
        ApplyPlateSize()
    end
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

-- 1.36.27: per-category plate dimensions.  Nil DB value = "inherit
-- global width/height from the Plate Size tab" (the pre-1.36.27
-- behavior for every plate).  Setting a value writes a numeric
-- override that Discovery.lua stashes on the plate's uf whenever
-- the plate is classified into this category — the UpdateAnchors
-- hook in _applyBarHeightToFrame reads that stash on every anchor
-- refresh.  UI currently exposes this on the Enemy NPCs tab
-- (Categories.lua { dimensions = true }); the data model is
-- category-agnostic so other tabs can opt in later.
function ns:GetCategoryWidth(id)
    local cat = MyNamePlatesDB.categories[id]
    return cat and tonumber(cat.width) or nil
end

function ns:GetCategoryHeight(id)
    local cat = MyNamePlatesDB.categories[id]
    return cat and tonumber(cat.height) or nil
end

function ns:SetCategoryWidth(id, value)
    local cat = MyNamePlatesDB.categories[id]
    if not cat then return end
    cat.width = value            -- nil clears the override
    if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
end

function ns:SetCategoryHeight(id, value)
    local cat = MyNamePlatesDB.categories[id]
    if not cat then return end
    cat.height = value
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

    -- Plate width: skip when at our default 110 — otherwise we'd force
    -- Blizzard's *small* nameplate width even when the player has Large
    -- Nameplates enabled (Blizzard's actual default is 145 or 185 with
    -- Large Nameplates on per BBP's midnight source).  Calling
    -- SetNamePlateSize with the smaller value shrinks the click box
    -- below the visible plate and breaks click-targeting.  Only apply
    -- when the user has explicitly widened.
    local ps = MyNamePlatesDB.plateSize
    if ps and ps.width ~= 110 then
        ApplyPlateSize()
    end
    -- Plate bar height: always install the UpdateAnchors hook so any
    -- future config change takes effect on the next anchor refresh.
    -- The hook body reads the DB fresh each time, so it's idempotent
    -- and self-updating.  Cheap: one SetHeight call per anchor refresh.
    ApplyBarHeight()

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
-- 1.36.1 note: NpcData entries gained optional spellID + important fields
-- but the auto-classification algorithm didn't change, so this stays at 7.
-- User-added `/mnp add` entries and auto-discovered records are preserved.
local CLASSIFIER_VERSION = 7

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        MyNamePlatesDB = MyNamePlatesDB or {}
        MergeDefaults(MyNamePlatesDB, BuildDefaults())
        if MyNamePlatesDB.classifierVersion ~= CLASSIFIER_VERSION then
            MyNamePlatesDB.npcs = {}
            MyNamePlatesDB.classifierVersion = CLASSIFIER_VERSION
        end

        -- 1.36.1 one-shot migration: bump users who still have the old
        -- iconSize = 26 default up to the new 30 (BBP parity).  Users
        -- who explicitly chose 26 in 1.35.x lose that choice here — the
        -- assumption is that anyone who set it to exactly 26 either
        -- accepted the old default or wanted BBP parity anyway.  Any
        -- other value (28, 34, 40, ...) is treated as an intentional
        -- pick and preserved.  Guarded by a version flag so this
        -- migration runs exactly once per DB.
        if not MyNamePlatesDB._iconSize30Applied then
            local L = MyNamePlatesDB.labels
            local pt = L and L.petTotemName
            if pt and tonumber(pt.iconSize) == 26 then
                pt.iconSize = 30
            end
            MyNamePlatesDB._iconSize30Applied = true
        end

        -- 1.36.5 one-shot migration: consolidate the four old plate-
        -- size keys (friendlyWidth / friendlyHeight / enemyWidth /
        -- enemyHeight) into the two new unified keys (width / height).
        -- The four old sliders silently no-op'd on retail Midnight
        -- 12.x because Blizzard removed SetNamePlateFriendlySize /
        -- SetNamePlateEnemySize; the addon should have been calling
        -- the unified SetNamePlateSize the whole time.  Uses math.max
        -- of each dimension so users who explicitly widened either
        -- friendly or enemy plates keep the larger value (matches
        -- BBP's own consolidation strategy at midnight/BetterBlizz-
        -- Plates.lua:2052).  Old keys are DROPPED so MergeDefaults
        -- next boot doesn't reintroduce them.  Guarded by a version
        -- flag so this runs exactly once per DB.
        if not MyNamePlatesDB._plateSizeUnified then
            local ps = MyNamePlatesDB.plateSize
            if ps then
                local fw = tonumber(ps.friendlyWidth)
                local ew = tonumber(ps.enemyWidth)
                local fh = tonumber(ps.friendlyHeight)
                local eh = tonumber(ps.enemyHeight)
                -- Only migrate a value in when the user had actually
                -- changed one of the old keys away from the pre-1.36.5
                -- default (110x45).  Otherwise leave the new keys at
                -- their defaults (already applied by MergeDefaults).
                if fw or ew or fh or eh then
                    local mw = math.max(fw or 110, ew or 110)
                    local mh = math.max(fh or 45,  eh or 45)
                    if mw ~= 110 or mh ~= 45 then
                        ps.width  = mw
                        ps.height = mh
                    end
                end
                ps.friendlyWidth  = nil
                ps.friendlyHeight = nil
                ps.enemyWidth     = nil
                ps.enemyHeight    = nil
            end
            MyNamePlatesDB._plateSizeUnified = true
        end

        -- 1.36.6 one-shot migration: `height`'s semantics changed from
        -- "click-box height passed to SetNamePlateSize" (which visibly
        -- did nothing in Midnight — see the CVars.lua header for the
        -- gory details) to "visible healthbar height applied via
        -- HealthBarsContainer:SetHeight per plate".  The old default
        -- was 45 and the slider range went up to 120; the new default
        -- is 10 with a max of 40.  If we leave existing users' saved
        -- height at the old value, their bar shoots up to 45px on next
        -- login — which is enormous and looks broken.
        --
        -- Strategy: if the stored height is ≥ 40 (i.e. anywhere near
        -- the old default range), treat that as "user was flailing at
        -- a slider that didn't work" and reset to the new default 10.
        -- Values below 40 might have been intentional (someone testing
        -- lower values pre-1.36.6) so we keep them.  Guarded by a
        -- version flag so this runs exactly once per DB.
        if not MyNamePlatesDB._plateBarHeightMigrated then
            local ps = MyNamePlatesDB.plateSize
            if ps then
                local h = tonumber(ps.height)
                if h and h >= 40 then
                    ps.height = 10
                end
            end
            MyNamePlatesDB._plateBarHeightMigrated = true
        end

        -- 1.36.25 one-shot migration: enemyPlayers split.  Prior versions
        -- had a single "Enemy Players & NPCs" master (id "enemyPlayers")
        -- that governed scale/alpha for both real hostile players AND
        -- every hostile NPC / unclassified summon.  1.36.25 splits the
        -- NPC/summon fallback into a new enemyNPCs category (see
        -- Categories.lua).  Without migration, users who had tuned the
        -- old catch-all (e.g. alpha 0.6 to dim mobs) would see all NPC
        -- plates snap back to 1.0/1.0 defaults on first login post-
        -- update while their enemyPlayers slider values (now players
        -- only) were preserved.  That reads as "the mod broke".
        --
        -- Fix: copy the pre-split enemyPlayers scale, alpha, hidden,
        -- highlighted, and highlightColor into the newly created
        -- enemyNPCs entry.  Existing NPC plate appearance therefore
        -- stays identical to how it looked before the split; users can
        -- then split them apart at their leisure by editing either tab.
        -- The `enabled` field is left at its own default (both start
        -- enabled) since enemyPlayers's CVar-driven visibility isn't
        -- meaningful for the CVar-less enemyNPCs category.
        --
        -- MergeDefaults above already created enemyNPCs at defaults, so
        -- we detect a fresh split by checking the version flag rather
        -- than "did enemyNPCs exist" (it always does now).
        if not MyNamePlatesDB._enemyNpcSplitMigrated then
            local ep = MyNamePlatesDB.categories and MyNamePlatesDB.categories.enemyPlayers
            local en = MyNamePlatesDB.categories and MyNamePlatesDB.categories.enemyNPCs
            if ep and en then
                en.scale       = ep.scale or en.scale
                en.alpha       = ep.alpha or en.alpha
                if ep.hidden then
                    en.hidden = en.hidden or {}
                    for k, v in pairs(ep.hidden) do en.hidden[k] = v end
                end
                if ep.highlighted then
                    en.highlighted = en.highlighted or {}
                    for k, v in pairs(ep.highlighted) do en.highlighted[k] = v end
                end
                if ep.highlightColor then
                    en.highlightColor = { ep.highlightColor[1], ep.highlightColor[2],
                                          ep.highlightColor[3], ep.highlightColor[4] }
                end
            end
            MyNamePlatesDB._enemyNpcSplitMigrated = true
        end

        -- 1.36.28 one-shot migration: split icon/name gates for the
        -- pet+totem block.  Prior to this version, `types` governed both
        -- the text overlay and the icon overlay — so a user who had
        -- disabled the "Warlock Pets" text (default) silently also
        -- silenced Warlock Pet icons.  1.36.28 introduces `iconTypes`
        -- as the new icon gate (Labels.lua) and adds a dedicated
        -- "Summon Icons & Names" UI tab that lets the user toggle each
        -- independently.
        --
        -- Fresh defaults set iconTypes = all true so new installs see
        -- every fallback icon.  Existing DBs still have `types` set to
        -- whatever the user picked (or the pre-1.36.28 defaults where
        -- only totem+psyfiend were on) — carry those choices over so
        -- upgraders' icons don't suddenly light up for pets they'd
        -- muted.  Guarded by a version flag so it runs exactly once.
        if not MyNamePlatesDB._iconTypesSplitMigrated then
            local L  = MyNamePlatesDB.labels
            local pt = L and L.petTotemName
            if pt and pt.types then
                pt.iconTypes = pt.iconTypes or {}
                for k, v in pairs(pt.types) do
                    if pt.iconTypes[k] == nil then
                        pt.iconTypes[k] = v
                    end
                end
            end
            MyNamePlatesDB._iconTypesSplitMigrated = true
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

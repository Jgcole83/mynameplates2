-- UI.lua
-- Builds the Settings panel: a root "MyNamePlates" category plus one
-- subcategory per entry in ns.CATEGORIES.

local addonName, ns = ...

local PANEL_TITLE = "MyNamePlates"
local PAD         = 16
local ROW         = 26
local SLIDER_W    = 220

----------------------------------------------------------------------
-- Common widget factories
----------------------------------------------------------------------
local refreshHooks = {}    -- list of fns called on reset / on /mnp refresh

local function MakeHeading(parent, text)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetText(text)
    fs:SetTextColor(1, 0.82, 0)
    return fs
end

local function MakeLabel(parent, text, color)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetText(text)
    if color then fs:SetTextColor(unpack(color)) end
    return fs
end

local function AttachTooltip(widget, title, body, extra)
    if not (title or body) then return end
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if title then GameTooltip:SetText(title, 1, 1, 1) end
        if body  then GameTooltip:AddLine(body, nil, nil, nil, true) end
        if extra then GameTooltip:AddLine(extra, 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

local function MakeCheckbox(parent, label, getter, setter, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb.Text:SetText(label)
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self) setter(self:GetChecked()) end)
    if tooltip then AttachTooltip(cb, label, tooltip) end
    table.insert(refreshHooks, function() cb:SetChecked(getter()) end)
    return cb
end

local function MakeSlider(parent, entry, getter, setter)
    local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    s:SetWidth(SLIDER_W)
    s:SetMinMaxValues(entry.min, entry.max)
    s:SetValueStep(entry.step)
    s:SetObeyStepOnDrag(true)

    local title = s:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
    title:SetText(entry.label)

    local valueText = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valueText:SetPoint("BOTTOMRIGHT", s, "TOPRIGHT", 0, 2)

    if s.Low  then s.Low:SetText(tostring(entry.min))  end
    if s.High then s.High:SetText(tostring(entry.max)) end

    local function fmt(v)
        return entry.step >= 1 and string.format("%d", v) or string.format("%.2f", v)
    end

    local function refresh()
        local v = getter()
        s:SetValue(v)
        valueText:SetText(fmt(v))
    end
    refresh()

    s:SetScript("OnValueChanged", function(_, value)
        if entry.step >= 1 then
            value = math.floor(value + 0.5)
        else
            value = math.floor(value / entry.step + 0.5) * entry.step
        end
        setter(value)
        valueText:SetText(fmt(value))
    end)

    AttachTooltip(s, entry.label, entry.tooltip)
    table.insert(refreshHooks, refresh)
    return s
end

----------------------------------------------------------------------
-- Header (title + reset) shared by every page
----------------------------------------------------------------------
local function AddHeader(panel, title, subtitle)
    local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    t:SetPoint("TOPLEFT", PAD, -PAD)
    t:SetText(title)

    local sub
    if subtitle then
        sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        sub:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -4)
        sub:SetWidth(500)
        sub:SetJustifyH("LEFT")
        sub:SetText(subtitle)
    end

    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("TOPRIGHT", -PAD, -PAD)
    reset:SetText("Reset All Settings")
    reset:SetScript("OnClick", function() ns:ResetAll() end)

    return t, sub, reset
end

----------------------------------------------------------------------
-- Color swatch button (opens the Blizzard color picker).  Defined
-- BEFORE BuildGeneralPanel so the General page's friendly-color picker
-- can use it.  (Lua resolves names lexically; functions defined after
-- BuildGeneralPanel would be looked up as globals at call time and
-- find nothing.)
----------------------------------------------------------------------
local function MakeColorSwatch(parent, getter, setter)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(22, 22)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0, 0, 0, 1)
    bg:SetAllPoints()

    local fill = btn:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetPoint("TOPLEFT",     1,  -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)

    local function refresh()
        local c = getter()
        fill:SetVertexColor(c[1] or 1, c[2] or 0, c[3] or 0, 1)
    end
    refresh()

    btn:SetScript("OnClick", function()
        local c = getter()
        local r, g, b = c[1] or 1, c[2] or 0, c[3] or 0
        local function onChange()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            setter(nr, ng, nb, 1.0)
            refresh()
        end
        local function onCancel(prev)
            if prev then setter(prev.r, prev.g, prev.b, 1.0); refresh() end
        end
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = r, g = g, b = b,
                hasOpacity = false,
                swatchFunc = onChange,
                cancelFunc = onCancel,
            })
        else
            ColorPickerFrame.func        = onChange
            ColorPickerFrame.cancelFunc  = onCancel
            ColorPickerFrame.hasOpacity  = false
            ColorPickerFrame.previousValues = { r = r, g = g, b = b }
            ColorPickerFrame:SetColorRGB(r, g, b)
            ColorPickerFrame:Hide()
            ColorPickerFrame:Show()
        end
    end)

    btn.Refresh = refresh
    AttachTooltip(btn, "Color picker",
        "Click to open the color picker for this swatch.")
    return btn
end

----------------------------------------------------------------------
-- General page (global CVars + plate width/height)
----------------------------------------------------------------------
local function BuildGeneralPanel(panel)
    AddHeader(panel, "MyNamePlates",
        "Global nameplate behaviour.  Per-category options live in the subcategories below.")

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
    scroll:SetPoint("BOTTOMRIGHT", -PAD * 2, PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local y = -8

    -- Single global toggle
    for _, e in ipairs(ns.GLOBAL) do
        if e.type == "toggle" then
            local cb = MakeCheckbox(content, e.label,
                function() return ns:GetGlobal(e.key) == "1" end,
                function(on) ns:SetGlobal(e.key, on and "1" or "0") end,
                e.tooltip)
            cb:SetPoint("TOPLEFT", 8, y)
            y = y - ROW
        end
    end

    y = y - 6
    MakeHeading(content, "Global Scale"):SetPoint("TOPLEFT", 0, y); y = y - 22
    for _, e in ipairs(ns.GLOBAL) do
        if e.type == "slider" and e.key:find("Scale") then
            local s = MakeSlider(content, e,
                function() return ns:GetGlobal(e.key) end,
                function(v) ns:SetGlobal(e.key, v)    end)
            s:SetPoint("TOPLEFT", 8, y - 14)
            y = y - 44
        end
    end

    y = y - 6
    MakeHeading(content, "Friendly Plate Color"):SetPoint("TOPLEFT", 0, y); y = y - 22

    local fcCb = MakeCheckbox(content, "Override friendly healthbar color",
        function() local c = ns:GetFriendlyColor(); return c and c.enabled == "1" end,
        function(on) ns:SetFriendlyColorEnabled(on) end,
        "Replace the default green friendly healthbar with your chosen color.")
    fcCb:SetPoint("TOPLEFT", 8, y); y = y - ROW

    local fcSwatch = MakeColorSwatch(content,
        function()
            local c = ns:GetFriendlyColor() or {}
            return { c.r or 0.2, c.g or 0.85, c.b or 0.2, c.a or 1 }
        end,
        function(r, g, b, a) ns:SetFriendlyColorRGB(r, g, b, a) end)
    fcSwatch:SetPoint("TOPLEFT", 8, y - 4)

    local fcSwatchLabel = MakeLabel(content, "Click swatch to pick color", { 0.7, 0.7, 0.7 })
    fcSwatchLabel:SetPoint("LEFT", fcSwatch, "RIGHT", 6, 0)
    y = y - ROW - 4

    local fcPlayers = MakeCheckbox(content, "Apply to friendly players",
        function() local c = ns:GetFriendlyColor(); return c and c.applyToPlayers ~= false end,
        function(on) ns:SetFriendlyColorTarget("players", on) end)
    fcPlayers:SetPoint("TOPLEFT", 8, y); y = y - ROW

    local fcNPCs = MakeCheckbox(content, "Apply to friendly NPCs",
        function() local c = ns:GetFriendlyColor(); return c and c.applyToNPCs ~= false end,
        function(on) ns:SetFriendlyColorTarget("npcs", on) end)
    fcNPCs:SetPoint("TOPLEFT", 8, y); y = y - ROW

    y = y - 6
    MakeHeading(content, "Plate Width / Bar Height"):SetPoint("TOPLEFT", 0, y); y = y - 22
    -- 1.36.6 note: retail Midnight drives the two dimensions with
    -- entirely different APIs.  Width goes through the unified
    -- C_NamePlate.SetNamePlateSize; visible bar height has to be
    -- applied per-plate via HealthBarsContainer:SetHeight inside a
    -- UpdateAnchors hook because Blizzard's height parameter to
    -- SetNamePlateSize only resizes the invisible click box.  Both
    -- sliders apply to friendly AND enemy plates.
    local note = MakeLabel(content,
        "Applies to friendly AND enemy plates.  Leave width at 110 to use Blizzard's own default (145 or 185 with Large Nameplates on).  Bar height defaults to 10 (Blizzard's own default) — drag lower for thinner, higher for thicker.",
        { 0.7, 0.7, 0.7 })
    note:SetPoint("TOPLEFT", 8, y - 2)
    y = y - 32
    for _, e in ipairs(ns.PLATE_SIZE) do
        local s = MakeSlider(content, e,
            function() return ns:GetPlateSize(e.key) end,
            function(v) ns:SetPlateSize(e.key, v)    end)
        s:SetPoint("TOPLEFT", 8, y - 14)
        y = y - 44
    end

    y = y - 6
    MakeHeading(content, "Global Opacity"):SetPoint("TOPLEFT", 0, y); y = y - 22
    for _, e in ipairs(ns.GLOBAL) do
        if e.type == "slider" and e.key:find("Alpha") then
            local s = MakeSlider(content, e,
                function() return ns:GetGlobal(e.key) end,
                function(v) ns:SetGlobal(e.key, v)    end)
            s:SetPoint("TOPLEFT", 8, y - 14)
            y = y - 44
        end
    end

    content:SetSize(560, -y + PAD)
end

----------------------------------------------------------------------
-- Category page common parts (master toggle + scale + alpha sliders)
----------------------------------------------------------------------
local SCALE_ENTRY = { key = "scale", label = "Scale (this category)",
                      tooltip = "Multiplier applied to nameplates in this category. 1.00 = no override.",
                      min = 0.5, max = 2.0, step = 0.05, default = 1.0 }
local ALPHA_ENTRY = { key = "alpha", label = "Opacity (this category)",
                      tooltip = "Opacity multiplier for nameplates in this category. 1.00 = no override.",
                      min = 0.0, max = 1.0, step = 0.05, default = 1.0 }

-- 1.36.27: per-category plate dimensions.  Ranges match the global
-- Plate Size sliders (CVars.lua ns.PLATE_SIZE) so a user who's
-- already comfortable with those knows the scale of the values here.
-- These are absolute pixel values applied on top of any category
-- scale multiplier — a 130-wide plate scaled to 1.2 renders 156px
-- wide.  Only shown on tabs with { dimensions = true } in
-- Categories.lua (currently Enemy NPCs).
local WIDTH_ENTRY  = { key = "width",  label = "Width (this category, px)",
                       tooltip = "Overrides the visible healthbar width for plates on this tab only.  Global Plate Size width still governs every other tab.  Click 'Reset to global' to clear the override.",
                       min = 50, max = 300, step = 1, default = 110 }
local HEIGHT_ENTRY = { key = "height", label = "Height (this category, px)",
                       tooltip = "Overrides the visible healthbar height for plates on this tab only.  Global Plate Size height still governs every other tab.  Click 'Reset to global' to clear the override.",
                       min = 2,  max = 40,  step = 1, default = 10  }

----------------------------------------------------------------------
-- 1.35.1: Shared BBP-parity totem indicator controls.
--
-- These controls live in MyNamePlatesDB.labels.petTotemName (a single
-- global settings block — one indicator for all totems, matching BBP's
-- own architecture where there's ONE Totem Indicator config that
-- applies to every totem plate).
--
-- We surface the same block in three places for discoverability:
--   1. Labels tab → Pet & Totem Name block (where text + icon settings
--      live together — mirrors "totem name + totem icon are two sides
--      of the same feature").
--   2. Enemy Totems category tab (primary discoverability — this is
--      where users go looking for "how do I customize enemy totems").
--   3. Enemy Psyfiend category tab (Psyfiend uses the same indicator
--      classification as regular totems via UnitChannelInfo).
--
-- All three UI instances edit the SAME saved-variable path, so changes
-- in one tab reflect immediately in the others.  This keeps the mental
-- model simple ("one totem indicator config") while making the controls
-- easy to find no matter which tab the user starts on.
----------------------------------------------------------------------
local TOTEM_INDICATOR_TOGGLES = {
    { key = "enemiesOnly",         label = "Enemies only",
      tip = "Show the indicator on enemy totems only.  Matches BBP's totemIndicatorEnemyOnly." },
    { key = "showOtherIcons",      label = "Show other icons",
      tip = "Render an icon on non-important totems too.  Off = only Capacitor / Psyfiend / Grounding-class totems get an icon." },
    { key = "showCooldownSwipe",   label = "Cooldown swipe",
      tip = "Show a reverse-fill cooldown swipe over the icon for Capacitor (2s) and Psyfiend (12s).  Matches BBP's showTotemIndicatorCooldownSwipe." },
    { key = "noGlow",              label = "No glow",
      tip = "Disable the important-totem glow halo.  Matches BBP's totemIndicatorNoGlow." },
    { key = "noAnimation",         label = "No animation",
      tip = "Disable the pulse animation on important-totem icons.  Matches BBP's totemIndicatorNoAnimation." },
    { key = "colorHealthBar",      label = "Color HP (important)",
      tip = "Recolor the healthbar with the totem's color for important totems (Capacitor/Psyfiend orange/purple, Grounding magenta).  Matches BBP's totemIndicatorColorHealthBar." },
    { key = "colorHealthBarOthers",label = "Color HP (others)",
      tip = "Recolor the healthbar with the generic totem color for non-important totems.  Matches BBP's totemIndicatorColorOtherHealthBars." },
    { key = "colorName",           label = "Color name (important)",
      tip = "Recolor the name text with the totem color for important totems.  Matches BBP's totemIndicatorColorName." },
    { key = "colorNameOthers",     label = "Color name (others)",
      tip = "Recolor the name text with the generic totem color for non-important totems.  Matches BBP's totemIndicatorColorNameOthers." },
    { key = "hideHealthBar",       label = "Hide HP bar",
      tip = "Hide the healthbar entirely except when the totem is your current target.  Matches BBP's totemIndicatorHideHealthBar." },
    { key = "hideName",            label = "Hide name",
      tip = "Blank out the name text on classified totem plates.  Matches BBP's totemIndicatorHideNameAndShiftIconDown." },
    { key = "tintIcon",            label = "Tint icon (dim)",
      tip = "Multiply the icon texture by the totem color.  Off (default) = icon shows its natural bright spellbook colors — the healthbar/name still get the totem color for classification cues.  On = strict BBP parity (dim brown wash for generic totems, magenta wash for important ones)." },
}

-- Reusable helper that emits the full BBP-parity block onto `parent`
-- starting at `startY`, returning the new y-cursor.  Layout is the
-- same across every host tab so users see a consistent panel.
--
-- IMPORTANT: writes to MyNamePlatesDB.labels.petTotemName — a
-- SHARED global block.  Every host tab edits the same underlying
-- settings; the same block on the Labels tab, Enemy Totems tab, and
-- Enemy Psyfiend tab all reflect the same values.
local function BuildTotemIndicatorControls(parent, startY, options)
    options = options or {}
    local labelKey = "petTotemName"
    local y = startY

    local behavHeading = MakeLabel(parent,
        options.heading or "Totem indicator (BBP parity):",
        { 1.0, 0.85, 0.3 })
    behavHeading:SetPoint("TOPLEFT", 8, y - 4)

    -- 1.36.2: dedicated Test button at the block heading.  Toggles the
    -- same ns.testMode.petTotemName state as the block-level Test on
    -- Labels → Pet & Totem Name, so all three instances stay in sync.
    -- When ON, _TotemIconType returns "totem" for every visible plate
    -- (see Labels.lua) — a target dummy, an enemy player, an ambient
    -- critter, whatever's on your screen renders the totem indicator
    -- with the current icon size / anchor / offset / color settings.
    -- Purpose: tune icon size on the fly against a target dummy in the
    -- world without needing to sit in an arena waiting for a totem
    -- to spawn.  State is NOT persisted — cleared on /reload.
    local testBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    testBtn:SetSize(100, 22)
    testBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, y - 2)
    local function refreshTestText()
        testBtn:SetText(ns.testMode and ns.testMode.petTotemName
                        and "Stop Test" or "Test Totems")
    end
    refreshTestText()
    testBtn:SetScript("OnClick", function()
        if not ns.testMode then return end
        if not ns.testMode.petTotemName then
            -- Coordinate with the two name test-modes on the Labels tab
            -- (they're mutually exclusive with petTotemName per the
            -- BuildLabelBlock Test-button logic).  If the user had
            -- either name test on, turn it off first so the two states
            -- don't produce the "one button still says Stop Test"
            -- confusion the block-level test callback already avoids.
            ns.testMode.name         = false
            ns.testMode.petTotemName = true
        else
            ns.testMode.petTotemName = false
        end
        refreshTestText()
        if ns.RefreshAllLabels then ns:RefreshAllLabels() end
    end)
    AttachTooltip(testBtn, "Test totem indicator",
        "Force the totem icon + color onto every visible nameplate so you can tune icon size / anchor / offsets / color live in the open world (target dummies work great).  Click again to revert.  Not saved to disk — cleared on /reload.")
    table.insert(refreshHooks, refreshTestText)

    y = y - ROW

    local behavNote = MakeLabel(parent,
        options.note
            or "Important totems (Capacitor / Psyfiend / Grounding) get glow + pulse + cooldown by default.",
        { 0.75, 0.75, 0.75 })
    behavNote:SetPoint("TOPLEFT", 8, y - 4)
    y = y - ROW

    -- Two-column layout for the toggle grid (mirrors BBP's Advanced
    -- Settings layout).
    local togStartY = y
    for i, t in ipairs(TOTEM_INDICATOR_TOGGLES) do
        local col = ((i - 1) % 2 == 0) and 8 or 200
        local r   = math.floor((i - 1) / 2)
        local ty  = togStartY - (r * ROW)
        local tk  = t.key
        local cb = MakeCheckbox(parent, t.label,
            function() local c = ns:GetLabelsConfig(labelKey); return c and c[tk] end,
            function(on) ns:SetLabelOption(labelKey, tk, on and true or false) end,
            t.tip)
        cb:SetPoint("TOPLEFT", col, ty)
    end
    local togRows = math.ceil(#TOTEM_INDICATOR_TOGGLES / 2)
    y = togStartY - (togRows * ROW) - 6

    -- 1.36.3: icon opacity slider.  Directly controls the alpha of
    -- SetVertexColor on the icon texture — dial from 0.10 (nearly
    -- transparent) to 1.00 (fully opaque, default).  Independent of
    -- the tintIcon checkbox: opacity applies whether the icon is
    -- rendered in natural colors or tinted.
    local ICON_ALPHA_SLIDER = { key = "iconAlpha", label = "Icon Opacity",
        tooltip = "How bright the icon appears.  1.00 = fully opaque (default).  Lower values fade the icon toward transparent — useful when the icon competes visually with the healthbar or the totem name.  Applies whether or not 'Tint icon' is on.",
        min = 0.10, max = 1.00, step = 0.05, default = 1.00 }
    local iconAlphaSlider = MakeSlider(parent, ICON_ALPHA_SLIDER,
        function() local c = ns:GetLabelsConfig(labelKey); return c and (c.iconAlpha or 1.0) or 1.0 end,
        function(v) ns:SetLabelOption(labelKey, "iconAlpha", v) end)
    iconAlphaSlider:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    -- 1.36.4: healthbar opacity slider.  Independent of the plate-
    -- level opacity (Enemy Totems tab → Opacity slider) — this
    -- controls JUST the totem's healthbar container.  Uses the same
    -- 3-layer stickiness as the color path: persistent marker on the
    -- uf (MyNP_totemHbAlpha) + Discovery SetAlpha reassert hook +
    -- 10 Hz RefreshAllLabels tick.  Interacts with "Hide HP bar":
    -- when hideHealthBar is on and the totem is NOT the current
    -- target, alpha is forced to 0; otherwise this slider's value
    -- applies.  0.00 = fully transparent, 1.00 = fully opaque
    -- (default; leaves the healthbar untouched).
    local HB_ALPHA_SLIDER = { key = "healthBarAlpha", label = "HP Bar Opacity",
        tooltip = "How opaque the totem's healthbar appears.  1.00 = fully opaque (default; leaves Blizzard's normal alpha alone).  0.00 = fully transparent.  Combines multiplicatively with the plate-level opacity on the Enemy Totems tab.  When 'Hide HP bar' is on, this value only applies while the totem is your current target.",
        min = 0.00, max = 1.00, step = 0.05, default = 1.00 }
    local hbAlphaSlider = MakeSlider(parent, HB_ALPHA_SLIDER,
        function() local c = ns:GetLabelsConfig(labelKey); return c and (c.healthBarAlpha or 1.0) or 1.0 end,
        function(v) ns:SetLabelOption(labelKey, "healthBarAlpha", v) end)
    hbAlphaSlider:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    -- Generic totem color picker (BBP totemIndicatorTotemColor).
    local gcLabel = MakeLabel(parent, "Generic totem color:", { 0.9, 0.9, 0.9 })
    gcLabel:SetPoint("TOPLEFT", 8, y - 4)
    local gcSwatch = MakeColorSwatch(parent,
        function()
            local c = ns:GetLabelsConfig(labelKey)
            return (c and c.genericColor) or { 0.40, 0.34, 0.21 }
        end,
        function(r, g, b)
            local c = ns:GetLabelsConfig(labelKey)
            if not c then return end
            local gc = c.genericColor
            if type(gc) ~= "table" then
                gc = { 0.40, 0.34, 0.21 }
                c.genericColor = gc
            end
            gc[1], gc[2], gc[3] = r, g, b
            if ns.RefreshAllLabels then ns:RefreshAllLabels() end
        end)
    gcSwatch:SetPoint("TOPLEFT", 150, y)
    local gcNote = MakeLabel(parent,
        "Used for unimportant totem icons + generic-totem HP/name recolor.",
        { 0.7, 0.7, 0.7 })
    gcNote:SetPoint("TOPLEFT", 8, y - ROW + 2)
    y = y - ROW - 18

    -- Optional cross-reference footer — points users to the other
    -- tabs so they know these settings are shared globally.
    if options.crossRef then
        local crossRef = MakeLabel(parent, options.crossRef,
            { 0.6, 0.6, 0.6 })
        crossRef:SetPoint("TOPLEFT", 8, y - 4)
        y = y - ROW
    end

    return y - 8
end

local function AddCategoryControls(content, def, startY)
    local y = startY

    local cb = MakeCheckbox(content, "Show " .. def.label,
        function() return ns:GetCategory(def.id).enabled == "1" end,
        function(on) ns:SetCategoryEnabled(def.id, on) end,
        def.cvar and ("CVar: " .. def.cvar) or nil)
    cb:SetPoint("TOPLEFT", 8, y)
    y = y - ROW - 6

    -- CVar-only categories (the parent "Friendly/Enemy Pets" tabs) just
    -- toggle a master CVar — every plate is routed to a per-class
    -- subcategory, so per-category scale/alpha here would be dead controls.
    if def.cvarOnly then
        return y
    end

    local s1 = MakeSlider(content, SCALE_ENTRY,
        function() return ns:GetCategory(def.id).scale or 1.0 end,
        function(v) ns:SetCategoryScale(def.id, v) end)
    s1:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    local s2 = MakeSlider(content, ALPHA_ENTRY,
        function() return ns:GetCategory(def.id).alpha or 1.0 end,
        function(v) ns:SetCategoryAlpha(def.id, v) end)
    s2:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    -- 1.36.27: per-category width / height sliders (opt-in via
    -- def.dimensions on the Categories.lua entry).  Nil DB value =
    -- inherit global; the slider shows the global fallback in that
    -- case so it never displays as "0px wide".  Reset button clears
    -- the override.
    if def.dimensions then
        local function globalW()
            return tonumber(MyNamePlatesDB and MyNamePlatesDB.plateSize
                            and MyNamePlatesDB.plateSize.width) or 110
        end
        local function globalH()
            return tonumber(MyNamePlatesDB and MyNamePlatesDB.plateSize
                            and MyNamePlatesDB.plateSize.height) or 10
        end

        local sw = MakeSlider(content, WIDTH_ENTRY,
            function() return ns:GetCategoryWidth(def.id) or globalW() end,
            function(v) ns:SetCategoryWidth(def.id, v) end)
        sw:SetPoint("TOPLEFT", 8, y - 14)
        local swReset = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        swReset:SetSize(140, 20)
        swReset:SetPoint("LEFT", sw, "RIGHT", 20, 0)
        swReset:SetText("Reset to global")
        swReset:SetScript("OnClick", function()
            ns:SetCategoryWidth(def.id, nil)
            if ns.RefreshUI then ns:RefreshUI() end
        end)
        AttachTooltip(swReset, "Reset width",
            "Clears the per-category width override on this tab; the global Plate Size width will apply again.")
        y = y - 44

        local sh = MakeSlider(content, HEIGHT_ENTRY,
            function() return ns:GetCategoryHeight(def.id) or globalH() end,
            function(v) ns:SetCategoryHeight(def.id, v) end)
        sh:SetPoint("TOPLEFT", 8, y - 14)
        local shReset = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        shReset:SetSize(140, 20)
        shReset:SetPoint("LEFT", sh, "RIGHT", 20, 0)
        shReset:SetText("Reset to global")
        shReset:SetScript("OnClick", function()
            ns:SetCategoryHeight(def.id, nil)
            if ns.RefreshUI then ns:RefreshUI() end
        end)
        AttachTooltip(shReset, "Reset height",
            "Clears the per-category height override on this tab; the global Plate Size height will apply again.")
        y = y - 44
    end

    return y
end

----------------------------------------------------------------------
-- NPC list widget (only on "list" categories)
----------------------------------------------------------------------
local function BuildNpcList(parent, def, startY)
    local heading = MakeHeading(parent, "Per-NPC Overrides")
    heading:SetPoint("TOPLEFT", 0, startY)

    local hint = MakeLabel(parent,
        "Show: nameplate visible.   ★: bright outline (kill priority).",
        { 0.7, 0.7, 0.7 })
    hint:SetPoint("TOPLEFT", 0, startY - 22)

    -- Color swatch + add target button
    local swatch = MakeColorSwatch(parent,
        function() return ns:GetCategoryHighlightColor(def.id) end,
        function(r, g, b, a) ns:SetCategoryHighlightColor(def.id, r, g, b, a) end)
    swatch:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -180, startY - 18)
    table.insert(refreshHooks, swatch.Refresh)

    local addBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    addBtn:SetSize(160, 22)
    addBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, startY - 18)
    addBtn:SetText("Add Target / Mouseover")
    AttachTooltip(addBtn, "Add Target", "Targets or mouseover a summoned unit, then click this to add it to the list.")

    local listTop = startY - 50

    -- Scrollable list container
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        frame:SetBackdropColor(0, 0, 0, 0.35)
        frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end
    frame:SetSize(560, 240)
    frame:SetPoint("TOPLEFT", 0, listTop)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     6,  -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local rows = {}

    local function GetOrCreateRow(i)
        local row = rows[i]
        if row then return row end

        row = CreateFrame("Frame", nil, content)
        row:SetHeight(22)
        row:SetPoint("LEFT")
        row:SetPoint("RIGHT")

        -- Visibility checkbox
        row.cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.cb:SetSize(22, 22)
        row.cb:SetPoint("LEFT", 0, 0)
        AttachTooltip(row.cb, "Show",
            "Untick to hide this NPC's nameplate while leaving the master toggle on.")

        -- Highlight (kill-priority) checkbox
        row.hl = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.hl:SetSize(22, 22)
        row.hl:SetPoint("LEFT", row.cb, "RIGHT", 0, 0)
        local star = row.hl:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        star:SetPoint("CENTER", row.hl, "CENTER", 0, 1)
        star:SetText("★")
        star:SetTextColor(1, 0.4, 0.4)
        AttachTooltip(row.hl, "Highlight as kill-priority",
            "Draws a bright outline around this NPC's nameplate using the colour set above.")

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", row.hl, "RIGHT", 4, 0)
        row.name:SetJustifyH("LEFT")

        row.id = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.id:SetPoint("RIGHT", -28, 0)
        row.id:SetJustifyH("RIGHT")

        row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.remove:SetSize(22, 18)
        row.remove:SetPoint("RIGHT", 0, 0)
        row.remove:SetText("X")

        rows[i] = row
        return row
    end

    local function HideExcessRows(usedCount)
        for i = usedCount + 1, #rows do
            rows[i]:Hide()
        end
    end

    local function refresh()
        local i = 0
        local y = 0
        for npcID, rec in ns:IterateNpcsForCategory(def.id) do
            i = i + 1
            local row = GetOrCreateRow(i)
            row:SetPoint("TOPLEFT", 0, y)
            row:Show()

            row.name:SetText(rec.name or ("NPC " .. npcID))
            row.id:SetText(tostring(npcID))

            row.cb:SetChecked(not ns:IsNpcHidden(def.id, npcID))
            row.cb:SetScript("OnClick", function(self)
                ns:SetNpcHidden(def.id, npcID, not self:GetChecked())
            end)

            row.hl:SetChecked(ns:IsNpcHighlighted(def.id, npcID))
            row.hl:SetScript("OnClick", function(self)
                ns:SetNpcHighlighted(def.id, npcID, self:GetChecked())
            end)

            row.remove:SetScript("OnClick", function()
                if MyNamePlatesDB.npcs and MyNamePlatesDB.npcs[npcID] then
                    MyNamePlatesDB.npcs[npcID] = nil
                end
                ns:SetNpcHidden(def.id, npcID, false)
                refresh()
            end)
            AttachTooltip(row.remove, "Remove from list",
                "Remove this NPC from the discovered list. Curated entries from NpcData.lua will reappear after /reload.")

            y = y - 22
        end
        HideExcessRows(i)
        content:SetSize(540, math.max(1, -y))
    end

    addBtn:SetScript("OnClick", function()
        local id, name, cat = ns:AddUnitFromTarget()
        if id then
            print(string.format("|cff00c0ffMyNamePlates|r: added %s (#%d) to %s.", name, id,
                ns.CATEGORY_BY_ID[cat] and ns.CATEGORY_BY_ID[cat].label or cat))
            if ns.RefreshUI then ns:RefreshUI() end
        else
            print("|cff00c0ffMyNamePlates|r: " .. (name or "couldn't add unit."))
        end
    end)

    table.insert(refreshHooks, refresh)
    refresh()

    return listTop - 240 - 8
end

----------------------------------------------------------------------
-- Category page builder (dispatches based on def.kind)
----------------------------------------------------------------------
-- 1.35.1: which category tabs get the BBP-parity totem indicator
-- controls injected between the standard controls (show/scale/alpha)
-- and the per-NPC list.  Both totem-family tabs qualify: Enemy Totems
-- (all standard totems) and Enemy Psyfiend (routes through the same
-- indicator via the channel-first classifier heuristic).
--
-- These settings are GLOBAL (MyNamePlatesDB.labels.petTotemName) so
-- the two tabs share values -- editing "No glow" on Enemy Totems flips
-- it for Psyfiend too and vice versa.  Same behavior as BBP which has
-- one "Totem Indicator" for all totem plates.
local TOTEM_INDICATOR_CATEGORIES = {
    enemyTotems   = true,
    enemyPsyfiend = true,
}

local function BuildCategoryPanel(panel, def)
    AddHeader(panel, def.label, def.blurb)

    -- 1.35.1: wrap the panel content in a ScrollFrame for the totem
    -- category tabs -- the added BBP-parity block + NPC list can push
    -- past the standard panel height, and users need to scroll to
    -- reach the list.  Non-totem tabs keep the original layout for
    -- backwards compat (no visual change on any other tab).
    local content
    if TOTEM_INDICATOR_CATEGORIES[def.id] then
        local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
        scroll:SetPoint("BOTTOMRIGHT", -PAD * 2, PAD)
        content = CreateFrame("Frame", nil, scroll)
        content:SetSize(560, 1)
        scroll:SetScrollChild(content)
    else
        content = CreateFrame("Frame", nil, panel)
        content:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
        content:SetPoint("BOTTOMRIGHT", -PAD,    PAD)
    end

    local y = -PAD
    if def.kind == "master" or def.kind == "list" then
        y = AddCategoryControls(content, def, y)
    end

    -- 1.35.1: inject the shared BBP-parity totem indicator block on
    -- the two totem-family tabs.  Same helper used on Labels →
    -- Pet & Totem Name so all three UI instances edit the same
    -- underlying settings.  The cross-ref footer tells users this
    -- is a shared config.
    if TOTEM_INDICATOR_CATEGORIES[def.id] then
        y = y - 8
        y = BuildTotemIndicatorControls(content, y, {
            heading  = "Totem indicator (BBP parity):",
            note     = "Shared with the other totem tab and with Labels → Pet & Totem Name. Editing here updates them all.",
            crossRef = "Icon size / anchor / offset lives on Labels → Pet & Totem Name.",
        })
    end

    if def.kind == "list" then
        y = y - 6
        BuildNpcList(content, def, y)
    end

    -- Size the scroll content so the vertical scrollbar knows its
    -- extent on the totem tabs.  y is negative and grows more
    -- negative as we add controls, so absolute value gives the
    -- required height.
    if TOTEM_INDICATOR_CATEGORIES[def.id] then
        content:SetSize(560, math.max(-y + PAD * 2, 400))
    end
end

----------------------------------------------------------------------
-- Indicators page  (target arrow, healer crosses)
----------------------------------------------------------------------
local ANCHOR_CHOICES = { "TOP", "TOPLEFT", "TOPRIGHT", "CENTER",
                         "LEFT", "RIGHT", "BOTTOM", "BOTTOMLEFT", "BOTTOMRIGHT" }

local SCALE_SLIDER_INDICATOR = { key = "scale", label = "Scale",
    tooltip = "Marker scale (1.0 = native).",
    min = 0.5, max = 3.0, step = 0.05, default = 1.0 }

local OFFSET_X_SLIDER = { key = "xOffset", label = "X Offset",
    tooltip = "Horizontal offset in pixels (positive = right).",
    min = -100, max = 100, step = 1, default = 0 }

local OFFSET_Y_SLIDER = { key = "yOffset", label = "Y Offset",
    tooltip = "Vertical offset in pixels (positive = up).",
    min = -100, max = 100, step = 1, default = 12 }

local function MakeAnchorDropdown(parent, getter, setter)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(110, 22)
    local function refresh() btn:SetText(getter() or "TOP") end
    refresh()
    btn:SetScript("OnClick", function(self)
        local i = 1
        local current = getter() or "TOP"
        for j, v in ipairs(ANCHOR_CHOICES) do
            if v == current then i = j; break end
        end
        i = (i % #ANCHOR_CHOICES) + 1
        setter(ANCHOR_CHOICES[i])
        refresh()
    end)
    AttachTooltip(btn, "Anchor",
        "Click to cycle through anchor points (TOP / TOPLEFT / etc.). The marker is anchored to the plate's healthbar at this point.")
    table.insert(refreshHooks, refresh)
    return btn
end

local function BuildIndicatorBlock(parent, startY, key, headingLabel)
    local heading = MakeHeading(parent, headingLabel)
    heading:SetPoint("TOPLEFT", 0, startY)

    -- Test button (top-right of the block) — toggles ns.testMode[key]
    -- which forces the marker to show on every visible plate so you can
    -- adjust position/scale live in the open world.
    local testBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    testBtn:SetSize(100, 22)
    testBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, startY)
    local function refreshTestText()
        testBtn:SetText(ns.testMode and ns.testMode[key] and "Stop Test" or "Test")
    end
    refreshTestText()
    testBtn:SetScript("OnClick", function()
        if not ns.testMode then return end
        ns.testMode[key] = not ns.testMode[key]
        refreshTestText()
        if ns.RefreshAllIndicators then ns:RefreshAllIndicators() end
        if ns.RefreshActiveNameplates then ns:RefreshActiveNameplates() end
    end)
    AttachTooltip(testBtn, "Test mode",
        "Click to force this marker to show on every visible nameplate so you can preview the position/scale settings in the open world. Click again to stop.")
    table.insert(refreshHooks, refreshTestText)

    local y = startY - 24

    local cb = MakeCheckbox(parent, "Enabled",
        function() local c = ns:GetIndicatorConfig(key); return c and c.enabled == "1" end,
        function(on) ns:SetIndicatorOption(key, "enabled", on and "1" or "0") end,
        "Show this marker when its conditions are met.")
    cb:SetPoint("TOPLEFT", 8, y)
    y = y - ROW

    local lbl = MakeLabel(parent, "Anchor:", { 0.9, 0.9, 0.9 })
    lbl:SetPoint("TOPLEFT", 8, y - 4)
    local anchor = MakeAnchorDropdown(parent,
        function() local c = ns:GetIndicatorConfig(key); return c and c.anchor end,
        function(v) ns:SetIndicatorOption(key, "anchor", v) end)
    anchor:SetPoint("TOPLEFT", 70, y)
    y = y - ROW - 6

    local sx = MakeSlider(parent, OFFSET_X_SLIDER,
        function() local c = ns:GetIndicatorConfig(key); return c and (c.xOffset or 0) or 0 end,
        function(v) ns:SetIndicatorOption(key, "xOffset", v) end)
    sx:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    local sy = MakeSlider(parent, OFFSET_Y_SLIDER,
        function() local c = ns:GetIndicatorConfig(key); return c and (c.yOffset or 0) or 0 end,
        function(v) ns:SetIndicatorOption(key, "yOffset", v) end)
    sy:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    local ss = MakeSlider(parent, SCALE_SLIDER_INDICATOR,
        function() local c = ns:GetIndicatorConfig(key); return c and (c.scale or 1.0) or 1.0 end,
        function(v) ns:SetIndicatorOption(key, "scale", v) end)
    ss:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    return y - 8
end

local function BuildIndicatorsPanel(panel)
    AddHeader(panel, "Indicators",
        "Cosmetic markers attached to nameplates: an arrow over your current target, and crosses on healers (green = friendly, red = enemy).")

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
    scroll:SetPoint("BOTTOMRIGHT", -PAD * 2, PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 1)
    scroll:SetScrollChild(content)

    local y = -8
    y = BuildIndicatorBlock(content, y, "target",         "Target Arrow")
    y = y - 12
    y = BuildIndicatorBlock(content, y, "healerFriendly", "Friendly Healer Cross (green)")
    y = y - 12
    y = BuildIndicatorBlock(content, y, "healerEnemy",    "Enemy Healer Cross (red)")
    y = y - 12
    y = BuildIndicatorBlock(content, y, "classFriendly",  "Friendly Class Icon")
    y = y - 12
    y = BuildIndicatorBlock(content, y, "classEnemy",     "Enemy Class Icon")

    content:SetSize(560, -y + PAD)
end

----------------------------------------------------------------------
-- Auras page  (watched-aura icon over plates: bubble, BoP, ice block...)
----------------------------------------------------------------------
local AURAS_SCALE_SLIDER = { key = "scale", label = "Scale",
    tooltip = "Aura icon scale (1.0 = native).",
    min = 0.5, max = 3.0, step = 0.05, default = 1.0 }

local AURAS_SIZE_SLIDER = { key = "iconSize", label = "Icon Size (px)",
    tooltip = "Base pixel size of the aura icon (before scale).",
    min = 12, max = 64, step = 1, default = 26 }

local function BuildAurasPanel(panel)
    -- Capture the Reset button so we can anchor our header controls to
    -- the LEFT of it instead of overlapping it in the corner.
    local _, _, resetBtn = AddHeader(panel, "Watched Auras",
        "Show an icon over a nameplate when the unit has one of the tracked auras (Divine Shield, BoP, Ice Block, big defensives, etc.). Add custom spells by ID.")

    -- Header-row controls placed to the left of "Reset All Settings":
    -- [Enable Auras]  [Test]  [Reset All Settings]
    local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testBtn:SetSize(100, 22)
    testBtn:SetPoint("RIGHT", resetBtn, "LEFT", -6, 0)
    local function refreshTestText()
        testBtn:SetText(ns.testMode and ns.testMode.auras and "Stop Test" or "Test")
    end
    refreshTestText()
    testBtn:SetScript("OnClick", function()
        if not ns.testMode then return end
        ns.testMode.auras = not ns.testMode.auras
        refreshTestText()
        if ns.RefreshAllAuras then ns:RefreshAllAuras() end
    end)
    AttachTooltip(testBtn, "Test mode",
        "Click to force a placeholder aura icon on every visible nameplate so you can see the position/scale live. Click again to stop.")
    table.insert(refreshHooks, refreshTestText)

    local enableBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    enableBtn:SetSize(120, 22)
    enableBtn:SetPoint("RIGHT", testBtn, "LEFT", -6, 0)
    local function refreshEnableText()
        local cfg = ns:GetAurasConfig()
        enableBtn:SetText((cfg and cfg.enabled == "1") and "Disable Auras" or "Enable Auras")
    end
    refreshEnableText()
    enableBtn:SetScript("OnClick", function()
        local cfg = ns:GetAurasConfig()
        if not cfg then return end
        ns:SetAurasOption("enabled", cfg.enabled == "1" and "0" or "1")
        refreshEnableText()
        if ns.RefreshUI then ns:RefreshUI() end
    end)
    AttachTooltip(enableBtn, "Master enable/disable",
        "Quick toggle for the entire Watched Auras feature. Same effect as the 'Show watched-aura icons' checkbox below.")
    table.insert(refreshHooks, refreshEnableText)

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
    scroll:SetPoint("BOTTOMRIGHT", -PAD * 2, PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 1)
    scroll:SetScrollChild(content)

    local y = -8

    -- Master toggle
    local cb = MakeCheckbox(content, "Show watched-aura icons",
        function() local c = ns:GetAurasConfig(); return c and c.enabled == "1" end,
        function(on)
            ns:SetAurasOption("enabled", on and "1" or "0")
            refreshEnableText()
        end,
        "Master switch for the watched-aura icon overlay.")
    cb:SetPoint("TOPLEFT", 8, y); y = y - ROW

    -- Friendly / enemy filter
    local cbF = MakeCheckbox(content, "Show on friendly plates",
        function() local c = ns:GetAurasConfig(); return c and c.showFriendly ~= false end,
        function(on) ns:SetAurasOption("showFriendly", on and true or false) end)
    cbF:SetPoint("TOPLEFT", 8, y); y = y - ROW

    local cbE = MakeCheckbox(content, "Show on enemy plates",
        function() local c = ns:GetAurasConfig(); return c and c.showEnemy ~= false end,
        function(on) ns:SetAurasOption("showEnemy", on and true or false) end)
    cbE:SetPoint("TOPLEFT", 8, y); y = y - ROW - 6

    -- ── Auto-detect categories (1.33.0) ───────────────────────────
    -- Category-based detection picks up any CC / defensive Blizzard
    -- classifies, even when it's NOT in the curated spellID list.
    -- User's explicit disable in the tracked-spell list still wins.
    local catHeading = MakeHeading(content, "Auto-detect categories")
    catHeading:SetPoint("TOPLEFT", 0, y); y = y - 22

    local cbCatCC = MakeCheckbox(content, "Crowd control (Cyclone, Poly, Fear, Sap, ...)",
        function() return ns:IsAuraCategoryEnabled("cc") end,
        function(on) ns:SetAuraCategoryEnabled("cc", on) end)
    cbCatCC:SetPoint("TOPLEFT", 8, y); y = y - ROW

    local cbCatBD = MakeCheckbox(content, "Big defensives (Divine Shield, Ice Block, Bubble, ...)",
        function() return ns:IsAuraCategoryEnabled("bigDefensive") end,
        function(on) ns:SetAuraCategoryEnabled("bigDefensive", on) end)
    cbCatBD:SetPoint("TOPLEFT", 8, y); y = y - ROW

    local cbCatED = MakeCheckbox(content, "External defensives (Sac, PS, GS, Ironbark, ...)",
        function() return ns:IsAuraCategoryEnabled("externalDefensive") end,
        function(on) ns:SetAuraCategoryEnabled("externalDefensive", on) end)
    cbCatED:SetPoint("TOPLEFT", 8, y); y = y - ROW - 6

    -- Anchor
    local lbl = MakeLabel(content, "Anchor:", { 0.9, 0.9, 0.9 })
    lbl:SetPoint("TOPLEFT", 8, y - 4)
    local anchorBtn = MakeAnchorDropdown(content,
        function() local c = ns:GetAurasConfig(); return c and c.anchor end,
        function(v) ns:SetAurasOption("anchor", v) end)
    anchorBtn:SetPoint("TOPLEFT", 70, y); y = y - ROW - 6

    -- Sliders
    local sx = MakeSlider(content, OFFSET_X_SLIDER,
        function() local c = ns:GetAurasConfig(); return c and (c.xOffset or 0) end,
        function(v) ns:SetAurasOption("xOffset", v) end)
    sx:SetPoint("TOPLEFT", 8, y - 14); y = y - 44

    local sy = MakeSlider(content, OFFSET_Y_SLIDER,
        function() local c = ns:GetAurasConfig(); return c and (c.yOffset or 0) end,
        function(v) ns:SetAurasOption("yOffset", v) end)
    sy:SetPoint("TOPLEFT", 8, y - 14); y = y - 44

    local ss = MakeSlider(content, AURAS_SCALE_SLIDER,
        function() local c = ns:GetAurasConfig(); return c and (c.scale or 1.0) end,
        function(v) ns:SetAurasOption("scale", v) end)
    ss:SetPoint("TOPLEFT", 8, y - 14); y = y - 44

    local sis = MakeSlider(content, AURAS_SIZE_SLIDER,
        function() local c = ns:GetAurasConfig(); return c and (c.iconSize or 26) end,
        function(v) ns:SetAurasOption("iconSize", v) end)
    sis:SetPoint("TOPLEFT", 8, y - 14); y = y - 50

    -- ── Tracked spell list ────────────────────────────────────────
    local heading = MakeHeading(content, "Tracked Auras")
    heading:SetPoint("TOPLEFT", 0, y); y = y - 22

    local hint = MakeLabel(content,
        "Untick to disable a default. Use the box below to add custom spell IDs.",
        { 0.7, 0.7, 0.7 })
    hint:SetPoint("TOPLEFT", 0, y); y = y - 22

    -- Add-by-ID input
    local idBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    idBox:SetSize(120, 22)
    idBox:SetPoint("TOPLEFT", 8, y)
    idBox:SetAutoFocus(false)
    idBox:SetNumeric(true)
    idBox:SetMaxLetters(8)

    local addBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    addBtn:SetSize(110, 22)
    addBtn:SetPoint("LEFT", idBox, "RIGHT", 6, 0)
    addBtn:SetText("Add by Spell ID")
    AttachTooltip(addBtn, "Add aura",
        "Look up the spell ID on Wowhead, paste/type it, and click Add. The aura will be added to the tracked list with sensible defaults.")
    y = y - 32

    -- Scrollable spell list
    local listFrame = CreateFrame("Frame", nil, content, "BackdropTemplate")
    if listFrame.SetBackdrop then
        listFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        listFrame:SetBackdropColor(0, 0, 0, 0.35)
        listFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end
    listFrame:SetSize(540, 240)
    listFrame:SetPoint("TOPLEFT", 0, y)

    local listScroll = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT",     6,  -6)
    listScroll:SetPoint("BOTTOMRIGHT", -28, 6)
    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(1, 1)
    listScroll:SetScrollChild(listContent)

    local rows = {}
    local function GetOrCreateRow(i)
        local row = rows[i]
        if row then return row end
        row = CreateFrame("Frame", nil, listContent)
        row:SetHeight(22)
        row:SetPoint("LEFT")
        row:SetPoint("RIGHT")

        row.cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.cb:SetSize(22, 22)
        row.cb:SetPoint("LEFT", 0, 0)

        row.icon = row:CreateTexture(nil, "OVERLAY")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", row.cb, "RIGHT", 4, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)

        row.id = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.id:SetPoint("RIGHT", -28, 0)

        row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.remove:SetSize(22, 18)
        row.remove:SetPoint("RIGHT", 0, 0)
        row.remove:SetText("X")
        AttachTooltip(row.remove, "Remove",
            "Remove this aura from the tracked list. Curated entries from the addon defaults will reappear after /reload.")

        rows[i] = row
        return row
    end

    local function refreshList()
        local i = 0
        local yy = 0
        for spellID, entry in ns:IterateAuras() do
            i = i + 1
            local row = GetOrCreateRow(i)
            row:SetPoint("TOPLEFT", 0, yy)
            row:Show()
            row.name:SetText(entry.name or ("Spell " .. spellID))
            row.id:SetText(tostring(spellID))

            -- Spell icon
            local iconID
            if C_Spell and C_Spell.GetSpellTexture then
                iconID = C_Spell.GetSpellTexture(spellID)
            end
            row.icon:SetTexture(iconID or 0)

            row.cb:SetChecked(ns:IsAuraEnabled(spellID))
            row.cb:SetScript("OnClick", function(self)
                ns:SetAuraEnabled(spellID, self:GetChecked())
            end)
            row.remove:SetScript("OnClick", function()
                ns:RemoveCustomAura(spellID)
                refreshList()
            end)
            yy = yy - 22
        end
        for j = i + 1, #rows do rows[j]:Hide() end
        listContent:SetSize(520, math.max(1, -yy))
    end

    addBtn:SetScript("OnClick", function()
        local spellID = tonumber(idBox:GetText())
        if not spellID then
            print("|cff00c0ffMyNamePlates|r: enter a numeric spell ID.")
            return
        end
        local ok, name = ns:AddCustomAura(spellID)
        if ok then
            print(("|cff00c0ffMyNamePlates|r: added %s (#%d) to tracked auras."):format(name, spellID))
            idBox:SetText("")
            refreshList()
        else
            print("|cff00c0ffMyNamePlates|r: " .. (name or "couldn't add"))
        end
    end)

    table.insert(refreshHooks, refreshList)
    refreshList()

    content:SetSize(560, math.abs(y) + 260)
end

----------------------------------------------------------------------
-- Labels page (custom name + spec text overlays)
----------------------------------------------------------------------
local LABEL_SCALE_SLIDER = { key = "scale", label = "Scale",
    tooltip = "Text scale multiplier (1.0 = native).",
    min = 0.5, max = 3.0, step = 0.05, default = 1.0 }

local LABEL_FONTSIZE_SLIDER = { key = "fontSize", label = "Font Size (px)",
    tooltip = "Override font size in pixels.  Set to 0 to use Blizzard's default size; any non-zero value forces that exact pixel height.",
    min = 0, max = 32, step = 1, default = 0 }

local LABEL_X_SLIDER = { key = "xOffset", label = "X Offset",
    tooltip = "Horizontal offset in pixels (positive = right).  Adjust to move name / spec left or right.",
    min = -200, max = 200, step = 1, default = 0 }

local LABEL_Y_SLIDER = { key = "yOffset", label = "Y Offset",
    tooltip = "Vertical offset in pixels (positive = up).",
    min = -100, max = 100, step = 1, default = 0 }

local function BuildLabelBlock(parent, startY, key, headingLabel, defaultY)
    local heading = MakeHeading(parent, headingLabel)
    heading:SetPoint("TOPLEFT", 0, startY)

    -- Test button (top-right of the block, aligned with the heading)
    -- mirrors the indicators/auras pattern: forces this block's config
    -- onto every visible plate so the user can tune offsets/scale/font
    -- live in the open world on whatever they're looking at, without
    -- needing the right unit type (a totem to test pet/totem block,
    -- a player to test the name block).  Skipped for Spec since Spec
    -- has its own resolution flow and no test-mode entry.
    if key == "name" or key == "petTotemName" then
        local testBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        testBtn:SetSize(100, 22)
        testBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, startY)
        local function refreshTestText()
            testBtn:SetText(ns.testMode and ns.testMode[key] and "Stop Test" or "Test")
        end
        refreshTestText()
        testBtn:SetScript("OnClick", function()
            if not ns.testMode then return end
            -- Make the two name test modes mutually exclusive — if the
            -- user clicks Test on one block while the other is active,
            -- swap rather than running both (running both would always
            -- prefer petTotemName per _PickNameConfig, which is fine
            -- but visually confusing because the other button still
            -- says "Stop Test").
            if not ns.testMode[key] then
                ns.testMode.name         = false
                ns.testMode.petTotemName = false
                ns.testMode[key] = true
            else
                ns.testMode[key] = false
            end
            refreshTestText()
            if ns.RefreshAllLabels then ns:RefreshAllLabels() end
        end)
        AttachTooltip(testBtn, "Test mode",
            "Click to force this block's settings onto every visible nameplate so you can tune offset/scale/font live on any unit (player, totem, dummy, anything).  Click again to revert.  Test mode does not save to disk and clears on /reload.")
        table.insert(refreshHooks, refreshTestText)
    end

    local y = startY - 24

    local cb = MakeCheckbox(parent, "Enabled",
        function() local c = ns:GetLabelsConfig(key); return c and c.enabled == "1" end,
        function(on) ns:SetLabelOption(key, "enabled", on and "1" or "0") end,
        "Show this text on nameplates.")
    cb:SetPoint("TOPLEFT", 8, y)
    y = y - ROW

    local cbF = MakeCheckbox(parent, "Show on friendly",
        function() local c = ns:GetLabelsConfig(key); return c and c.applyFriendly end,
        function(on) ns:SetLabelOption(key, "applyFriendly", on and true or false) end,
        "Display this text on friendly player plates.")
    cbF:SetPoint("TOPLEFT", 8, y)
    y = y - ROW

    local cbE = MakeCheckbox(parent, "Show on enemy",
        function() local c = ns:GetLabelsConfig(key); return c and c.applyEnemy end,
        function(on) ns:SetLabelOption(key, "applyEnemy", on and true or false) end,
        "Display this text on enemy player plates.")
    cbE:SetPoint("TOPLEFT", 8, y)
    y = y - ROW

    local lbl = MakeLabel(parent, "Anchor:", { 0.9, 0.9, 0.9 })
    lbl:SetPoint("TOPLEFT", 8, y - 4)
    local anchor = MakeAnchorDropdown(parent,
        function() local c = ns:GetLabelsConfig(key); return c and c.anchor end,
        function(v) ns:SetLabelOption(key, "anchor", v) end)
    anchor:SetPoint("TOPLEFT", 70, y)
    y = y - ROW - 6

    local sx = MakeSlider(parent, LABEL_X_SLIDER,
        function() local c = ns:GetLabelsConfig(key); return c and (c.xOffset or 0) or 0 end,
        function(v) ns:SetLabelOption(key, "xOffset", v) end)
    sx:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    local sy = MakeSlider(parent, LABEL_Y_SLIDER,
        function() local c = ns:GetLabelsConfig(key); return c and (c.yOffset or 0) or 0 end,
        function(v) ns:SetLabelOption(key, "yOffset", v) end)
    sy:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    local ss = MakeSlider(parent, LABEL_SCALE_SLIDER,
        function() local c = ns:GetLabelsConfig(key); return c and (c.scale or 1.0) or 1.0 end,
        function(v) ns:SetLabelOption(key, "scale", v) end)
    ss:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    local sf = MakeSlider(parent, LABEL_FONTSIZE_SLIDER,
        function() local c = ns:GetLabelsConfig(key); return c and (c.fontSize or 0) or 0 end,
        function(v) ns:SetLabelOption(key, "fontSize", v) end)
    sf:SetPoint("TOPLEFT", 8, y - 14)
    y = y - 44

    -- Per-summon-type filter (only on the Pet & Totem Name block).
    -- Lets the user cherry-pick which summon kinds get the always-
    -- visible label.  Use case from the field: in arena you want
    -- Totems and Psyfiend to scream above their plates but you don't
    -- want every Wild Imp / Dreadstalker / Vilefiend cluttering the
    -- screen with their names.  Defaults reflect that — totems and
    -- psyfiend ON, everything else OFF.
    if key == "petTotemName" then
        local heading = MakeLabel(parent, "Show name on these summon types:",
            { 1.0, 0.85, 0.3 })
        heading:SetPoint("TOPLEFT", 8, y - 4)
        y = y - ROW

        -- Two-column layout to keep the block from getting too tall.
        local TYPE_ROWS = {
            { st = "totem",       label = "Totems",            tip = "Capacitor, Healing Tide, Tremor, Earthbind, etc." },
            { st = "psyfiend",    label = "Psyfiend",          tip = "Priest's fear-spamming totem-like target." },
            { st = "guardian",    label = "Guardians",         tip = "Larger summons: Earth Elemental, Infernal, Demonic Tyrant, Statue of the Black Ox." },
            { st = "minion",      label = "Minions",           tip = "Wild Imp, Dreadstalker, Vilefiend, Observer." },
            { st = "minor",       label = "Minor (Minus)",     tip = "Tiny low-HP summons (Felguard adds, Imp variants)." },
            { st = "pet_hunter",  label = "Hunter Pets",       tip = "Hunter pets (every family/skin)." },
            { st = "pet_warlock", label = "Warlock Pets",      tip = "Warlock primary demons: Imp, Felhunter, Voidwalker, Succubus, Felguard." },
            { st = "pet_dk",      label = "Death Knight Pets", tip = "Unholy DK Risen Ghoul." },
            { st = "pet_mage",    label = "Mage Pets",         tip = "Frost Mage Water Elemental." },
        }
        local startY = y
        for i, row in ipairs(TYPE_ROWS) do
            local col = ((i - 1) % 2 == 0) and 8 or 200
            local r   = math.floor((i - 1) / 2)
            local cby = startY - (r * ROW)
            local st  = row.st
            local typeCB = MakeCheckbox(parent, row.label,
                function() return ns:GetLabelType(key, st) end,
                function(on) ns:SetLabelType(key, st, on) end,
                row.tip)
            typeCB:SetPoint("TOPLEFT", col, cby)
        end
        local rows = math.ceil(#TYPE_ROWS / 2)
        y = startY - (rows * ROW) - 6

        -- ---------------------------------------------------------
        -- 1.34.0: Icon overlay (arena fallback).
        --
        -- In retail Midnight 12.x arena, Blizzard anonymises every
        -- name-bearing field on enemy summon plates (UnitName /
        -- UnitGUID / uf.name:GetText() all return secret strings),
        -- so the text overlay above can't render totem names until
        -- the player targets or mouseovers the totem.
        --
        -- BBP's midnight/modules/totem.lua sidesteps this with a
        -- texture + color instead of the totem name (confirmed via
        -- their CHANGELOG 2.0.4: "Best that can be done atm.").
        -- We adopt the same pattern here as a fallback layer — the
        -- icon renders whenever the plate qualifies as a summon,
        -- regardless of whether we can resolve the name.
        --
        -- Detection heuristic (from BBP):
        --   * UnitCastingInfo → Capacitor Totem  (orange)
        --   * UnitChannelInfo → Psyfiend         (purple)
        --   * First HELPFUL + IsSpellImportant  → magenta
        --   * otherwise                          → generic brown
        -- ---------------------------------------------------------
        local iconHeading = MakeLabel(parent,
            "Icon overlay (arena fallback):",
            { 1.0, 0.85, 0.3 })
        iconHeading:SetPoint("TOPLEFT", 8, y - 4)
        y = y - ROW

        local iconNote = MakeLabel(parent,
            "In retail arena, Blizzard hides totem names — icon shows instead.",
            { 0.75, 0.75, 0.75 })
        iconNote:SetPoint("TOPLEFT", 8, y - 4)
        y = y - ROW

        local iconCB = MakeCheckbox(parent, "Show icon",
            function() local c = ns:GetLabelsConfig(key); return c and c.showIcon end,
            function(on) ns:SetLabelOption(key, "showIcon", on and true or false) end,
            "Render a small totem icon on summon plates.  Uses BBP's heuristic (Capacitor / Psyfiend / important-aura / generic).  Enables the name text (above) and the icon to work together — text where available, icon everywhere else.")
        iconCB:SetPoint("TOPLEFT", 8, y)
        y = y - ROW

        local ICON_SIZE_SLIDER = { key = "iconSize", label = "Icon Size",
            tooltip = "Icon dimensions in pixels.  30 matches BBP's fixed size.",
            min = 12, max = 64, step = 1, default = 30 }
        local iconSizeSlider = MakeSlider(parent, ICON_SIZE_SLIDER,
            function() local c = ns:GetLabelsConfig(key); return c and (c.iconSize or 30) or 30 end,
            function(v) ns:SetLabelOption(key, "iconSize", v) end)
        iconSizeSlider:SetPoint("TOPLEFT", 8, y - 14)
        y = y - 44

        local iconAnchorLbl = MakeLabel(parent, "Icon Anchor:", { 0.9, 0.9, 0.9 })
        iconAnchorLbl:SetPoint("TOPLEFT", 8, y - 4)
        local iconAnchorDD = MakeAnchorDropdown(parent,
            function() local c = ns:GetLabelsConfig(key); return c and c.iconAnchor end,
            function(v) ns:SetLabelOption(key, "iconAnchor", v) end)
        iconAnchorDD:SetPoint("TOPLEFT", 100, y)
        y = y - ROW - 6

        local ICON_X_SLIDER = { key = "iconXOffset", label = "Icon X Offset",
            tooltip = "Horizontal offset for the totem icon (positive = right).",
            min = -200, max = 200, step = 1, default = 0 }
        local iconX = MakeSlider(parent, ICON_X_SLIDER,
            function() local c = ns:GetLabelsConfig(key); return c and (c.iconXOffset or 0) or 0 end,
            function(v) ns:SetLabelOption(key, "iconXOffset", v) end)
        iconX:SetPoint("TOPLEFT", 8, y - 14)
        y = y - 44

        local ICON_Y_SLIDER = { key = "iconYOffset", label = "Icon Y Offset",
            tooltip = "Vertical offset for the totem icon (positive = up).",
            min = -100, max = 100, step = 1, default = 22 }
        local iconY = MakeSlider(parent, ICON_Y_SLIDER,
            function() local c = ns:GetLabelsConfig(key); return c and (c.iconYOffset or 22) or 22 end,
            function(v) ns:SetLabelOption(key, "iconYOffset", v) end)
        iconY:SetPoint("TOPLEFT", 8, y - 14)
        y = y - 44

        -- 1.35.1: BBP-parity totem indicator controls -- extracted to
        -- a shared helper so the Enemy Totems and Enemy Psyfiend
        -- category tabs surface the same block.  Same underlying
        -- settings (MyNamePlatesDB.labels.petTotemName), same layout.
        y = BuildTotemIndicatorControls(parent, y, {
            heading  = "Totem indicator (BBP parity):",
            note     = "Also available on Enemy Totems and Enemy Psyfiend tabs -- editing anywhere updates all three.",
        })
    end

    return y - 8
end

----------------------------------------------------------------------
-- 1.36.28: "Summon Icons & Names" panel
--
-- One row per summonType with:
--   * 24x24 preview of the fallback icon that will render for that type
--     (uses the exact texture ICON_BY_TYPE returns in Labels.lua so the
--     preview matches what plates draw in anonymised arena).
--   * "Show icon" checkbox -> writes labels.petTotemName.iconTypes[st].
--     Controls the icon overlay only.
--   * "Show name" checkbox -> writes labels.petTotemName.types[st].
--     Controls the text overlay only.  Same underlying value as the
--     older per-type checkbox grid on the Labels tab; both surfaces
--     stay in sync via the standard refresh hooks.
--
-- Also renders a short blurb per row so the user knows which pets fall
-- into each bucket (Warlock Pets = Imp/Observer/Felguard/...; Minion =
-- Wild Imp/Dreadstalker/...; etc.), which was previously buried in
-- tooltips on the Labels tab.
----------------------------------------------------------------------
local SUMMON_ICON_ROWS = {
    { st = "totem",       label = "Totems",
      blurb = "Capacitor, Healing Tide, Tremor, Earthbind, Grounding, Statue of the Ox, etc." },
    { st = "psyfiend",    label = "Psyfiend",
      blurb = "Priest's fear-spamming totem-like summon (Psychic Horror channel)." },
    { st = "pet_warlock", label = "Warlock Pets",
      blurb = "Primary demons: Imp, Felhunter, Voidwalker, Succubus, Felguard, Observer, Voidlord." },
    { st = "pet_hunter",  label = "Hunter Pets",
      blurb = "Every hunter pet family/skin (Cat, Bear, Spirit Beast, Dire Beast, etc.)." },
    { st = "pet_dk",      label = "Death Knight Pets",
      blurb = "Unholy DK Risen Ghoul, Abomination, Army of the Dead ghouls." },
    { st = "pet_mage",    label = "Mage Pets",
      blurb = "Frost Mage Water Elemental, Arcane Mage Mirror Images." },
    { st = "guardian",    label = "Guardians",
      blurb = "Larger cooldown summons: Earth Elemental, Infernal, Demonic Tyrant, Fel Lord." },
    { st = "minion",      label = "Minions",
      blurb = "Warlock Wild Imp, Dreadstalker, Vilefiend; Druid Force of Nature treants." },
    { st = "minor",       label = "Minor (Minus)",
      blurb = "Tiny low-HP summons (Bloodworms, imp variants marked as `minus` by Blizzard)." },
}

local function BuildSummonIconsPanel(panel)
    AddHeader(panel, "Summon Icons & Names",
        "Turn the icon overlay and text label on/off per summon type.  Handy in arena where Blizzard hides pet/totem names -- the icon renders instead.  Editing 'Show name' here also updates the per-type checkboxes on the Labels tab.")

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
    scroll:SetPoint("BOTTOMRIGHT", -PAD * 2, PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 1)
    scroll:SetScrollChild(content)

    -- Column layout (all offsets relative to `content`, y grows negative
    -- downward like the rest of the panels in this file):
    --   x = 8   -> icon preview (24x24)
    --   x = 44  -> type label + blurb (~200 wide)
    --   x = 260 -> Show icon checkbox
    --   x = 400 -> Show name checkbox
    local ICON_X, LABEL_X = 8, 44
    local ICON_CB_X, NAME_CB_X = 260, 400
    local ROW_H = 44   -- one line for label, one for blurb

    -- Column headers.
    local y = -8
    local hIcon = MakeLabel(content, "Icon", { 1.0, 0.85, 0.3 })
    hIcon:SetPoint("TOPLEFT", ICON_X, y)
    local hType = MakeLabel(content, "Summon Type", { 1.0, 0.85, 0.3 })
    hType:SetPoint("TOPLEFT", LABEL_X, y)
    local hIconCB = MakeLabel(content, "Show icon", { 1.0, 0.85, 0.3 })
    hIconCB:SetPoint("TOPLEFT", ICON_CB_X, y)
    local hNameCB = MakeLabel(content, "Show name", { 1.0, 0.85, 0.3 })
    hNameCB:SetPoint("TOPLEFT", NAME_CB_X, y)
    y = y - ROW - 6

    for _, row in ipairs(SUMMON_ICON_ROWS) do
        local st = row.st

        -- Icon preview.  Use a bare texture (not a Button) so it doesn't
        -- swallow clicks or steal keyboard focus.  Border matches the
        -- style of AuraIcon-Border used elsewhere in the panel.
        local iconFrame = CreateFrame("Frame", nil, content)
        iconFrame:SetSize(24, 24)
        iconFrame:SetPoint("TOPLEFT", ICON_X, y - 2)
        local tex = iconFrame:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(iconFrame)
        -- Trim the built-in Blizzard 8% border from the spell texture
        -- so the icon fills the preview cleanly (same trim BBP uses).
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local iconPath = (ns.GetIconForSummonType and ns:GetIconForSummonType(st))
                         or "Interface\\Icons\\INV_Misc_QuestionMark"
        tex:SetTexture(iconPath)

        -- Type label.
        local nameFS = MakeLabel(content, row.label)
        nameFS:SetPoint("TOPLEFT", LABEL_X, y)

        -- Blurb (one line below the label, dim grey).
        local blurbFS = MakeLabel(content, row.blurb, { 0.7, 0.7, 0.7 })
        blurbFS:SetPoint("TOPLEFT", LABEL_X, y - 14)
        blurbFS:SetWidth(210)
        blurbFS:SetJustifyH("LEFT")
        blurbFS:SetWordWrap(false)

        -- Show-icon checkbox.
        local iconCB = MakeCheckbox(content, "",
            function() return ns:GetLabelIconType("petTotemName", st) end,
            function(on) ns:SetLabelIconType("petTotemName", st, on) end,
            "Toggle the fallback icon overlay for this summon type.  Preview on the left shows exactly which texture will render when the pipeline falls back to type-based icons (anonymised arena plates).")
        iconCB:SetPoint("TOPLEFT", ICON_CB_X, y + 2)

        -- Show-name checkbox.
        local nameCB = MakeCheckbox(content, "",
            function() return ns:GetLabelType("petTotemName", st) end,
            function(on) ns:SetLabelType("petTotemName", st, on) end,
            "Toggle the custom text label for this summon type.  Same underlying setting as the per-type checkbox on the Labels tab -- editing here updates both places.")
        nameCB:SetPoint("TOPLEFT", NAME_CB_X, y + 2)

        y = y - ROW_H
    end

    -- ---------------------------------------------------------------
    -- 1.36.29: Important Totems grid.
    --
    -- Auto-populated from ns:GetImportantTotems() which pulls every
    -- record in NPC_DATA where `type == "totem"` AND `important ==
    -- true` (deduped by spellID so Capacitor's two NPC IDs collapse
    -- to a single row).  Each row shows the exact icon that will
    -- render for that totem on a plate (via C_Spell.GetSpellTexture
    -- on the record's spellID -- same path Step 1 of _ClassifyTotem
    -- uses) plus a checkbox that writes iconByNpcID[npcID] = false
    -- to suppress just that one totem's icon overlay.  Every alias
    -- npcID gets muted together via SetLabelIconForNpc so PvP-alt
    -- Capacitor doesn't leak through.
    -- ---------------------------------------------------------------
    y = y - 6
    local totemsHeader = MakeLabel(content,
        "Important Totems (Grounding-class -- glow + magenta highlight):",
        { 1.0, 0.85, 0.3 })
    totemsHeader:SetPoint("TOPLEFT", 8, y)
    y = y - ROW

    local totemsNote = MakeLabel(content,
        "Each row shows the exact icon this totem renders on its plate.  Toggle off to hide just that one totem's icon (plate stays visible; only the icon overlay is suppressed).  Applies to every NPC-ID variant of the same totem.",
        { 0.7, 0.7, 0.7 })
    totemsNote:SetPoint("TOPLEFT", 8, y - 4)
    totemsNote:SetWidth(540)
    totemsNote:SetJustifyH("LEFT")
    y = y - 40

    local totems = (ns.GetImportantTotems and ns:GetImportantTotems()) or {}
    if #totems == 0 then
        local empty = MakeLabel(content,
            "(No important totems found in NPC_DATA -- is NpcData.lua loaded?)",
            { 0.9, 0.5, 0.5 })
        empty:SetPoint("TOPLEFT", 8, y)
        y = y - ROW
    else
        -- Two-column grid: icon (24) + name (~170) + checkbox (24)
        -- per column, columns spaced 280px apart.
        local COL_X       = { 8, 288 }
        local ICON_INSET  = 0
        local NAME_INSET  = 30
        local CB_INSET    = 200
        local TOTEM_ROW_H = 30

        local startY = y
        for i, t in ipairs(totems) do
            local col   = ((i - 1) % 2) + 1
            local rowIx = math.floor((i - 1) / 2)
            local rowY  = startY - (rowIx * TOTEM_ROW_H)
            local baseX = COL_X[col]

            -- Icon preview via spellID.
            local iconFrame = CreateFrame("Frame", nil, content)
            iconFrame:SetSize(24, 24)
            iconFrame:SetPoint("TOPLEFT", baseX + ICON_INSET, rowY - 2)
            local tex = iconFrame:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints(iconFrame)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local iconTex
            if C_Spell and C_Spell.GetSpellTexture and t.spellID then
                local okI, tt = pcall(C_Spell.GetSpellTexture, t.spellID)
                if okI and tt then iconTex = tt end
            end
            tex:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")

            -- Name label.  Word-wrap off + fixed width so long names
            -- don't collide with the checkbox column.
            local nameFS = MakeLabel(content, t.name or "?")
            nameFS:SetPoint("TOPLEFT", baseX + NAME_INSET, rowY)
            nameFS:SetWidth(165)
            nameFS:SetJustifyH("LEFT")
            nameFS:SetWordWrap(false)

            -- Icon toggle.  Fires for every alias npcID so PvP-alt
            -- Capacitor / (alt) variants stay in sync with the row's
            -- canonical npcID.
            local aliases = t.aliasNpcIDs or { t.npcID }
            local iconCB  = MakeCheckbox(content, "",
                function()
                    return ns:GetLabelIconForNpc("petTotemName", t.npcID)
                end,
                function(on)
                    for _, aid in ipairs(aliases) do
                        ns:SetLabelIconForNpc("petTotemName", aid, on)
                    end
                end,
                (t.name or "?") .. " icon: on = render this totem's spellbook icon on its plate; off = suppress just this totem's icon (plate is still visible).")
            iconCB:SetPoint("TOPLEFT", baseX + CB_INSET, rowY + 2)
        end
        local rows = math.ceil(#totems / 2)
        y = startY - (rows * TOTEM_ROW_H) - 4
    end

    -- Footer note explaining what's not on this tab.
    y = y - 4
    local footer = MakeLabel(content,
        "Icon size, position, alpha, and colour live on the Labels > Pet & Totem Name block.  This tab controls WHICH types + individual totems render an icon/name -- not HOW they render.",
        { 0.65, 0.65, 0.65 })
    footer:SetPoint("TOPLEFT", 8, y)
    footer:SetWidth(540)
    footer:SetJustifyH("LEFT")
    y = y - 40

    content:SetSize(560, -y + PAD)
end

local function BuildLabelsPanel(panel)
    AddHeader(panel, "Labels",
        "Three blocks: Name controls player & regular NPC nameplates; Pet & Totem Name is a separate config for summons (when enabled); Spec adds a custom spec text on player plates.  Positive X = right, positive Y = up.")

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
    scroll:SetPoint("BOTTOMRIGHT", -PAD * 2, PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 1)
    scroll:SetScrollChild(content)

    local y = -8
    y = BuildLabelBlock(content, y, "name", "Name (players & NPCs)")
    y = y - 12
    y = BuildLabelBlock(content, y, "petTotemName",
        "Pet & Totem Name (summons: pets, totems, guardians, minions)")
    y = y - 12
    y = BuildLabelBlock(content, y, "spec", "Spec")
    y = y - 12

    content:SetSize(560, -y + PAD)
end

----------------------------------------------------------------------
-- Registration
----------------------------------------------------------------------
local rootCategory
local subCategoriesByID = {}

local function Register()
    if rootCategory then return end

    -- Root panel = General page
    local rootPanel = CreateFrame("Frame")
    rootPanel.name = PANEL_TITLE
    BuildGeneralPanel(rootPanel)
    rootCategory = Settings.RegisterCanvasLayoutCategory(rootPanel, PANEL_TITLE)
    Settings.RegisterAddOnCategory(rootCategory)

    for _, def in ipairs(ns.CATEGORIES) do
        if def.kind ~= "global" then
            local sub = CreateFrame("Frame")
            sub.name = def.label
            BuildCategoryPanel(sub, def)
            local subCat = Settings.RegisterCanvasLayoutSubcategory(rootCategory, sub, def.label)
            subCategoriesByID[def.id] = subCat
        end
    end

    -- Indicators subcategory (target arrow + healer crosses)
    local indicatorsPanel = CreateFrame("Frame")
    indicatorsPanel.name = "Indicators"
    BuildIndicatorsPanel(indicatorsPanel)
    Settings.RegisterCanvasLayoutSubcategory(rootCategory, indicatorsPanel, "Indicators")

    -- Auras subcategory (watched-aura icons: bubble, BoP, ice block, etc.)
    local aurasPanel = CreateFrame("Frame")
    aurasPanel.name = "Auras"
    BuildAurasPanel(aurasPanel)
    Settings.RegisterCanvasLayoutSubcategory(rootCategory, aurasPanel, "Auras")

    -- Labels subcategory (custom name + spec text overlays)
    local labelsPanel = CreateFrame("Frame")
    labelsPanel.name = "Labels"
    BuildLabelsPanel(labelsPanel)
    Settings.RegisterCanvasLayoutSubcategory(rootCategory, labelsPanel, "Labels")

    -- 1.36.28: dedicated Summon Icons & Names subcategory.
    -- Consolidates the per-summon-type icon/name toggles so users can
    -- see WHICH icon each type will render (live 24x24 preview) and
    -- toggle icon vs name independently.  Existing per-type name
    -- checkboxes on the Labels tab remain; both surfaces share the
    -- same underlying MyNamePlatesDB.labels.petTotemName.{types,iconTypes}
    -- fields via ns:Get/SetLabel[Icon]Type, so edits stay in sync.
    local summonIconsPanel = CreateFrame("Frame")
    summonIconsPanel.name = "Summon Icons & Names"
    BuildSummonIconsPanel(summonIconsPanel)
    Settings.RegisterCanvasLayoutSubcategory(rootCategory, summonIconsPanel,
        "Summon Icons & Names")
end

----------------------------------------------------------------------
-- Refresh hook (called by Core after ResetAll, by Discovery on add, etc.)
----------------------------------------------------------------------
function ns:RefreshUI()
    for _, fn in ipairs(refreshHooks) do
        pcall(fn)
    end
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
local function OpenPanel()
    Register()
    Settings.OpenToCategory(rootCategory:GetID())
end

SLASH_MYNAMEPLATES1 = "/mnp"
SLASH_MYNAMEPLATES2 = "/mynp"
SLASH_MYNAMEPLATES3 = "/mynameplates"
SlashCmdList["MYNAMEPLATES"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "reset" then
        ns:ResetAll()
        print("|cff00c0ffMyNamePlates|r: settings reset to defaults.")
    elseif msg == "add" then
        local id, name, cat = ns:AddUnitFromTarget()
        if id then
            print(string.format("|cff00c0ffMyNamePlates|r: added %s (#%d) to %s.", name, id,
                ns.CATEGORY_BY_ID[cat] and ns.CATEGORY_BY_ID[cat].label or cat))
            if ns.RefreshUI then ns:RefreshUI() end
        else
            print("|cff00c0ffMyNamePlates|r: " .. (name or "couldn't add unit."))
        end
    elseif msg == "status" or msg == "diag" or msg == "debug" then
        local plates = (C_NamePlate and C_NamePlate.GetNamePlates and #C_NamePlate.GetNamePlates()) or 0
        print(("|cff00c0ffMyNamePlates|r status:"):format())
        print(("  visible plates: %d"):format(plates))
        if ns.GetActiveCount then
            print(("  managed plates: %d"):format(ns:GetActiveCount()))
        end
        print(("  showEnemies CVar: %s"):format(GetCVar("nameplateShowEnemies") or "?"))
        print(("  showFriendlyPets CVar: %s"):format(GetCVar("nameplateShowFriendlyPets") or "?"))
        print(("  showEnemyPets CVar: %s"):format(GetCVar("nameplateShowEnemyPets") or "?"))
        if ns.DumpActive then ns:DumpActive() end
    elseif msg == "rescan" then
        if ns.RescanAllPlates then ns:RescanAllPlates() end
        ns:ApplyAll()
        print("|cff00c0ffMyNamePlates|r: rescanned plates and re-applied settings.")
    elseif msg == "trace" then
        if ns.IsTracing and ns:IsTracing() then
            ns:StopTrace()
        elseif ns.StartTrace then
            ns:StartTrace()
        end
    elseif msg == "deepdiag" or msg == "diag" then
        if ns.DeepDiag then ns:DeepDiag() end
    elseif msg == "labels" then
        -- Per-plate label diagnostic.  For each visible plate dump:
        --   * unit + name + isSummon classification
        --   * Blizzard uf.name state (text, MyNP_moved/suppressed flags)
        --   * our overlay state (MyNP_SummonName text/shown, MyNP_SpecText
        --     text/shown)
        --   * petTotemName cfg snapshot (enabled, anchor, offsets, allowed
        --     for this plate's type)
        -- Use this when totem/pet names "aren't showing" — it tells you
        -- exactly which gate is bailing.
        if ns.DumpLabels then ns:DumpLabels() else
            print("|cff00c0ffMyNamePlates|r: DumpLabels not available.")
        end
    elseif msg == "scoreboard" then
        -- Dump the cached scoreboard map (name -> talentSpec) and
        -- force a rebuild so we can see what C_PvP is actually
        -- returning to us.  Use this when /mnp labels shows
        -- SpecFS: shown=false on enemy plates with non-secret names.
        if ns.RebuildPvPScoreMap then
            print("|cff00c0ffMyNamePlates|r forcing scoreboard rebuild...")
            pcall(ns.RebuildPvPScoreMap, ns)
        end
        if ns.DumpPvPScoreboard then ns:DumpPvPScoreboard() end
    elseif msg == "pvp" then
        -- Probe scoreboard access via index iteration (the GUID-keyed
        -- C_PvP.GetScoreInfoByPlayerGuid path is broken in 12.x because
        -- enemy GUIDs are secret-string values).  Look for the target's
        -- NAME in the scoreboard, and dump that row's PVPScoreInfo.
        if not UnitExists("target") then
            print("|cff00c0ffMyNamePlates|r: no target — target a unit first.")
        else
            local tname = UnitName("target") or "?"
            local guid = UnitGUID("target")
            print(("|cff00c0ffMyNamePlates|r PvP scoreboard probe for %s:"):format(tname))

            -- GUID secret-ness — the smoking gun from the previous run.
            print(("  guid              = %s"):format(tostring(guid)))
            print(("  issecretvalue(guid)= %s"):format(
                tostring(guid and issecretvalue and issecretvalue(guid) or false)))
            print(("  name              = %s"):format(tostring(tname)))
            print(("  issecretvalue(name)= %s"):format(
                tostring(tname and issecretvalue and issecretvalue(tname) or false)))

            -- Score count via both modern + legacy APIs.
            local nModern, nLegacy
            if C_PvP and C_PvP.GetNumScores then
                local ok, v = pcall(C_PvP.GetNumScores)
                if ok then nModern = v end
            end
            if GetNumBattlefieldScores then
                local ok, v = pcall(GetNumBattlefieldScores)
                if ok then nLegacy = v end
            end
            print(("  C_PvP.GetNumScores       = %s"):format(tostring(nModern)))
            print(("  GetNumBattlefieldScores  = %s"):format(tostring(nLegacy)))

            -- Force a fresh scoreboard pull, then iterate.
            if RequestBattlefieldScoreData then
                pcall(RequestBattlefieldScoreData)
            end

            local n = nModern or nLegacy or 0
            if n <= 0 then
                print("  scoreboard EMPTY — try again in 2-3s after server pushes data.")
                return
            end

            local matched = false
            for i = 1, n do
                local info
                if C_PvP and C_PvP.GetScoreInfo then
                    local ok, v = pcall(C_PvP.GetScoreInfo, i)
                    if ok then info = v end
                end
                if info and info.name == tname then
                    matched = true
                    print(("  match at score index #%d:"):format(i))
                    for k, v in pairs(info) do
                        local typ = type(v)
                        local secretMark = (typ == "string" and issecretvalue
                                            and issecretvalue(v)) and " [SECRET]" or ""
                        if typ == "string" or typ == "number" or typ == "boolean" then
                            print(("    %s = %s (%s)%s"):format(
                                k, tostring(v), typ, secretMark))
                        elseif typ == "table" then
                            print(("    %s = <table>"):format(k))
                        else
                            print(("    %s = (%s)"):format(k, typ))
                        end
                    end
                    break
                end
            end
            if not matched then
                print(("  no scoreboard row matched name=%q (out of %d rows)"):format(
                    tname, n))
            end
        end
    elseif msg == "tooltip" then
        -- Dump the raw tooltip-data lines for the current target.
        -- Use this when enemy specs "miss" in BG/world — shows whether
        -- the spec line is actually present, and on which line/text
        -- field.  Reveals the difference between en-US "Frost Mage"
        -- and locale variants like "Mage Frost" or "Level 80 Frost
        -- Mage" so the lookup table / scan can be widened to match.
        if not UnitExists("target") then
            print("|cff00c0ffMyNamePlates|r: no target — mouseover or target a unit first.")
        elseif not (C_TooltipInfo and C_TooltipInfo.GetUnit) then
            print("|cff00c0ffMyNamePlates|r: C_TooltipInfo unavailable on this client.")
        else
            local data = C_TooltipInfo.GetUnit("target")
            print(("|cff00c0ffMyNamePlates|r tooltip for %s (%s):"):format(
                UnitName("target") or "?", UnitIsFriend("player","target") and "friend" or "enemy"))
            if not (data and data.lines) then
                print("  (no data)")
            else
                for i, line in ipairs(data.lines) do
                    print(("  [%d] type=%s left=%q right=%q"):format(
                        i, tostring(line and line.type),
                        tostring(line and line.leftText or ""),
                        tostring(line and line.rightText or "")))
                end
            end
        end
    elseif msg == "mem" or msg == "memory" or msg == "mem gc" or msg == "memory gc" then
        -- 1.34.1: memory diagnostic.  Dumps Lua GC state + per-cache
        -- sizes so we can spot growth-without-bound.  User reported
        -- ~40 MB memory usage in arena that got reclaimed on GC —
        -- that closure-churn is fixed in 1.34.1 via the debounced
        -- refresh consumer, and this command lets us verify.
        --
        -- Usage:
        --   /mnp mem          -- one-shot snapshot
        --   /mnp mem gc       -- snapshot, run collectgarbage("collect"),
        --                        snapshot again (shows garbage size)
        --
        -- What "high" looks like on this addon:
        --   * Lua memory total > 15 MB  → investigate
        --   * active + summonByPlate + specByPlate > 200 total → many
        --     plates in flight or cleanup regression
        --   * scoreboardByName > 40 → possibly a leaked map (should
        --     be capped by BG size)
        local before = collectgarbage("count")   -- KB across all Lua
        local function fmt(kb) return ("%.1f MB (%d KB)"):format(kb / 1024, kb) end
        print("|cff00c0ffMyNamePlates|r memory:")
        print(("  Lua total:            %s"):format(fmt(before)))
        if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
            pcall(UpdateAddOnMemoryUsage)
            local mnp = GetAddOnMemoryUsage("MyNamePlates") or 0
            print(("  MyNamePlates addon:   %s"):format(fmt(mnp)))
        end
        if ns.DumpCacheSizes then
            ns:DumpCacheSizes()
        end
        if msg == "mem gc" or msg == "memory gc" then
            collectgarbage("collect")
            local after = collectgarbage("count")
            print(("  Lua after GC:         %s   (reclaimed %.1f MB)"):format(
                fmt(after), (before - after) / 1024))
            if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
                pcall(UpdateAddOnMemoryUsage)
                local mnpAfter = GetAddOnMemoryUsage("MyNamePlates") or 0
                print(("  MyNamePlates after GC: %s"):format(fmt(mnpAfter)))
            end
        end
    else
        OpenPanel()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() Register() end)

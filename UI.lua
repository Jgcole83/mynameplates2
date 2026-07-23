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
    MakeHeading(content, "Plate Width / Height"):SetPoint("TOPLEFT", 0, y); y = y - 22
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
local function BuildCategoryPanel(panel, def)
    AddHeader(panel, def.label, def.blurb)

    local content = CreateFrame("Frame", nil, panel)
    content:SetPoint("TOPLEFT",     PAD,    -PAD * 4)
    content:SetPoint("BOTTOMRIGHT", -PAD,    PAD)

    local y = -PAD
    if def.kind == "master" or def.kind == "list" then
        y = AddCategoryControls(content, def, y)
    end
    if def.kind == "list" then
        y = y - 6
        BuildNpcList(content, def, y)
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
    end

    return y - 8
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
    else
        OpenPanel()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() Register() end)

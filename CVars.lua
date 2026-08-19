-- CVars.lua
-- The "General" page's options.  Per-category visibility, size, and opacity
-- now live in Categories.lua + the categories' own pages.

local _, ns = ...

----------------------------------------------------------------------
-- General toggles + global scale + global alpha CVars
----------------------------------------------------------------------
ns.GLOBAL = {
    -- Visibility master
    { key = "nameplateShowAll",
      label = "Always show nameplates",
      tooltip = "Show nameplates even when you don't have a target.",
      type = "toggle", default = "1" },

    -- (Click-through master toggle removed in v1.11.5: our C_NamePlate API
    -- calls were breaking click-targeting on retail Midnight 12.0.5,
    -- whereas Blizzard's defaults work fine.  Use BBP's friendly-clickthrough
    -- option if you need to control this.  We may revisit with a different
    -- approach in the future.)

    -- Global scale
    { key = "nameplateGlobalScale",
      label = "Global Scale",
      tooltip = "Multiplier applied to every nameplate.",
      type = "slider", default = 1.0, min = 0.5, max = 2.0, step = 0.05 },
    { key = "nameplateSelectedScale",
      label = "Selected Target Scale",
      tooltip = "Scale of your current target's nameplate.",
      type = "slider", default = 1.2, min = 0.5, max = 2.0, step = 0.05 },
    { key = "nameplateLargerScale",
      label = "Boss / Elite Scale",
      tooltip = "Scale used for important / boss units.",
      type = "slider", default = 1.2, min = 0.5, max = 2.0, step = 0.05 },
    { key = "nameplateMinScale",
      label = "Minimum Scale (far)",
      tooltip = "Minimum scale for distant nameplates.",
      type = "slider", default = 0.8, min = 0.5, max = 2.0, step = 0.05 },
    { key = "nameplateMaxScale",
      label = "Maximum Scale (near)",
      tooltip = "Maximum scale for close nameplates.",
      type = "slider", default = 1.0, min = 0.5, max = 2.0, step = 0.05 },

    -- Global alpha
    { key = "nameplateMinAlpha",
      label = "Minimum Alpha (far)",
      tooltip = "Opacity of nameplates at maximum distance.",
      type = "slider", default = 0.6, min = 0.0, max = 1.0, step = 0.05 },
    { key = "nameplateMaxAlpha",
      label = "Maximum Alpha (near)",
      tooltip = "Opacity of nameplates up close.",
      type = "slider", default = 1.0, min = 0.0, max = 1.0, step = 0.05 },
    { key = "nameplateSelectedAlpha",
      label = "Selected Target Alpha",
      tooltip = "Opacity of your current target's nameplate.",
      type = "slider", default = 1.0, min = 0.0, max = 1.0, step = 0.05 },
    { key = "nameplateNotSelectedAlpha",
      label = "Non-target Alpha",
      tooltip = "Opacity multiplier when you have a target other than the plate.",
      type = "slider", default = 1.0, min = 0.0, max = 1.0, step = 0.05 },
    { key = "nameplateOccludedAlphaMult",
      label = "Occluded Alpha Multiplier",
      tooltip = "Opacity multiplier for nameplates hidden behind objects.",
      type = "slider", default = 0.4, min = 0.0, max = 1.0, step = 0.05 },
}

----------------------------------------------------------------------
-- Plate width / height.
--
-- 1.36.6: two independent code paths, because in Midnight 12.x these
-- two dimensions are driven by entirely different APIs:
--
--   * WIDTH → C_NamePlate.SetNamePlateSize(width, BOX_H).  Visibly
--     resizes the healthbar and the click box together.  The old
--     split friendly/enemy setters were removed in Midnight so
--     everything goes through the unified call.
--
--   * HEIGHT → HealthBarsContainer:SetHeight(h) per plate, hooked
--     inside NamePlateUnitFrameMixin:UpdateAnchors so Blizzard
--     can't overwrite it on the next anchor refresh.  Passing a
--     custom height to SetNamePlateSize only changes the invisible
--     click box — the visible bar height is driven separately by
--     Blizzard's own NamePlateVerticalScale CVar times a constant,
--     which is why the pre-1.36.6 height slider silently no-op'd.
--     BBP hit the same wall (see midnight/BetterBlizzPlates.lua
--     :5646-5648, where their own "box height" slider is disabled
--     with the comment "Disabled until I figure out stuff") and
--     solved it the same way we do here via their HookHealthbarHeight
--     + AdjustHealthBarHeight (lines 2634 / 9580).
--
-- Defaults:
--   * width = 110 is our "unconfigured" sentinel — Core.lua's
--     ApplyAll skips SetNamePlateSize at this value so Blizzard's
--     Large Nameplates CVar can drive the width (145 without,
--     185 with) as usual.
--   * height = 10 matches BBP's default (4 * 2.7 = 10.8, rounded).
--     Applied unconditionally via the UpdateAnchors hook.  The
--     hook is cheap (a single SetHeight call per anchor refresh)
--     and idempotent.
----------------------------------------------------------------------
ns.PLATE_SIZE = {
    { key = "width",  label = "Nameplate Width", default = 110, min = 50, max = 300, step = 1,
      tooltip = "Width of the nameplate healthbar in pixels.  Applies to BOTH friendly and enemy plates — Blizzard removed the ability to set them separately in Midnight 12.x.  Leave at 110 to use Blizzard's default (which is 145 with Large Nameplates off, 185 with it on)." },
    { key = "height", label = "Bar Height",      default = 10,  min = 2,  max = 40,  step = 1,
      tooltip = "Height of the visible healthbar in pixels.  Applied per-plate via HealthBarsContainer:SetHeight because Blizzard's SetNamePlateSize height parameter in Midnight 12.x only resizes the invisible click box — it does NOT change the visible bar (that's driven separately by the NamePlateVerticalScale CVar).  Default 10 matches Blizzard's own default; drag lower for a thinner bar or higher for a thicker one." },
}

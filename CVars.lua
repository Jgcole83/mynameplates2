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
-- Plate width / height (set via C_NamePlate, not a CVar).
--
-- 1.36.5: Blizzard REMOVED C_NamePlate.SetNamePlateFriendlySize /
-- SetNamePlateEnemySize in retail Midnight 12.x — the only working
-- API is now the unified C_NamePlate.SetNamePlateSize(width, height)
-- which sets BOTH friendly and enemy plates to the same dimensions.
-- (Confirmed via BBP midnight/BetterBlizzPlates.lua:6002 comment:
-- "Blizzard decided to remove the API to control different widths for
-- Friendly/Enemy Nameplates in Midnight.")
--
-- Pre-1.36.5 the addon exposed four sliders (friendlyWidth,
-- friendlyHeight, enemyWidth, enemyHeight) but silently no-op'd
-- because we called the removed APIs.  The four old keys are
-- migrated to the two new unified keys in Core.lua's ADDON_LOADED
-- handler (max of friendly/enemy for each dimension).
--
-- Defaults track BBP: 110x45 is our "unconfigured" sentinel that
-- Core.lua's ApplyAll uses to SKIP calling the API — that leaves
-- Blizzard's own defaults (which depend on the Large Nameplates
-- CVar: 145 or 185 for width) untouched.  Any deviation from 110x45
-- triggers enforcement + the SetNamePlateSize reassert hook.
----------------------------------------------------------------------
ns.PLATE_SIZE = {
    { key = "width",  label = "Nameplate Width",  default = 110, min = 50, max = 300, step = 1,
      tooltip = "Width of the nameplate healthbar in pixels.  Applies to BOTH friendly and enemy plates — Blizzard removed the ability to set them separately in Midnight 12.x.  Leave at 110 to use Blizzard's default (which is 145 with Large Nameplates off, 185 with it on)." },
    { key = "height", label = "Nameplate Height", default = 45,  min = 10, max = 120, step = 1,
      tooltip = "Height of the nameplate healthbar in pixels.  Applies to BOTH friendly and enemy plates.  Leave at 45 to use Blizzard's default." },
}

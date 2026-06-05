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
-- Plate width / height (set via C_NamePlate, not a CVar)
----------------------------------------------------------------------
ns.PLATE_SIZE = {
    { key = "friendlyWidth",  label = "Friendly Width",  default = 110, min = 50, max = 250, step = 1 },
    { key = "friendlyHeight", label = "Friendly Height", default = 45,  min = 10, max = 100, step = 1 },
    { key = "enemyWidth",     label = "Enemy Width",     default = 110, min = 50, max = 250, step = 1 },
    { key = "enemyHeight",    label = "Enemy Height",    default = 45,  min = 10, max = 100, step = 1 },
}

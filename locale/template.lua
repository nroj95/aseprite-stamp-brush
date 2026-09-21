-- Stamp Brush translation template.
--
-- To add a translation:
-- 1. Copy this file and name it after Aseprite's language code, for example:
--      de.lua
--      nb.lua
--      pt-br.lua
-- 2. Translate only the quoted text on the right side.
-- 3. Keep every key on the left unchanged.
-- 4. Keep format placeholders such as %d unchanged.
--
-- You may omit strings you do not want to translate. Missing keys fall back
-- to the built-in English text.

return {
    clone_stamp = "Clone Stamp",
    eraser_only = "Eraser Only",
    eraser_needs_transparency =
        "Eraser Only requires a non-background layer with transparency.",

    tiled_mode = "Tiled Mode",
    radius = "Radius",
    opacity = "Opacity",
    softness = "Softness",

    apply = "Apply",
    reset = "Reset",
    before = "Before",
    after = "After",
    apply_changes = "Apply changes?",
    discard = "Discard",
    continue_editing = "Continue Editing",

    stroke_made_one = "1 stroke made.",
    strokes_made_other = "%d strokes made.",

    raster_layer_required =
        "Clone Stamp requires a raster image layer, not a tilemap or reference layer.",
    layer_locked =
        "The layer or one of its groups is locked.",
    no_active_cel =
        "No active cel!",
    unsupported_color_mode =
        "Unsupported image color mode.",
    no_usable_palette =
        "The active frame has no usable palette.",

    active_sprite_changed =
        "The active sprite changed while Clone Stamp was open. Changes were not applied.",
    original_cel_missing =
        "The original cel no longer exists.",
    original_cel_changed =
        "The original cel or canvas changed while Clone Stamp was open. Changes were not applied.",

    unknown_error = "Unknown error",
    full_error_report = "Full error report written to:",
    error_report_failed = "Could not write the full error report.",
    changes_not_applied =
        "Changes were not applied. Your session is still available.",
    clone_stamp_failed =
        "Clone Stamp failed.",
}

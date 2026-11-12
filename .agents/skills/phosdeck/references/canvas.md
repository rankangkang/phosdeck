# Canvas and local editing

Read the target photo ID and both revisions. For positions, render `get_photo_preview` and use coordinates normalized to the returned PNG's top-left origin. Convert pixel centers with `(pixel + 0.5) / dimension`. A `region` request returns its actual pixel-aligned bounds in the full preview. Coordinates for the next action are relative to the returned detail PNG. Use the new recipe revision and a fresh preview after a save.

## Geometry, sampling and repair

- Use `preview_variant=crop_canvas` for `set_crop(action=set)` and for points on `edit_perspective_guides`. Set an aspect ratio or lock, rotate, unlock or reset it using the crop actions. `set_photo_geometry` patches rotation, straightening, flips and perspective. Positive turns rotate the visible canvas clockwise. Read the effective crop and the saved version from `get_job`.
- Use `solve_perspective` for automatic correction. For guides, select the target and enter `set_workspace_view(view=develop, tool=crop)`. Begin the guide tool, add or move endpoints, and read the current guide state before finishing. The native solver may require more lines or report that a proposed correction is unsupported.
- `sample_preview` reads RGB and clipping from the returned PNG. Luminance zones, targeted adjustments and new point-color samples use a default saved preview with `editable_canvas=true`. Use `adjust_from_preview` for white balance, histogram, HSL, monochrome mixer, curves and defringe. `edit_point_color` returns the saved sample ID for later changes.
- Use `get_spot_repairs` for IDs and the source-space targets. Read one repair with `spot_id` for its full path. To add a repair, supply a point or path and optionally a `source_point` on the same saved preview. Subsequent actions can move the target, set or refresh its source, use automatic source selection, or edit its brush settings.

## Masks and local parameters

- Use `get_mask_state` to find groups, then pass a `mask_id` for its components and settings. Create a group with `edit_mask_group`, and combine components with `edit_mask_component`. A brush stroke uses `apply_mask_brush_stroke` with its entire path, including erase or auto-mask options. `set_mask_shape` takes linear endpoints or a radial center and corner. `set_mask_range` edits color samples and luminance. Readback points are normalized in the oriented source. Use a fresh saved preview for new canvas coordinates.
- Use `get_photo_preview(mask_overlay={mask_id, style, color})` to inspect a saved mask, or `without_mask_id` to compare the photo with that effect temporarily hidden. These views are for inspection. Switch to an editable preview to draw or sample for an adjustment. `set_mask_display` changes the active native Mask workspace.
- `set_local_adjustments` accepts `adjustments.basic`, `color`, `curves` and `zone_gains`, as well as mask `amount`. Use `transfer_local_adjustments` for the App's copy/paste of local parameters. `list_local_adjustment_presets` supplies IDs and revisions for `edit_local_adjustment_preset`. Preset application and paste preserve the target mask's shape and amount.

## Smart selections

Select the target and enter `set_workspace_view(view=develop, tool=mask)`. Check `get_capabilities.smart_mask_models`. Object selection, body parts and facial refinement depend on the installed models. Whole-person detection uses the native people workflow.

1. Call `start_smart_mask` with `workflow=object` or `people`. Omit target fields for a new group, give `mask_id` and `mask_operation` to combine, or give `mask_id` and `component_id` to refine saved smart coverage.
2. Poll `get_job` and read `get_mask_state` for the session ID, `selection_revision`, current candidates, people, faces and parts. Pass the latest session ID and revision to `edit_smart_mask_selection`. Points and boxes refer to a current saved preview. Inspect a candidate or selected coverage with `get_photo_preview(smart_overlay={smart_session_id, selection_revision, target, index})`, using the index only for an indexed target.
3. When `can_apply` is true and the selection matches the task, call `apply_smart_mask`. Poll for the saved version, affected mask IDs and undo operation. Cancel a running analysis with `cancel_job` or close an idle selection with `edit_smart_mask_selection(action=cancel)`.

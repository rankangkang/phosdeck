# Development and edit records

Use `get_photo_recipe` for the current global settings and the photo's source and recipe revisions. A `photo_id` identifies an edit version. You can read and save a specific version without selecting it in the App. For a history entry or snapshot, pass its ID from `list_edit_records` on the same version.

## Try exposure, color and preset strength before saving

1. Open a draft with `edit_photo_draft(action=begin)`, the photo ID, and the saved source and recipe revisions. Poll `get_job` for the draft ID and revision.
2. Pass both draft fields and the saved version identity to `set_global_adjustments` or `set_color_adjustments`. Poll each job and use the returned draft revision for the next call. Pass the draft fields and `photo_id` to `get_photo_recipe` to read the trial values.
3. Pass the same draft and saved version fields to `get_photo_preview`. Set `long_edge` and omit the region to see the whole edited photo. To compare against the saved version, request the same preview size with the saved version fields alone.
4. Commit or cancel with `edit_photo_draft` and the current draft ID and revision. A changed draft creates one history entry and one undo action on commit. Cancel discards the in-memory draft. After committing, verify the saved recipe and preview at the same size.

For preset strength, use `transfer_adjustments(action=preset)` in step 2. Pass the draft fields, current preset ID and revision, one target in `photo_ids`, and its saved versions in `expected_revisions`. Each consecutive preset trial replaces the previous trial from the same starting recipe. `amount` ranges from `0` to `2`, with `1` at 100 percent. `0` restores the starting recipe. A change through another draft edit tool starts a new baseline for the next preset trial. Read `preset_trial` for the current amount and groups. Use the returned draft revision alone with the saved photo identity when rendering the trial in `get_photo_preview`.

## Edit and verify

- Send only the fields you intend to change in `set_global_adjustments`, `set_color_adjustments`, `set_detail_adjustments` or `set_effects`. Use the registered input schemas for names and ranges. Exposure is in EV. Contrast and saturation are multipliers with neutral 1. Temperature is in kelvin. `as_shot_white_balance=true` restores both baseline values. Set `pipeline_version=2` to switch to current development when requested.
- `set_tone_curve` edits one luminance or RGB channel. Read its point list before using a zero-based point index. `set_zone_lighting` takes five gains from deep shadows to highlights. `reset_adjustments` resets one group. `group=all` invokes Phosdeck's full reset, including geometry, masks and repairs.
- For automatic white balance or tone use `run_automatic_adjustment`. For a batch use `apply_relative_exposure` or `match_total_exposures`, with an `expected_revisions` map from each supplied photo ID to its source and recipe revisions. Matching needs a source with aperture, shutter speed and ISO and a separate list of targets.
- Poll `get_job` until it reaches a final state. Read the per-photo results and `commit_state`. Batch adjustments can skip individual unsupported or unavailable targets. A stale target rejects the batch. Use the returned revisions with `get_photo_recipe` or `get_photo_preview` to verify the saved result. The same request ID returns the existing job. Use `cancel_job` to request cancellation and poll for the outcome.

## Compare, preview and restore

- In Develop or Single view, `set_before_after` changes the active canvas to `off`, `original`, `side_by_side` or `split`. Pass a history or snapshot ID to pin a saved reference. `get_workspace` shows the layout, both sides and preview readiness.
- For PNGs, `get_photo_preview` with `preview_variant=before` aligns the original or a specified record to the saved geometry. Use the default saved preview as the after image. `preview_variant=original` shows the uncropped baseline. In saved mode, a record ID previews that record's own geometry, a preset ID and revision previews its settings, and `group` temporarily hides that group in the rendered preview. These calls respect the image sharing switch.
- `preview_adjustment` shows a record in the navigator or a preset or hidden group on the active Develop canvas. Use `action=clear` to dismiss the temporary preview. Use `apply_edit_record` only when the user wants to restore a record as a new saved edit.
- `save_edit_snapshot` creates a named snapshot of the saved recipe. For renaming or deleting use the `snapshot_id` and `snapshot_revision` from `list_edit_records(record_type=snapshots)`. The deletion registers an undo action. Creation and rename follow the native snapshot save behavior.

## Presets and transfer

- `list_adjustment_presets` searches by name or filters by group and favorites. Use the current `preset_id` and `preset_revision` to update, preview, apply or delete a preset. Create or update from a saved photo and explicit parameter groups with `edit_adjustment_preset`.
- `transfer_adjustments` supports `copy`, `paste`, `sync`, `previous` and `preset`. `copy` stores the source in Phosdeck's adjustment clipboard. `paste` uses that stored recipe. `previous` uses the settings stored when leaving the previous photo, shown in `get_workspace`. `sync` uses an explicit source `photo_id`. Specify the target versions and the groups to transfer. For a preset, omitted groups use its saved selection and `amount=1` means 100 percent.
- To import Lightroom XMP presets, request file access with `purpose=xmp_presets` and have the user select the files in Phosdeck. Use the access ID with `plan_xmp_preset_import`. Read the candidate IDs and conversion issues from `get_job`, then import the chosen candidates with `import_xmp_presets`. Read back duplicates and the imported preset IDs. Applying an imported preset transfers only the supported settings declared by the XMP.

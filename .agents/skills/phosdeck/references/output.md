# Photo merge and export

Start with the current workspace. Use ordered `photo_ids` and `expected_revisions` with `source_revision` and `recipe_revision` keyed by each ID. Supply the catalog session and request fields from the registered schemas. Poll `get_job` until the job finishes and read its result items. When a plan expires, read the current photo versions and plan again.

## Merge originals

1. Use `plan_photo_merge` with the distinct originals in capture or focus order. Choose `panorama`, `hdr`, `hdrPanorama`, `focus`, `average`, `median`, `additive`, `lighten`, `darken` or `screen`. For `hdrPanorama`, keep the exposures of each camera position contiguous and set `bracket_size`. Review the plan's native options, filename and regular collection.
2. Call `render_merge_preview`. With **Share Photo Previews** enabled, use its `preview_id` with `get_merge_preview`. `display_ev` adjusts the viewing exposure. Use the latest prepared preview when saving.
3. Request `merge_destination` access. Use `save_photo_merge` with that access ID, the preview ID and a new filename with the matching extension. Choose `master_format: tiff` or `dng`. Set `stack_with_sources` according to the user's intent. Phosdeck stacks by default.
4. Check `published`, `verified` and `indexed`. Use the returned `photo_id` to edit or export the indexed master. An `operation_id` can undo the stack change while preserving the master. For a published file with incomplete registration, use `reveal_file_in_finder` with `kind: merge` and its `file_id` while the session is active. Verify the preserved file before importing it by reference. Use a new filename for a separate merge.

## Plan and deliver outputs

1. Request `export_destination` access. Use `plan_export` with one `options` object or a `specifications` array for multiple outputs. Supply a `title` and distinct `subfolder` per specification. An export preset is optional. Read `list_export_presets` and pass its `preset_id` and `preset_revision` together, then add any option overrides. `edit_export_preset` creates, updates, renames or deletes custom presets and can restore the current export options to defaults.
2. Choose `jpeg`, `png` or `tiff`. For JPEG, set `jpeg_matte` to `black` or `white`. PNG and 16-bit TIFF preserve alpha. Set `long_edge` in pixels or `null` for original size. Set `metadata_policy` according to the user's sharing intent. `capture` uses allowed camera fields, `description` uses the saved catalog caption and keywords, and `captureAndDescription` includes both. The default is `none`.
3. Read `get_export_preview` for paged filenames and conflicts. Pass a row's `output_id` for a PNG preview with **Share Photo Previews** enabled. Names can be checked with image sharing off. Use the requested naming, sizes and destinations to resolve conflicts and then replan. Run a ready plan with `run_export`.
4. Read the job's counts and output rows. Preserve `record_id` values for later verification and use `reveal_file_in_finder` with `kind: export` and `record_ids` to show delivered files. Report actual completed outputs and incomplete records. Dimensions are available for outputs that were published or verified during the job.

## Resume or verify

- If the client disconnects, recover the known job or resend the same request within its epoch. If the server or app has restarted, open the same catalog and use `list_export_records`, optionally with `unfinished_only` or explicit `record_ids`, before planning additional files.
- Call `verify_or_retry_export` with the intended record IDs. It checks the digest of existing outputs and can regenerate missing outputs from the frozen settings when sources and access are available. Set `include_completed: false` to retry only unfinished work. A conflicting file is preserved for review.
- If destination access expired, request `export_destination` for the exact original parent folder of the affected records, including the specification's subfolder when applicable. Use `reauthorize_export_location` with those IDs and retry. Work on each destination folder separately.
- After `cancel_job`, check the terminal state and any durable records before resuming. Cancellation can leave some outputs already published.

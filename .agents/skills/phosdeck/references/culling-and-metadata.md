# Culling and photo metadata

## Set the working range

Read `get_workspace` for the catalog session and the user's current view. Find sources with `list_library_sources`. For independent browsing, use `list_photos` with a `query` object, such as `{"source_id":"all","rating_threshold":4,"sort":"captureDate","descending":true}`. An empty object starts from all photos in capture order. Independent queries default to `listing=matches`, which includes folded stack members. With `listing=visible` the result follows stack folding.

Pass `next_cursor` as `cursor` for each continuation, omitting `query` and keeping its page size and listing. If the cursor expires, repeat the initial query with the current catalog session. Omit `query` on the first page to read the user's current results with the default `listing=visible`. Use `list_selected_photos` for the full selection, which can span pages and folded stacks.

When the user wants to change the view, use `set_library_query` for the source, criteria, filter sections, sort, or hold mode. Omitted fields retain their values. Specify `clear_filters` when starting with new criteria, and use `filters_open` to show or hide the filter controls. With `hold_results` on, saved ratings and other edits remain visible on the same result rows. Use `refresh_library_query` when the task calls for recomputing membership.

Use `select_photos` to select explicit version IDs, all matches, or the matching members of a stack. For a relative change to the current query or selection, pass the corresponding revision from the workspace. Use `action=open_version` to open a particular version and preserve the prior browse position. Use `navigate_library` for the previous or next photo or page, or for a recorded browse position.

## Compare and review

Use `analyze_photo_culling` to reduce a burst or search range before reviewing images. Supply up to 1,000 explicit `photo_ids` or an independent `query`, together with the catalog session. Poll `get_job` and page results with `next_offset`. Use the grouped rows' `recommended` and `rank` for a shortlist or pass `reference_photo_id` for similarity search. Prefer within-burst comparisons of the original-thumbnail sharpness score. If a source is unavailable or the report goes stale during analysis, check the source or start another analysis. For saved marks or stacks, explicitly invoke the corresponding tools after review.

Use `set_compare_photos` for a reference and candidate, or `set_survey_photos` for a group. Read the returned panes or survey page to identify the current versions. To pin a Develop reference, select the photo in Develop and wait for `can_edit` before calling `set_develop_reference`. Use `set_viewport` for zoom and pan. Centers are normalized from the image's top-left, and the reported current center can be clamped by the pane size. `set_clipping_display` controls the App's shadow and highlight overlays.

For review without switching the view, use `list_photos` with an independent `query` or with the shortlist's `photo_ids` in the order you want them displayed. Add `contact_sheet=true` to each page that needs a PNG. It defaults to 12 photos per page and accepts up to 24. The image and the `items` rows use the same continuous `number`. Skip cells with `thumbnail_status=unavailable` when choosing visually. A ready cell's `image_pixels` gives its image bounds in the sheet. Normalize a region inside those bounds and pass it as `region` with `resolution=native` to `get_photo_preview`, using that row's `photo_id`, `source_revision`, and `recipe_revision`. Use `plan_only=true` to inspect native dimensions and limits or pass `region_pixels` in the full photo's native coordinates. Both image calls require Share Photo Previews.

When a filename has multiple versions, resolve the intended version before writing.

## Write marks, keywords, or captions

- Use `set_photo_rating` for one version or `set_photo_ratings` for a common rating or a per-photo step. Pass the observed rating for each target, and set `advance` only if the user wants to move on from the active photo.
- Use `set_photo_marks` for flags and color labels. Each target carries the observed value of each field being changed. One mismatch blocks the batch. Review the reported current value before retrying.
- Read `list_keywords` with a `photo_id` to see that version's caption and keywords. Use `edit_photo_keywords` to add or remove terms for explicit versions. `rename_keyword` affects all associations of the catalog keyword, so use it when the user wants a catalog-wide rename.
- Use `set_photo_caption` with `expected_captions` mapping each target ID to its exact current caption. An empty new caption clears the field. If a caption changed, reconcile it with the user's intent before resubmitting.

Each catalog edit returns its actual affected IDs or values. An `operation_id` refers to one native undo step, even when it covers a batch.

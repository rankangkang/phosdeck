# Culling and photo metadata

## Set the working range

Read `get_workspace` for the active source, effective filters, selection, and browse position. Find other sources with `list_library_sources`. Use `set_library_query` to change the source, criteria, filter sections, sort, or hold mode. Omitted fields retain their values. Specify `clear_filters` when starting with new criteria, and use `filters_open` to show or hide the filter controls. With `hold_results` on, saved ratings and other edits remain visible on the same result rows. Use `refresh_library_query` when the task calls for recomputing membership.

Use `list_photos` with `listing=matches` to include folded stack members, or the default `listing=visible` for the grid order. Page with `next_cursor` and the same page size until it is null. Use `list_selected_photos` for the full selection, which can span pages and folded stacks. If a cursor expires, reread the workspace and start that list again.

Use `select_photos` to select explicit version IDs, all matches, or the matching members of a stack. For a relative change to the current query or selection, pass the corresponding revision from the workspace. Use `action=open_version` to open a particular version and preserve the prior browse position. Use `navigate_library` for the previous or next photo or page, or for a recorded browse position.

## Compare and review

Use `set_compare_photos` for a reference and candidate, or `set_survey_photos` for a group. Read the returned panes or survey page to identify the current versions. To pin a Develop reference, select the photo in Develop and wait for `can_edit` before calling `set_develop_reference`. Use `set_viewport` for zoom and pan. Centers are normalized from the image's top-left, and the reported current center can be clamped by the pane size. `set_clipping_display` controls the App's shadow and highlight overlays.

Use the saved photo ID and its source and recipe revisions with `get_photo_preview` to inspect the image. When a filename has multiple versions, resolve the intended version before writing.

## Write marks, keywords, or captions

- Use `set_photo_rating` for one version or `set_photo_ratings` for a common rating or a per-photo step. Pass the observed rating for each target, and set `advance` only if the user wants to move on from the active photo.
- Use `set_photo_marks` for flags and color labels. Each target carries the observed value of each field being changed. One mismatch blocks the batch. Review the reported current value before retrying.
- Read `list_keywords` with a `photo_id` to see that version's caption and keywords. Use `edit_photo_keywords` to add or remove terms for explicit versions. `rename_keyword` affects all associations of the catalog keyword, so use it when the user wants a catalog-wide rename.
- Use `set_photo_caption` with `expected_captions` mapping each target ID to its exact current caption. An empty new caption clears the field. If a caption changed, reconcile it with the user's intent before resubmitting.

Each catalog edit returns its actual affected IDs or values. An `operation_id` refers to one native undo step, even when it covers a batch.

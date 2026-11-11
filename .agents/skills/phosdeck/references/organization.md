# Photo organization

Use the current `catalog_session_id` for catalog tools, and the current `request_epoch` with a new `request_id` for each new write or plan. Read the tool schema for supported fields. Follow `next_offset` on collection, version, stack, pair, and job pages. Use a returned revision when acting on observed state.

## Collections

- Find collection IDs through `list_library_sources`. Read `get_collection` for `collection_revision`, saved rules or manual membership order, and current member IDs. Use the collection's `source_id` with `set_library_query` to open it.
- Use `save_collection` to create or rename a regular collection. Use `set_collection_members` with `add` or `remove` and explicit `photo_ids`. For `collect_results`, pass an existing `collection_id` or a new `name` and the reviewed `query_revision`. This collects all matching versions, including held and folded rows.
- Use `set_target_collection` to choose a regular collection for quick actions. Omitting the ID restores the default Quick Collection if it exists. Read `target_collection_id` from `get_workspace` before calling `edit_quick_collection` with `add` or `remove`. When the target is unset, omit `collection_id`. Adding creates the default Quick Collection when needed.
- Use `reorder_collection` with `set_manual_order` for the open collection. For `move`, pass the member `photo_ids` and optional `before_photo_id`. Omit the anchor to move to the end. Read `get_collection` for the resulting live order.
- Use `save_smart_collection` with `from_current_query=true` and the reviewed `query_revision`, or provide `rules` with `source_id`, `match`, and `conditions`. Conditions use the declared field and operator names. Values are strings, including numbers and booleans. `between` also uses `upper`. Read back the rules and current matches. Use `delete_collection` or `delete_smart_collection` to remove the collection and retain its photos.

## Edit versions

Call `list_photo_versions` with `photo_id` or the physical `source_id` from a photo row. The physical ID is used for version and pair tools. A library source such as `collection:<id>` is used for queries. Open the exact version with `select_photos` and `action=open_version`.

`create_virtual_copies` takes explicit `photo_ids` and uses their current saved edits. For a copy from a saved step, call `list_edit_records` on that version with `record_type=history` or `snapshots`, then pass the matching `history_id` or `snapshot_id` with one target. `expected_revisions` can pin the source and recipe of every target. Use `rename_photo_version` with `expected_name` for a virtual copy. Use `remove_photo_versions` for the specified edit versions, preserving the original files. Read the returned `operation_id` for undo availability.

## Display stacks

Use `list_photo_stacks` for group summaries and `stack_revision`. With `stack_id` or a member `photo_id`, it returns the ordered members and their `in_query` flags. Pass the reviewed revision to `edit_photo_stack`. Use `group` with a cover `photo_id` and the `photo_ids` to group or merge, `remove` or `ungroup` with member IDs, and `cover`, `split`, or `move` with one member. Use `earlier` or `later` as the move direction. Use `collapse` or `expand` with `stack_ids`, or use `select_all=true` with the reviewed `query_revision` for all matching stacks.

Use `plan_auto_stacks` with `interval_seconds` and the reviewed query, selection, or explicit IDs in the query. Poll `get_job` to a terminal state and page the proposed members. Review the grouping and skip counts. `apply_auto_stacks` applies the whole `plan_id` in one undoable action. Generate a fresh plan on `stale_plan`.

## RAW/JPEG pairs

Use `list_raw_jpeg_pairs` for saved pairs or `listing=sources` for physical RAW and JPEG IDs. One pair links the originals. Each side can have several edit versions.

1. Call `plan_raw_jpeg_pairs` with `action=detect` and the requested scope or explicit photo IDs. Poll `get_job` and page the candidates. Review the source names, eligibility and issues.
2. Use `action=verify` with the detection `plan_id` and the chosen eligible `candidate_ids`. For a known same-capture pair, use `action=manual` with `raw_source_id`, `jpeg_source_id` and `same_capture=true`. Read the finished job, including file verification failures or metadata warnings.
3. Call `apply_raw_jpeg_pairs` with the verified `plan_id` and the specific verified candidate IDs. Poll `get_job` for the saved pair IDs, `commit_state` and `operation_id`. On `stale_plan`, read the current relationships and generate a fresh proposal before retrying.

Use `list_photo_versions` with a partner's physical source ID to choose a version for opening, comparison or stacking. Use `unlink_raw_jpeg_pair` with the saved `pair_id` to remove the relationship and retain both originals and their edit versions.

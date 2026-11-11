# Library and import workflows

Use the registered tool schemas. Supply the current `catalog_session_id` where accepted, including for file access and catalog changes when a catalog is open. Include the current `request_epoch` and a new `request_id` where required. Keep an accepted `job_id` and poll `get_job` until it reaches a terminal state. Read each page of items needed to verify the result.

## File access and catalogs

- Call `request_file_access` with the purpose for the next operation. Tell the user which file or folder to choose in Phosdeck. Follow `user_action` if a second panel asks for the containing folder. Use the returned `access_id` only for its stated purpose and catalog session.
- For a known recent catalog, use the ID from `list_recent_catalogs`. Otherwise request `open_catalog` access, then call `open_catalog`. For a new catalog, request `create_catalog` access and pass a name to `create_catalog`. Wait for the user to handle any legacy extension choice in Phosdeck, then refresh the workspace.
- Use `list_library_sources` for root, folder and collection IDs. Relocate a root with `relocate_root` access and check the unverified items. For an individual original, pass `locate_original` access, the exact photo version ID and its saved source revision to `locate_photo_original`.

## Import and folder review

- Request `import_source` access and, for copy mode, `import_destination` access. Call `plan_photo_import`. Read its eligible candidates and blocked entries before starting. Copy mode accepts the native date layouts, an optional archive date and matching sidecars. To refine individual candidate selection or assign attachments to copy groups, replan with the base plan's IDs and the desired options.
- Start with the selected reference candidate IDs or copy group IDs. Use `select_all` only when the user wants all eligible items. At a filename conflict, use `resolve_import_conflict` with the current `job_id`, `conflict_id`, one of the allowed policies and an explicit `apply_to_remaining` value. Apply overwrite or a batch-wide policy only when it matches the user's intent. The user can also choose in Phosdeck.
- Check the terminal state and item outcomes. A copy file's publication and its `photo_id` report separate stages. A cancelled job can have published files or saved photos. Use `show_recent_import` to open, cull or leave the imported batch.
- For folder changes, use `plan_folder_review`, inspect the differences, then pass the explicitly selected difference IDs to `apply_folder_review`. For ambiguous moves map the difference to a listed location ID. On `stale_plan`, refresh the review and check the new differences before applying. `scan_library_folder` indexes directly when the user asks for a rescan.

## Cancellation and recovery

Call `cancel_job` by ID and check `get_job` for the final outcome. An HTTP reconnect retains the job. For a saved copy import after an App or service restart, open its catalog, find its `record_id` with `list_import_records` and query it with `get_job`. Use `resume_photo_import` when the record can resume. Request `restore_import_backup` access to recover a previous file into a folder under a new name. `clean_import_backup` requires confirmation in Phosdeck.

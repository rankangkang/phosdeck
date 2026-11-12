# Settings and maintenance

## Preferences and panels

- Read `get_preferences` and patch only the requested fields with `set_preferences`. Use the registered enum values and point ranges. Use `develop_groups` for individual Develop panels. In solo mode, expand one adjustment group at a time. The local service switch, preview sharing and connection credentials are in **Settings → Agent**.
- Call `show_app_panel` and poll `get_job` for `open_panel`. For shortcuts use `panel: settings` and `pane: shortcuts`. The workspace also reports the visible panel. When a sheet blocks another write, ask the user to dismiss it in Phosdeck and reread the workspace.
- Use `list_language_packs` to distinguish the selected pack from the running language. Import a validated resource bundle with `edit_language_pack(action=import)` and a `language_pack` access ID. Phosdeck selects it for the next launch. Use `select_language(action=community)` with an installed ID or `action=official` to follow macOS. Remove only the requested pack ID. Report `restart_required` and let the user reopen Phosdeck. Refresh connection credentials afterward.

## Storage and catalog files

- Read `get_storage_usage` for measured bytes and inaccessible entries. `set_cache_quota` accepts 1, 5 or 10 GiB. Clear the current catalog's rebuildable thumbnails with `clear_thumbnail_cache`. Use `removed_bytes` from the job. Browsing can regenerate thumbnails after the clear.
- Use `request_file_access` with `catalog_backup_destination` for `back_up_catalog` or `catalog_manifest_destination` for `export_catalog_manifest`. Supply a new filename or use the generated name. Verify publication and readback in the job. A database backup carries edits and records. Photos and rendered outputs live separately. The JSON manifest omits access bookmarks and includes source paths and catalog metadata.
- To restore, request `catalog_backup_source` for the backup and `create_catalog` for the new working folder. Call `restore_catalog_backup` with both access IDs and a new catalog name. Check `published`, `verified` and `opened`. If the file was published and opening failed, check the preserved file before making another copy. After opening, get the new catalog session and resolve targets again.

## RAW compatibility

- Request `camera_samples` for the intended RAW sample folder and call `run_camera_diagnostics`. Inspect individual verdicts and skipped checks. The first 32 supported files in that folder can be checked. A completed job reports evidence for these samples on this Mac.
- Use `get_camera_diagnostic_preview` with the returned `report_id` and `sample_index`. For an embedded image choose `preview_kind: embedded` when available. Image sharing is required to receive pixels. For the native review sheet use `show_app_panel(panel=camera_diagnostics)`.
- To save the current report, request `camera_report_destination` and call `save_camera_diagnostics_report`. After cancellation, check the job for the partial report ID and the number of completed samples. The JSON excludes source filenames, paths and pixels.

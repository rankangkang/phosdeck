---
name: phosdeck
description: Use Phosdeck's local MCP server to inspect its open photo catalog, browse the current query, view saved previews, and set or undo photo ratings. Use when the user asks to work with photos in Phosdeck.
---

# Phosdeck

Call `get_capabilities` and `get_workspace` before operating on a catalog. Check the App identity when both Phosdeck and Phosdeck Preview are connected. If the server is missing, have the user open **Settings → Agent**, enable **Local MCP Server**, and give the client the copied configuration and the token through the configured environment variable. Use the new address and token after a restart.

- For browsing, pass the current `catalog_session_id` to `list_photos`. Reuse `next_cursor` with the same page size until it is null. `matched_count` includes folded stack members and `visible_count` describes the rows you can page through. On `stale_cursor` or a catalog change, refresh the workspace and start the query again.
- For visual review, use `get_photo_preview` with the exact `photo_id`, `source_revision` and `recipe_revision` from the list or active photo. Review the returned PNG as the saved edit. If preview sharing is off, the user can enable **Share Photo Previews** in Settings. Refresh the target and revisions if the preview is stale.
- To rate a photo, use its version ID, the observed `expected_rating`, the intended `rating` from 0 through 5, the current `request_epoch`, and a new `request_id`. A filename can refer to multiple versions. Resolve the specific version before writing. Read back the rating after the write.
- Use `undo_operation` with the returned `operation_id`, the current catalog session and request epoch, and a new request ID. If the undo is no longer available, report the current state and use it to decide the next action with the user.

Check `structuredContent` for `status`, `data.commit_state` and `error.code`. The JSON text block carries the same result. If a connection drops before a write result arrives, reuse the same request ID and arguments within the same epoch. If the epoch expired, the saved state is uncertain, or a write returns a warning, read back the actual state before making another edit. Resolve rating conflicts against the observed current rating and the user's intent. When a native edit or task blocks a write, wait for it to finish and refresh the workspace.

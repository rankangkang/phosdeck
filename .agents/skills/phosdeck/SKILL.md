---
name: phosdeck
description: Work in Phosdeck through its local MCP server. Manage catalogs, import and locate originals, recover copy imports, cull and compare photos, and edit ratings, flags, color labels, keywords, and captions.
---

# Phosdeck

Call `get_capabilities` and `get_workspace` before operating on a catalog. Check the App identity when both Phosdeck and Phosdeck Preview are connected. If the server is missing, have the user open **Settings → Agent**, enable **Local MCP Server**, and give the client the copied configuration and the token through the configured environment variable. Use the new address and token after a restart.

- For catalog changes, file access, import, folder review or recovery, read [Library and import workflows](references/library-and-import.md).
- For filtering, selecting, comparing, marking or editing metadata, read [Culling and photo metadata](references/culling-and-metadata.md).
- For visual review, use `get_photo_preview` with the exact `photo_id`, `source_revision` and `recipe_revision` from the list or active photo. Review the returned PNG as the saved edit. If preview sharing is off, the user can enable **Share Photo Previews** in Settings. Refresh the target and revisions if the preview is stale.
- Use the returned `operation_id` with `undo_operation` if the user wants to undo the current action. Use `redo_operation` with the same operation ID after an MCP undo. Each uses the current catalog session and request epoch and a new request ID. If the action is no longer at the top of the native stack, reread the affected items before deciding how to proceed.

Check `structuredContent` for `status`, `data.commit_state` and `error.code`. The JSON text block carries the same result. If a connection drops before a write result arrives, reuse the same request ID and arguments within the same epoch. If the epoch expired, the saved state is uncertain, or a write returns a warning, read back the affected state before submitting another write. When a native edit or task blocks a write, refresh the workspace after it finishes.

---
name: phosdeck
description: Work in Phosdeck through its local MCP server. Import, cull, organize, edit, merge and export photos. Manage settings, language packs and thumbnail storage, back up or restore catalogs, and run local RAW diagnostics.
license: AGPL-3.0-only
---

# Phosdeck

Discover the connected tools and use their current schemas. Call `get_capabilities` and `get_workspace` before operating on a catalog. Check the app and catalog identity when both Phosdeck and Phosdeck Preview are connected.

If the server is off, have the user enable **Local MCP Server** in **Settings → Agent**. For a client that accepts `mcpServers` JSON, use **Copy JSON Configuration** for the Streamable HTTP address and bearer header. For Codex, use **Copy Codex Configuration** and supply the copied token through the named environment variable. Copy fresh connection details after a server restart.

- For catalog changes, file access, import, folder review or recovery, read [Library and import workflows](references/library-and-import.md).
- For filtering, selecting, comparing, marking or editing metadata, read [Culling and photo metadata](references/culling-and-metadata.md).
- For collections, virtual copies, display stacks or RAW/JPEG pairs, read [Photo organization](references/organization.md).
- For development, exposure, color and preset strength trials, before/after, adjustment transfer or saved edits, read [Development and edit records](references/development.md).
- For crop, perspective, pixel sampling, spot repair or local and smart masks, read [Canvas and local editing](references/canvas.md). Use a photo draft to try local edits on a 1:1 preview before saving.
- For merging originals, saving float TIFF or DNG masters, export presets, multi-size delivery and output recovery, read [Photo merge and export](references/output.md).
- For preferences, language packs, cache, catalog backup and restore, or RAW compatibility checks, read [Settings and maintenance](references/maintenance.md).
- For visual review, use `list_photos` with an independent `query` and `contact_sheet=true` to compare a page of saved versions while the user keeps their current view. Choose a numbered row, then pass its `photo_id`, `source_revision` and `recipe_revision` to `get_photo_preview` for a 1:1 region. If preview sharing is off, the user can enable **Share Photo Previews** in Settings. Refresh the list and revisions if a preview is stale.
- Use the returned `operation_id` with `undo_operation` if the user wants to undo the current action. Use `redo_operation` with the same operation ID after an MCP undo. Each uses the current catalog session and request epoch and a new request ID. If the action is no longer at the top of the native stack, reread the affected items before deciding how to proceed.

Check `structuredContent` for `status`, `data.commit_state` and `error.code`. The JSON text block carries the same result. Follow a returned `job_id` with `get_job` until it reaches a terminal state. If it asks for a choice in Phosdeck, tell the user what to select and then resume the same job. Read back the saved versions, output records, or files before reporting completion.

If a connection drops before a write result arrives, reuse the same request ID and arguments within the same epoch. If the epoch expired, the saved state is uncertain, or a write returns a warning, read back the affected state before submitting another write. When a native edit or task blocks a write, refresh the workspace after it finishes.

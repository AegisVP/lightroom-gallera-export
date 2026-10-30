# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Adobe Lightroom Classic plugin that exports finished photos to app.gallera.io. The user can upload to a new or an existing Gallera album and set that album's other settings from the export dialog.

## Lightroom SDK constraints

- The plugin is developed and run in **Lightroom Classic on Windows**. Build paths with `LrPathUtils` and avoid shell commands.
- The design is in @docs/superpowers/specs/2026-10-30-gallera-publish-plugin-design.md. Core modules (`GalleraApi`, `GallerySettings`, `GalleryLookup`, `FavoritesSync`, `PhotoOrder`) must not import Lightroom namespaces, so they stay unit-testable with plain Lua 5.1.
- The plugin runs on Lightroom's embedded **Lua 5.1**. There is no LuaRocks, no C modules, no `goto` and no integer division (`//`). Use `import 'LrHttp'` (etc.) for SDK namespaces and `require` only for `.lua` files inside the plugin folder.
- The plugin is a **Publish service**: registered under `LrExportServiceProvider` in `Info.lua` with `supportsIncrementalPublish = 'only'`. Each published collection maps to one Gallera gallery. Record the Gallera photo id on each rendition so deletes and re-publishes can find it.
- All network calls (`LrHttp.get`/`post`/`postMultipart`) must run inside `LrTasks.startAsyncTask` or an export task. Calling them on the UI thread fails or blocks Lightroom.
- `exportPresetFields` are saved in plain text in export presets. Store tokens and passwords with `LrPasswords`, never in preset fields.
- There is no test runner. To check a change, reload the plugin in Lightroom (File > Plug-in Manager > Reload) and run an export. Log with `LrLogger` (`logger:enable("logfile")`).

## Gallera API

Gallera has no public API. Everything known comes from browser traffic captures, documented in @docs/gallera-api.md.

- Don't invent endpoints or fields that aren't in that doc. If something is missing, ask for a new HAR capture.
- Store the numeric gallery `id` for each published collection, never the `slug`. Users can change the slug in Gallera, so look it up again before slug-based calls.
- `DELETE galleries/{slug}/delete` moves a gallery to the trash the first time and **permanently deletes** it the second time. Never retry it automatically, and check the gallery's state before calling it.
- Replacing a photo isn't possible. Re-publishing an edited photo means delete + upload, which creates a new photo id.
- HAR captures contain the account password and tokens. Never commit them (`*.har` is gitignored), and never log the full gallery object (it holds the gallery password).

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Adobe Lightroom Classic **publish service** plugin for app.gallera.io. Each Lightroom published collection (the user's "album") is linked to one Gallera **gallery**, which is either new or already exists. Publishing the collection uploads its finished photos to that gallery, and the collection settings dialog edits the gallery's settings.

Terms: in Lightroom it's a *published collection*; on Gallera it's a *gallery*. Use those words in code and docs.

## Lightroom SDK constraints

- The plugin is developed and run in **Lightroom Classic on Windows**. Build paths with `LrPathUtils` and avoid shell commands.
- The design is in @docs/DESIGN.md. Core modules (`GalleraApi`, `GallerySettings`, `GalleryLookup`, `FavoritesSync`, `PhotoOrder`, `Fingerprint`, `Redact`, `Names`, `Uploader`, `PublishPlan`) must not import Lightroom namespaces, so they stay unit-testable with plain Lua 5.1.
- The plugin runs on Lightroom's embedded **Lua 5.1**. There is no LuaRocks, no C modules, no `goto` and no integer division (`//`). Use `import 'LrHttp'` (etc.) for SDK namespaces and `require` only for `.lua` files inside the plugin folder.
- The plugin is a **Publish service**: registered under `LrExportServiceProvider` in `Info.lua` with `supportsIncrementalPublish = 'only'`. Each published collection maps to one Gallera gallery. Record the Gallera photo id on each rendition so deletes and re-publishes can find it.
- All network calls (`LrHttp.get`/`post`/`postMultipart`) must run inside `LrTasks.startAsyncTask` or an export task. Calling them on the UI thread fails or blocks Lightroom.
- `exportPresetFields` are saved in plain text in export presets. Store tokens and passwords with `LrPasswords`, never in preset fields. `LrPasswords.store(key, nil)` throws; clear a token by storing `''` and treat `''` as "no token".
- Inside tasks, use `LrTasks.pcall`, never plain `pcall`, around anything that touches the SDK. Photo reads (`getRawMetadata`, `getFormattedMetadata`, `getPropertyForPlugin`) and HTTP calls yield, and plain `pcall` fails with "Yielding is not allowed within a C or metamethod call".
- Catalog writes (`setRemoteId`, `setRemoteUrl`, `setName`, `setRawMetadata`, `setPropertyForPlugin`) must be inside `catalog:withWriteAccessDo`, even in `updateCollectionSettings`.
- To check a Lightroom-layer change, reload the plugin in Lightroom (File > Plug-in Manager > Reload) and publish. Log with `LrLogger` (`logger:enable("logfile")`). The log is written to `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\<logger name>.log` (not Documents). On this machine Documents is `Z:\Users\kg\Documents` and Pictures is `L:\`, so never hard-code those folders; use `LrPathUtils.getStandardFilePath`.

## Unit tests

Core modules are tested with **luaunit** (`spec/luaunit.lua`, vendored) on a portable Lua 5.1. Nothing is installed system-wide.

- Run all tests from the repo root: `tools\lua51\lua5.1.exe spec\run.lua` (Git Bash: `tools/lua51/lua5.1.exe spec/run.lua`). A non-zero exit code means a test failed.
- Test files are `spec/*_test.lua`. Each defines global `Test...` tables, and `spec/run.lua` picks them up. `package.path` covers `spec/` and `gallera.lrdevplugin/`.
- `tools/` is gitignored. To recreate it, download LuaBinaries `lua-5.1.5_Win64_bin.zip` (sourceforge.net/projects/luabinaries, 5.1.5 > Tools Executables) and unzip it into `tools\lua51\`.
- Fixtures in `spec/fixtures/` come from HAR captures and must be sanitized: no tokens, passwords, emails or signed URLs.

## Gallera API

Gallera has no public API. Everything known comes from browser traffic captures, documented in @docs/gallera-api.md.

- Don't invent endpoints or fields that aren't in that doc. If something is missing, ask for a new HAR capture.
- Store the numeric gallery `id` for each published collection, never the `slug`. Users can change the slug in Gallera, so look it up again before slug-based calls.
- `DELETE galleries/{slug}/delete` moves a gallery to the trash the first time and **permanently deletes** it the second time. Never retry it automatically, and check the gallery's state before calling it.
- Replacing a photo isn't possible. Re-publishing an edited photo means delete + upload, which creates a new photo id.
- HAR captures contain the account password and tokens. Never commit them (`*.har` is gitignored), and never log the full gallery object (it holds the gallery password).

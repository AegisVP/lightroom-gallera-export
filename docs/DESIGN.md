# Gallera Publish Service for Lightroom Classic: Design

- **Date:** 2026-10-30
- **Status:** Approved in brainstorming. Next step: write an implementation plan from this spec (superpowers `writing-plans`).
- **Companion docs:** `docs/gallera-api.md` (reverse-engineered API, the source of truth for endpoints), `CLAUDE.md`.

## 1. Purpose and success criteria

A personal-use Lightroom Classic plugin that publishes finished photos as JPEGs to app.gallera.io galleries and keeps each gallery in sync with a Lightroom published collection.

**The design succeeds when** the owner (a single Lightroom user with a single Gallera account) can do all of the following from Lightroom, without opening the Gallera website for routine work:
- Create a gallery, or link an existing one
- Publish photos
- Edit photos and re-publish them
- Remove photos
- Edit the gallery's Settings tab
- Apply clients' favorites selections as color labels, choosing a color for each list

**Environment**
- Runs in Lightroom Classic **on Windows**. Development and testing also happen on Windows.
- Personal use only: no public release, no auto-update checks, no localization.

## 2. Scope

### In the PoC
- A publish service: one published collection maps to one Gallera gallery.
- Create a new gallery (Gallera defaults) or link an existing one.
- Publish, re-publish (delete + upload), remove photos, rename the collection → rename the gallery, delete the collection (asks what to do with the gallery).
- The gallery **Settings** tab (5 sections), edited from the collection settings dialog. **Gallera is the source of truth.**
- JPEG rendering from the service's export settings, with a per-collection override of long edge size and JPEG quality.
- Photo order by capture date (per-collection checkbox, on by default).
- Client favorites → color labels. The user reviews the lists and picks a color for each one; nothing is applied automatically. Labels are mirrored without overwriting the user's own labels.
- Deleted-gallery detection (during operations and at Lightroom startup), with a rename + flag marker.
- Login with email/password once. Only the token is stored.

### Not in the PoC (possible future work)
| Item | Note |
|---|---|
| **Scenes** (Gallera folders) | **Design for it now** (see §11). The planned mapping is published collection set = gallery, collection = scene. |
| **Design tab** (cover/title photo, fonts, colors, layout, gradient) | Possibly a future version. The plugin must round-trip `design`/`cover` unchanged. |
| Matching existing gallery photos to Lightroom photos when linking | Photos already in a linked gallery are left alone. Lightroom only manages photos it uploaded. |
| Videos, non-JPEG formats | |
| Following Lightroom's custom sort order | Capture-date order only. |
| Accounts that sign in only through Google (no password) | Unsupported. |

## 3. Constraints and facts the design depends on

All are documented in `docs/gallera-api.md` unless noted.

1. **Gallera has no public API.** The plugin uses the private web API (Laravel backend, Bearer token). It can change without notice, so every HTTP call lives in one module (`GalleraApi`).
2. **Photos can't be replaced.** Re-publishing means uploading the new photo and deleting the old one. The photo id changes, and client favorites on the old photo are lost.
3. **`DELETE galleries/{slug}/delete` is dangerous.** On an active gallery it moves the gallery to the trash. On a gallery already in the trash it **permanently deletes** it. Gallera removes trashed galleries automatically after 7 days. Restoring a trashed gallery also brings back photos deleted from it (observed).
4. **Gallery slugs can change.** The user can edit a gallery's address on the website. Store the numeric gallery **id**, and look up the slug when it's needed.
5. **Uploads take 3 steps:** request a signed R2 URL (expires in 20 min) → PUT the bytes (no `Authorization` header) → confirm. The photo id is known from step 1.
6. **Ordering:** `POST photos/sort` takes the **complete** id list and `type: "manual"`. There's no "capture date" sort option in Gallera.
7. **Favorites:** a gallery can have several lists (one per client selection), each with `is_finished`. `latest[]` holds the photo objects. Whether `latest` is always complete is **unverified**.
8. **Lightroom SDK:**
   - Lua 5.1 with no JSON library.
   - Network calls must run inside tasks.
   - Lightroom has no "disabled" state for published collections.
   - Color labels are stored as text and depend on the active label set.

## 4. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | Publish service only (`supportsIncrementalPublish = 'only'`), not an Export dialog entry | The user wants ongoing sync with galleries |
| D2 | One collection = one gallery. No collection sets in the PoC; the model leaves room for scenes | Keeps the PoC simple; the next iteration adds scenes |
| D3 | Gallera is the source of truth for gallery settings. They're loaded fresh when the dialog opens and saved on OK as a merge of only the changed fields. Publishing never pushes settings | No conflicts with changes made on the website |
| D4 | Settings tab only (General, Scenes, Favorites, Saving, Access). The Design tab is excluded but round-tripped untouched | Design needs a visual preview; possible future version |
| D5 | New galleries are created empty with Gallera's defaults (no template copy) | User choice |
| D6 | Re-publish = upload new, **then** delete old | A failure never leaves a gap in the gallery |
| D7 | Removing photos from the collection deletes them from the gallery on publish | Standard publish behavior |
| D8 | Deleting a collection asks: **Move gallery to trash** / **Keep gallery** (unlink). The plugin never sends a second delete | User choice; protects against D-constraint 3 |
| D9 | Renaming the collection renames the gallery. A gallery renamed on the website does not rename the collection | Agreed default: the collection name stays under the user's control, and the settings dialog shows Gallera's current name. Name sync from Gallera could be added later if spike S3 shows `setName` works |
| D10 | A deleted gallery is detected during any Gallera operation and once at Lightroom startup. The collection is renamed `<original name> - (deleted)` and flagged. The plugin never acts on its own | No "disabled" state exists in Lightroom; renaming is the only visible marker |
| D11 | Deleted-gallery dialog: "This gallery was deleted[, but it is still available in Gallera trash]." Buttons: **[Restore]** (only if trashed) **[Create new]** **[Cancel]** | User choice |
| D12 | Photo order: after each publish, sort Lightroom-published photos by capture time and send the full order. A per-collection checkbox **Order by capture date** (default on) | Gallera has no capture-date sort |
| D13 | Favorites are **never applied automatically**. A **Client favorites** dialog lists every favorites list (title, Finished / In progress, photo count). The user picks a color for each list: Skip / Red / Yellow / Green / Blue / Purple. The last choice for each list is remembered and pre-filled next time; new lists default to Skip | User choice: the photographer decides what each selection means |
| D14 | Label mirroring, for each list given a color: add that color to the photos in the list. Remove it when a photo leaves the list, **only if** the plugin applied it from that list and the photo's label is still that color. Never overwrite a label the plugin didn't apply (report it as skipped). Which list and color the plugin applied is tracked in a hidden plugin metadata field | The plugin only touches labels it can prove it set |
| D15 | A list set to Skip is left entirely alone: its photos get no labels, and labels applied from it earlier are kept. Finished and unfinished lists are treated the same; the dialog only shows their status. A photo in two lists with **different** colors is left unchanged and reported as a conflict | Skipping never strips labels; the plugin never guesses |
| D16 | Favorites are matched by **recorded Gallera photo id**. Filenames are never changed; `lightroom_list` filename matching is a fallback only | Ids are exact; filenames are kept for human readability and the fallback |
| D17 | The Client favorites dialog opens from **Library > Plug-in Extras > Gallera client favorites…**. After a publish, if any list is new or has changed since the last review (by `items_count` / `is_finished`), the plugin asks "Client favorites changed (list 'vv'). Review now?" Yes opens the dialog | The dialog is offered when it's relevant, but nothing is applied without it |
| D22 | **Originals are never modified or deleted.** The only things the plugin changes in the catalog: color labels (D14), its own hidden metadata field, Lightroom's publish records, and the published collection's name, remote id and settings. What happens to rendered JPEGs is a service setting (D24) | User requirement |
| D24 | JPEGs are **kept by default**. Every rendered JPEG goes to `<folder>\<collection name>\`, where the folder defaults to `Pictures\Gallera` (`LrPathUtils.getStandardFilePath('pictures')`). A re-rendered photo overwrites its earlier JPEG. Service setting **Uploaded JPEGs**: **Keep, ask to remove after publish** (default) / **Always keep** / **Always remove after upload**. Only successfully uploaded JPEGs are ever removed; failed ones are always kept | User choice: the files are kept unless the user says otherwise |
| D25 | Failed uploads: each photo gets **up to 3 attempts** within a publish (on `network` errors, and on a PUT to an expired or rejected signed URL), waiting 2 s then 5 s, with a fresh signed URL each time. After that, the photo is reported failed (`rendition:uploadFailed`) and stays in Lightroom's publish queue. **Publish again** retries it; Lightroom re-renders from the original | Lightroom's standard retry is a manual re-publish; automatic attempts cover brief network problems |
| D23 | Storage: before uploading, compare the estimated publish size with free Gallera storage. If it may not fit, warn with **Continue anyway** / **Cancel**. During upload, stop when the next file truly doesn't fit | User choice |
| D18 | Rendering: JPEG only. The service holds the full Lightroom export settings. Each collection can override **long edge** and **JPEG quality** | User choice; feasibility must be proven first (spike S1) |
| D19 | Auth: email/password entered once, sent to `auth/login`, and **only the token is stored** (`LrPasswords`). Log out revokes the token. No automatic re-login (the password isn't stored) | The user doesn't want passwords saved; browser login isn't possible (no OAuth) |
| D20 | One Gallera account per publish service | User choice |
| D21 | Layered architecture: a Lightroom-free core (unit-tested) plus a thin Lightroom layer | Must grow over time (scenes, design) |

## 5. Architecture

### 5.1 File layout

```text
gallera.lrdevplugin/
  Info.lua                       -- plugin manifest
  Init.lua                       -- LrInitPlugin: starts the startup deleted-gallery check
  -- core (no Lr* imports; loadable by plain Lua 5.1 for tests)
  lib/json.lua                   -- bundled pure-Lua JSON (e.g. rxi/json.lua, MIT)
  GalleraApi.lua
  GallerySettings.lua
  GalleryLookup.lua
  FavoritesSync.lua
  PhotoOrder.lua
  -- Lightroom layer
  LrHttpAdapter.lua
  Auth.lua
  GalleraMetadata.lua            -- LrMetadataProvider: hidden plugin field(s)
  PublishServiceProvider.lua
  ServiceSettingsDialog.lua
  CollectionSettingsDialog.lua
  DeletedGallery.lua             -- rename/flag/unflag + the D11 dialog, shared by all entry points
  FavoritesDialog.lua            -- Client favorites dialog (per-list color choice)
  FavoritesCommand.lua           -- Library menu item that opens FavoritesDialog
  Log.lua                        -- LrLogger wrapper with redaction
spec/                            -- busted tests for core modules
  fixtures/                      -- sanitized JSON responses from HAR captures
docs/
  gallera-api.md
  manual-tests.md                -- Lightroom checklist (written during implementation)
```

**Core-module rule:** core modules must not `import` anything from Lightroom. Anything they need from Lightroom (HTTP, time, logging) is passed in. This keeps them testable outside Lightroom and reusable for scenes.

### 5.2 Core module interfaces

The return convention for anything that can fail is `result, err`, where `err = { kind = "auth"|"notFound"|"network"|"api", status = <http status|nil>, message = <string> }`.

**`GalleraApi`**: every endpoint in `docs/gallera-api.md`. It knows nothing about Lightroom.
```lua
local api = GalleraApi.new{ http = adapter, token = tokenOrNil }   -- base URL is internal
api:login(email, password)            --> token, user
api:logout()
api:getUser()                         --> user (incl. storage.used / storage.limit)
api:listGalleries()                   --> all active galleries (follows v2 pagination)
api:listGalleryNames()                --> {id, name}[] (galleries/list; for the link picker)
api:listTrashedGalleries()            --> galleries/my/deleted
api:createGallery{ name, date }       --> slug
api:getGallery(slug)                  --> full gallery object
api:saveGallery(slug, galleryObject)  --> new slug
api:trashGallery(galleryId)           --> ok   -- see safety rule below
api:restoreGallery(slug)
api:listPhotos(slug)                  --> photo objects, in gallery order
api:requestUpload{ galleryId, filename, filesize, filetype } --> { url, photoId }
api:putFile(url, bytes, contentType)
api:confirmUpload(photoId)
api:deletePhotos(slug, photoIds)
api:sortPhotos(slug, photoIds, folderId)  -- folderId nil for the PoC
api:getFavorites(slug)                --> lists
```
- **Safety rule:** there is **no** function that permanently deletes a gallery. `trashGallery` takes the **id**, looks the gallery up and refuses (`err.kind = "api"`) unless it's active. Only then does it send `DELETE …/delete`. It never retries.
- **Response handling:** it unwraps the `{status, message, data}` envelope. HTTP 401 → `auth`. HTTP 404 or `status = "notFound"` → `notFound`. A transport failure → `network`. Anything else with `status ~= "success"` → `api`, with Gallera's message.
- **Retries:** GET requests retry once on `network`. Nothing else is retried here; upload retries are the caller's decision.

**HTTP adapter contract** (implemented by `LrHttpAdapter`, faked in tests):
```lua
adapter.request{ method, url, headers, body, multipart } --> { status, body } | nil, networkErrorMessage
-- multipart: array of { name, value } parts (used by requestUpload)
```

**`GallerySettings`**: knows the Settings tab.
- `GallerySettings.FIELDS`: an ordered table of `{ section, key, label, apiField, type }` covering §7.2.
- `toProps(galleryObject)` → a flat table of dialog values.
- `diff(baselineProps, editedProps)` → only the changed keys.
- `apply(freshGalleryObject, changedProps)` → a new gallery object. Every other field (including `design`, `cover` and unknown fields) is copied unchanged.

**`GalleryLookup`**
```lua
GalleryLookup.find(api, galleryId) --> { state = "active"|"trashed"|"gone", slug, summary } | nil, err
```
It searches the active list first, then the trash. `gone` means the gallery is in neither. Callers cache the result for the length of one operation.

**`FavoritesSync`** is pure logic and does no I/O.
```lua
FavoritesSync.summarize(lists, photos) --> { { id, title, finished, count, matched }, ... }  -- rows for the dialog

FavoritesSync.plan{
  lists   = <getFavorites result>,
  choices = { [listId] = "red"|"yellow"|"green"|"blue"|"purple" },   -- lists absent = Skip
  photos  = { [remotePhotoId] = { key = <local photo key>, label = <current color|nil>,
                                  applied = <{ listId, color }|nil> } },
} --> {
  set      = { { key, color, listId } },  -- add, or change a label the plugin applied earlier
  remove   = { keys },
  skippedOtherLabel = { keys },           -- has a label the plugin didn't apply
  conflicts = { keys },                   -- in two chosen lists with different colors
  incompleteLists = { ids },              -- #latest < items_count; caller falls back / warns
}
```
- **Target:** a photo's target is the color of each chosen list whose `latest` contains its remote id. Two different target colors → `conflicts`, and the photo is left unchanged.
- **Set:** the photo has a target color `c`.
  - Current label `nil` → set `c`.
  - Current label equals `applied.color` (the plugin's own label) and differs from `c` → change it to `c`.
  - Current label `c` → only record `applied` (no visible change).
  - Any other label → `skippedOtherLabel`.
- **Remove:** the photo has no target, `applied.listId` is a **chosen** list this run, and its current label still equals `applied.color` → remove the label and clear `applied`.
- **Untouched:** photos whose `applied.listId` is skipped this run, or whose list no longer exists (D15).

**`PhotoOrder`**
```lua
PhotoOrder.compute{
  galleryPhotoIds = { ids in current gallery order },
  captureTimes    = { [remotePhotoId] = <number|nil> },  -- only Lightroom-published photos have entries
} --> sorted id list (complete)
```
- Lightroom photos with a capture time come first, by capture time. Ties are broken by remote id, i.e. upload order.
- Then Lightroom photos without a capture time, in their current gallery order.
- Then photos the plugin didn't upload, in their current gallery order.

### 5.3 Lightroom layer responsibilities

| Module | Responsibility |
|---|---|
| `Info.lua` | Registers the publish service provider, `LrInitPlugin = Init.lua`, `LrMetadataProvider = GalleraMetadata.lua`, and the Library menu item `LrLibraryMenuItems` → "Gallera client favorites…". Personal toolkit id, e.g. `com.pysarenko.gallera`. `LrSdkVersion` matches the installed Lightroom Classic. |
| `LrHttpAdapter` | Implements the adapter with `LrHttp.get`, `LrHttp.post(url, body, headers, method)` (incl. `PUT`) and `LrHttp.postMultipart`. Reads the status from the response headers. |
| `Auth` | `login(email, password)` → stores the token with `LrPasswords.store("gallera.token:" .. email, token)`. `logout()`, `token(email)`. The password is never stored or logged. |
| `GalleraMetadata` | A hidden custom field on each photo, `galleraLabelApplied` = `"<listId>:<color>"` (which list and color the plugin applied), used by D14. |
| `PublishServiceProvider` | The publish callbacks (§6). |
| `ServiceSettingsDialog` | `sectionsForTopOfDialog`: the account section (§7.1). |
| `CollectionSettingsDialog` | `viewForCollectionSettings` / `updateCollectionSettings` (§7.2). |
| `DeletedGallery` | `mark(collection, state)`, `unmark(collection)`, `prompt(state)` → `"restore"`, `"createNew"` or `"cancel"`. |
| `FavoritesDialog` | The Client favorites dialog (§7.3): one row per list with a color popup; Apply / Cancel. |
| `FavoritesCommand` | Opens `FavoritesDialog` for the selected published collection. |
| `Log` | `LrLogger("Gallera")` with the `logfile` output. Redaction rules in §8. |

## 6. Data model and flows

### 6.1 What Lightroom stores

| Where | What |
|---|---|
| Publish service settings | `email` (not secret), `username` (for display), `jpegHandling` (`"ask"` (default), `"keep"` or `"remove"`), `jpegFolder`, plus the standard export settings |
| `LrPasswords` | Token per email (`gallera.token:<email>`) |
| Published collection `remoteId` / `remoteUrl` | Gallera gallery **id** / gallery `public_url` |
| Collection settings (plugin-owned) | `favoritesColors` = `{ [listId] = color }` (last choices, to pre-fill the dialog), `favoritesSeen` = `{ [listId] = { count, finished } }` (to detect changed lists, D17), `orderByCapture` (default `true`), `overrideRender` (default `false`), `longEdge`, `jpegQuality`, `folderId` (always `nil` in the PoC), `deleted` = `nil` or `{ state, originalName }` (state is `"trashed"` or `"gone"`) |
| Published photo | `publishedPhotoId` = Gallera photo id. `publishedPhotoUrl` = gallery `public_url` (Gallera has no known per-photo page) |
| Photo custom metadata | `galleraLabelApplied` (`"<listId>:<color>"`) |
| Originals | **Never modified or deleted** (D22). Only the color label changes |

Gallera's own settings may also end up in collection settings, because the dialog binds them. **They are never read from there.** They're always loaded fresh (D3).

### 6.2 Creating or linking a collection (`updateCollectionSettings` on first OK)
1. **Create new:**
   - `createGallery{ name = collection name, date = today }`, then `getGallery(slug)` to get the id.
   - If the user edited any Settings fields in the dialog, `apply` + `saveGallery`.
2. **Link existing:** the picker (`listGalleryNames`) supplies the id. The dialog's Settings fields were already loaded from that gallery.
3. `setRemoteId(id)` and `setRemoteUrl(public_url)` on the published collection.

### 6.3 Opening and saving collection settings
1. Open the dialog with the Gallera sections disabled and the message "Loading from Gallera…".
2. Start a task: `GalleryLookup.find` (if not `active`, run the deleted-gallery flow in §6.9, then close or continue) → `getGallery(slug)` → `toProps` → fill the fields and keep a **baseline** copy.
3. On OK:
   - `diff(baseline, edited)`.
   - If anything changed: `getGallery(slug)` **again** (fresh) → `apply(fresh, changed)` → `saveGallery`.
   - Store the plugin-owned settings.
4. If Gallera can't be reached: the Gallera sections stay disabled, with a message. The plugin-owned settings are still editable and saved.

### 6.4 Publish (`processRenderedPhotos`)
1. **Token:** no token, or an `auth` error at any point → abort with "Log in again in the Gallera service settings".
2. **Gallery:** `GalleryLookup.find(remoteId)`.
   - **Active:** continue.
   - **Trashed or gone:** run the deleted-gallery flow (§6.9). On Cancel, abort the publish and mark the renditions as failed with "Gallery deleted".
3. **Storage pre-check** (D23): `getUser()` → `free = limit - used`.
   - **Estimate** = number of photos to upload × the average `filesize` of photos already in this gallery (`listPhotos`). For an empty gallery, use 8 MB per photo (a conservative full-resolution JPEG).
   - If estimate > free: "Gallera has X MB free. This publish is estimated at ~Y MB (N photos)." **[Continue anyway]** **[Cancel]**. Cancel aborts before anything is rendered or uploaded.
   - During upload, track `free`. If the next file is larger, stop uploading and mark the rest as failed: "Gallera storage full (used X of Y)".
4. **Render:** with the service settings, or with the collection override (D18; mechanism decided by spike S1).
5. **Per rendition** (photo):
   1. `requestUpload` (filename = the rendered file's name) → `putFile` → `confirmUpload`. The URL is requested immediately before the PUT.
   2. If any step fails (D25):
      - Clean up the half-created Gallera photo, if there is one (`deletePhotos(slug, {photoId})`, best effort).
      - Retry the whole sequence with a new signed URL, up to 3 attempts in total, waiting 2 s then 5 s. Only `network` errors and a failed PUT are retried. `auth` aborts the publish; other `api` errors fail the photo immediately.
      - After the last attempt, call `rendition:uploadFailed(message)` and continue with the next photo. The photo stays in Lightroom's publish queue for a manual retry.
   3. On success: `rendition:recordPublishedPhotoId(photoId)` and `recordPublishedPhotoUrl(public_url)`.
   4. If the photo was already published (re-publish), remember its **old** remote id.
   5. **The rendered JPEG** (D24): move it from Lightroom's temp folder to `<folder>\<collection name>\`, overwriting a file with the same name. The collection name is made safe for Windows: `<>:"/\|?*` are replaced with `_`. This happens whether the upload succeeded or failed. If the setting is **Always remove after upload** and the upload succeeded, delete it instead (`LrFileUtils.delete`).
6. **Delete old versions:** `deletePhotos(slug, oldIds)` for re-published photos whose new upload succeeded (D6).
7. **Order** (if `orderByCapture`): `listPhotos(slug)`, build `captureTimes` from Lightroom's `dateTimeOriginal` for this collection's published photos, `PhotoOrder.compute`, `sortPhotos(slug, ids, nil)`.
8. **Favorites check** (D17): `getFavorites(slug)`. If any list is new, or its `items_count` / `is_finished` differs from `favoritesSeen`, ask "Client favorites changed (list '<title>'…). Review now?" Yes → §6.8. Nothing is applied without the dialog.
9. **Summary dialog** (only if there were failures or skipped labels): uploaded / failed / labels added, removed and skipped. If photos failed: "N photos failed to upload. They're still queued; click Publish to retry."
10. **Keep, ask to remove** (the default setting): if at least one photo uploaded, ask "Remove the N uploaded JPEGs from `<folder>\<collection name>`?" **[Keep]** (default button) **[Remove]**. Remove deletes **only the JPEGs uploaded successfully in this publish**; failed ones stay. If the publish is cancelled or aborted midway, the JPEGs rendered so far have already been moved out of the temp folder (step 5.5), and the question covers the ones uploaded before the stop.

### 6.5 Removing photos (`deletePhotosFromPublishedCollection`)
This runs after the user removes photos from the published collection and clicks Publish. It deletes the **Gallera copies** only. `deletedCallback` just tells Lightroom the remote copy is gone, so Lightroom drops its publish record. The originals stay in the catalog and on disk, untouched (D22).
1. Look up the gallery.
2. **Active:** `deletePhotos(slug, ids)`, then `deletedCallback(id)` for each id Gallera confirmed.
3. **Trashed or gone:** call `deletedCallback` for all ids (there's no Gallera copy left to delete), and mark the collection (§6.9) without prompting.

### 6.6 Renaming the collection (`renamePublishServiceCollection`)
- **Flagged as deleted:** update `deleted.originalName` to the new name, with any ` - (deleted)` suffix stripped. Make no API call.
- **Otherwise:** `getGallery` → set `name` → `saveGallery`.

### 6.7 Deleting the collection (`deletePublishedCollection`)
- **Gallery active:** ask **Move gallery to Gallera trash** / **Keep gallery**. Trash → `trashGallery(id)`. Keep → nothing.
- **Gallery already trashed or gone:** no prompt, no API call.

### 6.8 Client favorites (always through the dialog, D13)
1. `getFavorites(slug)`. Build the `photos` map: for each published photo in the collection, `remotePhotoId → { key, current label color, galleraLabelApplied }`.
2. If `incompleteLists` would be non-empty (`#latest < items_count`): for those lists, fall back to matching `lightroom_list` against `original_filename` from `listPhotos`, and log a warning. Ambiguous names are reported and not labeled.
3. Show the **Client favorites dialog** (§7.3), pre-filled from `favoritesColors`. Cancel → nothing changes.
4. On Apply:
   - `plan{ choices }`.
   - Apply inside `catalog:withWriteAccessDo`:
     - **set:** set the color label and `galleraLabelApplied = "<listId>:<color>"`.
     - **remove:** clear the label and `galleraLabelApplied`.
   - Save `favoritesColors` and `favoritesSeen`.
5. Report the counts: labeled / changed / removed / kept their existing label / conflicts.

Entry points: the **Gallera client favorites…** menu item (for the selected published collection), and the "Review now?" prompt after a publish (§6.4 step 8).

### 6.9 Deleted gallery (D10, D11)
**Marking:**
- `DeletedGallery.mark(collection, state)` renames the collection to `<originalName> - (deleted)` (only if it isn't already marked) and stores `deleted = { state, originalName }`.
- `unmark` restores `originalName` and clears the flag.

**Prompt** (publish, opening settings, favorites sync):

> This gallery was deleted[, but it is still available in Gallera trash].
> [Restore] (only when trashed) [Create new] [Cancel]

- **Restore:** `restoreGallery(slug)` → `unmark` → continue. The dialog text warns that photos deleted from the gallery may come back.
- **Create new:**
  - `createGallery{ name = originalName, date = today }` → `setRemoteId` / `setRemoteUrl` → `unmark`.
  - Mark **all** published photos in the collection as modified (`publishedPhoto:setEditedFlag(true)`).
  - Continue. If this happens during a publish, finish the current batch, then tell the user: "Publish again to upload the remaining N photos."
- **Cancel:** the collection stays marked.

**Startup check** (`Init.lua`, background task, silent):
- For each publish service of this plugin that has a token: run `listGalleries` + `listTrashedGalleries` once.
- For each published collection with a `remoteId`: mark it if the gallery is trashed or gone. Unmark it if it's flagged but the gallery is active again (restored on the website).
- Network or auth failures are logged and otherwise ignored.

### 6.10 Login and logout
- **Log in:** a modal dialog with email + password field → `api:login` → store the token, show `username` and storage use. The password variable is discarded right away.
- **Log out:** `api:logout()` (best effort) → delete the stored token.

## 7. User interface

### 7.1 Service setup dialog
- **Gallera account** section (top):
  - Logged out: an email field and a **Log in…** button.
  - Logged in: "Logged in as `<username>` · `<used>` / `<limit>` GB used" and a **Log out** button.
- **Lightroom's standard sections:** File Naming, Image Sizing, Output Sharpening, Metadata, Watermarking.
  - `allowFileFormats = { 'JPEG' }`, `canExportVideo = false`.
  - Hide Export Location (and any section that doesn't apply to publishing).
  - File naming is under the user's control; the plugin never renames files (D16).
- **Uploaded JPEGs** section (D24): a popup (Keep, ask to remove after publish / Always keep / Always remove after upload) and a folder field with **Choose…**; default `Pictures\Gallera`.
- **`metadataThatTriggersRepublish`:** color label changes (and the plugin's own metadata field) **must not** mark photos for re-publish. Verify with spike S7.

### 7.2 Collection settings dialog
**Gallery** (top)
- First creation: radio **Create new gallery** / **Link existing gallery** (a popup of galleries).
- After that: the gallery name, its public URL, and **Open in browser**.

**Gallera Settings tab**: loaded fresh (D3) and laid out like the website.

| Section | Control | API field |
|---|---|---|
| General | Name | `name` |
| | Shooting date | `date` (`YYYY-MM-DD`) |
| | Address | `slug` (Gallera validates it; show its error) |
| | Language | `language` |
| | "Up" button | `top_button_enabled` |
| | Filename | `allow_caption` ⚠ mapping unverified |
| | Tutorial | `allow_tutorial` |
| | Autoplay videos | `autoplay_video` |
| | People recognition | `face_grouping_enabled` ⚠ may need a paid plan (`face_grouping_available`); disable the control when not available |
| Scenes | Show all photos | `allow_all_photos` |
| | Empty scenes | `allow_empty_folders` |
| | List view | `allow_list_view` |
| Favorites | Photo selection | `allow_favorite` |
| | Finish selection | `is_need_to_finish_favorites` |
| | Limit number of photos | `allow_limit_favorites` + `limit_favorites` |
| Saving | Download option | `allow_download` |
| | Available until | `storage_to_date` (`YYYY-MM-DD`) |
| Access | Public access / password | `is_public`, `has_password` + `password` (the field is visible only when password access is on) |
| | Hiding photos / client email | `allow_photo_hiding` + `photo_hiding_client_email` |

**Plugin settings** (stored in Lightroom)
- **Order by capture date:** a checkbox, default on.
- **Override size and quality:** a checkbox, plus long edge (px) and JPEG quality (0–100).
- A **Client favorites…** button that opens the dialog in §7.3.

### 7.3 Client favorites dialog
One row per favorites list in the gallery:

| List | Status | Photos | In this collection | Color |
|---|---|---|---|---|
| vv | Finished | 3 | 3 | popup: Skip / Red / Yellow / Green / Blue / Purple |
| (untitled) | In progress | 1 | 1 | popup |

- The Color popup is pre-filled from the last choice for that list. New lists start at Skip.
- An empty `title` or a URL-looking title (Gallera's default) is shown as "(untitled)".
- Buttons: **Apply** / **Cancel**. After Apply, a summary is shown (§6.8 step 5).

## 8. Errors, logging, security

| Error kind | Behavior |
|---|---|
| `auth` | Abort the operation: "Your Gallera login expired. Log in again in the service settings." |
| `network` | GETs retry once. Uploads get up to 3 attempts per photo (D25); after that the photo is reported failed, stays queued for the next Publish, and the summary lists it. |
| `notFound` (gallery) | Deleted-gallery flow (§6.9) |
| `api` | Show Gallera's `message` (e.g. a slug that's already taken) |

**Never retried:** `trashGallery`, `restoreGallery`, `createGallery` (to avoid duplicate galleries), `deletePhotos` (except the best-effort orphan cleanup in §6.4, which is attempted once per failed upload attempt).

**Logging** (`Log` module, `LrLogger` → logfile)
- Logged: operation names, gallery ids and slugs, photo ids, HTTP status, Gallera's `status` and `message`, timings.
- **Never logged:** the token, the password, the `Authorization` header, full gallery objects (they contain the gallery `password` and `public_url_with_token`), signed upload URLs (they hold credentials in the query string), or user emails.
- `Log` redacts any string field named `password`, `token` or `access_token`, and any URL with `X-Amz-Signature`.

**Repository hygiene:** `*.har` is gitignored. Test fixtures must be sanitized: no tokens, passwords, emails or signed URLs.

## 9. Verification plan

### 9.1 Spikes (first, in Lightroom on Windows; throwaway code)
Each spike answers a yes/no question. A "no" changes the design. Record the results in this spec (§12) before writing the plan.

| # | Question | Pass | Fallback if it fails |
|---|---|---|---|
| S1 | Can `processRenderedPhotos` render with a per-collection long edge and quality? (e.g. `rendition:skipRender()` + our own `LrExportSession` with modified `LR_size_*` / `LR_jpeg_quality`, or another documented mechanism) | The JPEGs have the override's size and quality, and publish state is recorded correctly | Drop the per-collection override. Use separate publish services per quality preset |
| S2 | Does `LrHttp.post(url, bytes, {Content-Type}, "PUT")` upload a binary JPEG to the R2 signed URL intact? | The file downloaded from Gallera is byte-identical | Use `LrHttp.post` with a different body-loading approach; worst case, a helper executable (would break "no external deps") |
| S3 | Can `updateCollectionSettings` make HTTP calls and call `setRemoteId` / `setName` on the published collection? | The gallery is created and the collection is linked and renamed | Create the gallery lazily on first publish |
| S4 | Can `viewForCollectionSettings` fill its fields asynchronously after an HTTP call? | The fields fill in after "Loading…" | Load synchronously before showing the dialog, with a progress scope |
| S5 | Can `LrInitPlugin` start a background task that reads publish services and renames collections? | The startup check runs without blocking Lightroom | Run the check when the plugin is first used in a session |
| S6 | Can a color label be set **by color**, independent of the active label set (e.g. `setRawMetadata('colorNameForLabel', 'red')` or similar)? | Works with the default label set and a renamed set | Map color → label text using the active label set; document the limitation |
| S7 | Can `metadataThatTriggersRepublish` exclude color label and plugin-metadata changes? | Labeling a published photo doesn't move it to "Modified" | Document it; consider writing labels only through the menu command |

### 9.2 Unit tests (core modules)
- **Tooling:** Lua 5.1 + busted on Windows (e.g. via `hererocks` or LuaRocks). The exact install steps go in CLAUDE.md once they're set up.
- **Fixtures:** sanitized responses from the HAR captures (login, gallery object, photos list, upload URL, favorites with finished and unfinished lists, sort echo, the 404 `notFound`).
- **Coverage:**
  - `GalleraApi`: request shapes (method, path, body, headers; the PUT carries no `Authorization`), envelope unwrapping, error kinds, `trashGallery` refusing a non-active gallery, pagination.
  - `GallerySettings`: `toProps`/`diff`/`apply` round-trip; `design`, `cover` and unknown fields are preserved.
  - `GalleryLookup`: active, trashed, gone, and a changed slug.
  - `FavoritesSync`: every rule in §5.2, incl. skipped lists left alone, the plugin's own label changed to a new color, a label the user set themselves (skipped), conflicting colors from two lists, removal only for lists chosen this run, a list that disappeared, and incomplete `latest`.
  - `PhotoOrder`: capture order, ties, missing capture times, photos the plugin didn't upload.

### 9.3 Manual tests (Lightroom on Windows)
Write `docs/manual-tests.md` during implementation. Use a dedicated **test gallery**, never a client gallery. Cover:
- Login and logout
- Create and link a collection
- Edit each Settings section and confirm on the website
- Publish, re-publish and remove photos
- Rename the collection
- Delete the collection (trash and keep)
- Delete the gallery on the website → startup check → restore on the website → startup check
- The deleted-gallery dialog: all three buttons
- Client favorites: the "Review now?" prompt after publish, two lists with different colors, Skip, un-favorite then apply again, a photo with your own label, Cancel changes nothing
- The order checkbox on and off
- The storage pre-check warning (Continue anyway and Cancel)
- Originals untouched: after publish, removal and favorites, only the color label changed
- Uploaded JPEGs: the default (Keep and Remove answers; Remove leaves the failed ones), Always keep, Always remove, re-publish overwrites, a collection name with characters Windows doesn't allow, a publish cancelled midway, and the temp folder left empty in every case
- Failed upload: disconnect the network mid-publish → the retries happen → the photo is reported failed and still queued → reconnect → Publish uploads it
- The log contains no secrets

## 10. Build order (input for the implementation plan)
1. Spikes S1–S7. Update this spec with the results.
2. Plugin skeleton (`Info.lua`, provider stub, logging) that loads in Lightroom.
3. Core modules with tests: `GalleraApi` + adapter contract → `GallerySettings` → `GalleryLookup` → `PhotoOrder` → `FavoritesSync`.
4. `LrHttpAdapter` + `Auth` + service dialog (log in and log out working end to end).
5. Collection dialog: create/link + Settings tab load and save.
6. Publish: upload, re-publish, remove, rename, delete the collection.
7. Ordering.
8. Deleted-gallery handling + startup check.
9. Client favorites: dialog, menu item and the post-publish "Review now?" prompt.
10. Manual test pass; update `docs/gallera-api.md` with anything new learned.

## 11. Preparing for scenes (next iteration)
- `folderId` exists in the collection settings and in `sortPhotos`; it's `nil` for now.
- Planned mapping: **published collection set = gallery**, **child collection = scene**. The gallery id moves to the set's `remoteId`, and each child collection stores its `folderId`. Migration: an existing collection becomes a set with one child, or stays a gallery-level collection. Decide in the scenes spec.
- Still needed from Gallera: HAR captures of creating, renaming and deleting a scene, moving photos into a scene, and sorting within a scene. Also uploading into a scene (does `upload/url` take a folder field?).
- `getCollectionBehaviorInfo` keeps `maxCollectionSetDepth = 0` for the PoC; scenes raise it.

## 12. Open questions and unverified assumptions
| Item | How to resolve |
|---|---|
| Spike results S1–S7 | §9.1 |
| "Filename" ↔ `allow_caption` | Toggle it on the website, then compare the gallery object |
| "People recognition" availability on the user's plan | Check `face_grouping_available` |
| Whether `photos/sort` with `type: manual` changes `order_by` to manual | Read the gallery after the first sort |
| Whether `latest` is always complete for big lists | Capture a favorites list with more than 20 photos |
| Token lifetime | Observe; the `auth` handling covers expiry |
| Error shapes for 401 and 422 (validation, e.g. a taken slug) | Capture once they happen; update `docs/gallera-api.md` |
| Meaning of `storage_period` on create | The PoC sends `"0"` as the website does |
| Whether `LrHttp` follows Gallera/R2 responses as expected on Windows (TLS, large bodies) | Spike S2 |

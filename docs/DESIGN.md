# Gallera Publish Service for Lightroom Classic: Design

- **Date:** 2026-10-30
- **Status:** Implemented (PoC), version 0.10.0 (2026-10-31). Spikes S1–S7 ran on 2026-10-30 (results in §12.1). Manual checklist: `docs/manual-tests.md`.
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
- Photo order on Gallera, per collection: capture date (default), Lightroom's User Order, or don't change.
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
| D8 | Deleting a collection: Lightroom asks whether to delete from the service. Its delete choice calls the plugin, which moves an **active** gallery to Gallera's deleted galleries (restorable on the website) without asking again; **Leave on service** doesn't call the plugin and keeps the gallery. The plugin never sends a second delete | User choice; protects against D-constraint 3. The plugin's own Delete gallery / Keep gallery question was removed (2026-10-31): it repeated Lightroom's | User choice; protects against D-constraint 3 |
| D9 | Renaming the collection renames the gallery. A gallery renamed on the website later does not rename the collection. The exception is linking (D26) | Agreed default: the collection name stays under the user's control, and the settings dialog shows Gallera's current name. Name sync from Gallera could be added later if spike S3 shows `setName` works |
| D10 | A deleted gallery is detected during any Gallera operation and once at Lightroom startup. The collection is renamed `<original name> - (deleted)` and flagged. The plugin never acts on its own | No "disabled" state exists in Lightroom; renaming is the only visible marker |
| D11 | Deleted-gallery dialog: "This gallery was deleted[, but it is still available in Gallera trash]." Buttons: **[Restore]** (only if trashed) **[Create new]** **[Cancel]** | User choice |
| D12 | Photo order, a per-collection setting **Order on Gallera**: **Capture date** (default: after each publish, sort Lightroom-published photos by capture time and send the full order), **Lightroom order** (the collection's User Order, sent on every Publish through `imposeSortOrderOnPublishedCollection`; photos added on the website go last), **Don't change**. The plugin can't set Lightroom's order, so it only pushes Lightroom's order to the website | Gallera has no capture-date sort. User choice (2026-10-31, replacing the checkbox): the Lightroom and website orders should match, and reordering in Lightroom must reach the website |
| D13 | Favorites are **never applied automatically**. A **Client favorites** dialog lists every favorites list (title, Finished / In progress, photo count). The user picks a color for each list: Skip / Red / Yellow / Green / Blue / Purple. The last choice for each list is remembered and pre-filled next time; new lists default to Skip | User choice: the photographer decides what each selection means |
| D14 | Label mirroring, for each list given a color: add that color to the photos in the list. Remove it when a photo leaves the list, **only if** the plugin applied it from that list and the photo's label is still that color. Never overwrite a label the plugin didn't apply (report it as skipped). Which list and color the plugin applied is tracked in a hidden plugin metadata field. "Still that color" is checked with `colorNameForLabel` under the active label set (S6: Lightroom stores the label *text*, so after a label-set switch the color no longer matches and the photo is left alone) | The plugin only touches labels it can prove it set |
| D15 | A list set to Skip is left entirely alone: its photos get no labels, and labels applied from it earlier are kept. Finished and unfinished lists are treated the same; the dialog only shows their status. A photo in two lists with **different** colors is left unchanged and reported as a conflict | Skipping never strips labels; the plugin never guesses |
| D16 | Favorites are matched by **recorded Gallera photo id**. Filenames are never changed; `lightroom_list` filename matching is a fallback only | Ids are exact; filenames are kept for human readability and the fallback |
| D17 | The Client favorites dialog opens from **Library > Plug-in Extras > Gallera client favorites…**. After a publish, if any list is new or has changed since the last review (by `items_count` / `is_finished`), the plugin asks "Client favorites changed (list 'vv'). Review now?" Yes opens the dialog | The dialog is offered when it's relevant, but nothing is applied without it |
| D22 | **Originals are never modified or deleted.** The only things the plugin changes in the catalog: color labels (D14), its own hidden metadata field, Lightroom's publish records, and the published collection's name, remote id and settings. What happens to rendered JPEGs is a service setting (D24) | User requirement |
| D24 | JPEGs are **kept by default**. Every rendered JPEG goes to `<folder>\<collection name>\`, where the folder defaults to `Pictures\Gallera` (`LrPathUtils.getStandardFilePath('pictures')`). A re-rendered photo overwrites its earlier JPEG. Service setting **Uploaded JPEGs**: **Keep, ask to remove after publish** (default) / **Always keep** / **Always remove after upload**. Only successfully uploaded JPEGs are ever removed; failed ones are always kept. Each collection can override it: **Uploaded JPEGs** = **Service setting** (default) / Keep, ask to remove / Always keep / Always remove after upload (`PublishPlan.jpegHandling`) | User choice: the files are kept unless the user says otherwise; per-collection choice added 2026-10-31 |
| D25 | Failed uploads: each photo gets **up to 3 attempts** within a publish (on `network` errors, and on a PUT to an expired or rejected signed URL), waiting 2 s then 5 s, with a fresh signed URL each time. After that, the photo is reported failed (`rendition:uploadFailed`) and stays in Lightroom's publish queue. **Publish again** retries it; Lightroom re-renders from the original | Lightroom's standard retry is a manual re-publish; automatic attempts cover brief network problems |
| D23 | Storage: before uploading, compare the estimated publish size with free Gallera storage. If it may not fit, warn with **Continue anyway** / **Cancel**. During upload, stop when the next file truly doesn't fit | User choice |
| D18 | Rendering: JPEG only. The service holds the full Lightroom export settings. Each collection can override **long edge** and **JPEG quality**. Mechanism (S1 variant A): in `processRenderedPhotos`, before the first `exportContext:renditions()` call, write the override's `LR_size_*` / `LR_jpeg_quality` into `exportContext.propertyTable`, and restore the saved values when the loop ends (also on error) | User choice; proven by spike S1 |
| D19 | Auth: email/password entered once, sent to `auth/login`, and **only the token is stored** (`LrPasswords`). Log out revokes the token. No automatic re-login (the password isn't stored) | The user doesn't want passwords saved; browser login isn't possible (no OAuth) |
| D20 | One Gallera account per publish service. Checked after each **Log in**: if the service has linked collections and the account owns none of their galleries (active or trashed), the dialog says they belong to another account and offers **[Log out]** (default) / **[Keep this account]** | User choice; the check (2026-10-31) keeps another account's login from making every linked gallery look deleted |
| D21 | Layered architecture: a Lightroom-free core (unit-tested) plus a thin Lightroom layer | Must grow over time (scenes, design) |
| D26 | Linking an existing gallery renames the collection to the gallery's name. The picker hides galleries that another collection of this service is already linked to | User choice: the gallery wins on link |
| D27 | Kept JPEGs (D24) are tracked per collection as `jpegFiles = { [photo localIdentifier] = file name }` together with `jpegFolderPath`, the folder those names were written to. In any other folder (JPEG folder setting changed, collection renamed) the names aren't the plugin's: it starts with an empty map there, so a same-named file is never overwritten or deleted (`PublishPlan.jpegFilesFor`, final review 2026-10-31). A re-render of the same photo overwrites its own file. If the name is taken by a different photo, a suffix is added: `name-2.jpg`, `name-3.jpg`, … The uploaded `filename` stays the rendered name without the suffix | User choice; collisions are unlikely but must never overwrite another photo's JPEG |
| D28 | JSON: bundled **dkjson** (pure Lua, MIT), not rxi/json.lua. It keeps JSON `null` (`json.null`) and tells empty objects from empty arrays, so a gallery object read with GET and saved back keeps every field as it was | rxi drops `null` keys and writes `{}` as `[]`, which would change `design`/`cover` on save (D4) |
| D30 | **A queued photo re-uploads, with one guard for client favorites.** Lightroom queues a published photo only on a develop change or a manual *Mark to Re-publish*; title, rating and label edits don't queue it (seen on 0.5.0). Every queued photo re-uploads and replaces its earlier version (D6). The guard: queued photos whose Gallera photo is in a client favorites list are listed in one dialog (thumbnail, file name, the lists it's in, **Picture changed** when it changed, a checkbox each, none checked; **Select all** / **Select none** / **Select changed**). **[Re-upload checked]** re-uploads the checked ones. Unchecked unchanged photos keep their Gallera photo and are recorded as published again with the same remote id; unchecked changed photos fail with "Not re-uploaded: in client favorites" and stay queued (Gallera still has the old picture). **[Cancel]** stops the whole publish without any change (nothing rendered, uploaded or recorded). "Changed" comes from a fingerprint stored at each upload of what shapes the pixels: develop settings (crop included), orientation, and the effective render settings (service settings + collection override), so a changed collection size/quality counts as a picture change | User choice (2026-10-31, replacing the earlier "metadata never counts" rule and D31's separate warning). A re-upload gets a new photo id and loses the client's favorites on it |
| D31 | *Merged into D30 (2026-10-31).* The separate warning before re-uploading photos in client favorites is gone; the D30 dialog lists every queued photo in client favorites, changed or not | User choice: one dialog |
| D29 | Unit tests use **luaunit** (vendored `spec/luaunit.lua`) on a portable Lua 5.1 in the gitignored `tools/lua51/`. Run: `tools\lua51\lua5.1.exe spec\run.lua` | busted needs C modules and a compiler. The user doesn't want the machine's setup changed |

## 5. Architecture

### 5.1 File layout

```text
gallera.lrdevplugin/
  Info.lua                       -- plugin manifest
  small_icon.png                 -- 16x16 service icon in the Publish Services panel (Gallera's favicon)
  Init.lua                       -- LrInitPlugin: starts the startup deleted-gallery check
  -- core (no Lr* imports; loadable by plain Lua 5.1 for tests)
  -- All files sit in the plugin root: Lightroom's `require` is assumed not to load from subfolders (unverified).
  dkjson.lua                     -- bundled pure-Lua JSON (dkjson, MIT; D28)
  GalleraApi.lua
  GallerySettings.lua
  GalleryLookup.lua
  FavoritesSync.lua
  PhotoOrder.lua
  Fingerprint.lua                -- D30: stable hash of the inputs that shape the rendered pixels
  Redact.lua                     -- masks secrets before logging (§8)
  Names.lua                      -- deleted marker, Windows-safe folder names, kept-JPEG names (D27)
  Uploader.lua                   -- one photo's 3-step upload with D25 retries
  PublishPlan.lua                -- classify + favorites guard (D30), storage estimate (D23), confirmed deletes
  -- Lightroom layer
  LrHttpAdapter.lua
  Auth.lua
  CollectionStore.lua            -- reads/merges plugin-owned collection settings
  Publish.lua                    -- processRenderedPhotos (§6.4)
  GalleraMetadata.lua            -- LrMetadataProvider: hidden plugin field(s)
  PublishServiceProvider.lua
  ServiceSettingsDialog.lua
  CollectionSettingsDialog.lua
  DeletedGallery.lua             -- rename/flag/unflag + the D11 dialog, shared by all entry points
  FavoritesDialog.lua            -- Client favorites dialog (per-list color choice)
  FavoritesCommand.lua           -- Library menu item that opens FavoritesDialog
  Log.lua                        -- LrLogger wrapper with redaction
spec/                            -- luaunit tests for core modules (D29)
  luaunit.lua                    -- vendored luaunit 3.4
  run.lua                        -- runs every spec/*_test.lua
  *_test.lua
  fixtures/                      -- sanitized JSON responses from HAR captures
tools/                           -- gitignored; portable Lua 5.1 in tools/lua51/
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
- **Response handling:** it unwraps the `{status, message, data}` envelope. HTTP 401 or 403, or `status = "auth"` → `auth` (an invalid or revoked token returns **403** `{"status":"auth","message":"Unauthenticated."}`, observed in the spikes). Gallera's `message` is localized (e.g. Ukrainian), so code never branches on it; it's only shown or logged. HTTP 404 or `status = "notFound"` → `notFound`. A transport failure → `network`. Anything else with `status ~= "success"` → `api`, with Gallera's message.
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

```lua
PhotoOrder.fromSequence{ galleryPhotoIds = {...}, sequence = { remote ids in Lightroom's User Order } } --> complete id list
PhotoOrder.mode(collectionSettings) --> 'capture' | 'lightroom' | 'none'
```
- `fromSequence`: the sequence first (ids not in the gallery dropped), then the other gallery photos in gallery order.
- `mode`: `galleryOrder`; collections saved with the old `orderByCapture = false` read as `'none'`; default `'capture'`.

**`Fingerprint`** (D30) is pure logic.
```lua
Fingerprint.of{ develop = <getDevelopSettings() table>, orientation = <string|nil>, render = <table of LR_* render keys> }
  --> "<hex>"   -- same inputs, same string, whatever the table iteration order
```
- Serializes the inputs with sorted keys (nested tables included) and hashes the result with two 32-bit rolling hashes computed with plain arithmetic (Lua 5.1 has no bit operations). It's for change detection, not security.
- Numbers are rounded to 6 significant digits before hashing, so float noise doesn't count as a change.

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
| Collection settings (plugin-owned) | `favoritesColors` = `{ [listId] = color }` (last choices, to pre-fill the dialog), `favoritesSeen` = `{ [listId] = { count, finished } }` (to detect changed lists, D17), `jpegHandling` (`'service'` (default), `'ask'`, `'keep'` or `'remove'`, D24), `galleryOrder` (`'capture'` (default), `'lightroom'` or `'none'`; the old `orderByCapture` checkbox is read by `PhotoOrder.mode`), `overrideRender` (default `false`), `longEdge`, `jpegQuality`, `folderId` (always `nil` in the PoC), `deleted` = `nil` or `{ state, originalName }` (state is `"trashed"` or `"gone"`), `jpegFiles` = `{ [photo localIdentifier] = file name }` (D27), `fingerprints` = `{ [photo localIdentifier] = fingerprint of the uploaded version }` (D30) |
| Published photo | `publishedPhotoId` = Gallera photo id. `publishedPhotoUrl` = gallery `public_url` (Gallera has no known per-photo page) |
| Photo custom metadata | `galleraLabelApplied` (`"<listId>:<color>"`) |
| Originals | **Never modified or deleted** (D22). Only the color label changes |

Gallera's own settings may also end up in collection settings, because the dialog binds them. **They are never read from there.** They're always loaded fresh (D3).

### 6.2 Creating or linking a collection (`updateCollectionSettings` on first OK)
1. **Create new:**
   - `createGallery{ name = collection name, date = today }`, then `getGallery(slug)` to get the id.
   - If the user edited any Settings fields in the dialog, `apply` + `saveGallery`.
2. **Link existing:** the picker (`listGalleryNames`, minus galleries already linked to another collection of this service) supplies the id. The dialog's Settings fields were already loaded from that gallery. The collection is renamed to the gallery's name (D26).
3. `setRemoteId(id)` and `setRemoteUrl(public_url)` on the published collection.

How this runs (spike S3):
- `updateCollectionSettings` can call Gallera directly (`LrTasks.canYield()` is true there). Steps 1–3 run inside the callback, and the catalog writes go inside `catalog:withWriteAccessDo`.
- Lightroom saves the name from the dialog **after** the callback returns and overwrites any `setName` made inside it. So the D26 rename runs in an `LrTasks.startAsyncTask` started from the callback, after a short delay (1 s worked). The Publish Services panel may show the new name only after it redraws.
- For a new collection, `viewForCollectionSettings` gets no `publishedCollection` (it doesn't exist yet), but `updateCollectionSettings` does.

Whenever a lookup (`GalleryLookup.find` or `getGallery`) returns a `public_url` that differs from the stored `remoteUrl` (the slug was changed on the website), the plugin updates `remoteUrl`.

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
3. **Storage pre-check** (D23), run after the classification in step 4 so it knows which photos will really upload: `getUser()` → `free = limit - used`. If `storage.limit` is missing or null, skip the check.
   - **Estimate** = number of photos to upload × the average `filesize` of photos already in this gallery (`listPhotos`). For an empty gallery, use 8 MB per photo (a conservative full-resolution JPEG).
   - If estimate > free: "Gallera has X MB free. This publish is estimated at ~Y MB (N photos)." **[Continue anyway]** **[Cancel]**. Cancel aborts before anything is rendered or uploaded.
   - During upload, track `free`. If the next file is larger, stop uploading and mark the rest as failed: "Gallera storage full (used X of Y)".
4. **Classify** (D30): for every photo in the publish, compute its fingerprint.
   - Already published and the fingerprint equals `fingerprints[photo]` → **unchanged**; otherwise (new photo, picture change) → **changed**.
   - If any queued photo is already on Gallera: `getFavorites(slug)`, matched by remote id. A list whose `latest[]` is shorter than `items_count` (seen: 4 of 6) also matches its `lightroom_list` names against `original_filename` from `listPhotos` (no extension, any case; an ambiguous name marks every photo that has it). If the favorites can't be read, every queued photo on Gallera counts as in a list.
   - Not in any list → **upload**. In a list → the D30 dialog: checked → **upload**; unchecked and unchanged → **kept**: render and discard (`skipRender()` throws once the renditions loop has started), `recordPublishedPhotoId` with the **same** remote id, nothing uploaded or deleted; unchecked and changed → **held**: render, discard, `uploadFailed("Not re-uploaded: in client favorites. Still queued…")`.
   - **Cancel** in the dialog stops the publish before the renditions loop: nothing is rendered, uploaded or recorded, and the photos stay queued (seen on 0.5.7).
   - The storage pre-check (step 3) counts only the photos to upload.
5. **Render:** with the service settings, or with the collection override (D18: set the override in `exportContext.propertyTable` before the renditions loop, restore it afterwards, also on error). Two publishes of the same service at the same time would share that table, so the plugin allows only one publish of the service at a time (a module-level busy flag; a second one waits).
6. **Per rendition** (photo):
   1. `requestUpload` (filename = the rendered file's name) → `putFile` → `confirmUpload`. The URL is requested immediately before the PUT.
   2. If any step fails (D25):
      - Clean up the half-created Gallera photo, if there is one (`deletePhotos(slug, {photoId})`, best effort).
      - Retry the whole sequence with a new signed URL, up to 3 attempts in total, waiting 2 s then 5 s. Only `network` errors and a failed PUT are retried. `auth` aborts the publish; other `api` errors fail the photo immediately.
      - After the last attempt, call `rendition:uploadFailed(message)` and continue with the next photo. The photo stays in Lightroom's publish queue for a manual retry.
   3. On success: `rendition:recordPublishedPhotoId(photoId)` and `recordPublishedPhotoUrl(public_url)`, and store the photo's fingerprint in `fingerprints`.
   4. If the photo was already published (re-publish), remember its **old** remote id.
   5. **The rendered JPEG** (D24): move it from Lightroom's temp folder to `<folder>\<collection name>\`. It overwrites this photo's earlier JPEG (from `jpegFiles`). If the name belongs to a different photo, a `-2`, `-3`, … suffix is added (D27). The collection name is made safe for Windows: `<>:"/\|?*` are replaced with `_`. This happens whether the upload succeeded or failed. If the setting is **Always remove after upload** and the upload succeeded, delete it instead (`LrFileUtils.delete`).
7. **Delete old versions:** `deletePhotos(slug, oldIds)` for re-published photos whose new upload succeeded (D6), plus `pendingDeletes` left by an earlier publish whose delete didn't happen (login expired, failed call), which are stored again if this delete fails too (`PublishPlan.replacedToDelete`), only ids still in the gallery (`listPhotos` + `PublishPlan.inGallery`): one id from another gallery (after Create new, §6.9) fails the whole call with 422. Skipped in the publish that ran Create new.
8. **Order** (if Order on Gallera is **Capture date**; **Lightroom order** is sent by `imposeSortOrderOnPublishedCollection`, which Lightroom calls after the uploads, see §6.4a): `listPhotos(slug)` (photos with a non-null `deleted_at` are left out, here and in the storage estimate), build `captureTimes` from Lightroom's `dateTimeOriginal` for this collection's published photos, `PhotoOrder.compute`, `sortPhotos(slug, ids, nil)`.
9. **Favorites check** (D17), run from `imposeSortOrderOnPublishedCollection` (§6.4a) because Lightroom calls it on every Publish, also with nothing queued, while `processRenderedPhotos` runs only for queued photos: `getFavorites(slug)`. If any list is new, or its `items_count` / `is_finished` differs from `favoritesSeen`, ask "Client favorites changed (list '<title>'…). Review now?" Yes → §6.8. Nothing is applied without the dialog.
10. **Summary dialog** (only if there were failures or skipped labels): uploaded / failed / labels added, removed and skipped. If photos failed: "N photos failed to upload. They're still queued; click Publish to retry."
11. **Keep, ask to remove** (the default setting): if at least one photo uploaded, ask "Remove the N uploaded JPEGs from `<folder>\<collection name>`?" **[Keep]** (default button) **[Remove]**. Remove deletes **only the JPEGs uploaded successfully in this publish**; failed ones stay. If the publish is cancelled or aborted midway, the JPEGs rendered so far have already been moved out of the temp folder (step 6.5), and the question covers the ones uploaded before the stop.

### 6.4a Lightroom order (`imposeSortOrderOnPublishedCollection`)
- The provider sets `supportsCustomSortOrder = true`, so published collections have Lightroom's User Order. Moving photos doesn't queue them; on every Publish (also with nothing queued) Lightroom calls `imposeSortOrderOnPublishedCollection(publishSettings, info, remoteIdSequence)` after the uploads, with every published photo's remote id in User Order. New photos can only be moved once they're published.
- `info` has no `publishedCollection`; the collection is `catalog:getPublishedCollectionByLocalIdentifier(info.localCollectionId)`.
- Only collections set to **Lightroom order**: `GalleryLookup.find` → `listPhotos` → `PhotoOrder.fromSequence` → `sortPhotos` (skipped when the order is already the same). Failures are logged only.

### 6.5 Removing photos (`deletePhotosFromPublishedCollection`)
This runs after the user removes photos from the published collection and clicks Publish. It deletes the **Gallera copies** only. `deletedCallback` just tells Lightroom the remote copy is gone, so Lightroom drops its publish record. The originals stay in the catalog and on disk, untouched (D22).
1. Look up the gallery.
2. **Active:** `deletePhotos(slug, ids)`, then `deletedCallback(id)` for each id Gallera confirmed. An id whose photo is already gone from the gallery (deleted on the website) also counts as deleted. Noticing photos deleted on the website and queueing them for re-publish is out of scope for the PoC.
3. **Trashed or gone:** call `deletedCallback` for all ids (there's no Gallera copy left to delete), and mark the collection (§6.9) without prompting.

### 6.6 Renaming the collection (`renamePublishServiceCollection`)
- **Flagged as deleted:** update `deleted.originalName` to the new name, with any ` - (deleted)` suffix stripped. Make no API call.
- **Otherwise:** `getGallery` → set `name` → `saveGallery`.

### 6.7 Deleting the collection (`deletePublishedCollection`)
- **Gallery active:** `trashGallery(id)` right away; Lightroom's own dialog already asked (D8). `trashGallery` refuses when the trash holds a gallery with the same slug, or the trash can't be read: the DELETE goes by slug, and on a trashed gallery it deletes permanently.
- Lightroom doesn't call this when a whole publish service is deleted, and offers no Leave on Service choice for a collection with no published photos.
- **Gallery already trashed or gone:** no prompt, no API call.

### 6.8 Client favorites (always through the dialog, D13)
1. `getFavorites(slug)`. Build the `photos` map: for each published photo in the collection, `remotePhotoId → { key, current label color, galleraLabelApplied }`.
2. If `incompleteLists` would be non-empty (`#latest < items_count`): for those lists, fall back to matching `lightroom_list` against `original_filename` from `listPhotos`, and log a warning. Ambiguous names are reported and not labeled.
3. Show the **Client favorites dialog** (§7.3), pre-filled from `favoritesColors`. Cancel → nothing changes.
4. On Apply:
   - `plan{ choices }`.
   - Before writing, note which of the affected photos' published-photo records are **not** edited (`publishedPhoto:getEditedFlag()`).
   - Apply inside `catalog:withWriteAccessDo`:
     - **set:** `photo:setRawMetadata('colorNameForLabel', color)` (S6: works under any label set; Lightroom stores that set's text for the color) and `galleraLabelApplied = "<listId>:<color>"`.
     - **remove:** clear the label and `galleraLabelApplied`.
   - **Undo the re-publish flag (S7):** Lightroom marks every photo whose label changed as modified, and `metadataThatTriggersRepublish` can't prevent it. Poll for up to ~10 s until the noted photos are flagged, then `setEditedFlag(false)` on those that were not edited before (inside `withWriteAccessDo`). Photos the user really edited stay queued. On 0.9.1 no photo was flagged within 10 s of a label change (as on 0.5.0: label edits don't queue with `metadataThatTriggersRepublish = { default = false }`), so the wait is 2 s and the unflag stays as a safety net. After a Lightroom restart the labeled photos were still under Published.
   - Save `favoritesColors` and `favoritesSeen`.
5. Report the counts: labeled / changed / removed / kept their existing label / conflicts.

- Incomplete lists (`#latest < items_count`) are completed by `FavoritesSync.completeLists`: a `lightroom_list` name (compared lowercased, already without extension) matching exactly one photo's `original_filename` without extension adds it; a name matching several photos is reported in the summary and labels nothing.
- Conflicts count only between lists **chosen** this run: with one of two lists set to Skip, a photo in both gets the other list's color.
- The summary names (up to 10) the photos that kept their own label and the conflicts (user, 2026-10-31).

Entry points: the **Gallera client favorites…** menu item (for the selected published collection), the **Client favorites…** button in the collection settings dialog, and the "Review now?" prompt after a publish (§6.4 step 9).

### 6.9 Deleted gallery (D10, D11)
**Marking:**
- `DeletedGallery.mark(collection, state)` renames the collection to `<originalName> - (deleted)` (only if it isn't already marked) and stores `deleted = { state, originalName }`.
- `unmark` restores `originalName` and clears the flag.

**Prompt** (publish, favorites sync). The collection settings dialog only shows the deleted status and says to Publish: a rename made while it is open is overwritten by its Name field. The prompt comes first; the collection is marked only when it stays deleted (Cancel, or Restore / Create new failed):

> This gallery was deleted[, but it is still available in Gallera trash].
> [Restore] (only when trashed) [Create new] [Cancel]

- **Restore:** `restoreGallery(slug)` → `unmark` → continue. The dialog text warns that photos deleted from the gallery may come back.
- **Create new:**
  - `createGallery{ name = originalName, date = today }` → `setRemoteId` / `setRemoteUrl` → `unmark`.
  - Mark **all** published photos in the collection as modified (`publishedPhoto:setEditedFlag(true)`).
  - Continue. If this happens during a publish, finish the current batch, then tell the user: "Publish again to upload the remaining N photos."
- **Cancel:** the collection stays marked.
- Create new during a publish: the "Publish again to upload the remaining N photos" message is shown before the renditions loop (a message after it never appeared).

**Startup check** (`Init.lua`, background task, silent):
- For each publish service of this plugin that has a token: run `listGalleries` + `listTrashedGalleries` once.
- For each published collection with a `remoteId`: mark it if the gallery is trashed or gone. Unmark it if it's flagged but the gallery is active again (restored on the website).
- Network or auth failures are logged and otherwise ignored.
- A service whose account owns none of its linked galleries (D20 `ownsAny`) is skipped. That also skips a service whose every gallery was permanently deleted; Publish still detects it.
- Lightroom also runs `LrInitPlugin` at the start of every publish, so the check can run while the D11 prompt is open. Before marking, it looks up the collection's current `remoteId` again (`GalleryLookup.find`), so a gallery restored or re-created meanwhile isn't marked.
- The plugin's own `setName` does not call `renamePublishedCollection`.
- Lightroom runs `LrInitPlugin` again on each plugin reload, sometimes several times in a row (S5). The check sets each collection's state from Gallera's answer (never toggles), so running it twice gives the same result, and a run that starts while another is in progress returns at once.

### 6.10 Login and logout
- **Log in:** a modal dialog with email + password field → `api:login` → store the token, show `username` and storage use. The password variable is discarded right away.
- **Log out:** `api:logout()` (best effort) → clear the stored token by storing `''` (`LrPasswords.store(key, nil)` throws). An empty token counts as logged out.

## 7. User interface

### 7.1 Service setup dialog
- **Gallera account** section (top):
  - Logged out: an email field and a **Log in…** button.
  - Logged in: "Logged in as `<username>` · `<used>` / `<limit>` GB used" and a **Log out** button.
  - After a login: the D20 account check (`GalleryLookup.ownsAny` over `listGalleries` + `listTrashedGalleries`).
  - Save stays disabled on login/logout (the token is in `LrPasswords`, not in the settings). `startDialog` sets `LR_includeVideoFiles = false` first: Lightroom doesn't keep it in the saved settings and its own reset to `false` (`canExportVideo = false`) enabled Save and made every Save ask to re-publish all photos.
- **Lightroom's standard sections:** File Naming, Image Sizing, Output Sharpening, Metadata, Watermarking.
  - `allowFileFormats = { 'JPEG' }`, `canExportVideo = false`.
  - Hide Export Location (and any section that doesn't apply to publishing).
  - File naming is under the user's control; the plugin never renames files (D16).
- **Uploaded JPEGs** section (D24): a popup (Keep, ask to remove after publish / Always keep / Always remove after upload) and a folder field with **Choose…**; default `Pictures\Gallera`.
- **`metadataThatTriggersRepublish`:** `{ default = false }`, so metadata edits don't queue photos (D30). On 0.5.0, title, rating and label edits made in Lightroom's UI didn't queue a photo; S7 saw a label written by the plugin (`setRawMetadata`) mark it modified, so the favorites flow clears the flags it caused (§6.8 step 4), keeping the queue to real changes and manual marks.

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
- **Order on Gallera:** a popup, Capture date (default) / Lightroom order (User Order) / Don't change, with the hint "Lightroom order: sort the collection by User Order and drag photos; Publish sends the order."
- **Uploaded JPEGs:** a popup, Service setting (default) / Keep, ask to remove after publish / Always keep / Always remove after upload (D24).
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
- **Tooling (D29):** luaunit on a portable Lua 5.1 (LuaBinaries 5.1.5 Win64 in the gitignored `tools/lua51/`). Nothing is installed system-wide. Run `tools\lua51\lua5.1.exe spec\run.lua`. Setup steps are in CLAUDE.md.
- **Fixtures:** sanitized responses from the HAR captures (login, gallery object, photos list, upload URL, favorites with finished and unfinished lists, sort echo, the 404 `notFound`).
- **Coverage:**
  - `GalleraApi`: request shapes (method, path, body, headers; the PUT carries no `Authorization`), envelope unwrapping, error kinds, `trashGallery` refusing a non-active gallery, pagination.
  - `GallerySettings`: `toProps`/`diff`/`apply` round-trip; `design`, `cover`, unknown fields, `null` values and empty objects are preserved through decode → apply → encode (D28).
  - `GalleryLookup`: active, trashed, gone, and a changed slug.
  - `FavoritesSync`: every rule in §5.2, incl. skipped lists left alone, the plugin's own label changed to a new color, a label the user set themselves (skipped), conflicting colors from two lists, removal only for lists chosen this run, a list that disappeared, and incomplete `latest`.
  - `PhotoOrder`: capture order, ties, missing capture times, photos the plugin didn't upload; Lightroom sequence order; the setting's mode.
  - `Fingerprint`: same inputs in a different table order give the same value; any change to a develop value, orientation or render setting gives a different one; float noise below the rounding doesn't.

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
1. Spikes S1–S7 (a throwaway plugin, removed after implementation; results in §12.1). Update this spec with the results.
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

### 12.1 Spike results (2026-10-30, Lightroom Classic 15.6, Windows)
| # | Result | Findings |
|---|---|---|
| S1 | ✅ Pass (variant A) | Writing `LR_size_doConstrain/resizeType='longEdge'/maxWidth/maxHeight/units` and `LR_jpeg_quality` (0–1) into `exportContext.propertyTable` before `renditions()` renders at the override (1000 px, ~120 KB instead of 2048 px, ~1.6 MB). Restoring afterwards leaves the service settings unchanged (checked in Edit Settings). Publish records are written normally. Variant B (`skipRender` + own `LrExportSession`) wasn't needed and wasn't run |
| S2 | ✅ Pass | `LrHttp.post(url, body, {Content-Type}, 'PUT')` uploads to the R2 signed URL with the body as a whole string **and** as a chunked function body (+ `totalSize`). 11.3 MB took 2.3 s. Gallera's `filesize` equals the local byte count. `image_url` is a re-encoded display copy (max 1920 px long edge, ~q90), so it can't be used for a byte comparison |
| S3 | ✅ Pass, with a change | HTTP works inside `updateCollectionSettings`. `setRemoteId`/`setRemoteUrl`/`setName` need `withWriteAccessDo` there. Lightroom saves the dialog's name after the callback, overwriting `setName` made inside it; a rename from an async task 1 s after the callback sticks (confirmed after restart). The Publish Services panel didn't redraw that rename until restart |
| S4 | ✅ Pass | An async task started in `viewForCollectionSettings` fills bound fields after the dialog is shown ("Loading…" → "Loaded", username filled, field enabled) |
| S5 | ✅ Pass | On a real restart the `LrInitPlugin` task ran once, saw the publish service and its collections, renamed a collection (visible in the panel) and called Gallera, in 0.6 s without blocking Lightroom. Plugin **reloads** run the init script several times in a row |
| S6 | ✅ Pass | `setRawMetadata('colorNameForLabel', color)` sets the label by color under both Lightroom Default and Review Status (it stores that set's text, e.g. "To Print" for purple). Read the color with `getRawMetadata('colorNameForLabel')`; `getRawMetadata('label')` is an unknown key — the text comes from `getFormattedMetadata('label')` |
| S7 | ❌ Fail → fallback ✅ | A label change marks the photo as modified even with `label = false`, `colorNameForLabel = false` or `default = false`. Fallback that works: after the label write, Lightroom flags the photo within 2 s; `publishedPhoto:setEditedFlag(false)` clears it and it stays cleared (photos jump back to Published) |

Other SDK facts from the spikes (also in CLAUDE.md): `LrPasswords.store(key, nil)` throws; plain `pcall` around yielding SDK calls fails ("Yielding is not allowed…"), use `LrTasks.pcall`; LrLogger writes to `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\`.

### 12.2 Still open
| Item | How to resolve |
|---|---|
| ~~Clearing a label with `setRawMetadata('colorNameForLabel', 'none')` (or `''`)~~ | **Resolved (Task 19, 0.9.2):** `'none'` clears the label |
| Whether a flag cleared with `setEditedFlag(false)` stays cleared after a Lightroom restart | Not exercised: label changes never flagged a photo (Task 19). After a restart the labeled photos were still under Published |
| ~~Whether `rendition:skipRender()` works for unchanged photos~~ | **Resolved (Task 15, 0.5.2):** inside the renditions loop it throws "AgExportRendition:skip(): must not be called after exportSession has started rendering". Kept photos render and the file is discarded (a 1-photo publish took 1.5 s); `recordPublishedPhotoId` with the old id then marks them published. Held photos render first too, since `uploadFailed` before the render isn't reported (Task 14) |
| ~~Which develop-setting keys change without a visible change, and the raw-metadata key for orientation~~ | **Resolved (Task 15, 0.4.7, 178 develop keys):** a title or rating change changed no develop key, so `EXCLUDED_DEVELOP_KEYS` stays empty. `getRawMetadata('orientation')` works (`'DA'` → `'CD'` after Rotate Left; the develop settings also carry `orientation`). Exposure changes `Exposure2012`. A white-balance slider moved and moved back changes only the `WhiteBalance` label ("As Shot" → "Custom"), which counts as a change |
| ~~Gallera favorites `latest[]` completeness~~ | **Resolved (Task 15):** not complete. A list with `items_count` 6 returned 4 in `latest` (and 5 `lightroom_list` names), so names are matched as a fallback (§6.4 step 4). After a favorited photo is re-uploaded, the list still counts the old photo by name, so the new photo with that name is treated as a favorite too |
| "Filename" ↔ `allow_caption` | Toggle it on the website, then compare the gallery object |
| "People recognition" availability on the user's plan | Check `face_grouping_available` |
| ~~Whether `photos/sort` with `type: manual` changes `order_by` to manual~~ | **Resolved (Task 17, 0.7.x):** yes, after the plugin's sort the website's sort option shows Manual. In a manually ordered gallery Gallera puts a new upload first |
| ~~Whether `latest` is always complete for big lists~~ | **Resolved:** not even for small lists (4 of 6); the name fallback (`FavoritesSync.completeLists`, `PublishPlan.favoriteIndex`) always applies when `#latest < items_count` |
| Token lifetime | Observe; the `auth` handling covers expiry |
| ~~Error shape for 422 (validation, e.g. a taken slug)~~ | **Resolved:** the usual wrapper with a localized `message` (wrong password, taken slug, foreign photo id); see `docs/gallera-api.md` |
| Meaning of `storage_period` on create | The PoC sends `"0"` as the website does |
| Whether Lightroom's `require` can load files from plugin subfolders | Not tested; all modules stay in the plugin root (§5.1) |
| Whether `storage.limit` can be null (unlimited plans) | Handled by skipping the pre-check (§6.4) |

### 12.3 Lightroom SDK facts learned during implementation (Lightroom Classic 15.6, Windows)
1. In `sectionsForTopOfDialog`, `visible` bindings never hid a row; `enabled` bindings work.
2. `rendition:uploadFailed()` before `waitForRender()` isn't reported. Render first.
3. Offline, `LrHttp.postMultipart` returns a body with no HTTP status (not `nil`); a missing status is treated as a network failure.
4. `LrDialogs.message` after the renditions loop never appeared; `LrDialogs.confirm` after the loop works; dialogs before the loop work.
5. The service dialog's Save is enabled by any net change of a property after it opens, including Lightroom's own `LR_*` resets; OK then asks to mark all photos for re-publish. Lightroom resets `LR_includeVideoFiles` to false when `canExportVideo = false`, so `startDialog` sets it. Non-preset `ui_*` keys don't enable Save.
6. The collection dialog's confirm button says "Edit"/"Create" (Lightroom's own).
7. `updateCollectionSettings` + `withWriteAccessDo` + a 1 s-delayed `setName` works for the D26 rename. Keys set to nil on `info.collectionSettings` there don't stick.
8. `exportSession:photosToExport()` returns an iterator; `getPublishedPhotos()` an array.
9. `rendition:skipRender()` throws inside the renditions loop.
10. Returning from `processRenderedPhotos` without iterating `renditions()` leaves the photos queued, no error.
11. `f:catalog_photo { photo, width, height }` shows thumbnails in a modal dialog; `f:scrolled_view` with bound checkboxes works.
12. `getRawMetadata('orientation')` works; `getDevelopSettings()` has 178 keys.
13. With `metadataThatTriggersRepublish = { default = false }`, title, rating and color-label changes don't queue a published photo, including labels set by the plugin with `setRawMetadata('colorNameForLabel', …)` (contrary to spike S7). `'none'` clears a label.
14. `deletePhotosFromPublishedCollection` gets the collection's local id as a 4th argument.
15. Deleting a published collection: Lightroom asks first; its **Leave on service** choice doesn't call `deletePublishedCollection`.
16. With `supportsCustomSortOrder = true`, moving photos in User Order doesn't queue them; every Publish (also with nothing queued) calls `imposeSortOrderOnPublishedCollection` after the uploads, with all remote ids in User Order. Its `info` has `localCollectionId`, `remoteCollectionId`, `name`, `collectionSettings`, `publishSettings`, `publishedUrl`, `parents`, `isDefaultCollection`, `isCollectionSet`, `publishConnectionId`, and no `publishedCollection`. Unpublished photos can't be moved.
17. `processRenderedPhotos` isn't called when nothing is queued.
18. Lightroom runs `LrInitPlugin` again at the start of every publish, not only on startup and reload.
19. The plugin's own `collection:setName` doesn't call `renamePublishedCollection`.
20. The Publish Services panel can draw a newly created collection's row narrow (name cropped) until the panel is resized.

# Gallera Publish Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Lightroom Classic publish service that keeps each published collection in sync with one app.gallera.io gallery: create/link, publish/re-publish/remove, gallery settings, deleted-gallery handling and client favorites → color labels.

**Architecture:** A Lightroom-free core (pure Lua 5.1, unit-tested with luaunit) holds all API, settings, ordering, fingerprint, naming, planning and favorites logic. A thin Lightroom layer wires it to the SDK callbacks, dialogs and catalog. Every HTTP call goes through `GalleraApi` and an injected HTTP adapter.

**Tech Stack:** Lua 5.1 (Lightroom's embedded runtime), Lightroom Classic SDK (tested on 15.6, Windows), dkjson 2.8 (vendored), luaunit 3.4 (vendored, `spec/luaunit.lua`), portable Lua 5.1 in `tools/lua51/`.

**Spec:** `docs/DESIGN.md` (decisions D1–D31, spike results §12.1). API facts: `docs/gallera-api.md`. Project rules: `CLAUDE.md`.

## Global Constraints

- Plugin folder `gallera.lrdevplugin/` at the repo root. Every `.lua` file sits in its root (no subfolders, §5.1). Toolkit id `com.pysarenko.gallera`.
- Core modules (`GalleraApi`, `GallerySettings`, `GalleryLookup`, `FavoritesSync`, `PhotoOrder`, `Fingerprint`, plus `Redact`, `Names`, `Uploader`, `PublishPlan` added by this plan) never `import` a Lightroom namespace. Whatever they need is passed in.
- Lua 5.1 only: no `goto`, no `//`, no bit library, no C modules. `require` only for plugin files.
- Inside tasks use `LrTasks.pcall`, never `pcall`, around SDK calls. All catalog writes go inside `catalog:withWriteAccessDo(name, fn, { timeout = 10 })`. All HTTP runs in a task (an `LrTasks.startAsyncTask`, `LrFunctionContext.postAsyncTaskWithContext` or the export task).
- Base URL `https://api.gallera.io/api/`. Request headers `Accept: application/json`, `X-Requested-With: XMLHttpRequest`, `Authorization: Bearer <token>`, plus `Content-Type: application/json` for JSON bodies. The R2 `PUT` sends **only** `Content-Type`.
- Errors are `result, err` with `err = { kind = "auth"|"notFound"|"network"|"api", status = <number|nil>, message = <string> }`. Never branch on Gallera's `message` (it's localized).
- Store the gallery **id** as the collection's `remoteId`, never the slug. Look up the slug per operation (`GalleryLookup.find`).
- `DELETE galleries/{slug}/delete` is sent only by `api:trashGallery(id)`, only for an active gallery, never retried. No code path permanently deletes a gallery.
- Tokens live only in `LrPasswords` under `"gallera.token:" .. email`. Logout stores `''`; `''` means no token. Never log the token, password, `Authorization`, signed URLs, emails or a whole gallery object.
- Originals are never modified or deleted (D22).
- Git: the user runs git. Each task ends with a **Commit** step that lists the files and a suggested message; don't run `git commit` yourself.
- Manual Lightroom checks are done by the user, **one step at a time**. Before each, bump `VERSION` in `gallera.lrdevplugin/Info.lua` and say which version Plug-in Manager should show. Logs: `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\Gallera.log`. Use a dedicated test gallery, never a client gallery.
- Unit tests: `tools\lua51\lua5.1.exe spec\run.lua` from the repo root (one class: add `-p TestName`). Test files are `spec/*_test.lua` and define global `Test...` tables. Test data with backslash escapes is written with the Write tool, not a shell heredoc.

## Review Focus

1. **Token revoked mid-publish:** an upload step returns 403 `auth`. Expected: the publish stops at once with "Your Gallera login expired. Log in again in the service settings.", without retrying the photo 3 times. (Test in Task 10.)
2. **R2 rejects the PUT with 403** (expired signed URL): this is not a login problem. Expected: `putFile` reports `api`, not `auth`, so the upload is retried with a fresh URL. (Test in Task 3.)
3. **Non-ASCII names** (the user writes Ukrainian): gallery and collection names and file names survive JSON and multipart unchanged. (Tests in Tasks 2 and 8.)
4. **Collection names that Windows can't use as folders** (`a/b`, `Wedding.`, `CON`): the kept-JPEG folder is still created. (Test in Task 8.)
5. **Photo already deleted on the website**, then removed from the collection: Lightroom drops the record instead of keeping it forever. (Test in Task 11.)

---

### Task 1: Plugin skeleton, JSON, redacting log

**Files:**
- Create: `gallera.lrdevplugin/Info.lua`, `gallera.lrdevplugin/dkjson.lua`, `gallera.lrdevplugin/Redact.lua`, `gallera.lrdevplugin/Log.lua`, `gallera.lrdevplugin/PublishServiceProvider.lua`, `gallera.lrdevplugin/Init.lua`, `gallera.lrdevplugin/GalleraMetadata.lua`
- Modify: `docs/DESIGN.md` §5.1 (add `Redact.lua`, `Names.lua`, `Uploader.lua`, `PublishPlan.lua` to the core list; `CollectionStore.lua`, `Publish.lua` to the Lightroom layer), `CLAUDE.md` (core module list)
- Test: `spec/json_test.lua`, `spec/redact_test.lua`

**Interfaces:**
- Produces: `require 'dkjson'` (`json.encode`, `json.decode(s, 1, json.null)`, `json.null`); `Redact.value(v) -> v'` (deep copy) and `Redact.text(s) -> s'`; `Log.info(...)`, `Log.warn(...)`, `Log.error(...)` (args: strings, numbers, tables; tables are redacted, then JSON-encoded).

- [ ] **Step 1: Vendor dkjson.** Download `https://dkolf.de/dkjson-lua/dkjson-2.8.lua` (the latest 2.x from that page if 2.8 is gone) to `gallera.lrdevplugin/dkjson.lua`. Keep its license header unchanged.

- [ ] **Step 2: Write the failing tests**

```lua
-- spec/json_test.lua
local lu, json = require('luaunit'), require('dkjson')
TestJson = {}
function TestJson:testNullAndEmptyObjectSurviveRoundTrip()
  local s = '{"a":null,"design":{},"list":[],"name":"Весілля"}'
  local back = json.decode(json.encode(json.decode(s, 1, json.null)), 1, json.null)
  lu.assertEquals(back.a, json.null)
  lu.assertStrContains(json.encode(json.decode(s, 1, json.null)), '"design":{}')
  lu.assertStrContains(json.encode(json.decode(s, 1, json.null)), '"list":[]')
  lu.assertEquals(back.name, 'Весілля')
end
function TestJson:testLargeIdsEncodeAsIntegers()
  lu.assertEquals(json.encode({ 140349250, 140466391 }), '[140349250,140466391]')
end

-- spec/redact_test.lua
local lu, Redact = require('luaunit'), require('Redact')
TestRedact = {}
function TestRedact:testSecretFieldsAreMasked()
  local r = Redact.value({ name = 'g', password = 'p', Token = 't', access_token = 'a',
    public_url_with_token = 'u', nested = { password = 'x' } })
  lu.assertEquals(r, { name = 'g', password = '***', Token = '***', access_token = '***',
    public_url_with_token = '***', nested = { password = '***' } })
end
function TestRedact:testSignedUrlIsMasked()
  lu.assertEquals(Redact.text('PUT https://r2.example/x?X-Amz-Signature=abc&y=1'), 'PUT <signed url>')
end
function TestRedact:testInputIsNotModified()
  local t = { password = 'p' }; Redact.value(t); lu.assertEquals(t.password, 'p')
end
```

- [ ] **Step 3: Run them.** `tools\lua51\lua5.1.exe spec\run.lua -p TestRedact`. Expected: ERROR `module 'Redact' not found`. TestJson already passes.

- [ ] **Step 4: Implement `Redact.value` / `Redact.text`** in `Redact.lua`. Mask keys (case-insensitive) `password`, `token`, `access_token`, `public_url_with_token`. In strings, replace every URL containing `X-Amz-Signature` (up to the next whitespace) with `<signed url>`.

- [ ] **Step 5: Run the tests.** Expected: all pass.

- [ ] **Step 6: Lightroom layer.**
  - **`Info.lua`:**
    - `LrSdkVersion = 14.0`, `LrSdkMinimumVersion = 13.0`, `LrToolkitIdentifier = 'com.pysarenko.gallera'`, `LrPluginName = 'Gallera'`
    - `LrInitPlugin = 'Init.lua'`, `LrMetadataProvider = 'GalleraMetadata.lua'`
    - `LrExportServiceProvider = { title = 'Gallera', file = 'PublishServiceProvider.lua' }`
    - `VERSION = { major = 0, minor = 1, revision = 0 }`
  - **`Log.lua`:** `LrLogger('Gallera')` with `enable('logfile')`. It passes every argument through `Redact`.
  - **`GalleraMetadata.lua`:** one hidden field: `{ id = 'galleraLabelApplied', dataType = 'string' }` with no title, `schemaVersion = 1`.
  - **`Init.lua`:** logs "Gallera plugin loaded" and the version.
  - **`PublishServiceProvider.lua`:**
    - `supportsIncrementalPublish = 'only'`, `allowFileFormats = { 'JPEG' }`, `canExportVideo = false`, `hideSections = { 'exportLocation' }`, `hidePrintResolution = true`
    - `metadataThatTriggersRepublish` returns `{ default = false }` (D30)
    - `getCollectionBehaviorInfo` returns `{ defaultCollectionName = 'Gallery', defaultCollectionCanBeDeleted = true, canAddCollection = true, maxCollectionSetDepth = 0 }`
    - `processRenderedPhotos` stub: log and `uploadFailed('Not implemented yet')` for each rendition.
  - Update DESIGN.md §5.1 and CLAUDE.md as listed under Files.

- [ ] **Step 7: Manual check (user).** Plug-in Manager > Add `gallera.lrdevplugin`. Expected:
  - Version 0.1.0 is shown with no load error.
  - "Gallera" appears in Publish Services > Set Up.
  - `Gallera.log` contains "Gallera plugin loaded".

- [ ] **Step 8: Commit.** `gallera.lrdevplugin/*`, `spec/json_test.lua`, `spec/redact_test.lua`, `docs/DESIGN.md`, `CLAUDE.md`. Message: `feat: plugin skeleton, dkjson, redacting log`.

---

### Task 2: GalleraApi — transport, errors, auth and gallery endpoints

**Files:**
- Create: `gallera.lrdevplugin/GalleraApi.lua`, `spec/support/fake_http.lua`, `spec/fixtures/gallery.json` (synthetic, built from the field list in `docs/gallera-api.md`; must include `"design":{"theme":"light"}`, `"cover":{}`, `"storage_to_date":null`, `"extra_unknown":{"k":[]}`, `"password":"secret"`, `"id":837261`, `"slug":"test-gallery"`, `"public_url":"https://user.gallera.io/test-gallery"`)
- Test: `spec/gallera_api_test.lua`

**Interfaces:**
- Consumes: `dkjson`.
- Produces:
  - `GalleraApi.BASE_URL`
  - `GalleraApi.new{ http = adapter, token = string|nil } -> api`, with the token in `api.token`
  - `api:login(email, password) -> token, user`
  - `api:logout() -> true`
  - `api:getUser() -> user`
  - `api:listGalleries() -> galleries[]` (follows pagination)
  - `api:listGalleryNames() -> {id, name}[]`
  - `api:listTrashedGalleries() -> galleries[]`
  - `api:createGallery{ name, date } -> slug`
  - `api:getGallery(slug) -> gallery` (decoded with `json.null`)
  - `api:saveGallery(slug, gallery) -> newSlug`
  - `api:restoreGallery(slug) -> true`
  - On failure, each returns `nil, err`.
  - **Adapter contract:** `adapter.request{ method, url, headers = {[name]=value}, body = string|nil, multipart = {{name, value}}|nil } -> { status = number, body = string } | nil, networkMessage`.
  - **FakeHttp:**
    - `FakeHttp.new() -> fake`
    - `fake:respond(status, bodyTableOrString)` queues a response.
    - `fake:failNetwork(msg)` queues a network failure.
    - `fake.requests` records the requests.
    - `fake.adapter` is passed as `http`.
    - An unqueued request raises an error.

- [ ] **Step 1: Write the failing tests** (`TestGalleraApi`, using FakeHttp; `B = GalleraApi.BASE_URL`; `ok(data)` = `{status='success', message='OK', data=data}`):
  - `testLoginSendsJsonAndNoAuthHeader`:
    - `respond(200, ok{token='1|abc', user={username='u'}})`.
    - `login('a@b.c','pw')` returns `'1|abc'` and `user.username == 'u'`.
    - The request is `POST`, `B..'auth/login'`, with headers `Accept`, `X-Requested-With`, `Content-Type` set as in Global Constraints and no `Authorization`.
    - The decoded body equals `{email='a@b.c', password='pw'}`.
  - `testTokenSendsBearer`: with `token='1|abc'`, `getUser()` sends `Authorization == 'Bearer 1|abc'`.
  - `testAuthStatusAndHttpCodesMapToAuth`:
    - `403 {status='auth', message='Unauthenticated.'}` gives `err.kind == 'auth'` and `err.status == 403`.
    - A bare `401` gives `auth`.
  - `testNotFound`: `404 {status='notFound'}` gives `notFound`.
  - `testOtherStatusIsApiWithMessage`: `200 {status='error', message='Адреса зайнята'}` gives `kind 'api'` and the message unchanged.
  - `testGetRetriesOnceOnNetwork`:
    - With `failNetwork` then `ok`, the call succeeds and `#requests == 2`.
    - With two `failNetwork`, the result is `kind 'network'` and `#requests == 2`.
  - `testPostIsNotRetried`: `createGallery` with `failNetwork` gives `network` and `#requests == 1`.
  - `testListGalleriesFollowsPagination`:
    - Page 1 has 2 galleries and `pagination.has_more = true`; page 2 has 1 and `false`.
    - The result has 3 galleries.
    - The URLs are `B..'v2/galleries/my?page=1&sort=created&search='` and the same with `page=2`.
  - `testCreateGalleryBody` (Review Focus 3):
    - `createGallery{name='Весілля Олени', date='2026-10-30'}` returns `data.gallery` (`'vesillia'`).
    - The raw body contains `"storage_period":"0"` and `"copy_gallery_id":null`.
    - The decoded body has `name == 'Весілля Олени'`.
  - `testSaveGalleryKeepsUnknownFields`:
    - `getGallery('test-gallery')` with the fixture, then `saveGallery('test-gallery', g)` with `ok{slug='test-gallery2'}`, returns `'test-gallery2'`.
    - The raw POST body to `B..'galleries/test-gallery'` contains `"cover":{}`, `"storage_to_date":null` and `"extra_unknown":{"k":[]}`.
  - `testTrashedListAcceptsBothShapes`: `data = [g]` and `data = {galleries=[g]}` both give 1 gallery (the shape isn't documented).

- [ ] **Step 2: Run them.** `tools\lua51\lua5.1.exe spec\run.lua -p TestGalleraApi`. Expected: ERROR `module 'GalleraApi' not found`.

- [ ] **Step 3: Implement** the Interfaces above in `GalleraApi.lua`.
  - Decode responses with `json.decode(body, 1, json.null)`. Encode bodies with `json.encode` and send `json.null` for nulls.
  - Error mapping order:
    1. A transport failure gives `network`.
    2. HTTP 401/403 or `status == 'auth'` gives `auth`.
    3. HTTP 404 or `status == 'notFound'` gives `notFound`.
    4. Any other `status ~= 'success'`, or a body that isn't JSON, gives `api`.
  - `message` is Gallera's message, or `'HTTP <n>'`.
  - Only `GET` retries, once, and only on `network`.

- [ ] **Step 4: Run the tests.** Expected: all `TestGalleraApi` tests pass.

- [ ] **Step 5: Commit.** `GalleraApi.lua`, `spec/support/fake_http.lua`, `spec/fixtures/gallery.json`, `spec/gallera_api_test.lua`. Message: `feat: GalleraApi transport, errors, auth and gallery endpoints`.

---

### Task 3: GalleraApi — photos, upload, favorites, trash safety

**Files:**
- Modify: `gallera.lrdevplugin/GalleraApi.lua`
- Test: `spec/gallera_api_photos_test.lua`

**Interfaces:**
- Produces:
  - `api:listPhotos(slug) -> photos[]` (leaves out photos whose `deleted_at` isn't null)
  - `api:requestUpload{ galleryId, filename, filesize, filetype } -> { url, photoId }`
  - `api:putFile(url, bytes, contentType) -> true`
  - `api:confirmUpload(photoId) -> true`
  - `api:deletePhotos(slug, ids) -> deletedIds[]`
  - `api:sortPhotos(slug, ids, folderId) -> true`
  - `api:getFavorites(slug) -> lists[]`
  - `api:trashGallery(galleryId) -> true`

- [ ] **Step 1: Write the failing tests** (`TestGalleraApiPhotos`):
  - `testRequestUploadIsMultipart`:
    - The multipart parts are exactly `{ {name='gallery', value='837261'}, {name='filename', value='DSC_0001.jpg'}, {name='filesize', value='11285192'}, {name='filetype', value='image/jpeg'} }`.
    - The request has no `Content-Type` header.
    - The result is `{url='https://r2/u', photoId=140466391}`.
  - `testPutFileSendsOnlyContentType` (api with a token):
    - `putFile('https://r2/u?X-Amz-Signature=s', 'BYTES', 'image/jpeg')` sends `method 'PUT'`, the URL unchanged, `body 'BYTES'` and headers exactly `{['Content-Type']='image/jpeg'}`.
    - An empty 200 response gives `true`.
  - `testPutFileForbiddenIsApiNotAuth` (Review Focus 2): `403` with body `<Error><Code>AccessDenied</Code></Error>` gives `kind 'api'`, `status 403`, and a message containing `AccessDenied`.
  - `testConfirmUpload`: `POST B..'photos/upload/140466391/uploaded'` with body `{"photo":140466391}`.
  - `testDeletePhotosBody`: the raw body is `{"gallery":"test-gallery","photos":[140349250]}` (key order may differ: compare the decoded body). The result is `data`.
  - `testSortPhotosBody` (Review Focus 3, ids): the decoded body is `{sorted={140349250,140349246}, gallery='test-gallery', type='manual'}`. The raw body contains `"folder":null` and `140349250`, and not `e+`.
  - `testListPhotosDropsDeleted`: of 3 photos, the one with `deleted_at = '2026-10-30'` is dropped. `json.null` and missing both count as not deleted.
  - `testGetFavorites`: `GET B..'galleries/test-gallery/favorites'` returns `data`.
  - `testTrashGalleryRefusesNonActive`: the id isn't in `listGalleries` (one page). The result is `kind 'api'`, and no `DELETE` request is made.
  - `testTrashGalleryDeletesActiveOnce`:
    - Id 837261 has slug `'x'`.
    - Exactly one request `DELETE B..'galleries/x/delete'` is made.
    - With `failNetwork` on that DELETE, the result is `network` and there is still exactly one DELETE.

- [ ] **Step 2: Run them.** Expected: FAIL. The new methods are nil.

- [ ] **Step 3: Implement.**
  - `putFile` doesn't go through the JSON envelope. Any 2xx counts as success. Any other status gives `api`, with the R2 `<Code>` in the message when present. A transport failure gives `network`.
  - `trashGallery` finds the slug with `listGalleries` and never retries.

- [ ] **Step 4: Run all tests.** `tools\lua51\lua5.1.exe spec\run.lua`. Expected: all pass.

- [ ] **Step 5: Commit.** Message: `feat: GalleraApi photos, upload, favorites, safe trash`.

---

### Task 4: GallerySettings

**Files:**
- Create: `gallera.lrdevplugin/GallerySettings.lua`
- Test: `spec/gallery_settings_test.lua`

**Interfaces:**
- Produces:
  - `GallerySettings.FIELDS`: an ordered array of `{ section, key, label, type }`. `key` is the API field name. `type` is one of `'string'|'date'|'bool'|'number'|'password'`. An optional `availableKey` holds the name of a read-only flag that enables the control.
  - `GallerySettings.toProps(gallery) -> {[key]=value}`, with `json.null` turned into nil.
  - `GallerySettings.diff(baseline, edited) -> {[key]=value}`
  - `GallerySettings.apply(fresh, changed) -> gallery`

- [ ] **Step 1: Write the failing tests** (`TestGallerySettings`):
  - `testFieldsMatchSettingsTab`: the keys, in order, are exactly
    - General: `name, date, slug, language, top_button_enabled, allow_caption, allow_tutorial, autoplay_video, face_grouping_enabled`
    - Scenes: `allow_all_photos, allow_empty_folders, allow_list_view`
    - Favorites: `allow_favorite, is_need_to_finish_favorites, allow_limit_favorites, limit_favorites`
    - Saving: `allow_download, storage_to_date`
    - Access: `is_public, has_password, password, allow_photo_hiding, photo_hiding_client_email`
    - `face_grouping_enabled` has `availableKey = 'face_grouping_available'`, and `password` has type `'password'`.
  - `testToPropsTurnsNullIntoNil`: for the fixture, `storage_to_date` is nil and `name` keeps its value.
  - `testDiffReturnsOnlyChanges`: `diff({name='a', is_public=true}, {name='b', is_public=true})` returns `{name='b'}`.
  - `testApplyKeepsEverythingElse`:
    - `apply(fixture, {name='Новий'})`, encoded and decoded again, has `name == 'Новий'`, `design.theme == 'light'`, `storage_to_date == json.null`, and a raw string containing `"cover":{}` and `"extra_unknown":{"k":[]}`.
    - The fixture table isn't modified.
  - `testApplyStartsFromFreshObject`:
    - The baseline says `allow_download=false`. The fresh object says `true`. Only `name` changed.
    - The result has `allow_download == true`.

- [ ] **Step 2: Run them.** Expected: ERROR `module 'GallerySettings' not found`.
- [ ] **Step 3: Implement.** `apply` deep-copies `fresh`, keeping the dkjson metatables so `{}` stays an object, then sets the changed keys.
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: Commit.** Message: `feat: GallerySettings field map, diff and merge`.

---

### Task 5: GalleryLookup

**Files:**
- Create: `gallera.lrdevplugin/GalleryLookup.lua`
- Test: `spec/gallery_lookup_test.lua`

**Interfaces:**
- Consumes: `api:listGalleries()` and `api:listTrashedGalleries()` (Tasks 2–3; the tests use a stub table).
- Produces:
  - `GalleryLookup.index(activeList, trashedList) -> function(id) -> { state = 'active'|'trashed'|'gone', slug = string|nil, summary = table|nil }`
  - `GalleryLookup.find(api, galleryId) -> result | nil, err`
  - Ids are compared as numbers: `tonumber(remoteId)`.

- [ ] **Step 1: Write the failing tests** (`TestGalleryLookup`):
  - `testActive`: id 1 is in the active list (slug `'a'`). The result is `{state='active', slug='a'}`, and `listTrashedGalleries` isn't called.
  - `testTrashed`: id 2 is only in the trash. The result is `{state='trashed', slug='t'}`.
  - `testGone`: the id is in neither list. The result is `{state='gone'}`.
  - `testChangedSlugUsesCurrentSlug`: the stored id `'1'` (a string, as `remoteId` stores it) is listed with slug `'renamed'`. The result's slug is `'renamed'`.
  - `testErrorsPassThrough`: `listGalleries` returns `nil, {kind='auth'}`, so `find` returns `nil, {kind='auth'}`.
- [ ] **Step 2: Run them.** Expected: ERROR module not found.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: Commit.** Message: `feat: GalleryLookup id -> state and current slug`.

---

### Task 6: PhotoOrder

**Files:**
- Create: `gallera.lrdevplugin/PhotoOrder.lua`
- Test: `spec/photo_order_test.lua`

**Interfaces:**
- Produces: `PhotoOrder.compute{ galleryPhotoIds = {ids}, captureTimes = {[id] = number|false} } -> ids[]`. A key that is present means "uploaded by the plugin". The value `false` means the photo has no capture time.

- [ ] **Step 1: Write the failing tests** (`TestPhotoOrder`):
  - `testCaptureOrderFirst`:
    - Gallery order `{10, 11, 12}`, times `{[10]=300, [11]=100, [12]=200}`.
    - Result `{11, 12, 10}`.
  - `testTiesByRemoteId`: times `{[20]=5, [19]=5}`, result `{19, 20}`.
  - `testNoCaptureTimeKeepsGalleryOrderAfterTimed`:
    - Gallery `{1, 2, 3}`, times `{[1]=false, [2]=9, [3]=false}`.
    - Result `{2, 1, 3}`.
  - `testForeignPhotosLastInGalleryOrder`:
    - Gallery `{7, 5, 6}`, times `{[6]=1}`.
    - Result `{6, 7, 5}`.
  - `testCompleteList`: the output length equals the input length, with no duplicates.
- [ ] **Step 2: Run them.** Expected: ERROR. **Step 3: Implement.** **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: PhotoOrder capture-date order`.

---

### Task 7: Fingerprint

**Files:**
- Create: `gallera.lrdevplugin/Fingerprint.lua`
- Test: `spec/fingerprint_test.lua`

**Interfaces:**
- Produces:
  - `Fingerprint.of{ develop = table, orientation = string|nil, render = table } -> string` (16 lowercase hex characters).
  - `Fingerprint.RENDER_KEYS`: `{ 'LR_size_doConstrain', 'LR_size_resizeType', 'LR_size_maxWidth', 'LR_size_maxHeight', 'LR_size_units', 'LR_size_resolution', 'LR_size_doNotEnlarge', 'LR_jpeg_quality', 'LR_export_colorSpace', 'LR_outputSharpeningOn', 'LR_outputSharpeningMedia', 'LR_outputSharpeningLevel', 'LR_useWatermark', 'LR_watermarking_id' }`
  - `Fingerprint.EXCLUDED_DEVELOP_KEYS`: a set, empty for now. Task 15 fills it.

- [ ] **Step 1: Write the failing tests** (`TestFingerprint`):
  - `testOrderIndependent`: two tables with the same nested content, built in different insertion orders, give equal fingerprints.
  - `testDevelopChangeChanges`: `Exposure2012 = 0.5` vs `0.6` gives different fingerprints.
  - `testOrientationAndRenderChange`: `orientation 'AB'` vs `'BC'` differ, and `render.LR_jpeg_quality 0.8` vs `0.9` differ.
  - `testFloatNoiseIgnored`: `0.1 + 0.2` vs `0.3` give equal fingerprints (rounded to 6 significant digits).
  - `testExcludedKeysIgnored`: with `EXCLUDED_DEVELOP_KEYS.Noise = true`, a change to `develop.Noise` doesn't change the fingerprint. Restore the set afterwards.
  - `testFormat`: the result matches `^%x+$` and has length 16.
- [ ] **Step 2: Run them.** Expected: ERROR.
- [ ] **Step 3: Implement.**
  - Serialize canonically, with sorted keys and type tags, and numbers formatted `%.6g`.
  - Then compute two 32-bit rolling hashes with plain arithmetic, e.g. `h = (h * 31 + byte) % 4294967296` and `h2 = (h2 * 131 + byte) % 4294967296`. Both stay exact in doubles.
  - Output `string.format('%08x%08x', h, h2)`.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Fingerprint of the inputs that shape the pixels`.

---

### Task 8: Names (deleted marker, safe folder, JPEG names)

**Files:**
- Create: `gallera.lrdevplugin/Names.lua`
- Test: `spec/names_test.lua`

**Interfaces:**
- Produces:
  - `Names.DELETED_SUFFIX = ' - (deleted)'`
  - `Names.markDeleted(name) -> name`, idempotent
  - `Names.stripDeleted(name) -> name`
  - `Names.safeFolder(name) -> name`
  - `Names.jpegTarget(jpegFiles, photoKey, leafName, exists) -> leafName`, where `exists(leaf) -> bool` tells whether that file exists in the target folder

- [ ] **Step 1: Write the failing tests** (`TestNames`):
  - `testMarkIsIdempotent`: `markDeleted('A')` is `'A - (deleted)'`, and marking that again gives the same string. `stripDeleted('A - (deleted)')` is `'A'`.
  - `testSafeFolder` (Review Focus 4):
    - `'a<b>c:d"e/f\\g|h?i*j'` becomes `'a_b_c_d_e_f_g_h_i_j'`.
    - `'Wedding. '` becomes `'Wedding'`.
    - `'CON'` becomes `'_CON'` and `'nul.txt'` becomes `'_nul.txt'`.
    - `''` becomes `'_'`.
    - `'Весілля Олени'` stays unchanged.
  - `testJpegTargetOwnFileIsOverwritten`: `jpegFiles = {k1='DSC_1.jpg'}` and the file exists. `jpegTarget(jpegFiles, 'k1', 'DSC_1.jpg', exists)` returns `'DSC_1.jpg'`.
  - `testJpegTargetOtherPhotoGetsSuffix`:
    - `jpegFiles = {k1='DSC_1.jpg'}`. `jpegTarget(jpegFiles, 'k2', 'DSC_1.jpg', exists)` returns `'DSC_1-2.jpg'`.
    - If `'DSC_1-2.jpg'` also exists and belongs to nobody, the result is `'DSC_1-3.jpg'`.
  - `testJpegTargetFreeName`: no map entry and no file, so the name is unchanged.
- [ ] **Step 2: Run them.** Expected: ERROR. **Step 3: Implement.** **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Names for deleted marker, folders and kept JPEGs`.

---

### Task 9: FavoritesSync

**Files:**
- Create: `gallera.lrdevplugin/FavoritesSync.lua`
- Test: `spec/favorites_sync_test.lua`

**Interfaces:**
- Produces:
  - `FavoritesSync.summarize(lists, photos)` and `FavoritesSync.plan{ lists, choices, photos }` with exactly the shapes in DESIGN.md §5.2.
  - `FavoritesSync.displayTitle(title) -> string`: `'(untitled)'` for nil, `''` or a title starting with `http`.
  - `FavoritesSync.changedLists(lists, seen) -> lists[]` (D17): a list counts as changed if it's new, or if its `items_count` or `is_finished` differs.
  - `FavoritesSync.seenFrom(lists) -> {[listId] = {count, finished}}`.
  - `photos[remoteId].applied` is parsed by the caller from `"<listId>:<color>"`.

- [ ] **Step 1: Write the failing tests** (`TestFavoritesSync`). Use lists shaped like the doc example: id 85261 "vv" finished, `latest` ids {1, 2, 3}; id 85241, `latest` {2}.
  - `testSetOnEmptyLabel`: choice `{[85261]='red'}`, photo 1 with no label → `set` contains `{key='k1', color='red', listId=85261}`.
  - `testChangeOwnLabel`: photo 1 has label `'green'` with `applied = {85261, 'green'}` → set to `red`.
  - `testSameColorOnlyRecords`: label `'red'`, no `applied` → in `set` (the caller records `applied`, and the label doesn't visibly change).
  - `testOtherLabelSkipped`: label `'yellow'`, no `applied` → `skippedOtherLabel = {'k1'}`.
  - `testConflict`: 85261 is red and 85241 is blue. Photo 2 is in both → `conflicts = {'k2'}` and it isn't in `set`.
  - `testRemoveOnlyFromChosenListWhenStillOurColor`:
    - Photo 4 isn't in any list, with `applied = {85261, 'red'}` and label `'red'` → in `remove`.
    - With label `'blue'` → not removed.
  - `testSkippedListLeftAlone`: no choice for 85261, and photo 4 has `applied = {85261, 'red'}` → it's in neither `remove` nor `set`.
  - `testVanishedListLeftAlone`: `applied.listId = 999`, which isn't in the lists → untouched.
  - `testIncompleteList`: `items_count = 5` with 3 `latest` entries → `incompleteLists = {85261}`.
  - `testSummarize`: the rows are `{id, title, finished, count, matched}`. For the URL-titled list, `title` is `'(untitled)'`, and `matched` counts only the photos in `photos`.
  - `testChangedLists`: with `seen = {[85261]={count=3, finished=true}}`, only 85241 is returned. After `items_count` becomes 4, 85261 is returned too.
- [ ] **Step 2: Run them.** Expected: ERROR. **Step 3: Implement** the rules in DESIGN.md §5.2. **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: FavoritesSync plan for labels from client lists`.

---

### Task 10: Uploader (one photo, D25 retries)

**Files:**
- Create: `gallera.lrdevplugin/Uploader.lua`
- Test: `spec/uploader_test.lua`

**Interfaces:**
- Consumes: `api:requestUpload`, `api:putFile`, `api:confirmUpload` and `api:deletePhotos` (Task 3). The tests use a scripted stub api.
- Produces: `Uploader.upload(api, { galleryId, slug, filename, bytes, contentType = 'image/jpeg' }, sleep) -> photoId | nil, err`. `sleep(seconds)` is injected; in Lightroom it's `LrTasks.sleep`. `Uploader.WAITS = {2, 5}`.

- [ ] **Step 1: Write the failing tests** (`TestUploader`):
  - `testHappyPath`: the result is the `photoId` from `requestUpload`. Call order: requestUpload, putFile, confirmUpload. No sleeps.
  - `testPutFailureRetriesWithFreshUrl`:
    - The first `putFile` returns `nil, {kind='api', status=403}`, and the second succeeds.
    - `requestUpload` is called twice.
    - `deletePhotos(slug, {firstPhotoId})` is called once, as cleanup.
    - The sleeps are `{2}`.
  - `testNetworkThreeTimesFails`: every `putFile` returns `network`. The result is `nil, err` with `kind 'network'`. The sleeps are `{2, 5}`, `requestUpload` is called 3 times, and there are 3 cleanups.
  - `testAuthStopsImmediately` (Review Focus 1): `confirmUpload` returns `auth`. The result is `auth` after 1 attempt, with no sleep. Cleanup is attempted once.
  - `testApiErrorOnRequestNotRetried`: `requestUpload` returns `api`. The result is `api`, with 1 call and no sleep.
- [ ] **Step 2: Run them.** Expected: ERROR. **Step 3: Implement.** **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Uploader with D25 retries`.

---

### Task 11: PublishPlan (classify, estimate, deletes, favorites index)

**Files:**
- Create: `gallera.lrdevplugin/PublishPlan.lua`
- Test: `spec/publish_plan_test.lua`

**Interfaces:**
- Consumes: `FavoritesSync.displayTitle` (Task 9).
- Produces:
  - `PublishPlan.classify{ photos = { {key, remoteId=number|nil, fingerprint} }, fingerprints = {[key]=fp}, favoriteIndex = {[remoteId]={titles}} } -> { unchanged = {photo}, upload = {photo}, inFavorites = { {photo, titles} } }`
  - `PublishPlan.favoriteIndex(lists) -> {[photoId] = {displayTitles}}`
  - `PublishPlan.estimateBytes(count, galleryPhotos) -> number`. `PublishPlan.DEFAULT_PHOTO_BYTES = 8 * 1024 * 1024`.
  - `PublishPlan.confirmedDeletes(requestedIds, deletedIds, remainingIds) -> ids`

- [ ] **Step 1: Write the failing tests** (`TestPublishPlan`):
  - `testClassify`:
    - k1 is published with an equal fingerprint → `unchanged`.
    - k2 is published with a different fingerprint → `upload`.
    - k3 is new (no `remoteId`) → `upload`.
    - k4 is published with no stored fingerprint → `upload`.
  - `testInFavoritesOnlyForReuploads`: the index contains k2's `remoteId` and k1's. Only k2 is in `inFavorites`, with its titles.
  - `testFavoriteIndexUsesDisplayTitles`: a URL-titled list gives `'(untitled)'`.
  - `testEstimate`: `estimateBytes(3, { {filesize=10}, {filesize=20} })` is `45`, and `estimateBytes(2, {})` is `2 * 8 * 1024 * 1024`.
  - `testConfirmedDeletes` (Review Focus 5): requested `{1, 2, 3}`, Gallera confirmed `{1}`, remaining in the gallery `{2}`. The result is `{1, 3}`: 3 is already gone, and 2 still exists.
- [ ] **Step 2: Run them.** Expected: ERROR. **Step 3: Implement.** **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: PublishPlan classify, estimate, confirmed deletes`.

---

### Task 12: HTTP adapter, auth, service settings dialog (login/logout end to end)

**Files:**
- Create: `gallera.lrdevplugin/LrHttpAdapter.lua`, `gallera.lrdevplugin/Auth.lua`, `gallera.lrdevplugin/ServiceSettingsDialog.lua`
- Modify: `gallera.lrdevplugin/PublishServiceProvider.lua`, `gallera.lrdevplugin/Info.lua` (version 0.2.0)

**Interfaces:**
- Consumes: `GalleraApi.new` (Task 2) and its adapter contract.
- Produces:
  - `LrHttpAdapter.request(req)`:
    - `GET` uses `LrHttp.get`. `multipart` uses `LrHttp.postMultipart`. Everything else uses `LrHttp.post(url, body or '', headers, method, timeout)`, with a 300 s timeout for `PUT`.
    - It converts the header map to `{field, value}` and reads the status from `headers.status`.
    - When the body is nil, it returns `nil, headers.error.name`.
  - `Auth.token(email) -> string|nil`, `Auth.store(email, token)`, `Auth.clear(email)` (stores `''`)
  - `Auth.api(publishSettings) -> api | nil, err{kind='auth', message='Log in to Gallera in the service settings.'}`
  - `ServiceSettingsDialog.sectionsForTopOfDialog(f, propertyTable)`
  - `exportPresetFields`:
    - `{ key = 'email', default = '' }`
    - `{ key = 'username', default = '' }`
    - `{ key = 'jpegHandling', default = 'ask' }` (values `'ask'|'keep'|'remove'`)
    - `{ key = 'jpegFolder', default = LrPathUtils.child(LrPathUtils.getStandardFilePath('pictures'), 'Gallera') }`

- [ ] **Step 1: Implement** the three modules and wire `sectionsForTopOfDialog` and `exportPresetFields` into the provider.
  - Account section (§7.1):
    - Logged out: an email field and **Log in…**. Logged in: "Logged in as `<username>` · `<used>` / `<limit>` GB used", with **Log out**.
    - **Log in…** opens a modal with `password_field` and runs `api:login` in `LrFunctionContext.postAsyncTaskWithContext`. It clears the password property right after.
    - A Google-only account (`has_password == false`) gets the message "This Gallera account has no password. Set one on the website first."
  - **Uploaded JPEGs** section (D24): a popup with **Keep, ask to remove after publish** / **Always keep** / **Always remove after upload**, and a folder field with **Choose…** (`LrDialogs.runOpenPanel` with `canChooseDirectories = true`).
- [ ] **Step 2: Run all unit tests.** Expected: still all pass. Nothing in the core changed.
- [ ] **Step 3: Manual check (user, one step at a time, version 0.2.0).**
  1. Reload the plugin.
  2. Set up a Gallera service. Log in with a wrong password: Gallera's message is shown and nothing is stored.
  3. Log in correctly: the username and storage are shown.
  4. Reopen the settings: still logged in.
  5. Log out: back to logged out, and the log shows `auth/logout` 200.
  6. `Gallera.log` contains no token, password or email.
- [ ] **Step 4: Commit.** Message: `feat: login/logout in the publish service settings`.

---

### Task 13: Collection settings: create/link, Settings tab load and save

**Files:**
- Create: `gallera.lrdevplugin/CollectionStore.lua`, `gallera.lrdevplugin/CollectionSettingsDialog.lua`
- Modify: `gallera.lrdevplugin/PublishServiceProvider.lua`, `Info.lua` (0.3.0)

**Interfaces:**
- Consumes: `Auth.api`, `GalleryLookup.find`, `GallerySettings.*`, `api:listGalleryNames`, `api:createGallery`, `api:getGallery`, `api:saveGallery`.
- Produces:
  - `CollectionStore.read(collection) -> table` (`getCollectionInfoSummary().collectionSettings`, or `{}`)
  - `CollectionStore.update(collection, changes)`: merges the changes and calls `collection:setCollectionSettings(merged)` inside `withWriteAccessDo`.
  - Plugin-owned collection settings keys: `orderByCapture` (default `true`), `overrideRender` (default `false`), `longEdge`, `jpegQuality`, `folderId`, `deleted`, `jpegFiles`, `fingerprints`, `favoritesColors`, `favoritesSeen`.
  - Dialog-only keys are prefixed `g_` (the Gallera fields), `ui_` (status) and `link_` (mode and picked id). They're never read back as truth (D3).

- [ ] **Step 1: Implement `viewForCollectionSettings`** (§6.3, §7.2, S4 pattern):
  - Build the controls from `GallerySettings.FIELDS`. They start disabled, with "Loading from Gallera…".
  - An async task does `find` → `getGallery` → `toProps` and fills the `g_` keys. It keeps a baseline copy in a Lua upvalue and then enables the controls.
  - The password field is visible only when `g_has_password` is set.
  - `face_grouping_enabled` is disabled unless `face_grouping_available` is true.
  - For a collection without a `remoteId`: **Create new gallery** / **Link existing gallery** radio buttons. The link popup comes from `listGalleryNames`, minus the ids that are the `remoteId` of another collection of this service (D26).
  - For a linked collection: the gallery name, its `public_url`, and **Open in browser** (`LrHttp.openUrlInBrowser`).
  - Plugin settings: **Order by capture date**; **Override size and quality** with long edge and quality (0–100).
- [ ] **Step 2: Implement `updateCollectionSettings`** (§6.2, S3 findings):
  - Create: `createGallery{ name = info.name, date = os.date('%Y-%m-%d') }` → `getGallery` for the id.
  - Link: the picked id.
  - Then `setRemoteId(tostring(id))` and `setRemoteUrl(public_url)` inside `withWriteAccessDo`.
  - If the Settings fields changed: fresh `getGallery` → `apply` → `saveGallery`. On an `api` error, `LrDialogs.message` with Gallera's message.
  - On link only, an `LrTasks.startAsyncTask` that sleeps 1 s and then calls `setName(gallery.name)` (D26).
  - Save the plugin-owned settings with `CollectionStore.update`.
  - When a lookup's `public_url` differs from the stored `remoteUrl`, update it (§6.2).
- [ ] **Step 3: Run all unit tests.** Expected: pass.
- [ ] **Step 4: Manual check (user, 0.3.0, one step at a time).**
  1. Create a collection "Plugin test" with **Create new**: the gallery appears on the website with that name, and Edit Collection shows its URL.
  2. Create a collection with **Link existing** to the test gallery: after a moment the collection takes the gallery's name. The already linked gallery isn't offered in the picker.
  3. Edit Collection: the Settings fields fill in after "Loading…".
  4. Change Name, Download option and the password, then OK: the website shows the change, and the gallery's design is unchanged.
  5. Enter a slug that's already taken: Gallera's message is shown.
- [ ] **Step 5: Commit.** Message: `feat: create/link galleries and edit their settings`.

---

### Task 14: Publish — upload path, override, kept JPEGs

**Files:**
- Create: `gallera.lrdevplugin/Publish.lua`
- Modify: `gallera.lrdevplugin/PublishServiceProvider.lua` (`processRenderedPhotos = Publish.process`), `Info.lua` (0.4.0)

**Interfaces:**
- Consumes: `Auth.api`, `GalleryLookup.find`, `Uploader.upload`, `Names.safeFolder`, `Names.jpegTarget`, `CollectionStore.*`, `Fingerprint.of`, `Fingerprint.RENDER_KEYS`.
- Produces:
  - `Publish.process(functionContext, exportContext)`
  - `Publish.applyOverride(props, collectionSettings) -> saved`
  - `Publish.restoreOverride(props, saved)`
  - Prefs key `LrPrefs.prefsForPlugin().overrideBackup = { [serviceKey] = saved }`. `serviceKey = exportContext.publishService.localIdentifier`; if that field doesn't exist, use `exportContext.publishService:getName()` and log which one was used.

- [ ] **Step 1: Implement `Publish.process`** for §6.4 steps 1, 2, 5, 6, 7, 10 and 11. Classification and the storage check come in Task 15; until then, every rendition uploads.
  - **Auth / gallery:** if there's no api, fail all renditions with the auth message. If the gallery isn't `active`, fail them with "Gallery deleted". Task 18 adds the dialog.
  - **One publish per service at a time:** a module-level `busy[serviceKey]` flag. A second publish waits with `LrTasks.sleep(0.5)`.
  - **Override (D18):**
    - If `overrideBackup[serviceKey]` exists from a crash, restore it first and log a warning.
    - When `overrideRender` is set: save the 8 keys `LR_size_doConstrain/resizeType/maxWidth/maxHeight/units/doNotEnlarge`, `LR_jpeg_quality` and `LR_jpeg_useLimitSize` into prefs, then write `longEdge` and `jpegQuality / 100`.
    - Restore everything and clear prefs in every exit path. Wrap the loop in `LrTasks.pcall`.
  - **Per rendition:**
    - `waitForRender` → read the bytes → `Uploader.upload` (filename = the rendered leaf name; `sleep = LrTasks.sleep`).
    - If the error kind is `auth`, fail this and all remaining renditions with the auth message and stop.
    - On success: `recordPublishedPhotoId(tostring(photoId))`, `recordPublishedPhotoUrl(public_url)`, and store `fingerprints[key] = Fingerprint.of{ develop = photo:getDevelopSettings(), orientation = photo:getRawMetadata('orientation'), render = <RENDER_KEYS from props after the override> }`.
    - If `rendition.publishedPhotoId` was set, remember it as an old id.
  - **Kept JPEG (D24/D27):** the folder is `jpegFolder\Names.safeFolder(collectionName)`. Move the file there with `Names.jpegTarget`, deleting the target first when it's this photo's own file, and update `jpegFiles`. With `'remove'`, a successful upload deletes the file instead.
  - **After the loop:**
    - `deletePhotos(slug, oldIds)` for successful re-uploads (D6).
    - Summary dialog when something failed (§6.4 step 10).
    - With `'ask'`, the Keep/Remove question about the JPEGs uploaded in this publish (§6.4 step 11).
    - Save `jpegFiles` and `fingerprints` with `CollectionStore.update`.
- [ ] **Step 2: Run all unit tests.** Expected: pass.
- [ ] **Step 3: Manual check (user, 0.4.0, one step at a time).**
  1. Publish 3 photos: they appear in the test gallery, and the JPEGs are in `L:\Gallera\Plugin test\`.
  2. Turn on the override (1000 px, quality 50) and Mark to Republish one photo, then Publish: the new photo on the website is 1000 px, the old one is gone, and the service's Edit Settings still show its own values.
  3. Disconnect the network mid-publish: the photo is retried (see the log), then reported failed and still queued. Reconnect and publish: it uploads.
  4. Name a collection `a/b.` and publish: the folder `a_b` is created.
  5. Log out, then publish: the run stops with the login message at once.
- [ ] **Step 4: Commit.** Message: `feat: publish upload path with render override and kept JPEGs`.

---

### Task 15: Publish — unchanged photos (D30), favorites warning (D31), storage check (D23)

**Files:**
- Modify: `gallera.lrdevplugin/Publish.lua`, `gallera.lrdevplugin/Fingerprint.lua` (`EXCLUDED_DEVELOP_KEYS`), `Info.lua` (0.5.0), `docs/DESIGN.md` §12.2 (record the findings)

**Interfaces:**
- Consumes: `PublishPlan.classify`, `PublishPlan.favoriteIndex`, `PublishPlan.estimateBytes`, `api:getFavorites`, `api:getUser`, `api:listPhotos`.

- [ ] **Step 1: Find the noisy develop keys.**
  - Temporarily log `photo:getDevelopSettings()` and `getRawMetadata('orientation')` for one photo (version 0.5.0-pre, user step).
  - User: change the photo's title and star rating, then trigger the log. Then rotate the photo, then change its exposure.
  - Put every develop key that changed on the metadata-only edit into `Fingerprint.EXCLUDED_DEVELOP_KEYS`.
  - If `'orientation'` errors, use the raw key that actually works and record it in DESIGN.md §12.2.
- [ ] **Step 2: Implement classification** before the renditions loop (§6.4 step 4):
  - Photos come from `exportSession:photosToExport()`. Existing remote ids come from `publishedCollection:getPublishedPhotos()`, mapping `getPhoto().localIdentifier` to `tonumber(getRemoteId())`. Lightroom stores remote ids as strings, while Gallera's JSON ids are numbers.
  - Run `PublishPlan.classify`. Get the favorites only when some re-upload exists.
  - When `inFavorites` isn't empty, show the D31 dialog with the exact copy from DESIGN.md D31.
  - **Unchanged** photos: `skipRender()` at the start of their loop iteration, then `recordPublishedPhotoId(oldId)` and `recordPublishedPhotoUrl`. Nothing is uploaded or deleted.
  - **Skipped** photos: `skipRender()` and `uploadFailed('Skipped: in client favorites')`.
  - Then run the storage pre-check on the upload set only (D23): the exact dialog copy from §6.4 step 3, and the in-loop "Gallera storage full (used X of Y)" stop.
- [ ] **Step 3: Run all unit tests.** Expected: pass.
- [ ] **Step 4: Manual check (user, 0.5.0, one step at a time).**
  1. Give a published photo a red label and 3 stars, then Publish: no upload (the photo id on the website is unchanged), and the photo is back under Published.
  2. Change its exposure, then Publish: a new upload, and the old photo is gone.
  3. As the client on the website, favorite a photo. Change it in Lightroom and Publish: the D31 warning appears. **Skip these** leaves it queued. **Re-upload anyway** uploads it.
  4. Check whether unchanged photos were still rendered (log timing). Record in DESIGN.md §12.2 whether `skipRender` works; if it doesn't, the photo renders and the file is discarded.
- [ ] **Step 5: Commit.** Message: `feat: skip unchanged photos, warn before losing favorites, storage check`.

---

### Task 16: Remove photos, rename and delete collections

**Files:**
- Modify: `gallera.lrdevplugin/PublishServiceProvider.lua`, `Info.lua` (0.6.0)

**Interfaces:**
- Consumes: `GalleryLookup.find`, `api:deletePhotos`, `api:listPhotos`, `PublishPlan.confirmedDeletes`, `api:getGallery`, `api:saveGallery`, `api:trashGallery`, `Names.stripDeleted`, `CollectionStore`.

- [ ] **Step 1: Implement** `deletePhotosFromPublishedCollection(publishSettings, ids, deletedCallback, localCollectionId)`, `renamePublishedCollection(publishSettings, info)` and `deletePublishedCollection(publishSettings, info)` per §6.5–§6.7.
  - Find the collection for the delete with `catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)`. If that 4th parameter isn't passed, log it and find the collection through `getPublishServices`.
  - For the delete prompt use `LrDialogs.confirm('Delete the Gallera gallery too?', 'Move gallery to Gallera trash moves it to the trash on the website. Keep gallery leaves it on Gallera.', 'Move gallery to Gallera trash', 'Keep gallery')`.
- [ ] **Step 2: Manual check (user, 0.6.0, one step at a time).**
  1. Remove a photo from the collection and Publish: it's gone from the website.
  2. Delete a photo on the website, remove it in Lightroom, and Publish: the record disappears without an error.
  3. Rename the collection: the gallery is renamed on the website.
  4. Delete a collection and choose **Keep gallery**: the gallery stays.
  5. Delete another one and choose **Move gallery to Gallera trash**: the gallery is in the website's trash, not permanently deleted.
- [ ] **Step 3: Commit.** Message: `feat: remove photos, rename and delete collections`.

---

### Task 17: Order by capture date

**Files:**
- Modify: `gallera.lrdevplugin/Publish.lua`, `Info.lua` (0.7.0)

**Interfaces:**
- Consumes: `PhotoOrder.compute`, `api:listPhotos`, `api:sortPhotos`.

- [ ] **Step 1: Implement §6.4 step 8.** It runs after the uploads and deletes, only when `orderByCapture` is set.
  - `captureTimes` covers every published photo of this collection: the existing records plus the ids recorded in this run. Keys are `tonumber(remoteId)`, to match `listPhotos` ids.
  - The value is `photo:getRawMetadata('dateTimeOriginal')`, or `false`.
  - Then `sortPhotos(slug, ids, nil)`.
- [ ] **Step 2: Manual check (user, 0.7.0).**
  1. Publish photos in a shuffled order: the website shows them by capture time.
  2. Turn the checkbox off, add a photo, and Publish: the website's order isn't touched.
  3. Note whether the website's sort option now says "Manual". Record the result in DESIGN.md §12.2.
- [ ] **Step 3: Commit.** Message: `feat: order gallery by capture date`.

---

### Task 18: Deleted-gallery handling and startup check

**Files:**
- Create: `gallera.lrdevplugin/DeletedGallery.lua`
- Modify: `gallera.lrdevplugin/Init.lua`, `gallera.lrdevplugin/Publish.lua`, `gallera.lrdevplugin/CollectionSettingsDialog.lua`, `Info.lua` (0.8.0)

**Interfaces:**
- Consumes: `GalleryLookup.index`, `GalleryLookup.find`, `Names.markDeleted`, `Names.stripDeleted`, `CollectionStore`, `api:restoreGallery`, `api:createGallery`.
- Produces:
  - `DeletedGallery.mark(collection, state)`, `DeletedGallery.unmark(collection)`
  - `DeletedGallery.prompt(state) -> 'restore'|'createNew'|'cancel'`
  - `DeletedGallery.handle(collection, api, state) -> 'continue'|'cancel'` (runs the D11 flow)

- [ ] **Step 1: Implement §6.9.**
  - Use the D11 dialog copy exactly. The **Restore** text warns that photos deleted from the gallery may come back.
  - **Create new:** mark every published photo as edited with `setEditedFlag(true)` inside `withWriteAccessDo`, and clear `fingerprints` so they really upload.
  - Wire the flow into Publish (step 2), the collection settings load (§6.3) and, later, favorites.
- [ ] **Step 2: Implement the startup check** in `Init.lua`:
  - A module-level `running` flag makes a second run return at once.
  - For each service of this plugin with a token: `listGalleries` and `listTrashedGalleries` once, then `GalleryLookup.index`.
  - Mark or unmark every collection with a `remoteId`.
  - Errors are only logged.
- [ ] **Step 3: Manual check (user, 0.8.0, one step at a time).**
  1. Trash the test gallery on the website and restart Lightroom: the collection shows " - (deleted)".
  2. Restore it on the website and restart: the name is back.
  3. Trash it again and Publish: the dialog offers Restore / Create new / Cancel. Try each in turn (Cancel leaves it marked; Restore continues; Create new makes a gallery and uploads everything).
- [ ] **Step 4: Commit.** Message: `feat: deleted-gallery detection, dialog and startup check`.

---

### Task 19: Client favorites → color labels

**Files:**
- Create: `gallera.lrdevplugin/FavoritesDialog.lua`, `gallera.lrdevplugin/FavoritesCommand.lua`
- Modify: `gallera.lrdevplugin/Info.lua` (`LrLibraryMenuItems = { { title = 'Gallera client favorites...', file = 'FavoritesCommand.lua' } }`, 0.9.0), `gallera.lrdevplugin/Publish.lua` (D17 prompt), `gallera.lrdevplugin/CollectionSettingsDialog.lua` (**Client favorites…** button)

**Interfaces:**
- Consumes: `FavoritesSync.*`, `api:getFavorites`, `api:listPhotos`, `CollectionStore`, `DeletedGallery.handle`.
- Produces: `FavoritesDialog.run(collection)`. It's used by the menu item, the settings button and the post-publish prompt.

- [ ] **Step 1: Implement §6.8 and §7.3.**
  - Rows come from `summarize`. The popups are pre-filled from `favoritesColors`, and new lists start at Skip.
  - For incomplete lists, fall back to matching `lightroom_list` against `original_filename` without its extension. Ambiguous names are reported and get no label.
  - **Apply:**
    1. Note the published photos whose `getEditedFlag()` is false.
    2. Write the labels inside `withWriteAccessDo`: `setRawMetadata('colorNameForLabel', color)`, and `setPropertyForPlugin(_PLUGIN, 'galleraLabelApplied', listId .. ':' .. color)`. To remove a label, try `'none'`, then `''`. Record which one works in DESIGN.md §12.2.
    3. Poll for up to 10 s, then call `setEditedFlag(false)` on the noted photos that are now flagged (S7b).
    4. Save `favoritesColors` and `favoritesSeen`, and show the counts.
  - `FavoritesCommand` finds the selected published collection of this service through `catalog:getActiveSources()`, or tells the user to select one.
  - **D17:** at the end of Publish, if `FavoritesSync.changedLists` isn't empty, ask "Client favorites changed (list '<title>'…). Review now?" with Yes/No.
- [ ] **Step 2: Run all unit tests.** Expected: pass.
- [ ] **Step 3: Manual check (user, 0.9.0, one step at a time).**
  1. As the client, make 2 lists on the website and Publish: the "Review now?" prompt appears.
  2. Choose red and blue for the lists: the labels are set, and the photos stay under Published.
  3. Un-favorite a photo on the website and apply again: its red label is removed.
  4. Give a photo your own yellow label and apply: it's kept and reported as skipped.
  5. Set a list to Skip: nothing changes.
  6. Cancel: nothing changes.
  7. Restart Lightroom: the photos are still under Published. Record this in DESIGN.md §12.2.
- [ ] **Step 4: Commit.** Message: `feat: client favorites to color labels`.

---

### Task 20: Manual test pass and cleanup

**Files:**
- Create: `docs/manual-tests.md`
- Modify: `docs/gallera-api.md`, `docs/DESIGN.md` (§12, status), `Info.lua` (1.0.0)
- Delete: `spikes/`

- [ ] **Step 1: Write `docs/manual-tests.md`** from DESIGN.md §9.3. Add the manual checks from Tasks 12–19 as one checklist, with the expected result for each step.
- [ ] **Step 2: User runs the full checklist** on version 1.0.0, one step at a time. Fix what fails, adding a unit test first where the cause is in a core module.
- [ ] **Step 3: Update the docs.** Add the Gallera facts learned during implementation to `docs/gallera-api.md`: the trashed-list shape, any 422 error shape, and the effect of `photos/sort` on `order_by`. Close the answered rows in DESIGN.md §12.2, and set the status to "Implemented (PoC)".
- [ ] **Step 4: Delete `spikes/`**. Its findings live in DESIGN.md §12.1. The user removes the spike publish service in Lightroom.
- [ ] **Step 5: Commit.** Message: `docs: manual test checklist; remove spike plugin`.

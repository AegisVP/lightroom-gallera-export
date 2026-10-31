# Gallera private API (reverse-engineered)

Gallera has no public API. This document comes from HAR captures of the app.gallera.io web UI made on 2026-10-30. The API can change without notice, so keep every call in a single Lua module.

## Basics

- Base URL: `https://api.gallera.io/api/`
- Request headers: `Accept: application/json`, `X-Requested-With: XMLHttpRequest`, `Authorization: Bearer <token>`, and `Content-Type: application/json` for JSON bodies.
- Every response is wrapped: `{"status": "success", "message": "...", "data": ..., "count"?: n}`. Check `status`, not only the HTTP code.
- Errors use the same wrapper. The backend is Laravel. Captured so far:
  - HTTP 404, `{"status": "notFound", "message": "No query results for model [App\\Models\\Gallery].", "data": {"message": ...}}`.
  - HTTP **403**, `{"status": "auth", "message": "Unauthenticated."}` for a revoked or invalid token (seen from the Lightroom spikes, 2026-10-30). Not 401.
  - 422 (validation) hasn't been captured yet.
- `message` is **localized** to the account's language (e.g. login success came back as "Авторизація успішна"). Branch on `status` and the HTTP code, never on `message`.
- Galleries have two identifiers:
  - `id` (numeric, never changes)
  - `slug` (used in most URLs). **The user can change the slug at any time** (observed: `new-gallery` → `new-gallery2`). Store `id` and look up the current `slug` before any slug-based call.

## Auth

`POST auth/login`
```json
{"email": "...", "password": "..."}
```
→ `data.token`, `data.user` (`id`, `username`, `storage.used`/`storage.limit` in bytes, `subscription_type`, `google_id`, `has_password`).

- The token looks like a Laravel Sanctum token (`<id>|<secret>`). No expiry was observed. If any call returns `status: "auth"` (HTTP 403, possibly 401), log in again.
- `POST auth/logout` (no body) revokes the token.
- `GET user` returns the same user object (useful for validating a stored token).
- Accounts created through Google sign-in may have `has_password: false`, and email/password login won't work for them.

## Galleries

### List
- `GET v2/galleries/my?page=1&sort=created&search=` → `data.galleries[]` (`id`, `name`, `slug`, `date`, `photos_count`, `is_public`, `has_password`, `allow_download`, `storage_to_date`, …), `data.pagination` (`current_page`, `last_page`, `has_more`, `total`). **Use this one to resolve id → slug.**
- `GET galleries/list` → `data[]` with only `{id, name, small_cover_url}`. No slug, but cheap. Good for a picker.
- `GET galleries/my/deleted` → galleries in the trash.

### Create
`POST galleries/create`
```json
{"name": "My gallery", "date": "2026-10-30", "storage_period": "0", "copy_gallery_id": null}
```
→ `data.gallery` = the new **slug** (no id). Call `GET galleries/{slug}` to get the id. The meaning of `storage_period` is unconfirmed; the UI sent `"0"`.

### Read / update settings
- `GET galleries/{slug}` → the full gallery object.
- `POST galleries/{slug}` with the **full gallery object** (the UI sends back everything it got from GET, with changed fields). Do read-modify-write. → `data.slug`, which may differ from the URL if the slug was changed.

Fields seen changing in the settings UI:

| Field | Type / notes |
|---|---|
| `name` | string. Renaming does not change the slug |
| `slug` | string. Editable, and becomes the public URL path |
| `date` | `YYYY-MM-DD` |
| `language` | e.g. `en` |
| `is_public` | bool |
| `has_password`, `password` | bool + plain-text gallery password |
| `allow_download` | bool |
| `allow_favorite`, `allow_limit_favorites`, `limit_favorites`, `is_need_to_finish_favorites` | client favorites |
| `allow_caption`, `allow_list_view`, `allow_all_photos`, `allow_empty_folders`, `allow_tutorial`, `autoplay_video`, `top_button_enabled` | bools |
| `allow_photo_hiding`, `photo_hiding_client_email` | client photo hiding |
| `storage_to_date` | `YYYY-MM-DD`, the gallery expiry (free plan: about 30 days) |
| `order_by` | Sort options in the UI: Filename (a-z), Filename (z-a), Uploading date, Shuffle, Manual. Only one API value has been seen: `oldest` (probably Uploading date). There's no "capture date" option |
| `design` | object: `theme`, `layout`, `padding`, `cover_type`, title/subtitle fonts, colors, sizes, positions (desktop + `_mobile` variants) |
| `cover` | object: `url`, `position {x, y}`, `uploaded` |

Read-only fields of interest: `id`, `public_url` (e.g. `https://<username>.gallera.io/<slug>`), `public_url_with_token`, `frame_url`, `photos_count`, `storage_used`, `favorites_count`.

⚠️ The gallery object contains the gallery `password` and an access token in `public_url_with_token`. Never log it whole.

### Delete / restore
- `DELETE galleries/{slug}/delete` (no body) does two different things depending on state:
  - On an active gallery → `"Gallery moved to deleted list."` A soft delete into the trash; the gallery keeps its `id` and `slug`.
  - On a gallery **already in the trash** → `"Gallery deleted."` A permanent delete. There's no separate endpoint, so calling delete twice in a row destroys the gallery.
- `POST galleries/{slug}/restore` (no body) → success, and the gallery is back in `v2/galleries/my`.
- Trashed galleries **don't appear** in `v2/galleries/my`, only in `galleries/my/deleted`. If a stored id isn't found in the main list, check the trash before treating the gallery as gone.
- Other slug-based calls on a trashed gallery fail (e.g. `GET galleries/{slug}/stats` → 404 `notFound`).
- There's no "empty trash" for all galleries at once. Trashed galleries that aren't permanently deleted are removed with their photos **7 days** after deletion (per the user, not seen in traffic).

### Other
- `GET galleries/{slug}/stats` → `views_count`, `downloads_count`, `shares_count`, …
- `GET galleries/{slug}/folders` → folders in the gallery (not explored).

## Photos

### Upload (3 steps)

1. `POST photos/upload/url`, **multipart/form-data**:
   - `gallery` = numeric gallery **id**
   - `filename` = original file name
   - `filesize` = bytes
   - `filetype` = MIME type, e.g. `image/jpeg`

   → `data.url` (a pre-signed Cloudflare R2 URL, **expires in 20 min**) and `data.photo` (with `id`; this is the remote photo ID to record).
2. `PUT <data.url>` with the raw file bytes as the body and `Content-Type: <filetype>`. **Do not send the `Authorization` header** to R2. → 200 with an empty body.
3. `POST photos/upload/{id}/uploaded` with `{"photo": <id>}` → success.

Optional: poll `POST photos/processed` with `{"photo_ids": [ids]}`. It returns photos whose processing has finished (`is_compressing: false`, with `preview_url`, `image_url` filled in). It returns an empty `data` while they are still processing. An 11 MB JPEG took about 5 s.

Verified from Lightroom (`LrHttp`, Windows) on 2026-10-30: the PUT works with the body as one string or as a chunked function body; 11.3 MB took 2.3 s. After processing, the photo's `filesize` equals the uploaded byte count. That's the check that the upload is complete.

The web UI also calls `POST analytics/uploading`. That call isn't needed.

### List
`GET photos/{slug}` → `data[]` photo objects: `id`, `original_filename`, `filesize`, `preview_mini_url`, `preview_url`, `image_url`, `is_compressing`, `is_hidden_by_client`, `order_number`, `gallery_id`, `deleted_at`.

- `filesize` is the size of the uploaded original.
- `image_url` is **not** the original: it's a re-encoded display copy, at most 1920 px on the long edge, about JPEG quality 90 (a 6048 px, 11 MB upload came back as 1920 px, 493 KB). No URL for the original has been seen.

### Delete
`POST photos/delete`
```json
{"gallery": "<slug>", "photos": [140349250]}
```
→ `data` = the deleted ids. It appears to be a soft delete (the gallery's `deleted_count` goes up).

### Sort (manual order)
`POST photos/sort`
```json
{"sorted": [140349250, 140349246, 140349889, 140349890, 140349891, 140349895],
 "gallery": "<slug>", "folder": null, "type": "manual"}
```
→ `data` echoes the request.

- `sorted` is the **complete** list of photo ids in the new order. The UI sends every photo even when only two swapped places. Send all photos, including ones the plugin didn't upload.
- `type: "manual"` matches the "Manual" sort option. Presumably this also switches the gallery's `order_by` to manual (unverified).
- `folder` is `null` for the whole gallery. It is presumably a scene (folder) id when sorting within a scene, which is relevant once scenes are supported.

### Replace
**Not supported.** Re-publishing a photo means delete + upload, which gives it a new id, and any client favorites on the old one are lost.

## Client favorites

`GET galleries/{slug}/favorites` → `data[]`, one entry per client favorites list (a gallery can have several):

| Field | Notes |
|---|---|
| `id`, `slug` | List id; slug is `<id>-<slugified title>` |
| `title` | Name the client gave the list. Defaults to the gallery's public URL if they didn't name it |
| `is_finished` | `true` once the client pressed "Finish selection" |
| `items_count` | Number of photos in the list |
| `latest[]` | Full photo objects (`id`, `original_filename`, …). Match these `id`s against recorded remote photo ids |
| `lightroom_list[]` | `original_filename` values **without extension** (Gallera's "copy for Lightroom" text) |
| `public_url` | Client-facing URL of the list |
| `created_at_formatted`, `updated_at_formatted` | Localized relative time strings ("3 seconds ago"); not machine-readable |

Example (one finished list, one unfinished):
```json
{"id": 85261, "title": "vv", "is_finished": true, "items_count": 3,
 "lightroom_list": ["vlad1", "vlad2", "Screenshot 2025-06-09 at 20.49.13"],
 "latest": [{"id": 140349250, ...}, {"id": 140349246, ...}, {"id": 140349890, ...}]}
{"id": 85241, "title": "https://<username>.gallera.io/<slug>", "is_finished": false, "items_count": 1,
 "lightroom_list": ["vlad2"], "latest": [{"id": 140349246, ...}]}
```

- `latest` is **not** always complete: a list with `items_count` 6 returned 4 photos in `latest` and 5 names in `lightroom_list` (2026-10-31, from Lightroom). If `#latest < items_count`, don't trust `latest` alone: also match `lightroom_list` against `original_filename` from `GET photos/{slug}` (ambiguous when two photos have the same name). After a favorited photo is deleted, the list appears to keep counting it.
- Observed side effect: a photo deleted with `photos/delete` (140349250) came back after its gallery was trashed and restored (`updated_at` = restore time, `deleted_at: null`). Restoring a gallery appears to restore photos deleted from it too.

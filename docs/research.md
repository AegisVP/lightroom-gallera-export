# Research: Photoshop edits in a published collection

Status: research only, nothing implemented (2026-11-06).

## The workflow

Some photos need Photoshop. Today the user exports the RAW as a JPEG, edits it in Photoshop and uploads the JPEG to Gallera by hand. That bypasses the published collection, so the gallery can no longer be managed from Lightroom.

Lightroom's own round trip removes the manual steps:

1. In the published collection, **Photo > Edit In > Edit in Adobe Photoshop** (Ctrl+E) on the RAW.
2. Edit in Photoshop and save with **Ctrl+S** (not Save As). Lightroom imports the saved file as `<name>-Edit.tif` (or `.psd`, per Preferences > External Editing), stacked with the RAW.
3. **Publish.** The plugin renders the JPEG from the edited file like any other photo.

Seen by the user (2026-11-06):

- Editing from **inside** the published collection adds the `-Edit` copy to that collection, under **New Photos to Publish**.
- The **original stays** in the collection, so a publish would upload both.
- Editing from outside the collection (e.g. All Photographs) doesn't add the copy to the collection.

## Proposals

### R1. Setting: publish the edited copy instead of the original

A new setting, **Photoshop edits**: *Publish both* / *Replace the original with the edited copy*.

When it's on, at publish:

- An **original** is a photo in the collection that has an **edited copy** in the same collection.
- An edited copy matches `<original base name>-Edit` or `-Edit-<n>` with a `.tif`, `.tiff`, `.psd` or `.psb` extension, in the original's folder. If it works, the photo's stack (`getRawMetadata` stack keys) confirms the match.
- The original is removed from the collection and isn't uploaded. If it was published before, its Gallera photo is deleted. Client favorites on it are lost because Gallera can't replace a photo, so the client-favorites rule applies (see open questions).
- The edited copy is published with the stripped name (R2).

### R2. Strip `-Edit` from the uploaded name

This is part of the R1 setting (on when R1 is on). The uploaded `filename`, and the kept JPEG's name (D27), drop the `-Edit` suffix:

- `IMG_1234-Edit.tif` → `IMG_1234.jpg`
- `IMG_1234-Edit-2.tif` → `IMG_1234-2.jpg`

Clients then see the same name as the original on Gallera (Filename caption, the favorites "copy for Lightroom" list). Favorites sync matches by recorded photo id first, so the stripped name is safe. The name fallback (`lightroom_list` vs `original_filename`) uses the uploaded name, which is the stripped one. A kept JPEG name that's already taken gets D27's `-2`, `-3`, … suffix as usual.

This can be pure logic in `Names` (unit-testable).

### R3. Count a Photoshop re-save as a picture change

The D30 fingerprint covers develop settings, orientation and render settings, not the file. A TIFF/PSD re-saved in Photoshop has new pixels but the same fingerprint. So in the client-favorites dialog it shows as unchanged, and **Select changed** skips it. If it's left unchecked, the old Gallera photo is kept and recorded as published, and the edit never reaches Gallera.

Fix: for TIFF/PSD sources, add the file's size and modification time to the fingerprint inputs. Not for RAW (never changes), and not for JPEG/DNG (Lightroom can rewrite them when it saves metadata to the file, which would give false "changed" marks).

Changing the fingerprint inputs makes every stored TIFF/PSD fingerprint differ once. The only effect is a one-time "Picture changed" mark on queued TIFF/PSD photos that are in client favorites.

## Open questions

1. **Does a Photoshop re-save of a published `-Edit` photo queue it** under Modified Photos to Re-Publish? (To test; postponed by the user.) If not, the user marks it with Mark to Re-publish. R3 matters either way, once it's queued.
2. **Scope of the setting:** a service setting with a per-collection override (like Uploaded JPEGs, D24), or per collection only?
3. **Default:** on or off?
4. **Original in client favorites:** removing it deletes the Gallera photo and the client's selection on it. Options: ask in the D30 dialog, keep both and report, or always replace.
5. **Several edits of one original** (`-Edit`, `-Edit-2` both in the collection): publish all edits (names `IMG_1234`, `IMG_1234-2`), or only the newest?
6. **Removing a photo from the collection during a publish:** a spike is needed. Can `collection:removePhotos` run inside `processRenderedPhotos`? Does Lightroom then call `deletePhotosFromPublishedCollection` in the same publish or the next one? If the plugin deletes the Gallera photo itself, Lightroom must not try again with an id that no longer exists. Gallera accepts an already deleted id from the same gallery (docs/gallera-api.md), so a second delete would be harmless.
7. **Stack keys:** which `getRawMetadata` stack fields are reliable (`isInStackInFolder`, `stackInFolderMembers`, `topOfStackInFolderContainingPhoto`)? Spike, or use name matching only.

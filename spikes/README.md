# Spike plugin (throwaway)

`gallera-spike.lrdevplugin` answers the yes/no questions S1–S7 in `docs/DESIGN.md` §9.1. It isn't the real plugin, and none of its code is meant to be reused as-is.

Every result appears in a dialog and is also written to `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\GalleraSpike.log`. The log never contains the token, password or signed URLs.

The menu items are under **File > Plug-in Extras** (any module) and **Library > Plug-in Extras** (Library module only). JPEG copies go to `<Pictures>\GalleraSpike\`. On this machine Pictures is redirected to `L:\`.

## Setup

1. Lightroom: **File > Plug-in Manager > Add**, choose `spikes\gallera-spike.lrdevplugin`.
   - If Lightroom asks to update the catalog for the plugin's metadata, accept. That's the hidden field for S6/S7.
   - If loading from `Z:` fails, copy the folder to `C:` and add it from there.
2. **File > Plug-in Extras > Gallera spike: log in...** with your Gallera email and password. Only the token is stored.
3. On the website, create a **test gallery** (for S2). Never use a client gallery.
4. In the **Publish Services** panel, set up **Gallera spike**. The defaults are fine. This creates a collection called "Spike".

## Runs

Do them in this order, because S6/S7 need photos that were already published in S1.

### S4: async fill of the collection dialog
Right-click the "Spike" collection > **Edit Collection...**
- **Pass:** "Loading from Gallera..." changes to "Loaded: HTTP 200" after about 2 s, and the username field fills in and becomes enabled.

### S1: per-collection size and quality
The variant is chosen per collection in **Edit Collection...**. Publishing without opening that dialog always uses "No override". A handful of photos is enough. Every variant re-renders them all.

1. Add 3 photos to "Spike". In **Edit Collection...**, set the S1 variant to **No override**, then **Publish**. The dialog shows the size and quality from the service settings. This is the baseline.
2. Edit the collection: variant **A**, long edge `1000`, quality `50`. Select the photos, right-click > **Mark to Republish**, then **Publish**.
3. Same again with variant **B**.
- **Pass** for a variant: its dialog shows `1000` px on the long edge and a quality clearly different from the baseline, and the photos end up under **Published Photos**.
- After variant A, also open the service's **Edit Settings...** and check that Image Sizing still shows your own values. A changes the settings temporarily and restores them.
- Copies of the JPEGs are in `Pictures\GalleraSpike\S1\` if you want to look at them.

### S3: HTTP + setRemoteId/setName from the collection dialog
1. Create a new collection in the service (right-click the service > **Create Published Collection...**). Name it "S3 new" and tick the **S3** checkbox in the dialog, then OK.
2. Edit an existing collection, tick **S3**, then OK.
- **Pass:** the result dialog says the HTTP call and all three writes are OK, and the collection is renamed with " (S3)".
- The dialog also says whether this only worked from a background task after the dialog closed. That's useful to know either way.

### S5: startup background task
1. Create a published collection named **S5 test**.
2. **Plug-in Manager > Reload Plug-in**. The name should change to "S5 test - (deleted)".
3. Quit and restart Lightroom. It should change back. Lightroom must stay responsive during startup.
- **Pass:** both renames happen, and the log shows `S5 done: ok= true`.

### S6: color label by color
Select some photos, then **File > Plug-in Extras > Gallera spike S6/S7: set color label...**
1. Method `colorNameForLabel`, color **red**. Check that the photos get a red label.
2. Switch **Metadata > Color Label Set** to another set (for example *Review Status*), or rename the colors under **Edit...**. Run again with **green**.
3. Try method `label` once with both label sets, and color **none** to clear the label.
- **Pass:** `colorNameForLabel` sets the right color with both label sets.

### S7: labels must not trigger re-publish
Use photos that were published in S1 and show under **Published Photos**:
1. Run S6 on them (method `colorNameForLabel`, hidden field ticked).
2. Set a label by hand (key 6–9).
3. Run S6 with method **hidden field only**.
- **Pass:** after each step the photos stay under **Published Photos** and don't move to **Modified Photos to Re-Publish**.
- For comparison, change the title or caption: that **should** move them.

### S2: binary PUT to R2
**File > Plug-in Extras > Gallera spike S2: upload a JPEG...**. Choose a big JPEG (10+ MB) and your test gallery. Run it twice, once with each **PUT body** mode.
- **Pass:** steps 1–3 are OK, Gallera's file size MATCHes, and the downloaded image is BYTE-IDENTICAL. If Gallera re-encodes the image, a matching file size plus a correct-looking image in `Pictures\GalleraSpike\S2\` also counts.
- At the end you can delete the test photo.

## Afterwards

Tell me when you're done. I'll read `GalleraSpike.log`, record the results in DESIGN.md §12, and adjust the design where a spike failed. You can then remove the plugin in the Plug-in Manager and delete the "Gallera spike" publish service, its collections, and `<Pictures>\GalleraSpike` (`L:\GalleraSpike` here).

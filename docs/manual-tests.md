# Manual tests (Lightroom Classic on Windows)

Run on a dedicated **test gallery and test photos**, never a client gallery. Do one step at a time and check the
result before the next one. After each step, read the log:
`%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\Gallera.log`.

Before you start:
- File > Plug-in Manager shows the Gallera plugin with the version under test. After any plugin change, click
  **Reload Plug-in**.
- A second browser window in private/incognito mode is open for acting as the **client** (favorites).
- Note the free space of the folder for kept JPEGs (default `Pictures\Gallera`).

## 1. Account (service settings)

| # | Do | Expect |
|---|---|---|
| 1.1 | Set up a Gallera publish service. Log in with a wrong password | "The email or password is wrong." (English, whatever the account language); nothing stored; the window shows Not logged in |
| 1.2 | Log in correctly | Username and storage use are shown |
| 1.3 | Close the service settings with **Cancel** (Save stays disabled: logging in changes no saved setting) and reopen them | Still logged in || 1.4 | Log out | Logged out; the log shows `auth/logout` 200 |
| 1.5 | Log in with a **different** Gallera account on a service that has linked collections | "This Gallera account has none of the galleries…" with **Log out** / **Keep this account** (D20). Galleries in the trash still count as owned |

## 2. Collections and gallery settings

| # | Do | Expect |
|---|---|---|
| 2.1 | Create a collection with **Create new gallery** | The gallery appears on the website with that name; Edit Collection shows its address |
| 2.2 | Create a collection with **Link existing gallery** | After ~1 s the collection takes the gallery's name (D26). A gallery already linked to another collection isn't in the picker |
| 2.3 | Edit Collection | "Loading from Gallera…", then the Settings fields fill in |
| 2.4 | Change a field in each section (General, Scenes, Favorites, Saving, Access), OK | The website shows each change; the gallery's design is unchanged |
| 2.5 | Enter a slug that's already taken | "The address '…' can't be used: another of your galleries may already have it. Choose a different address." |
| 2.6 | Reopen Edit Collection after 2.4 | No `g_password` / dialog keys are kept in the catalog (log shows none) |
| 2.7 | Rename the collection in the Publish Services panel | The gallery is renamed on the website |

Known Lightroom display issue: right after creating a collection, its row in the Publish Services panel can be
drawn narrow with the name cropped until the panel is resized. The plugin doesn't draw that panel.

## 3. Publish

| # | Do | Expect |
|---|---|---|
| 3.1 | Add ~6 photos and Publish | They appear on the website. With the default **Uploaded JPEGs = Keep, ask to remove**, the "Remove the N uploaded JPEG(s)?" question appears: **Keep** keeps them in `<folder>\<collection name>\`, **Remove** deletes them |
| 3.2 | Give a published photo a label and stars | It is not queued (stays under Published) |
| 3.3 | Change a photo's exposure, Publish | A new upload; the old photo is gone from the website (D6); its kept JPEG is overwritten |
| 3.4 | Right-click a photo > Mark to Re-publish, Publish | It re-uploads (D30) |
| 3.5 | Turn on **Override size and quality** (1000 px, quality 50), mark a photo, Publish | The website's photo is 1000 px; the service's own export settings are unchanged |
| 3.6 | Service setting **Always keep**, publish | No question; JPEGs kept |
| 3.7 | Service setting **Always remove after upload**, publish | No question; uploaded JPEGs deleted |
| 3.7a | Collection **Uploaded JPEGs** = Always keep while the service says Always remove; publish | No question; the JPEG is kept (the collection wins). Back to **Service setting**: the service's choice applies again |
| 3.8 | Name a collection `a/b.` and publish | The JPEG folder `a_b` is created |
| 3.8a | Collection with a kept JPEG `X.jpg`. Put an unrelated file named `X.jpg` into `<folder>\<new name>\`, rename the collection to `<new name>`, re-publish the photo | The unrelated `X.jpg` is untouched; the new JPEG is `X-2.jpg`; the old folder is untouched |
| 3.8b | Cyrillic collection name and file name (e.g. `Весілля`, `Фото_001`) | Gallery name, folder and Gallera file name keep the Cyrillic text |
| 3.9 | Disconnect the network mid-publish | The log shows retries (2 s, 5 s); the photo is reported failed and still queued. Reconnect, Publish: it uploads |
| 3.10 | Cancel a publish midway (the progress bar's X) | The rest stay queued; JPEGs rendered so far are in the collection folder; the temp folder is empty. Lightroom's list: "Not rendered: the publish was cancelled. Still queued…" for the photo being rendered, and Lightroom's own "An unknown error occurred. This photo was not rendered." for the photos it never handed over |
| 3.11 | Log out, then Publish | The run stops at once with the login message; photos stay queued |
| 3.12 | Storage (needs an account with little free space): publish more than fits | "Gallera has X MB free…" **Continue anyway** / **Cancel**. Cancel changes nothing. During upload the run stops when the next file doesn't fit: "Gallera storage full…" |

## 4. Client favorites guard on re-upload (D30)

| # | Do | Expect |
|---|---|---|
| 4.1 | As the client, favorite 2 photos. In Lightroom change one of them and mark the other to re-publish, Publish | "Gallera: photos in client favorites" lists both, none checked, the changed one says **Picture changed** |
| 4.2 | **Cancel** | Nothing is rendered, uploaded or recorded; both stay queued |
| 4.3 | Publish again, check nothing, **Re-upload checked** | The unchanged one is kept (same photo id); the changed one fails "Not re-uploaded: in client favorites…" and stays queued |
| 4.4 | Publish again, **Select changed**, **Re-upload checked** | The changed one re-uploads |

## 5. Removing photos and deleting collections

| # | Do | Expect |
|---|---|---|
| 5.1 | Remove a photo from the collection, Publish | It's gone from the website; no error |
| 5.2 | Delete a photo on the website, then remove it in Lightroom, Publish | The record disappears without an error |
| 5.3 | Delete a collection; in Lightroom's dialog choose **Leave on service** | The plugin isn't asked; the gallery stays on Gallera |
| 5.4 | Delete a collection; choose Lightroom's delete-from-service option | No second question; the gallery is in the website's deleted galleries (trash), not permanently deleted |

## 6. Order on Gallera

| # | Do | Expect |
|---|---|---|
| 6.1 | **Capture date** (default): publish photos added in a shuffled order | The website shows them by capture time; its sort option shows Manual |
| 6.2 | **Lightroom order**: sort the collection by User Order, drag photos, Publish with nothing queued | The website shows the Lightroom order |
| 6.3 | Lightroom order: add a photo, Publish, drag it first, Publish | The website shows it first |
| 6.4 | **Don't change**: reorder on the website, add a photo, Publish | The website keeps its order (Gallera puts a new upload first) |

## 7. Deleted gallery

| # | Do | Expect |
|---|---|---|
| 7.1 | Trash the gallery on the website; restart Lightroom (or reload the plugin) | The collection is renamed `<name> - (deleted)` |
| 7.2 | Restore it on the website; restart | The name is back |
| 7.3 | Trash it again; mark a photo; Publish | "This gallery was deleted, but it is still available in Gallera trash." **Restore** / **Create new** / **Cancel** |
| 7.4 | **Cancel** | The photo fails "Gallery deleted on Gallera…"; the collection is marked |
| 7.5 | Publish, **Restore** | The gallery is back, the name too, the photo uploads |
| 7.6 | Delete the gallery permanently on the website; mark a photo; Publish | "This gallery was deleted." **Create new** / **Cancel** |
| 7.7 | **Create new** | A new gallery; "This publish uploads its 1 photo(s). Publish again to upload the remaining N". The next Publish uploads them, with no 422 in the log |
| 7.8 | Edit Collection of a marked collection | The status line says the gallery was deleted and to Publish |

## 8. Client favorites → color labels

| # | Do | Expect |
|---|---|---|
| 8.1 | As the client, make 2 lists (one photo in both). Publish with nothing queued | "Client favorites changed (list '…'). Review now?" |
| 8.2 | **Yes**; choose Red and Blue; **Apply** | Labels set; the photo in both lists is named as a conflict and unchanged; the photos stay under Published |
| 8.3 | Un-favorite a red photo on the website; Library > Plug-in Extras > **Gallera client favorites…**; Apply | Its red label is removed |
| 8.4 | Give a blue photo your own Yellow label; Apply | It stays yellow and is named under "Kept their own label" |
| 8.5 | Set Red to **Skip**; Apply | Red labels stay; the former conflict photo gets Blue |
| 8.6 | Change colors, **Cancel** | Nothing changes; reopening shows the last applied colors |
| 8.7 | Edit Collection > **Client favorites…** | The same dialog opens |
| 8.8 | Restart Lightroom | The labeled photos are still under Published |

## 9. Safety

| # | Do | Expect |
|---|---|---|
| 9.1 | After all of the above, compare an original file's size and date | Unchanged; in the catalog only color labels changed (D22) |
| 9.2 | Search `Gallera.log` for the email, the password, `token`, `Bearer`, `X-Amz-` and the gallery password | None found |
| 9.3 | Check Lightroom's temp folder after the publishes | No leftover rendered JPEGs |

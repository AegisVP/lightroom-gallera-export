--[[ Client favorites dialog (D13-D17, DESIGN.md §6.8, §7.3): one row per favorites list with a color popup;
     Apply mirrors the chosen lists onto color labels (FavoritesSync.plan). Nothing is applied without it.
     Must run inside a task. Labels change the photos, so Lightroom flags them for re-publish (S7);
     the flag is undone for photos that weren't already edited. ]]
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Auth = require 'Auth'
local GalleraApi = require 'GalleraApi'
local CollectionStore = require 'CollectionStore'
local DeletedGallery = require 'DeletedGallery'
local FavoritesSync = require 'FavoritesSync'
local GalleryLookup = require 'GalleryLookup'
local Log = require 'Log'

local FavoritesDialog = {}

local COLORS = { 'red', 'yellow', 'green', 'blue', 'purple' }
local COLOR_ITEMS = {
	{ title = 'Skip', value = 'skip' },
	{ title = 'Red', value = 'red' },
	{ title = 'Yellow', value = 'yellow' },
	{ title = 'Green', value = 'green' },
	{ title = 'Blue', value = 'blue' },
	{ title = 'Purple', value = 'purple' },
}
local IS_COLOR = {}
for _, c in ipairs(COLORS) do IS_COLOR[c] = true end

local function errorText(err)
	if err and err.kind == 'auth' then return Auth.EXPIRED_MESSAGE end
	return GalleraApi.userText(err)   -- English; Gallera's own message is in the account's language
end

local function fail(message)
	Log.warn('favorites:', message)
	LrDialogs.message('Gallera client favorites', message, 'warning')
end

-- Settings tables keyed by list id: keys are read back as numbers whatever the catalog stored.
local function byListId(t)
	local out = {}
	for k, v in pairs(type(t) == 'table' and t or {}) do out[tonumber(k) or k] = v end
	return out
end

-- "<listId>:<color>" -> { listId = n, color = c }
local function parseApplied(value)
	if type(value) ~= 'string' then return nil end
	local listId, color = value:match('^(%d+):(%a+)$')
	if not listId then return nil end
	return { listId = tonumber(listId), color = color }
end

-- Published photos of the collection: photos map for FavoritesSync, and key -> { photo, published }.
local function readPhotos(collection)
	local catalog = LrApplication.activeCatalog()
	local published = collection:getPublishedPhotos()
	local list = {}
	for _, p in ipairs(published) do list[#list + 1] = p:getPhoto() end
	local labels = catalog:batchGetRawMetadata(list, { 'colorNameForLabel' })
	local applied = catalog:batchGetPropertyForPlugin(list, _PLUGIN, { 'galleraLabelApplied' })
	local photos, byKey = {}, {}
	for _, p in ipairs(published) do
		local id = tonumber(p:getRemoteId())
		if id then
			local photo = p:getPhoto()
			local key = tostring(photo.localIdentifier)
			local label = labels[photo] and labels[photo].colorNameForLabel
			photos[id] = {
				key = key,
				label = IS_COLOR[label] and label or nil,
				applied = parseApplied(applied[photo] and applied[photo].galleraLabelApplied),
			}
			byKey[key] = { photo = photo, published = p }
		end
	end
	return photos, byKey
end

-- The gallery's slug, running the deleted-gallery flow (§6.9) if needed. Returns slug | nil.
local function activeSlug(collection, api)
	local galleryId = tonumber(collection:getRemoteId())
	if not galleryId then return fail('This collection is not linked to a Gallera gallery.') end
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then return fail(errorText(err)) end
	if found.state ~= 'active' then
		if DeletedGallery.handle(collection, api, found) ~= 'continue' then return nil end
		found, err = GalleryLookup.find(api, tonumber(collection:getRemoteId()))
		if not found or found.state ~= 'active' then return fail(errorText(err)) end
	elseif DeletedGallery.flag(collection) then
		DeletedGallery.unmark(collection)
	end
	return found.slug
end

local function showDialog(collection, rows, colors, notes)
	return LrFunctionContext.callWithContext('GalleraFavoritesDialog', function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		local share = LrView.share
		local header = f:row {
			f:static_text { title = 'List', width = share 'fav_title', font = '<system/bold>' },
			f:static_text { title = 'Status', width = share 'fav_status', font = '<system/bold>' },
			f:static_text { title = 'Photos', width = share 'fav_count', font = '<system/bold>' },
			f:static_text { title = 'In this collection', width = share 'fav_matched', font = '<system/bold>' },
			f:static_text { title = 'Color', font = '<system/bold>' },
		}
		local column = { spacing = f:control_spacing(), bind_to_object = props, header }
		for i, row in ipairs(rows) do
			local previous = colors[row.id]
			props['color' .. i] = IS_COLOR[previous] and previous or 'skip'
			column[#column + 1] = f:row {
				f:static_text { title = row.title, width = share 'fav_title', width_in_chars = 18 },
				f:static_text { title = row.finished and 'Finished' or 'In progress', width = share 'fav_status' },
				f:static_text { title = tostring(row.count), width = share 'fav_count' },
				f:static_text { title = tostring(row.matched), width = share 'fav_matched' },
				f:popup_menu { value = LrView.bind('color' .. i), items = COLOR_ITEMS, width_in_chars = 8 },
			}
		end
		for _, note in ipairs(notes) do
			column[#column + 1] = f:static_text { title = note, width_in_chars = 60, height_in_lines = 2 }
		end
		local answer = LrDialogs.presentModalDialog {
			title = 'Gallera client favorites: ' .. collection:getName(),
			contents = f:column(column),
			actionVerb = 'Apply',
		}
		if answer ~= 'ok' then return nil end
		local picked = {}
		for i, row in ipairs(rows) do picked[row.id] = props['color' .. i] end
		return picked
	end)
end

local function write(name, fn)
	LrApplication.activeCatalog():withWriteAccessDo('Gallera: ' .. name, fn, { timeout = 10 })
end

-- Clears a photo's color label. 'none' first, then '' (DESIGN §12.2 records which one works).
local clearValue
local function clearLabel(photo)
	local tries = clearValue and { clearValue } or { 'none', '' }
	for _, value in ipairs(tries) do
		local ok, err = LrTasks.pcall(function() photo:setRawMetadata('colorNameForLabel', value) end)
		if ok then
			if clearValue ~= value then Log.info('favorites: label cleared with', "'" .. value .. "'") end
			clearValue = value
			return true
		end
		Log.warn('favorites: clearing the label with', "'" .. value .. "'", 'failed:', tostring(err))
	end
	return false
end

-- §6.8 step 4. Returns counts for the summary.
local function apply(collection, result, photos, byKey)
	local labelOf = {}
	for _, p in pairs(photos) do labelOf[p.key] = p.label end

	-- Photos whose label really changes; Lightroom flags them for re-publish (S7).
	local changing = {}
	for _, s in ipairs(result.set) do
		if labelOf[s.key] ~= s.color then changing[#changing + 1] = s.key end
	end
	for _, key in ipairs(result.remove) do changing[#changing + 1] = key end
	local wasClean = {}
	for _, key in ipairs(changing) do
		local entry = byKey[key]
		if entry and not entry.published:getEditedFlag() then wasClean[#wasClean + 1] = entry.published end
	end

	local counts = { labeled = 0, changed = 0, recorded = 0, removed = 0, failed = 0 }
	write('client favorites', function()
		for _, s in ipairs(result.set) do
			local photo = byKey[s.key].photo
			local before = labelOf[s.key]
			if before ~= s.color then photo:setRawMetadata('colorNameForLabel', s.color) end
			photo:setPropertyForPlugin(_PLUGIN, 'galleraLabelApplied', s.listId .. ':' .. s.color)
			if before == nil then
				counts.labeled = counts.labeled + 1
			elseif before ~= s.color then
				counts.changed = counts.changed + 1
			else
				counts.recorded = counts.recorded + 1
			end
		end
		for _, key in ipairs(result.remove) do
			local photo = byKey[key].photo
			if clearLabel(photo) then
				photo:setPropertyForPlugin(_PLUGIN, 'galleraLabelApplied', nil)
				counts.removed = counts.removed + 1
			else
				counts.failed = counts.failed + 1
			end
		end
	end)

	-- S7b: wait until Lightroom has flagged the changed photos, then clear the flag on the ones that weren't
	-- edited before. Photos the user really edited stay queued. On 0.9.1 no photo was flagged within 10 s
	-- (label edits don't queue with metadataThatTriggersRepublish = { default = false }), so the wait is short.
	if #wasClean > 0 then
		local deadline = LrDate.currentTime() + 2
		local function allFlagged()
			for _, p in ipairs(wasClean) do
				if not p:getEditedFlag() then return false end
			end
			return true
		end
		while not allFlagged() and LrDate.currentTime() < deadline do LrTasks.sleep(0.25) end
		local unflagged = 0
		write('keep photos published', function()
			for _, p in ipairs(wasClean) do
				if p:getEditedFlag() then
					p:setEditedFlag(false)
					unflagged = unflagged + 1
				end
			end
		end)
		Log.info('favorites:', unflagged, 'of', #wasClean, 'photo(s) unflagged after the label change')
	end
	return counts
end

-- File names for the summary: up to 10, then "and N more".
local function names(keys, byKey)
	local out = {}
	for i, key in ipairs(keys) do
		if i > 10 then
			out[#out + 1] = string.format('and %d more', #keys - 10)
			break
		end
		local entry = byKey[key]
		local ok, name = LrTasks.pcall(function() return entry.photo:getFormattedMetadata('fileName') end)
		out[#out + 1] = ok and name or key
	end
	return table.concat(out, ', ')
end

local function summary(counts, result, ambiguous, byKey)
	local lines = {
		string.format('Labels added: %d', counts.labeled),
		string.format('Labels changed: %d', counts.changed),
		string.format('Labels removed: %d', counts.removed),
	}
	if #result.skippedOtherLabel > 0 then
		lines[#lines + 1] = string.format('Kept their own label (not changed): %d: %s', #result.skippedOtherLabel,
			names(result.skippedOtherLabel, byKey))
	end
	if #result.conflicts > 0 then
		lines[#lines + 1] = string.format('In lists with different colors (not changed): %d: %s', #result.conflicts,
			names(result.conflicts, byKey))
	end
	if counts.failed > 0 then lines[#lines + 1] = string.format('Labels that could not be removed: %d', counts.failed) end
	for _, a in ipairs(ambiguous) do
		lines[#lines + 1] = string.format("Not labeled: '%s' in list '%s' matches several photos.", a.name, a.list)
	end
	return table.concat(lines, '\n')
end

-- Opens the dialog for a published collection of this plugin and applies the choices. Run inside a task.
function FavoritesDialog.run(collection)
	local okRun, runErr = LrTasks.pcall(function()
		local api = Auth.api(collection:getService():getPublishSettings())
		if not api then return fail(Auth.LOGIN_HELP) end
		local slug = activeSlug(collection, api)
		if not slug then return end

		local lists, err = api:getFavorites(slug)
		if not lists then return fail(errorText(err)) end
		if #lists == 0 then
			return LrDialogs.message('Gallera client favorites', 'This gallery has no client favorites lists yet.', 'info')
		end
		local ambiguous, notes = {}, {}
		local galleryPhotos
		for _, list in ipairs(lists) do
			if #(list.latest or {}) < (tonumber(list.items_count) or 0) then
				galleryPhotos = galleryPhotos or api:listPhotos(slug) or {}
			end
		end
		if galleryPhotos then
			lists, ambiguous = FavoritesSync.completeLists(lists, galleryPhotos)
			Log.warn('favorites: a list is incomplete in Gallera; photos also matched by file name')
			notes[#notes + 1] = 'Some lists are incomplete in Gallera; their photos are also matched by file name.'
		end

		local photos, byKey = readPhotos(collection)
		local settings = CollectionStore.read(collection)
		local colors = byListId(settings.favoritesColors)
		local rows = FavoritesSync.summarize(lists, photos)
		local picked = showDialog(collection, rows, colors, notes)
		if not picked then return Log.info('favorites: cancelled') end

		local choices, stored = {}, {}
		for id, color in pairs(picked) do
			stored[tostring(id)] = color
			if IS_COLOR[color] then choices[id] = color end
		end
		local result = FavoritesSync.plan { lists = lists, choices = choices, photos = photos }
		local counts = apply(collection, result, photos, byKey)

		local seen = {}
		for id, s in pairs(FavoritesSync.seenFrom(lists)) do seen[tostring(id)] = s end
		CollectionStore.update(collection, { favoritesColors = stored, favoritesSeen = seen })
		Log.info('favorites: applied', counts.labeled, 'added,', counts.changed, 'changed,', counts.recorded,
			'recorded,', counts.removed, 'removed,', #result.skippedOtherLabel, 'skipped,', #result.conflicts, 'conflicts')
		LrDialogs.message('Gallera client favorites', summary(counts, result, ambiguous, byKey), 'info')
	end)
	if not okRun then
		Log.error('favorites: failed:', tostring(runErr))
		LrDialogs.message('Gallera client favorites', 'Something went wrong: ' .. tostring(runErr), 'critical')
	end
end

-- D17 (§6.4 step 9): after a Publish, offers the dialog when a list is new or changed since the last Apply
-- (favoritesSeen). Yes opens it in its own task, so the publish finishes first. Must run inside a task.
function FavoritesDialog.offerReview(collection, api, slug)
	local lists, err = api:getFavorites(slug)
	if not lists then return Log.warn('favorites: cannot read the lists:', errorText(err)) end
	local changed = FavoritesSync.changedLists(lists, byListId(CollectionStore.read(collection).favoritesSeen))
	if #changed == 0 then return end
	local titles = {}
	for i = 1, math.min(#changed, 3) do titles[i] = "'" .. FavoritesSync.displayTitle(changed[i].title) .. "'" end
	local more = #changed > 3 and string.format(' and %d more', #changed - 3) or ''
	local answer = LrDialogs.confirm(
		string.format('Client favorites changed (list %s%s). Review now?', table.concat(titles, ', '), more),
		'Nothing is applied until you choose colors and click Apply.', 'Yes', 'No')
	Log.info('favorites: changed in', #changed, 'list(s); review:', answer)
	if answer == 'ok' then LrTasks.startAsyncTask(function() FavoritesDialog.run(collection) end) end
end

return FavoritesDialog

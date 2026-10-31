--[[ processRenderedPhotos (DESIGN.md §6.4): re-upload queued photos except unchanged ones in client favorites
     the user keeps (D30), check storage (D23), render (with the collection's size/quality override, D18),
     upload with retries (D25), record publish state and fingerprints (D30), delete replaced photos (D6),
     keep or remove the rendered JPEGs (D24, D27), sort the gallery by capture time (D12). Originals are never touched (D22). ]]
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Auth = require 'Auth'
local CollectionStore = require 'CollectionStore'
local DeletedGallery = require 'DeletedGallery'
local Fingerprint = require 'Fingerprint'
local GalleryLookup = require 'GalleryLookup'
local Log = require 'Log'
local Names = require 'Names'
local PhotoOrder = require 'PhotoOrder'
local PublishPlan = require 'PublishPlan'
local Uploader = require 'Uploader'

local Publish = {}

-- The export settings the override writes (S1 variant A), saved before and restored after rendering.
local OVERRIDE_KEYS = {
	'LR_size_doConstrain', 'LR_size_resizeType', 'LR_size_maxWidth', 'LR_size_maxHeight', 'LR_size_units',
	'LR_size_doNotEnlarge', 'LR_jpeg_quality', 'LR_jpeg_useLimitSize',
}

-- Appended to a photo's failure message in Lightroom's "Failed publish files" list (D25).
local QUEUED = ' Still queued: click Publish to retry.'
local HELD = 'Not re-uploaded: in client favorites.' .. QUEUED
-- Cancel in any pre-publish dialog stops the whole publish: nothing renders, uploads or is recorded (user, 0.5.6).
local CANCELLED = { kind = 'cancelled' }

-- One publish per service at a time: they share exportContext.propertyTable, which the override changes.
local busy = {}

local function serviceKey(exportContext)
	local service = exportContext.publishService
	local id = service and service.localIdentifier
	if id ~= nil then return 'id:' .. tostring(id) end
	local name = service and service:getName() or '?'
	Log.warn('publish: publishService.localIdentifier missing; keyed by service name')
	return 'name:' .. name
end

-- Override (D18) -------------------------------------------------------------------

-- Writes the collection's long edge / quality into the export settings. Returns the values it replaced.
function Publish.applyOverride(props, collectionSettings)
	local saved = {}
	for _, k in ipairs(OVERRIDE_KEYS) do saved[k] = props[k] end
	local edge = tonumber(collectionSettings.longEdge) or 2048
	local quality = tonumber(collectionSettings.jpegQuality) or 80
	local values = {
		LR_size_doConstrain = true,
		LR_size_resizeType = 'longEdge',
		LR_size_maxWidth = edge,
		LR_size_maxHeight = edge,
		LR_size_units = 'pixels',
		LR_size_doNotEnlarge = true,
		LR_jpeg_quality = quality / 100,
		LR_jpeg_useLimitSize = false,
	}
	for k, v in pairs(values) do props[k] = v end
	return saved
end

function Publish.restoreOverride(props, saved)
	for _, k in ipairs(OVERRIDE_KEYS) do props[k] = saved[k] end
end

-- The saved service values live in prefs until restored, so a crash mid-publish can be repaired next time.
local function setBackup(key, saved)
	local prefs = LrPrefs.prefsForPlugin()
	local all = {}
	for k, v in pairs(prefs.overrideBackup or {}) do all[k] = v end
	all[key] = saved
	prefs.overrideBackup = all   -- reassigned: prefs only persist top-level assignments
end

local function getBackup(key)
	local all = LrPrefs.prefsForPlugin().overrideBackup
	return all and all[key]
end

-- Kept JPEGs (D24, D27) --------------------------------------------------------------

local function moveFile(from, to)
	if LrFileUtils.exists(to) then LrFileUtils.delete(to) end
	local ok = LrTasks.pcall(function() LrFileUtils.move(from, to) end)
	if ok and LrFileUtils.exists(to) then return true end
	-- Across drives (temp on C:, Pictures elsewhere) a move may not work: copy, then delete the source.
	ok = LrTasks.pcall(function() LrFileUtils.copy(from, to) end)
	if ok and LrFileUtils.exists(to) then
		LrFileUtils.delete(from)
		return true
	end
	return false
end

local function readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local data = f:read('*a')
	f:close()
	return data
end

-- Photo reads that may fail give nil instead of an error.
local function safeRead(fn)
	local ok, value = LrTasks.pcall(fn)
	if ok then return value end
	Log.warn('publish: photo read failed:', tostring(value))
	return nil
end

local function renderSettings(props)
	local r = {}
	for _, k in ipairs(Fingerprint.RENDER_KEYS) do r[k] = props[k] end
	return r
end

local function fingerprintOf(photo, render)
	return Fingerprint.of {
		develop = safeRead(function() return photo:getDevelopSettings() end) or {},
		orientation = safeRead(function() return photo:getRawMetadata('orientation') end),
		render = render,
	}
end

-- The run ----------------------------------------------------------------------------

-- A login problem needs the user to act, so it gets its own dialog, not just a line in Lightroom's failure list.
local function loginDialog(message)
	Log.warn('publish: login needed')
	LrDialogs.message('Gallera: log in to publish', message .. '\n\nThe photos stay queued for the next Publish.', 'critical')
end

-- Lightroom showed no "Failed publish files" list when uploadFailed came before the render finished
-- (0.4.3), so the rendition is rendered first; its temp file is deleted (nothing was uploaded to keep).
local function failRendered(rendition, message)
	local rendered, path = rendition:waitForRender()
	if rendered and path then LrFileUtils.delete(path) end
	rendition:uploadFailed(message)
end

local function failAll(exportContext, message)
	Log.warn('publish: not uploading:', message)
	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		failRendered(rendition, message)
	end
end

local function errorText(err)
	if err and err.kind == 'auth' then return Auth.EXPIRED_MESSAGE end
	return tostring(err and err.message or 'Gallera error')
end

-- D30 guard: queued photos in client favorites re-upload only if the user checks them here (none checked by
-- default). Returns { [photo key] = true } for the checked ones, or nil on Cancel.
local function chooseFavorites(guarded, photosByKey, favoritesKnown)
	return LrFunctionContext.callWithContext('Gallera favorites guard', function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		local list = { spacing = f:control_spacing() }
		for i, p in ipairs(guarded) do
			local photo = photosByKey[p.key]
			props['pick' .. i] = false
			local quoted = {}
			for _, title in ipairs(p.favorites or {}) do quoted[#quoted + 1] = "'" .. title .. "'" end
			list[#list + 1] = f:row {
				f:checkbox { value = LrView.bind('pick' .. i), title = '' },
				f:catalog_photo { photo = photo, width = 64, height = 64 },
				f:column {
					f:static_text { title = tostring(safeRead(function() return photo:getFormattedMetadata('fileName') end) or p.key) },
					f:static_text { title = #quoted > 0 and ('♥ ' .. table.concat(quoted, ', ')) or '' },
					f:static_text { title = p.changed and 'Picture changed' or '' },
				},
			}
		end
		local function setAll(value, onlyChanged)
			for i, p in ipairs(guarded) do props['pick' .. i] = value and (p.changed or not onlyChanged) end
		end
		local intro = favoritesKnown
			and string.format('%d queued photo(s) are in client favorites.', #guarded)
			or string.format('Could not read the client favorites. %d queued photo(s) may be in them.', #guarded)
		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:static_text { title = intro },
			f:static_text { title = 'Re-uploading a photo gives it a new Gallera id and removes it from the favorites lists.' },
			f:static_text { title = 'Select which photos to re-upload. Unselected unchanged photos stay on Gallera as they are;' },
			f:static_text { title = 'unselected changed photos stay queued.' },
			f:row {
				f:push_button { title = 'Select all', action = function() setAll(true) end },
				f:push_button { title = 'Select none', action = function() setAll(false) end },
				f:push_button { title = 'Select changed', action = function() setAll(true, true) end },
			},
			f:scrolled_view { width = 460, height = math.min(400, #guarded * 76 + 12), f:column(list) },
		}
		local answer = LrDialogs.presentModalDialog {
			title = 'Gallera: photos in client favorites', contents = contents,
			actionVerb = 'Re-upload checked', cancelVerb = 'Cancel',
		}
		if answer ~= 'ok' then return nil end
		local force, n = {}, 0
		for i, p in ipairs(guarded) do
			if props['pick' .. i] then
				force[p.key] = true
				n = n + 1
			end
		end
		Log.info('publish:', #guarded, 'queued photo(s) in favorites,', n, 'checked to re-upload')
		return force
	end)
end

-- The favorites index ({ [remote id] = { titles } }), or nil when Gallera couldn't say; an auth error is returned.
local function readFavorites(api, slug)
	local lists, err = api:getFavorites(slug)
	if not lists then
		if err.kind == 'auth' then return nil, err end
		Log.warn('publish: favorites check failed:', err.kind, err.status, err.message)
		return nil
	end
	for _, list in ipairs(lists) do
		local ids = {}
		for _, photo in ipairs(type(list.latest) == 'table' and list.latest or {}) do
			ids[#ids + 1] = tostring(type(photo) == 'table' and photo.id)
		end
		Log.info('publish: favorites list', tostring(list.id), 'items', tostring(list.items_count),
			'finished', tostring(list.is_finished), 'names', type(list.lightroom_list) == 'table' and #list.lightroom_list or 0,
			'latest', table.concat(ids, ','))
	end
	-- latest[] can be shorter than items_count (seen: 4 of 6): then names are matched against the gallery's photos.
	local galleryPhotos
	if PublishPlan.hasIncompleteFavorites(lists) then
		galleryPhotos, err = api:listPhotos(slug)
		if not galleryPhotos then
			if err.kind == 'auth' then return nil, err end
			Log.warn('publish: gallery photos for the favorites fallback failed:', err.kind, err.status, err.message)
			return nil
		end
	end
	return PublishPlan.favoriteIndex(lists, galleryPhotos)
end

-- D30: classify before anything renders. Every queued photo uploads, except photos in client favorites that the
-- user doesn't check: unchanged ones are kept, changed ones held (still queued). Returns
-- { [photo key] = { kind = 'unchanged'|'upload'|'held', remoteId, fingerprint } }, or nil plus an error:
-- CANCELLED, or an auth error when the user must log in.
local function plan(exportContext, api, slug, fingerprints, render)
	local remoteIds = {}
	for _, published in ipairs(exportContext.publishedCollection:getPublishedPhotos()) do
		local id = tonumber(published:getRemoteId())
		if id then remoteIds[tostring(published:getPhoto().localIdentifier)] = id end
	end
	local photos, photosByKey = {}, {}
	for photo in exportContext.exportSession:photosToExport() do   -- an iterator, not an array
		local key = tostring(photo.localIdentifier)
		photosByKey[key] = photo
		photos[#photos + 1] = { key = key, remoteId = remoteIds[key], fingerprint = fingerprintOf(photo, render) }
		Log.info('publish: photo', key, 'remote', tostring(remoteIds[key]), 'fingerprint stored', tostring(fingerprints[key]),
			'now', photos[#photos].fingerprint)
	end

	local published = 0
	for _, p in ipairs(photos) do
		if p.remoteId then published = published + 1 end
	end
	local result = PublishPlan.classify { photos = photos, fingerprints = fingerprints }
	local hold = {}
	if published > 0 then
		local index, err = readFavorites(api, slug)
		if err then return nil, err end
		result = PublishPlan.classify { photos = photos, fingerprints = fingerprints, favoriteIndex = index }
		local guarded, force = PublishPlan.guardFavorites(result, index ~= nil)
		if #guarded > 0 then
			local checked = chooseFavorites(guarded, photosByKey, index ~= nil)
			if not checked then return nil, CANCELLED end
			local checkedForce
			checkedForce, hold = PublishPlan.applyGuard(guarded, checked)
			for key in pairs(checkedForce) do force[key] = true end
		end
		result = PublishPlan.classify { photos = photos, fingerprints = fingerprints, force = force }
	end

	local decisions, held = {}, 0
	for _, p in ipairs(result.unchanged) do decisions[p.key] = { kind = 'unchanged', remoteId = p.remoteId } end
	for _, p in ipairs(result.upload) do
		decisions[p.key] = { kind = hold[p.key] and 'held' or 'upload', fingerprint = p.fingerprint }
		if hold[p.key] then held = held + 1 end
	end
	Log.info('publish: plan', #result.unchanged, 'kept,', #result.upload - held, 'to upload,', held, 'held')
	return decisions
end

-- D23: the free storage before the loop ({ free, limit }, or nil when unknown or unlimited), plus an error:
-- CANCELLED, or an auth error for the login flow.
-- Order (D12, §6.4 step 8) ---------------------------------------------------------------

local function sameOrder(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Sorts the gallery by capture time: every published photo of the collection (earlier records plus the ids
-- recorded in this run, keyed by number to match listPhotos) gets its dateTimeOriginal, or false.
local function orderByCapture(collection, api, slug, recorded)
	local photoById = {}
	for _, published in ipairs(collection:getPublishedPhotos()) do
		local id = tonumber(published:getRemoteId())
		if id then photoById[id] = published:getPhoto() end
	end
	for id, photo in pairs(recorded) do photoById[id] = photo end

	local photos = {}
	for _, photo in pairs(photoById) do photos[#photos + 1] = photo end
	local raw = LrApplication.activeCatalog():batchGetRawMetadata(photos, { 'dateTimeOriginal' })
	local captureTimes = {}
	for id, photo in pairs(photoById) do
		local t = raw[photo] and raw[photo].dateTimeOriginal
		captureTimes[id] = type(t) == 'number' and t or false
	end

	local galleryPhotos, err = api:listPhotos(slug)
	if not galleryPhotos then
		Log.warn('publish: not ordered, cannot list the gallery photos:', errorText(err))
		return
	end
	local current = {}
	for _, p in ipairs(galleryPhotos) do
		local id = tonumber(p.id)
		if id then current[#current + 1] = id end
	end
	local order = PhotoOrder.compute { galleryPhotoIds = current, captureTimes = captureTimes }
	if sameOrder(order, current) then
		Log.info('publish: gallery already in capture order,', #order, 'photo(s)')
		return
	end
	local _, sortErr = api:sortPhotos(slug, order, nil)
	if sortErr then
		Log.warn('publish: sorting failed:', errorText(sortErr))
	else
		Log.info('publish: sorted', #order, 'photo(s) by capture time')
	end
end

local function storageCheck(api, slug, uploadCount)
	if uploadCount == 0 then return nil end
	local user, err = api:getUser()
	if not user then
		if err.kind == 'auth' then return nil, err end
		Log.warn('publish: storage check skipped:', err.kind, err.status, err.message)
		return nil
	end
	local free = PublishPlan.freeBytes(user)
	if not free then return nil end
	local storage = { free = free, limit = tonumber(user.storage.limit) }
	local estimate = PublishPlan.estimateBytes(uploadCount, api:listPhotos(slug))
	Log.info('publish: storage free', PublishPlan.formatBytes(free), 'estimate', PublishPlan.formatBytes(estimate))
	if estimate <= free then return storage end
	local answer = LrDialogs.confirm(PublishPlan.storageWarning(free, estimate, uploadCount), nil, 'Continue anyway', 'Cancel')
	if answer ~= 'ok' then return nil, CANCELLED end
	return storage
end

local function run(exportContext, key)
	local props = exportContext.propertyTable
	local collection = exportContext.publishedCollection
	local count = exportContext.exportSession:countRenditions()
	local started = LrDate.currentTime()
	exportContext:configureProgress { title = string.format('Publishing %d photo(s) to Gallera', count) }
	Log.info('publish: start,', count, 'photo(s)')

	local backup = getBackup(key)
	if backup then
		Log.warn('publish: restoring export settings left over from an interrupted publish')
		Publish.restoreOverride(props, backup)
		setBackup(key, nil)
	end

	local api, authErr = Auth.api(props)
	if not api then
		loginDialog(Auth.LOGIN_HELP)
		return failAll(exportContext, authErr.message)
	end
	local galleryId = tonumber(collection:getRemoteId())
	if not galleryId then
		return failAll(exportContext, 'This collection is not linked to a Gallera gallery. Edit the collection to link one.')
	end
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then return failAll(exportContext, errorText(err)) end
	-- §6.9: Restore / Create new / Cancel. After Create new, every photo uploads to the new gallery.
	local recreated = false
	if found.state ~= 'active' then
		local outcome, how = DeletedGallery.handle(collection, api, found)
		if outcome ~= 'continue' then return failAll(exportContext, 'Gallery deleted on Gallera.' .. QUEUED) end
		recreated = how == 'created'
		galleryId = tonumber(collection:getRemoteId())
		found, err = GalleryLookup.find(api, galleryId)
		if not found then return failAll(exportContext, errorText(err)) end
		if found.state ~= 'active' then return failAll(exportContext, 'Gallery deleted on Gallera.' .. QUEUED) end
		if recreated then
			-- Photos outside this publish were marked to re-publish by Create new.
			local inRun = {}
			for photo in exportContext.exportSession:photosToExport() do inRun[photo.localIdentifier] = true end
			local remaining = 0
			for _, published in ipairs(collection:getPublishedPhotos()) do
				if not inRun[published:getPhoto().localIdentifier] then remaining = remaining + 1 end
			end
			if remaining > 0 then
				LrDialogs.message('Gallera: new gallery created',
					string.format('This publish uploads its %d photo(s). Publish again to upload the remaining %d photo(s).',
						count, remaining), 'info')
			end
		end
	elseif DeletedGallery.flag(collection) then
		DeletedGallery.unmark(collection)   -- restored on the website
	end
	local slug = found.slug
	local gallery = api:getGallery(slug)
	local publicUrl = gallery and type(gallery.public_url) == 'string' and gallery.public_url or collection:getRemoteUrl()

	local settings = CollectionStore.read(collection)
	local jpegFiles, fingerprints = settings.jpegFiles or {}, settings.fingerprints or {}
	local handling = props.jpegHandling or 'ask'
	local root = props.jpegFolder
	if type(root) ~= 'string' or root == '' then
		root = LrPathUtils.child(LrPathUtils.getStandardFilePath('pictures'), 'Gallera')
	end
	local folder = LrPathUtils.child(root, Names.safeFolder(collection:getName()))
	local folderOk = LrTasks.pcall(function() LrFileUtils.createAllDirectories(folder) end) and LrFileUtils.exists(folder)
	if not folderOk then Log.warn('publish: cannot create the JPEG folder; rendered files stay in the temp folder') end

	local function keepJpeg(path, photoKey, leaf, uploaded)
		if uploaded and handling == 'remove' then
			LrFileUtils.delete(path)
			return nil
		end
		if not folderOk then return nil end
		local target = Names.jpegTarget(jpegFiles, photoKey, leaf, function(l)
			return LrFileUtils.exists(LrPathUtils.child(folder, l)) and true or false
		end)
		local old = jpegFiles[photoKey]
		if not moveFile(path, LrPathUtils.child(folder, target)) then
			Log.warn('publish: could not move a rendered JPEG to the collection folder')
			return nil
		end
		if old and old:lower() ~= target:lower() then LrFileUtils.delete(LrPathUtils.child(folder, old)) end
		jpegFiles[photoKey] = target
		return LrPathUtils.child(folder, target)
	end

	-- The override is applied first: the fingerprints include the effective render settings.
	local saved
	if settings.overrideRender then
		saved = Publish.applyOverride(props, settings)
		setBackup(key, saved)
		Log.info('publish: render override', settings.longEdge, 'px, quality', settings.jpegQuality)
	end
	local render = renderSettings(props)

	local uploaded, failed, unchanged, held, oldIds, keptUploaded = 0, 0, 0, 0, {}, {}
	-- Gallera photo id -> photo, for every id recorded in this run (the catalog shows them after the publish).
	local recorded = {}
	local authStopped, cancelled = false, false
	-- Before the renditions loop: on Cancel the loop never starts, so nothing is rendered or recorded.
	local function stopBeforeLoop(stopErr)
		if stopErr == CANCELLED then
			cancelled = true
			Log.info('publish: cancelled by the user; nothing published')
			return
		end
		loginDialog(Auth.EXPIRED_HELP)
		failAll(exportContext, errorText(stopErr))
	end
	local ok, loopErr = LrTasks.pcall(function()
		local decisions, planErr = plan(exportContext, api, slug, fingerprints, render)
		if not decisions then return stopBeforeLoop(planErr) end
		local uploadCount = 0
		for _, d in pairs(decisions) do
			if d.kind == 'upload' then uploadCount = uploadCount + 1 end
		end
		local storage, storageErr = storageCheck(api, slug, uploadCount)
		if storageErr then return stopBeforeLoop(storageErr) end
		local storageFull

		for _, rendition in exportContext:renditions { stopIfCanceled = true } do
			local photo = rendition.photo
			local photoKey = tostring(photo.localIdentifier)
			local decision = decisions[photoKey] or { kind = 'upload' }
			if decision.kind == 'unchanged' then
				-- D30: same picture, kept for its favorites; mark it published again. skipRender() can't be used:
				-- Lightroom rejects it once the renditions loop has started rendering (0.5.2), so render and discard.
				local rendered, path = rendition:waitForRender()
				if rendered and path then LrFileUtils.delete(path) end
				rendition:recordPublishedPhotoId(tostring(decision.remoteId))
				recorded[tonumber(decision.remoteId)] = photo
				if publicUrl then rendition:recordPublishedPhotoUrl(publicUrl) end
				unchanged = unchanged + 1
				Log.info('publish: unchanged photo', decision.remoteId, 'kept')
			elseif decision.kind == 'held' then
				held = held + 1
				failRendered(rendition, HELD)
			elseif authStopped then
				failRendered(rendition, Auth.EXPIRED_MESSAGE)
			else
				local success, pathOrMessage = rendition:waitForRender()
				if not success then
					failed = failed + 1
					rendition:uploadFailed(tostring(pathOrMessage) .. QUEUED)
				else
					local leaf = LrPathUtils.leafName(pathOrMessage)
					local bytes = readFile(pathOrMessage)
					local size = bytes and #bytes
					local photoId, uploadErr
					if not bytes then
						uploadErr = { kind = 'api', message = 'Could not read the rendered file.' }
					elseif storage and (storageFull or size > storage.free) then
						-- D23: stop uploading once the next file doesn't fit.
						storageFull = storageFull or PublishPlan.storageFullMessage(storage.limit - storage.free, storage.limit)
						uploadErr = { kind = 'storage', message = storageFull }
					else
						photoId, uploadErr = Uploader.upload(api, {
							galleryId = galleryId, slug = slug, filename = leaf, bytes = bytes, contentType = 'image/jpeg',
						}, LrTasks.sleep)
					end
					bytes = nil

					if photoId then
						uploaded = uploaded + 1
						if storage then storage.free = math.max(0, storage.free - size) end
						local oldId = tonumber(rendition.publishedPhotoId)
						rendition:recordPublishedPhotoId(tostring(photoId))
						recorded[tonumber(photoId)] = photo
						if publicUrl then rendition:recordPublishedPhotoUrl(publicUrl) end
						-- After Create new the old ids belong to the deleted gallery: nothing to replace.
						if oldId and not recreated then oldIds[#oldIds + 1] = oldId end
						fingerprints[photoKey] = decision.fingerprint or fingerprintOf(photo, render)
						Log.info('publish: uploaded photo', photoId, oldId and ('replacing ' .. oldId) or '')
					elseif uploadErr.kind == 'auth' then
						authStopped = true
						loginDialog(Auth.EXPIRED_HELP)
						rendition:uploadFailed(Auth.EXPIRED_MESSAGE)
					else
						failed = failed + 1
						Log.warn('publish: upload failed:', uploadErr.kind, uploadErr.status, uploadErr.message)
						rendition:uploadFailed(errorText(uploadErr) .. QUEUED)
					end

					local kept = keepJpeg(pathOrMessage, photoKey, leaf, photoId ~= nil)
					if kept and photoId then keptUploaded[#keptUploaded + 1] = { key = photoKey, path = kept } end
				end
			end
		end
	end)

	if saved then
		Publish.restoreOverride(props, saved)
		setBackup(key, nil)
	end

	-- D6: replaced photos are deleted only after their new version uploaded.
	-- Only ids still in this gallery: one foreign id (e.g. from a gallery deleted and re-created, §6.9)
	-- fails the whole photos/delete call with 422.
	if #oldIds > 0 and not authStopped then
		local galleryPhotos = api:listPhotos(slug)
		if galleryPhotos then oldIds = PublishPlan.inGallery(oldIds, galleryPhotos) end
	end
	if #oldIds > 0 and not authStopped then
		local deleted, deleteErr = api:deletePhotos(slug, oldIds)
		if deleted then
			Log.info('publish: deleted', #deleted, 'replaced photo(s)')
		else
			Log.warn('publish: deleting replaced photos failed:', deleteErr.kind, deleteErr.status, deleteErr.message)
		end
	end

	if ok and not cancelled and not authStopped and PhotoOrder.mode(settings) == 'capture' then
		local orderOk, orderErr = LrTasks.pcall(orderByCapture, collection, api, slug, recorded)
		if not orderOk then Log.error('publish: ordering failed:', tostring(orderErr)) end
	end

	if not ok then Log.error('publish: stopped by an error:', tostring(loopErr)) end
	Log.info('publish: done,', uploaded, 'uploaded,', unchanged, 'kept,', held, 'held,', failed, 'failed in',
		string.format('%.1fs', LrDate.currentTime() - started))
	-- No summary dialog for failures: Lightroom shows its own "Failed publish files" list with each
	-- photo's uploadFailed message (which says it's still queued), and a second dialog didn't appear.

	if handling == 'ask' and #keptUploaded > 0 then
		local answer = LrDialogs.confirm(
			string.format('Remove the %d uploaded JPEG(s) from %s?', #keptUploaded, folder),
			'They are on Gallera now. JPEGs that failed to upload are kept either way.',
			'Keep', 'Cancel', 'Remove')
		if answer == 'other' then
			for _, kept in ipairs(keptUploaded) do
				LrFileUtils.delete(kept.path)
				jpegFiles[kept.key] = nil
			end
			Log.info('publish: removed', #keptUploaded, 'uploaded JPEG(s)')
		end
	end

	if not cancelled then CollectionStore.update(collection, { jpegFiles = jpegFiles, fingerprints = fingerprints }) end

	-- D17 (§6.4 step 9) runs in imposeSortOrderOnPublishedCollection: Lightroom calls it on every Publish.
	if not ok then error(loopErr, 0) end
end

function Publish.process(functionContext, exportContext)
	local key = serviceKey(exportContext)
	while busy[key] do LrTasks.sleep(0.5) end
	busy[key] = true
	local ok, err = LrTasks.pcall(run, exportContext, key)
	busy[key] = nil
	if not ok then error(err, 0) end
end

return Publish

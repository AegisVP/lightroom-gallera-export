--[[ processRenderedPhotos (DESIGN.md §6.4): render (with the collection's size/quality override, D18),
     upload with retries (D25), record publish state and fingerprints (D30), delete replaced photos (D6),
     keep or remove the rendered JPEGs (D24, D27). Originals are never touched (D22). ]]
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local Auth = require 'Auth'
local CollectionStore = require 'CollectionStore'
local Fingerprint = require 'Fingerprint'
local GalleryLookup = require 'GalleryLookup'
local Log = require 'Log'
local Names = require 'Names'
local Uploader = require 'Uploader'

local Publish = {}

-- The export settings the override writes (S1 variant A), saved before and restored after rendering.
local OVERRIDE_KEYS = {
	'LR_size_doConstrain', 'LR_size_resizeType', 'LR_size_maxWidth', 'LR_size_maxHeight', 'LR_size_units',
	'LR_size_doNotEnlarge', 'LR_jpeg_quality', 'LR_jpeg_useLimitSize',
}

-- Appended to a photo's failure message in Lightroom's "Failed publish files" list (D25).
local QUEUED = ' Still queued: click Publish to retry.'

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

-- Photo reads that may fail (the orientation key is unverified, §12.2) give nil instead of an error.
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

-- The run ----------------------------------------------------------------------------

-- A login problem needs the user to act, so it gets its own dialog, not just a line in Lightroom's failure list.
local function loginDialog(message)
	Log.warn('publish: login needed')
	LrDialogs.message('Gallera: log in to publish', message .. '\n\nThe photos stay queued for the next Publish.', 'critical')
end

-- Lightroom showed no "Failed publish files" list when uploadFailed came before the render finished
-- (0.4.3), so each rendition is rendered first; its temp file is deleted (nothing was uploaded to keep).
local function failAll(exportContext, message)
	Log.warn('publish: not uploading:', message)
	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local rendered, path = rendition:waitForRender()
		if rendered and path then LrFileUtils.delete(path) end
		rendition:uploadFailed(message)
	end
end

local function errorText(err)
	if err and err.kind == 'auth' then return Auth.EXPIRED_MESSAGE end
	return tostring(err and err.message or 'Gallera error')
end

local function run(exportContext, key)
	local props = exportContext.propertyTable
	local collection = exportContext.publishedCollection
	local count = exportContext.exportSession:countRenditions()
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
	if found.state ~= 'active' then return failAll(exportContext, 'Gallery deleted') end
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

	local saved
	if settings.overrideRender then
		saved = Publish.applyOverride(props, settings)
		setBackup(key, saved)
		Log.info('publish: render override', settings.longEdge, 'px, quality', settings.jpegQuality)
	end
	local render = renderSettings(props)

	local uploaded, failed, oldIds, keptUploaded = 0, 0, {}, {}
	local authStopped = false
	local ok, loopErr = LrTasks.pcall(function()
		for _, rendition in exportContext:renditions { stopIfCanceled = true } do
			if authStopped then
				rendition:uploadFailed(Auth.EXPIRED_MESSAGE)
			else
				local photo = rendition.photo
				local photoKey = tostring(photo.localIdentifier)
				local success, pathOrMessage = rendition:waitForRender()
				if not success then
					failed = failed + 1
					rendition:uploadFailed(tostring(pathOrMessage) .. QUEUED)
				else
					local leaf = LrPathUtils.leafName(pathOrMessage)
					local bytes = readFile(pathOrMessage)
					local photoId, uploadErr
					if bytes then
						photoId, uploadErr = Uploader.upload(api, {
							galleryId = galleryId, slug = slug, filename = leaf, bytes = bytes, contentType = 'image/jpeg',
						}, LrTasks.sleep)
					else
						uploadErr = { kind = 'api', message = 'Could not read the rendered file.' }
					end
					bytes = nil

					if photoId then
						uploaded = uploaded + 1
						local oldId = tonumber(rendition.publishedPhotoId)
						rendition:recordPublishedPhotoId(tostring(photoId))
						if publicUrl then rendition:recordPublishedPhotoUrl(publicUrl) end
						if oldId then oldIds[#oldIds + 1] = oldId end
						fingerprints[photoKey] = Fingerprint.of {
							develop = safeRead(function() return photo:getDevelopSettings() end) or {},
							orientation = safeRead(function() return photo:getRawMetadata('orientation') end),
							render = render,
						}
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
	if #oldIds > 0 and not authStopped then
		local deleted, deleteErr = api:deletePhotos(slug, oldIds)
		if deleted then
			Log.info('publish: deleted', #deleted, 'replaced photo(s)')
		else
			Log.warn('publish: deleting replaced photos failed:', deleteErr.kind, deleteErr.status, deleteErr.message)
		end
	end

	if not ok then Log.error('publish: stopped by an error:', tostring(loopErr)) end
	Log.info('publish: done,', uploaded, 'uploaded,', failed, 'failed')
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

	CollectionStore.update(collection, { jpegFiles = jpegFiles, fingerprints = fingerprints })
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

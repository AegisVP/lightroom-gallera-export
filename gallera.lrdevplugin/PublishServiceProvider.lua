--[[ Gallera publish service provider (DESIGN.md §5.3, §6): publish, remove photos (§6.5),
     rename (§6.6) and delete (§6.7) collections. ]]
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Auth = require 'Auth'
local CollectionSettingsDialog = require 'CollectionSettingsDialog'
local CollectionStore = require 'CollectionStore'
local DeletedGallery = require 'DeletedGallery'
local FavoritesDialog = require 'FavoritesDialog'
local GalleryLookup = require 'GalleryLookup'
local Log = require 'Log'
local Names = require 'Names'
local PhotoOrder = require 'PhotoOrder'
local Publish = require 'Publish'
local PublishPlan = require 'PublishPlan'
local ServiceSettingsDialog = require 'ServiceSettingsDialog'

local provider = {
	supportsIncrementalPublish = 'only',
	allowFileFormats = { 'JPEG' },
	canExportVideo = false,
	hideSections = { 'exportLocation' },
	hidePrintResolution = true,
	-- User Order in published collections; Lightroom passes it to imposeSortOrderOnPublishedCollection (D12).
	supportsCustomSortOrder = true,

	-- Saved in plain text in presets: never a token or password here.
	exportPresetFields = {
		{ key = 'email', default = '' },
		{ key = 'jpegHandling', default = 'ask' },   -- 'ask' | 'keep' | 'remove' (D24)
		{ key = 'jpegFolder', default = LrPathUtils.child(LrPathUtils.getStandardFilePath('pictures'), 'Gallera') },
	},

	startDialog = ServiceSettingsDialog.startDialog,
	sectionsForTopOfDialog = ServiceSettingsDialog.sectionsForTopOfDialog,

	viewForCollectionSettings = CollectionSettingsDialog.viewForCollectionSettings,
	updateCollectionSettings = CollectionSettingsDialog.updateCollectionSettings,
}

-- D30: metadata never counts as a change; the fingerprint decides what re-uploads.
function provider.metadataThatTriggersRepublish(publishSettings)
	return { default = false }
end

function provider.getCollectionBehaviorInfo(publishSettings)
	return {
		defaultCollectionName = 'Gallery',
		defaultCollectionCanBeDeleted = true,
		canAddCollection = true,
		maxCollectionSetDepth = 0,
	}
end

provider.processRenderedPhotos = Publish.process

local function errorText(err)
	if err and err.kind == 'auth' then return Auth.EXPIRED_MESSAGE end
	return tostring(err and err.message or 'Gallera error')
end

-- Finding the collection -------------------------------------------------------------

-- The published collection the removed photos belong to. Lightroom passes its local id as the 4th argument;
-- without it, the collection whose published photos carry these remote ids is searched for.
local function collectionOf(ids, localCollectionId, what)
	local catalog = LrApplication.activeCatalog()
	if localCollectionId ~= nil then
		local c = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)
		if c then return c end
		Log.warn(what .. ': no published collection with local id', localCollectionId)
	else
		Log.info(what .. ': no collection id from Lightroom; searching the Gallera services')
	end
	local wanted = {}
	for _, id in ipairs(ids) do wanted[tostring(id)] = true end
	for _, service in ipairs(catalog:getPublishServices(_PLUGIN.id)) do
		for _, c in ipairs(service:getChildCollections()) do
			for _, published in ipairs(c:getPublishedPhotos()) do
				if wanted[tostring(published:getRemoteId())] then return c end
			end
		end
	end
	return nil
end

-- After every Publish (D12, D17) ---------------------------------------------------------------

-- Sends Lightroom's User Order to the gallery: photos added on the website go after the Lightroom ones.
local function sortToLightroomOrder(api, slug, remoteIdSequence)
	local photos, err = api:listPhotos(slug)
	if not photos then return Log.warn('lightroom order: cannot list the gallery photos:', errorText(err)) end
	local current = {}
	for _, p in ipairs(photos) do
		local id = tonumber(p.id)
		if id then current[#current + 1] = id end
	end
	local order = PhotoOrder.fromSequence { galleryPhotoIds = current, sequence = remoteIdSequence }
	local same = #order == #current
	for i = 1, #order do
		if order[i] ~= current[i] then same = false end
	end
	if same then return Log.info('lightroom order: gallery already in this order') end
	local _, sortErr = api:sortPhotos(slug, order, nil)
	if sortErr then return Log.warn('lightroom order: sorting failed:', errorText(sortErr)) end
	Log.info('lightroom order: sorted', #order, 'photo(s)')
end

-- Lightroom calls this on every Publish, also with nothing queued, after the uploads, with the collection's
-- User Order as remote ids. It sorts 'Lightroom order' collections and offers the favorites review (D17).
-- Failures are logged, never raised.
function provider.imposeSortOrderOnPublishedCollection(publishSettings, info, remoteIdSequence)
	-- info has no publishedCollection here, but localCollectionId (seen on 0.7.2).
	remoteIdSequence = remoteIdSequence or {}
	Log.info('after publish:', #remoteIdSequence, 'photo id(s)')
	local collection = collectionOf(remoteIdSequence, info and info.localCollectionId, 'after publish')
	if not collection then return Log.warn('after publish: collection not found') end
	local galleryId = tonumber(collection:getRemoteId())
	if not galleryId then return end
	local api = Auth.api(publishSettings)
	if not api then return Log.warn('after publish: not logged in') end
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then return Log.warn('after publish:', errorText(err)) end
	if found.state ~= 'active' then return Log.info('after publish: gallery is', found.state) end

	local mode = PhotoOrder.mode(CollectionStore.read(collection))
	Log.info('after publish: collection', collection:getName(), 'order mode', mode)
	if mode == 'lightroom' then sortToLightroomOrder(api, found.slug, remoteIdSequence) end
	FavoritesDialog.offerReview(collection, api, found.slug)
end

-- Removing photos (§6.5) --------------------------------------------------------------

local RETRY = ' The removed photos stay listed; Publish again to retry.'

-- Deletes the Gallera copies only; deletedCallback drops Lightroom's publish record. Originals stay (D22).
-- An error raised here is shown by Lightroom, and the photos it wasn't called for stay listed.
function provider.deletePhotosFromPublishedCollection(publishSettings, ids, deletedCallback, localCollectionId)
	Log.info('remove photos:', #ids, 'photo(s), collection', localCollectionId)
	-- Gallera photo ids are numbers; anything else has no Gallera copy to delete.
	local photoIds, byNumber = {}, {}
	for _, id in ipairs(ids) do
		local n = tonumber(id)
		if n then
			if not byNumber[n] then
				photoIds[#photoIds + 1] = n
				byNumber[n] = {}
			end
			table.insert(byNumber[n], id)
		else
			deletedCallback(id)
		end
	end
	if #photoIds == 0 then return end
	local function drop(numbers)
		for _, n in ipairs(numbers) do
			for _, id in ipairs(byNumber[n]) do deletedCallback(id) end
		end
	end

	local collection = collectionOf(ids, localCollectionId, 'remove photos')
	if not collection then error('Gallera: could not find the published collection of the removed photos.' .. RETRY) end
	local galleryId = tonumber(collection:getRemoteId())
	if not galleryId then
		Log.warn('remove photos: the collection is not linked to a gallery; dropping the records')
		return drop(photoIds)
	end

	local api = Auth.api(publishSettings)
	if not api then error(Auth.LOGIN_HELP .. RETRY) end
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then error('Gallera: ' .. errorText(err) .. RETRY) end
	if found.state ~= 'active' then
		-- No Gallera copy is left to delete. The collection is marked without a prompt (§6.5, §6.9).
		Log.info('remove photos: gallery', galleryId, 'is', found.state, '; dropping the records')
		drop(photoIds)
		return DeletedGallery.mark(collection, found.state)
	end
	if DeletedGallery.flag(collection) then DeletedGallery.unmark(collection) end

	local deleted
	deleted, err = api:deletePhotos(found.slug, photoIds)
	if not deleted then
		if err and (err.kind == 'auth' or err.kind == 'network') then error('Gallera: ' .. errorText(err) .. RETRY) end
		-- E.g. a photo already deleted on the website: the gallery's photo list below decides.
		Log.warn('remove photos: delete failed:', errorText(err))
		deleted = {}
	end

	local deletedSet, allDeleted = {}, true
	for _, id in ipairs(deleted) do deletedSet[tonumber(id) or id] = true end
	for _, n in ipairs(photoIds) do
		if not deletedSet[n] then allDeleted = false end
	end
	-- Photos still in the gallery. One already gone from it (deleted on the website) counts as deleted.
	-- If the list can't be read, only the ids Gallera confirmed count.
	local remaining = photoIds
	if not allDeleted then
		local photos, listErr = api:listPhotos(found.slug)
		if photos then
			remaining = {}
			for _, p in ipairs(photos) do remaining[#remaining + 1] = p.id end
		else
			Log.warn('remove photos: cannot list the gallery photos:', errorText(listErr))
		end
	end

	local confirmed = PublishPlan.confirmedDeletes(photoIds, deleted, remaining)
	drop(confirmed)
	Log.info('remove photos:', #confirmed, 'of', #photoIds, 'removed from the gallery')
	local left = #photoIds - #confirmed
	if left > 0 then
		error(string.format('Gallera: %d photo(s) could not be deleted from the gallery.', left) .. RETRY)
	end
end

-- Renaming (§6.6) -----------------------------------------------------------------------

-- A Gallera failure is reported in a dialog, not raised: the collection keeps its new name either way.
function provider.renamePublishedCollection(publishSettings, info)
	local collection = info.publishedCollection
	local newName = info.name
	Log.info('rename collection')
	local settings = CollectionStore.read(collection)
	if type(settings.deleted) == 'table' then
		-- Flagged as deleted (§6.9): only the remembered name changes, without the marker. No API call.
		local ok, err = LrTasks.pcall(CollectionStore.update, collection, {
			deleted = { state = settings.deleted.state, originalName = Names.stripDeleted(newName) },
		})
		if not ok then Log.error('rename collection: cannot store the name:', err) end
		return
	end
	local galleryId = tonumber(collection:getRemoteId())
	if not galleryId then return end

	local function report(reason)
		Log.warn('rename collection: gallery not renamed:', reason)
		LrDialogs.message('Gallera: gallery not renamed',
			"The collection was renamed, but its Gallera gallery wasn't: " .. reason
				.. '\n\nRename the gallery on the website, or rename the collection again.', 'warning')
	end
	local api = Auth.api(publishSettings)
	if not api then return report(Auth.LOGIN_MESSAGE) end
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then return report(errorText(err)) end
	if found.state ~= 'active' then
		Log.info('rename collection: gallery', galleryId, 'is', found.state, '; not renamed')
		return
	end
	local gallery
	gallery, err = api:getGallery(found.slug)
	if not gallery then return report(errorText(err)) end
	-- Linking (D26) renames the collection to the gallery's name: nothing to save then.
	if gallery.name == newName then
		Log.info('rename collection: the gallery already has this name')
		return
	end
	gallery.name = newName
	local slug
	slug, err = api:saveGallery(found.slug, gallery)
	if not slug then return report(errorText(err)) end
	Log.info('rename collection: gallery', galleryId, 'renamed')
end

-- Deleting (§6.7) -----------------------------------------------------------------------

-- A Gallera failure is reported in a dialog, not raised. The trash call is never retried (DESIGN §8):
-- a second DELETE deletes the gallery permanently.
function provider.deletePublishedCollection(publishSettings, info)
	local collection = info.publishedCollection
	local galleryId = tonumber(collection and collection:getRemoteId())
	Log.info('delete collection: gallery', galleryId)
	if not galleryId then return end
	if type(CollectionStore.read(collection).deleted) == 'table' then
		Log.info('delete collection: gallery already flagged deleted; no prompt')
		return
	end

	local function report(reason)
		Log.warn('delete collection: gallery left on Gallera:', reason)
		LrDialogs.message('Gallera: gallery left on Gallera',
			'The collection was deleted, but its gallery stays on Gallera: ' .. reason
				.. '\n\nDelete the gallery on the website if you no longer need it.', 'warning')
	end
	local api = Auth.api(publishSettings)
	if not api then return report(Auth.LOGIN_MESSAGE) end
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then return report(errorText(err)) end
	if found.state ~= 'active' then
		Log.info('delete collection: gallery is', found.state, '; no prompt')
		return
	end

	local answer = LrDialogs.confirm('Delete the Gallera gallery too?',
		'Deleting the gallery moves it to the deleted galleries on the Gallera website. It can be restored there.',
		'Delete gallery', 'Keep gallery')
	if answer ~= 'ok' then
		Log.info('delete collection: gallery kept')
		return
	end
	local ok
	ok, err = api:trashGallery(galleryId)
	if not ok then return report(errorText(err)) end
	Log.info('delete collection: gallery', galleryId, 'moved to the trash')
end

return provider

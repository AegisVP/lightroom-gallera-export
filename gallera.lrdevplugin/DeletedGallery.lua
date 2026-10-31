--[[ Deleted gallery (D10, D11, DESIGN.md §6.9): the " - (deleted)" marker on a collection whose gallery was
     deleted on Gallera, the Restore / Create new / Cancel dialog, and the silent startup check.
     Network calls must run inside a task. Restore and the gallery delete are never retried (DESIGN §8). ]]
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local Auth = require 'Auth'
local GalleraApi = require 'GalleraApi'
local CollectionStore = require 'CollectionStore'
local GalleryLookup = require 'GalleryLookup'
local Log = require 'Log'
local Names = require 'Names'

local DeletedGallery = {}

local function write(name, fn)
	LrApplication.activeCatalog():withWriteAccessDo('Gallera: ' .. name, fn, { timeout = 10 })
end

local function rename(collection, name)
	if collection:getName() == name then return end
	local ok, err = LrTasks.pcall(write, 'rename collection', function() collection:setName(name) end)
	if not ok then Log.warn('deleted gallery: rename failed:', tostring(err)) end
end

local function errorText(err)
	if err and err.kind == 'auth' then return Auth.EXPIRED_MESSAGE end
	return GalleraApi.userText(err)   -- English; Gallera's own message is in the account's language
end

-- The collection's `deleted` flag { state, originalName }, or nil.
function DeletedGallery.flag(collection)
	local d = CollectionStore.read(collection).deleted
	return type(d) == 'table' and d or nil
end

-- The collection's name without the marker.
function DeletedGallery.originalName(collection)
	local flag = DeletedGallery.flag(collection)
	return flag and flag.originalName or Names.stripDeleted(collection:getName())
end

-- Stores the flag before renaming: a rename callback triggered by setName then only updates originalName (§6.6).
function DeletedGallery.mark(collection, state)
	local originalName = DeletedGallery.originalName(collection)
	CollectionStore.update(collection, { deleted = { state = state, originalName = originalName } })
	rename(collection, Names.markDeleted(collection:getName()))
	Log.info('deleted gallery: collection marked,', state)
end

function DeletedGallery.unmark(collection)
	local flag = DeletedGallery.flag(collection)
	if not flag then return end
	rename(collection, flag.originalName or Names.stripDeleted(collection:getName()))
	CollectionStore.update(collection, { deleted = CollectionStore.CLEAR })
	Log.info('deleted gallery: collection unmarked')
end

-- D11. Returns 'restore', 'createNew' or 'cancel'. Restore is offered only for a gallery in the trash.
function DeletedGallery.prompt(state, name)
	local trashed = state == 'trashed'
	local message = trashed and 'This gallery was deleted, but it is still available in Gallera trash.'
		or 'This gallery was deleted.'
	local info = 'Collection: ' .. name .. '\n\n'
		.. (trashed and 'Restore brings the gallery back. Photos deleted from the gallery may come back with it.\n' or '')
		.. 'Create new makes a new gallery and uploads all photos of the collection again.\n'
		.. 'Cancel leaves the collection marked as deleted.'
	if trashed then
		local answer = LrDialogs.confirm(message, info, 'Restore', 'Cancel', 'Create new')
		if answer == 'ok' then return 'restore' end
		if answer == 'other' then return 'createNew' end
		return 'cancel'
	end
	return LrDialogs.confirm(message, info, 'Create new', 'Cancel') == 'ok' and 'createNew' or 'cancel'
end

-- Creates a gallery for the collection and links it; every published photo is marked to re-publish and
-- the fingerprints are cleared so they really upload. Returns true | nil, message.
local function createNew(collection, api, name)
	local slug, err = api:createGallery { name = name, date = os.date('%Y-%m-%d') }
	if not slug then return nil, errorText(err) end
	local gallery
	gallery, err = api:getGallery(slug)
	if type(gallery) ~= 'table' or not tonumber(gallery.id) then return nil, errorText(err) end
	write('link new gallery', function()
		collection:setRemoteId(tostring(gallery.id))
		if type(gallery.public_url) == 'string' then collection:setRemoteUrl(gallery.public_url) end
		for _, published in ipairs(collection:getPublishedPhotos()) do published:setEditedFlag(true) end
	end)
	CollectionStore.update(collection, { fingerprints = CollectionStore.CLEAR })
	Log.info('deleted gallery: created gallery', gallery.id)
	return true
end

-- The D11 flow for a gallery found trashed or gone. Returns 'continue' (the collection is linked to an active
-- gallery again; the second value is 'restored' or 'created') or 'cancel' (the collection stays marked).
function DeletedGallery.handle(collection, api, found)
	local name = DeletedGallery.originalName(collection)
	local choice = DeletedGallery.prompt(found.state, name)
	Log.info('deleted gallery: gallery', found.state, '; user chose', choice)
	if choice == 'restore' then
		local ok, err = api:restoreGallery(found.slug)
		if ok then
			DeletedGallery.unmark(collection)
			return 'continue', 'restored'
		end
		Log.warn('deleted gallery: restore failed:', errorText(err))
		LrDialogs.message('Gallera: gallery not restored', errorText(err), 'critical')
	elseif choice == 'createNew' then
		local ok, err = createNew(collection, api, name)
		if ok then
			DeletedGallery.unmark(collection)
			return 'continue', 'created'
		end
		Log.warn('deleted gallery: create failed:', err)
		LrDialogs.message('Gallera: gallery not created', err, 'critical')
	end
	DeletedGallery.mark(collection, found.state)
	return 'cancel'
end

-- Startup check (§6.9) ------------------------------------------------------------------

local running = false

local function checkService(service)
	local okSettings, settings = LrTasks.pcall(function() return service:getPublishSettings() end)
	if not okSettings then return Log.warn('startup check: cannot read the service settings:', tostring(settings)) end
	local api = Auth.api(settings)
	if not api then return Log.info('startup check: not logged in; skipped') end
	local active, err = api:listGalleries()
	local trashed
	if active then trashed, err = api:listTrashedGalleries() end
	if not active or not trashed then return Log.warn('startup check: skipped:', errorText(err)) end

	local collections, ids = {}, {}
	for _, c in ipairs(service:getChildCollections()) do
		local id = tonumber(c:getRemoteId())
		if id then
			collections[#collections + 1] = { collection = c, id = id }
			ids[#ids + 1] = id
		end
	end
	-- D20: another account's login must not make every linked gallery look deleted.
	if not GalleryLookup.ownsAny(ids, active, trashed) then
		return Log.warn('startup check: the account owns none of the linked galleries; skipped')
	end
	local lookup = GalleryLookup.index(active, trashed)
	local marked, unmarked = 0, 0
	for _, entry in ipairs(collections) do
		local state = lookup(entry.id).state
		local action = GalleryLookup.reconcile(state, DeletedGallery.flag(entry.collection))
		if action == 'mark' then
			-- A publish may have restored or re-created the gallery since the lists were read (Lightroom runs
			-- this check at the start of each publish): look up the collection's current gallery again.
			local fresh = GalleryLookup.find(api, tonumber(entry.collection:getRemoteId()))
			if fresh and GalleryLookup.reconcile(fresh.state, DeletedGallery.flag(entry.collection)) == 'mark' then
				DeletedGallery.mark(entry.collection, fresh.state)
				marked = marked + 1
			else
				Log.info('startup check: gallery changed meanwhile; not marked')
			end
		elseif action == 'unmark' then
			DeletedGallery.unmark(entry.collection)
			unmarked = unmarked + 1
		end
	end
	Log.info('startup check:', #collections, 'collection(s),', marked, 'marked,', unmarked, 'unmarked')
end

-- Silent: errors are logged only. A run that starts while another is in progress returns at once.
function DeletedGallery.startupCheck()
	if running then return Log.info('startup check: already running') end
	running = true
	local ok, err = LrTasks.pcall(function()
		for _, service in ipairs(LrApplication.activeCatalog():getPublishServices(_PLUGIN.id)) do
			checkService(service)
		end
	end)
	running = false
	if not ok then Log.error('startup check failed:', tostring(err)) end
end

return DeletedGallery

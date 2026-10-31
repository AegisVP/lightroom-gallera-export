--[[ Published collection settings: create or link a gallery, the Gallera Settings tab, and the plugin's own
     settings (DESIGN.md §6.2, §6.3, §7.2; spikes S3, S4).
     Gallera is the source of truth (D3): the g_* fields are loaded fresh when the dialog opens, and on OK only
     the changed fields are applied to a freshly fetched gallery object. g_*, ui_* and link_* keys are
     dialog-only and are cleared when the dialog is saved, so the gallery password doesn't stay in the catalog.
     Note: 'visible' bindings don't work in these dialogs (Task 12 finding); controls use 'enabled'. ]]
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Auth = require 'Auth'
local CollectionStore = require 'CollectionStore'
local GalleryLookup = require 'GalleryLookup'
local GallerySettings = require 'GallerySettings'
local Log = require 'Log'
local PhotoOrder = require 'PhotoOrder'

local CollectionSettingsDialog = {}

local DEFAULT_LONG_EDGE = 2048
local DEFAULT_QUALITY = 80

-- The open dialog's state, shared by viewForCollectionSettings and updateCollectionSettings.
-- The dialog is modal, so there is at most one. { galleryId, baseline = normalized props | nil }
local session

local function gkey(key) return 'g_' .. key end

local function errorText(err)
	if err and err.kind == 'auth' then return Auth.EXPIRED_MESSAGE end
	return 'Gallera: ' .. tostring(err and err.message or 'unknown error')
end

local function isTrue(v) return v == true or v == 1 end

local function catalogWrite(name, fn)
	LrApplication.activeCatalog():withWriteAccessDo('Gallera: ' .. name, fn, { timeout = 10 })
end

-- Fields shown by the Access radio pair instead of their own controls.
local ACCESS_KEYS = { is_public = true, has_password = true }

local function enabledKey(field) return 'ui_en_' .. field.key end
local function itemsKey(field) return 'ui_items_' .. field.key end

-- Each control is enabled once the gallery is loaded, if its 'requires' switch is on and its 'availableKey'
-- flag was true in the gallery object.
local function refreshEnabled(cs)
	for _, field in ipairs(GallerySettings.FIELDS) do
		local on = cs.ui_loaded == true
		if field.requires then on = on and cs[gkey(field.requires)] == true end
		if field.availableKey then on = on and cs.ui_faceAvailable == true end
		cs[enabledKey(field)] = on
	end
end

local function setLoaded(cs, loaded, status)
	cs.ui_loaded = loaded
	cs.ui_status = status or ''
	refreshEnabled(cs)
end

-- Fills the g_* fields from a gallery object. Returns the normalized baseline.
local function fillFields(cs, gallery)
	local props = GallerySettings.normalize(GallerySettings.toProps(gallery))
	for _, f in ipairs(GallerySettings.FIELDS) do
		local v = props[f.key]
		if v == nil and f.type ~= 'number' then v = '' end
		if f.type == 'choice' then cs[itemsKey(f)] = GallerySettings.choiceItems(f, v) end
		cs[gkey(f.key)] = v
	end
	Log.info('collection settings: gallery language code', props.language)
	cs.ui_faceAvailable = isTrue(gallery.face_grouping_available)
	cs.ui_photoCount = tonumber(gallery.photos_count) or 0
	cs.ui_access = GallerySettings.accessMode(props)
	cs.ui_galleryName = type(gallery.name) == 'string' and gallery.name or ''
	cs.ui_publicUrl = type(gallery.public_url) == 'string' and gallery.public_url or ''
	return props
end

local function editedProps(cs)
	local props = {}
	for _, f in ipairs(GallerySettings.FIELDS) do props[f.key] = cs[gkey(f.key)] end
	return GallerySettings.normalize(props)
end

local function updateRemoteUrl(collection, publicUrl)
	if collection and type(publicUrl) == 'string' and collection:getRemoteUrl() ~= publicUrl then
		catalogWrite('update gallery URL', function() collection:setRemoteUrl(publicUrl) end)
		Log.info('collection settings: remoteUrl updated')
	end
end

-- Async: find the gallery, load it and fill the fields. collection is nil while linking.
local function loadGallery(cs, api, galleryId, collection)
	setLoaded(cs, false, 'Loading from Gallera…')
	local found, err = GalleryLookup.find(api, galleryId)
	if session == nil or session.galleryId ~= galleryId then return end
	if not found then return setLoaded(cs, false, errorText(err)) end
	if found.state ~= 'active' then
		return setLoaded(cs, false, found.state == 'trashed'
			and 'This gallery was deleted on Gallera. It is still in the Gallera trash.'
			or 'This gallery was deleted on Gallera.')
	end
	local gallery
	gallery, err = api:getGallery(found.slug)
	if session == nil or session.galleryId ~= galleryId then return end
	if not gallery then return setLoaded(cs, false, errorText(err)) end
	session.baseline = fillFields(cs, gallery)
	setLoaded(cs, true)
	Log.info('collection settings: loaded gallery', galleryId, found.slug)
	updateRemoteUrl(collection, gallery.public_url)
end

-- Gallery ids already linked to another collection of this service (D26).
local function linkedIds(info, except)
	local services = info.publishService and { info.publishService }
		or LrApplication.activeCatalog():getPublishServices(_PLUGIN.id)
	local ids = {}
	for _, service in ipairs(services) do
		for _, c in ipairs(service:getChildCollections()) do
			local id = tonumber(c:getRemoteId())
			if id and c ~= except then ids[id] = true end
		end
	end
	return ids
end

local function loadLinkPicker(cs, api, info)
	cs.ui_linkStatus = 'Loading galleries…'
	local names, err = api:listGalleryNames()
	if not names then
		cs.ui_linkStatus = errorText(err)
		return
	end
	local taken = linkedIds(info, info.publishedCollection)
	local items = {}
	for _, g in ipairs(names) do
		local id = tonumber(g.id)
		if id and not taken[id] then items[#items + 1] = { title = tostring(g.name), value = id } end
	end
	table.sort(items, function(a, b) return a.title:lower() < b.title:lower() end)
	cs.ui_linkItems = items
	cs.ui_linkStatus = #items == 0 and 'No unlinked galleries on Gallera.' or ''
end

local function onLinkChoice(cs, api)
	cs.ui_linkEnabled = cs.link_mode == 'link'
	if cs.link_mode == 'link' and tonumber(cs.link_id) then
		session.galleryId = tonumber(cs.link_id)
		session.baseline = nil
		local galleryId = session.galleryId
		LrTasks.startAsyncTask(function() loadGallery(cs, api, galleryId, nil) end)
	else
		session.galleryId = nil
		session.baseline = nil
		setLoaded(cs, false, cs.link_mode == 'link' and 'Pick a gallery to link.'
			or 'The gallery settings can be edited after the gallery is created.')
	end
end

-- View -------------------------------------------------------------------------

local function galleryView(f, cs, linked)
	local bind = LrView.bind
	if linked then
		return f:column {
			f:row {
				f:static_text { title = 'Gallery:', width = LrView.share 'galleryLabel' },
				f:static_text { title = bind 'ui_galleryName', width_in_chars = 40 },
			},
			f:row {
				f:static_text { title = 'Address:', width = LrView.share 'galleryLabel' },
				f:static_text { title = bind 'ui_publicUrl', width_in_chars = 40 },
				f:push_button {
					title = 'Open in browser',
					enabled = bind 'ui_loaded',
					action = function()
						if cs.ui_publicUrl and cs.ui_publicUrl ~= '' then LrHttp.openUrlInBrowser(cs.ui_publicUrl) end
					end,
				},
			},
		}
	end
	return f:column {
		f:radio_button { title = 'Create new gallery', value = bind 'link_mode', checked_value = 'create' },
		f:row {
			f:radio_button { title = 'Link existing gallery:', value = bind 'link_mode', checked_value = 'link' },
			f:popup_menu { value = bind 'link_id', items = bind 'ui_linkItems', enabled = bind 'ui_linkEnabled', width_in_chars = 30 },
		},
		f:static_text { title = bind 'ui_linkStatus', width_in_chars = 50 },
	}
end

local function fieldView(f, field, cs)
	local bind = LrView.bind
	local key = gkey(field.key)
	local enabled = bind(enabledKey(field))
	if field.type == 'bool' then
		return f:checkbox { title = field.label, value = bind(key), enabled = enabled }
	end
	local control
	if field.type == 'password' then
		-- Plain text on purpose: it's the user's own gallery password, shown in plain text on the website too.
		control = f:edit_field { value = bind(key), enabled = enabled, width_in_chars = 20 }
	elseif field.type == 'choice' then
		cs[itemsKey(field)] = GallerySettings.choiceItems(field, nil)
		control = f:popup_menu { value = bind(key), items = bind(itemsKey(field)), enabled = enabled, width_in_chars = 14 }
	elseif field.type == 'number' then
		control = f:edit_field {
			value = bind(key), enabled = enabled, precision = 0, width_in_digits = 6,
			validate = function(_, value)
				return GallerySettings.check(field, value, { [field.maxKey or ''] = cs.ui_photoCount })
			end,
		}
	else
		control = f:edit_field { value = bind(key), enabled = enabled, width_in_chars = field.type == 'date' and 10 or 22 }
	end
	local label = field.label .. (field.type == 'date' and ' (YYYY-MM-DD):' or ':')
	return f:row {
		f:static_text { title = label, width = LrView.share 'fieldLabel', alignment = 'right' },
		control,
	}
end

-- Access is one choice on the website: Public access, or Password access with the password field.
local function accessView(f)
	local bind = LrView.bind
	return f:row {
		f:radio_button { title = 'Public access', value = bind 'ui_access', checked_value = 'public', enabled = bind 'ui_loaded' },
		f:radio_button { title = 'Password access', value = bind 'ui_access', checked_value = 'password', enabled = bind 'ui_loaded' },
	}
end

local function sectionView(f, name, cs)
	local rows = { title = name, fill_horizontal = 1 }
	if name == 'Access' then rows[#rows + 1] = accessView(f) end
	for _, field in ipairs(GallerySettings.FIELDS) do
		if field.section == name and not ACCESS_KEYS[field.key] then rows[#rows + 1] = fieldView(f, field, cs) end
	end
	return f:group_box(rows)
end

local function pluginView(f)
	local bind = LrView.bind
	return f:group_box {
		title = 'Lightroom',
		fill_horizontal = 1,
		f:row {
			f:static_text { title = 'Order on Gallera:' },
			f:popup_menu {
				value = bind 'galleryOrder',
				items = {
					{ title = 'Capture date', value = 'capture' },
					{ title = 'Lightroom order (User Order)', value = 'lightroom' },
					{ title = "Don't change", value = 'none' },
				},
			},
		},
		f:static_text {
			title = 'Lightroom order: sort the collection by User Order and drag photos; Publish sends the order.',
			fill_horizontal = 1,
		},
		f:row {
			f:checkbox { title = 'Override size and quality:', value = bind 'overrideRender' },
			f:static_text { title = 'Long edge (px)' },
			f:edit_field { value = bind 'longEdge', enabled = bind 'overrideRender', min = 100, max = 20000, precision = 0, width_in_digits = 6 },
			f:static_text { title = 'JPEG quality (0–100)' },
			f:edit_field { value = bind 'jpegQuality', enabled = bind 'overrideRender', min = 0, max = 100, precision = 0, width_in_digits = 4 },
		},
	}
end

function CollectionSettingsDialog.viewForCollectionSettings(f, publishSettings, info)
	local cs = info.collectionSettings
	local collection = info.publishedCollection
	local remoteId = collection and collection:getRemoteId()
	local galleryId = tonumber(remoteId)
	session = { galleryId = galleryId }

	cs.galleryOrder = PhotoOrder.mode(cs)
	if cs.overrideRender == nil then cs.overrideRender = false end
	if cs.longEdge == nil then cs.longEdge = DEFAULT_LONG_EDGE end
	if cs.jpegQuality == nil then cs.jpegQuality = DEFAULT_QUALITY end
	cs.ui_galleryName = ''
	cs.ui_publicUrl = collection and collection:getRemoteUrl() or ''
	cs.ui_faceAvailable = false
	setLoaded(cs, false, 'Loading from Gallera…')

	local api = Auth.api(publishSettings)
	if galleryId then
		if api then
			LrTasks.startAsyncTask(function() loadGallery(cs, api, galleryId, collection) end)
		else
			setLoaded(cs, false, Auth.LOGIN_MESSAGE)
		end
	else
		cs.link_mode = 'create'
		cs.link_id = nil
		cs.ui_linkItems = {}
		cs.ui_linkEnabled = false
		cs.ui_linkStatus = ''
		setLoaded(cs, false, 'The gallery settings can be edited after the gallery is created.')
		if api then
			LrTasks.startAsyncTask(function() loadLinkPicker(cs, api, info) end)
			cs:addObserver('link_mode', function() onLinkChoice(cs, api) end)
			cs:addObserver('link_id', function() onLinkChoice(cs, api) end)
		else
			cs.ui_linkStatus = Auth.LOGIN_MESSAGE
		end
	end
	for _, field in ipairs(GallerySettings.FIELDS) do
		if field.requires then cs:addObserver(gkey(field.requires), function() refreshEnabled(cs) end) end
	end
	cs:addObserver('ui_access', function()
		local current = { is_public = cs.g_is_public, has_password = cs.g_has_password }
		for k, v in pairs(GallerySettings.accessChanges(current, cs.ui_access)) do cs[gkey(k)] = v end
	end)

	return f:column {
		bind_to_object = cs,
		spacing = f:control_spacing(),
		fill_horizontal = 1,
		f:group_box { title = 'Gallera gallery', fill_horizontal = 1, galleryView(f, cs, galleryId ~= nil) },
		f:static_text { title = LrView.bind 'ui_status', fill_horizontal = 1, width_in_chars = 70 },
		f:row {
			fill_horizontal = 1,
			f:column { fill_horizontal = 1, sectionView(f, 'General', cs), sectionView(f, 'Scenes', cs) },
			f:column { fill_horizontal = 1, sectionView(f, 'Favorites', cs), sectionView(f, 'Saving', cs), sectionView(f, 'Access', cs) },
		},
		pluginView(f),
	}
end

-- Save --------------------------------------------------------------------------

local function clearDialogKeys(cs)
	for _, f in ipairs(GallerySettings.FIELDS) do cs[gkey(f.key)] = nil end
	for _, f in ipairs(GallerySettings.FIELDS) do
		cs[enabledKey(f)] = nil
		cs[itemsKey(f)] = nil
	end
	for _, k in ipairs { 'ui_loaded', 'ui_status', 'ui_galleryName', 'ui_publicUrl', 'ui_faceAvailable', 'ui_photoCount',
		'ui_access', 'ui_linkItems', 'ui_linkEnabled', 'ui_linkStatus', 'link_mode', 'link_id' } do
		cs[k] = nil
	end
end

-- Returns the active gallery's slug and fresh object, or nil, message.
local function freshGallery(api, galleryId)
	local found, err = GalleryLookup.find(api, galleryId)
	if not found then return nil, errorText(err) end
	if found.state ~= 'active' then return nil, 'The Gallera gallery was deleted; its settings were not saved.' end
	local gallery
	gallery, err = api:getGallery(found.slug)
	if not gallery then return nil, errorText(err) end
	return found.slug, gallery
end

-- Creates the gallery or links the picked one, and records it on the collection. Returns gallery | nil, message.
local function createOrLink(api, cs, info, collection)
	local gallery, err
	if cs.link_mode == 'link' then
		local galleryId = tonumber(cs.link_id)
		if not galleryId then return nil, 'No gallery was picked, so the collection is not linked to Gallera.' end
		local _, fresh = freshGallery(api, galleryId)
		if type(fresh) ~= 'table' then return nil, fresh end
		gallery = fresh
	else
		local slug
		slug, err = api:createGallery { name = info.name, date = os.date('%Y-%m-%d') }
		if not slug then return nil, errorText(err) end
		gallery, err = api:getGallery(slug)
		if not gallery then return nil, 'The gallery was created, but reading it back failed. ' .. errorText(err) end
		Log.info('collection settings: created gallery', gallery.id, slug)
	end
	catalogWrite('link gallery', function()
		collection:setRemoteId(tostring(gallery.id))
		if type(gallery.public_url) == 'string' then collection:setRemoteUrl(gallery.public_url) end
	end)
	Log.info('collection settings: linked gallery', gallery.id)
	return gallery
end

-- Saves the changed Settings-tab fields to a fresh gallery object. Returns the gallery name now on Gallera.
local function saveChanges(api, galleryId, changed, collection)
	local slug, fresh = freshGallery(api, galleryId)
	if not slug then
		LrDialogs.message('Gallera settings were not saved', fresh, 'warning')
		return nil
	end
	local newSlug, err = api:saveGallery(slug, GallerySettings.apply(fresh, changed))
	if not newSlug then
		Log.warn('collection settings: save failed:', err and err.kind, err and err.status, err and err.message)
		LrDialogs.message('Gallera settings were not saved', errorText(err), 'warning')
		return nil
	end
	local keys = {}
	for k in pairs(changed) do keys[#keys + 1] = k end
	Log.info('collection settings: saved fields', table.concat(keys, ','), 'slug', newSlug)
	local saved = api:getGallery(newSlug)
	if saved then updateRemoteUrl(collection, saved.public_url) end
	return saved and saved.name
end

local function update(publishSettings, info)
	local cs = info.collectionSettings
	local collection = info.publishedCollection
	local s = session or {}
	session = nil
	if not collection then
		Log.warn('updateCollectionSettings: no publishedCollection')
		return
	end

	local api = Auth.api(publishSettings)
	local galleryId = tonumber(collection:getRemoteId())
	local linkedGallery
	if not galleryId then
		if not api then
			LrDialogs.message('Not linked to Gallera', Auth.LOGIN_MESSAGE, 'warning')
			return
		end
		local gallery, message = createOrLink(api, cs, info, collection)
		if not gallery then
			LrDialogs.message('Not linked to Gallera', message, 'warning')
			return
		end
		galleryId = tonumber(gallery.id)
		if cs.link_mode == 'link' then linkedGallery = gallery end
	end

	local newName
	if api and s.baseline and s.galleryId == galleryId then
		local changed = GallerySettings.diff(s.baseline, editedProps(cs))
		if next(changed) then newName = saveChanges(api, galleryId, changed, collection) end
	end

	-- D26: linking renames the collection to the gallery's name. Lightroom saves the dialog's name after this
	-- callback, so the rename runs 1 s later (spike S3).
	if linkedGallery then
		local name = newName or linkedGallery.name
		if type(name) == 'string' and name ~= '' and name ~= info.name then
			LrTasks.startAsyncTask(function()
				LrTasks.sleep(1)
				local ok, err = LrTasks.pcall(function()
					catalogWrite('rename collection', function() collection:setName(name) end)
				end)
				if not ok then Log.warn('link: rename failed:', tostring(err)) end
			end)
		end
	end
end

function CollectionSettingsDialog.updateCollectionSettings(publishSettings, info)
	local ok, err = LrTasks.pcall(update, publishSettings, info)
	clearDialogKeys(info.collectionSettings)
	-- Lightroom saves the dialog's values after this callback (S3), so the clear above doesn't always stick
	-- ('link test' kept g_password): rewrite the stored settings without dialog keys a moment later.
	local collection = info.publishedCollection
	if collection then
		LrTasks.startAsyncTask(function()
			LrTasks.sleep(1)
			local cleaned = LrTasks.pcall(CollectionStore.update, collection, {})
			if not cleaned then Log.warn('updateCollectionSettings: dialog keys not cleared') end
		end)
	end
	if not ok then
		Log.error('updateCollectionSettings failed:', tostring(err))
		LrDialogs.message('Gallera', 'Saving the collection settings failed: ' .. tostring(err), 'critical')
	end
end

return CollectionSettingsDialog

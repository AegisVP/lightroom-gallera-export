--[[ The gallery Settings tab (DESIGN.md §7.2, D3, D4). Core module: no Lightroom imports.
     Gallera is the source of truth: the dialog loads props fresh, diffs them on OK, and the changes are
     applied to a freshly fetched gallery object. Everything else in that object (design, cover, unknown
     fields, nulls, empty objects) is sent back unchanged. ]]
local json = require 'dkjson'

local GallerySettings = {}

-- key is the API field name. availableKey: a read-only gallery flag that must be true to enable the control.
-- requires: another field (a bool) that must be on to enable this one. min / maxKey: a number's range; maxKey
-- names a read-only gallery field holding the maximum.
GallerySettings.FIELDS = {
	{ section = 'General', key = 'name', label = 'Name', type = 'string' },
	{ section = 'General', key = 'date', label = 'Shooting date', type = 'date' },
	{ section = 'General', key = 'slug', label = 'Address', type = 'string' },
	-- The website's languages. Only 'en' is confirmed from a capture; the others are ISO 639-1 guesses,
	-- and an unknown code from Gallera is kept as an extra choice (choiceItems).
	{ section = 'General', key = 'language', label = 'Language', type = 'choice', options = {
		{ title = 'English', value = 'en' }, { title = 'Ukrainian', value = 'uk' }, { title = 'Polish', value = 'pl' },
		{ title = 'German', value = 'de' }, { title = 'Spanish', value = 'es' }, { title = 'Czech', value = 'cs' },
		{ title = 'French', value = 'fr' }, { title = 'Italian', value = 'it' },
	} },
	{ section = 'General', key = 'top_button_enabled', label = '"Up" button', type = 'bool' },
	{ section = 'General', key = 'allow_caption', label = 'Filename', type = 'bool' },
	{ section = 'General', key = 'allow_tutorial', label = 'Tutorial', type = 'bool' },
	{ section = 'General', key = 'autoplay_video', label = 'Autoplay videos', type = 'bool' },
	{ section = 'General', key = 'face_grouping_enabled', label = 'People recognition', type = 'bool',
		availableKey = 'face_grouping_available' },
	{ section = 'Scenes', key = 'allow_all_photos', label = 'Show all photos', type = 'bool' },
	{ section = 'Scenes', key = 'allow_empty_folders', label = 'Empty scenes', type = 'bool' },
	{ section = 'Scenes', key = 'allow_list_view', label = 'List view', type = 'bool' },
	{ section = 'Favorites', key = 'allow_favorite', label = 'Photo selection', type = 'bool' },
	{ section = 'Favorites', key = 'is_need_to_finish_favorites', label = 'Finish selection', type = 'bool',
		requires = 'allow_favorite' },
	{ section = 'Favorites', key = 'allow_limit_favorites', label = 'Limit number of photos', type = 'bool' },
	{ section = 'Favorites', key = 'limit_favorites', label = 'Photo limit', type = 'number',
		requires = 'allow_limit_favorites', min = 1, maxKey = 'photos_count' },
	{ section = 'Saving', key = 'allow_download', label = 'Download option', type = 'bool' },
	{ section = 'Saving', key = 'storage_to_date', label = 'Available until', type = 'date' },
	{ section = 'Access', key = 'is_public', label = 'Public access', type = 'bool' },
	{ section = 'Access', key = 'has_password', label = 'Password access', type = 'bool' },
	{ section = 'Access', key = 'password', label = 'Password', type = 'password',
		requires = 'has_password' },
	{ section = 'Access', key = 'allow_photo_hiding', label = 'Hiding photos', type = 'bool' },
	{ section = 'Access', key = 'photo_hiding_client_email', label = 'Client email', type = 'string',
		requires = 'allow_photo_hiding' },
}

-- The Settings-tab fields of a gallery object, with JSON null turned into nil.
function GallerySettings.toProps(gallery)
	local props = {}
	for _, f in ipairs(GallerySettings.FIELDS) do
		local v = gallery[f.key]
		if v ~= json.null then props[f.key] = v end
	end
	return props
end

-- Props in the form the dialog's controls use: bools are true/false (Gallera may send 1/0), numbers are
-- numbers, and an empty text field is nil (Gallera's null). Normalize both the baseline and the edited
-- values before diff, so an untouched dialog has no changes.
function GallerySettings.normalize(props)
	local out = {}
	for _, f in ipairs(GallerySettings.FIELDS) do
		local v = props[f.key]
		if f.type == 'bool' then
			v = v == true or v == 1 or v == '1'
		elseif f.type == 'number' then
			v = tonumber(v)
		elseif v == '' then
			v = nil
		end
		out[f.key] = v
	end
	return out
end

-- Access is one choice on the website: public, or password (with the password field). It's stored as two
-- flags, is_public and has_password, which the dialog sets together.
function GallerySettings.accessMode(props)
	if props.has_password == true or props.has_password == 1 then return 'password' end
	return 'public'
end

function GallerySettings.accessFields(mode)
	return { is_public = mode ~= 'password', has_password = mode == 'password' }
end

-- The flags to set when the dialog's Access choice is mode: none if the gallery is already in that mode
-- (showing the current mode must never change a flag), else both flags.
function GallerySettings.accessChanges(props, mode)
	if GallerySettings.accessMode(props) == mode then return {} end
	return GallerySettings.accessFields(mode)
end

-- Popup items for a 'choice' field. A current value that isn't a known option is added, so it's kept.
function GallerySettings.choiceItems(field, current)
	local items, known = {}, false
	for _, o in ipairs(field.options) do
		items[#items + 1] = { title = o.title, value = o.value }
		known = known or o.value == current
	end
	if type(current) == 'string' and current ~= '' and not known then
		items[#items + 1] = { title = current, value = current }
	end
	return items
end

-- Checks a dialog value against the field's range (min, and maxKey read from the gallery object).
-- Returns ok, value, message: the edit_field 'validate' contract.
function GallerySettings.check(field, value, gallery)
	if field.min == nil and field.maxKey == nil then return true, value end
	local n = tonumber(value)
	local min = field.min or 0
	local max = field.maxKey and math.max(tonumber(gallery and gallery[field.maxKey]) or 0, min)
	if n and n >= min and (max == nil or n <= max) then return true, n end
	local range = max and (min .. ' to ' .. max) or ('at least ' .. min)
	return false, value, field.label .. ' must be ' .. range .. '.'
end

-- Only the fields whose value changed. A field cleared in the dialog becomes json.null, so Gallera gets null.
function GallerySettings.diff(baseline, edited)
	local changed = {}
	for _, f in ipairs(GallerySettings.FIELDS) do
		local before, after = baseline[f.key], edited[f.key]
		if before ~= after then
			if after == nil then after = json.null end
			changed[f.key] = after
		end
	end
	return changed
end

-- Deep copy that keeps dkjson's metatables ({} stays an object) and the json.null sentinel itself.
local function copy(v)
	if type(v) ~= 'table' or v == json.null then return v end
	local out = {}
	for k, item in pairs(v) do out[k] = copy(item) end
	return setmetatable(out, getmetatable(v))
end

-- A new gallery object: fresh with the changed fields set. fresh itself is not modified.
function GallerySettings.apply(fresh, changed)
	local out = copy(fresh)
	for k, v in pairs(changed) do out[k] = v end
	return out
end

-- A copy of stored collection settings without the collection dialog's g_*/ui_*/link_* keys (dialog-only, D3;
-- g_password is the gallery password and must not stay in the catalog).
function GallerySettings.withoutDialogKeys(settings)
	local out = {}
	for k, v in pairs(settings) do
		local dialogKey = type(k) == 'string' and (k:find('^g_') or k:find('^ui_') or k:find('^link_'))
		if not dialogKey then out[k] = v end
	end
	return out
end

return GallerySettings

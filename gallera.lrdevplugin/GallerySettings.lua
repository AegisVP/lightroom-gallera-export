--[[ The gallery Settings tab (DESIGN.md §7.2, D3, D4). Core module: no Lightroom imports.
     Gallera is the source of truth: the dialog loads props fresh, diffs them on OK, and the changes are
     applied to a freshly fetched gallery object. Everything else in that object (design, cover, unknown
     fields, nulls, empty objects) is sent back unchanged. ]]
local json = require 'dkjson'

local GallerySettings = {}

-- key is the API field name. availableKey: a read-only gallery flag that must be true to enable the control.
GallerySettings.FIELDS = {
	{ section = 'General', key = 'name', label = 'Name', type = 'string' },
	{ section = 'General', key = 'date', label = 'Shooting date', type = 'date' },
	{ section = 'General', key = 'slug', label = 'Address', type = 'string' },
	{ section = 'General', key = 'language', label = 'Language', type = 'string' },
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
	{ section = 'Favorites', key = 'is_need_to_finish_favorites', label = 'Finish selection', type = 'bool' },
	{ section = 'Favorites', key = 'allow_limit_favorites', label = 'Limit number of photos', type = 'bool' },
	{ section = 'Favorites', key = 'limit_favorites', label = 'Photo limit', type = 'number' },
	{ section = 'Saving', key = 'allow_download', label = 'Download option', type = 'bool' },
	{ section = 'Saving', key = 'storage_to_date', label = 'Available until', type = 'date' },
	{ section = 'Access', key = 'is_public', label = 'Public access', type = 'bool' },
	{ section = 'Access', key = 'has_password', label = 'Password access', type = 'bool' },
	{ section = 'Access', key = 'password', label = 'Password', type = 'password' },
	{ section = 'Access', key = 'allow_photo_hiding', label = 'Hiding photos', type = 'bool' },
	{ section = 'Access', key = 'photo_hiding_client_email', label = 'Client email', type = 'string' },
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

return GallerySettings

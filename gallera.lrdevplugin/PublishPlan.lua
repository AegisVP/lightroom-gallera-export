--[[ Publish decisions that don't need Lightroom (DESIGN.md §6.4, §6.5). Core module: no Lightroom imports.
     classify and the favorites guard (D30), favorites index, storage estimate (D23), confirmed deletes. ]]
local FavoritesSync = require 'FavoritesSync'

local PublishPlan = {}

PublishPlan.DEFAULT_PHOTO_BYTES = 8 * 1024 * 1024

-- photos = { { key, remoteId = number|nil, fingerprint } }; fingerprints = { [key] = fingerprint at upload };
-- favoriteIndex = { [remoteId] = { titles } }; force = { [key] = true } for unchanged photos that re-upload.
-- unchanged: published and the picture didn't change. upload: new photos, picture changes and forced photos.
-- Entries are copies of the photos with .favorites = the titles of the lists their Gallera photo is in.
function PublishPlan.classify(opts)
	local unchanged, upload = {}, {}
	local index = opts.favoriteIndex or {}
	local force = opts.force or {}
	for _, photo in ipairs(opts.photos) do
		local entry = {
			key = photo.key, remoteId = photo.remoteId, fingerprint = photo.fingerprint,
			favorites = photo.remoteId and index[tonumber(photo.remoteId)] or nil,
		}
		local stored = opts.fingerprints[photo.key]
		if photo.remoteId and stored and stored == photo.fingerprint and not force[photo.key] then
			unchanged[#unchanged + 1] = entry
		else
			upload[#upload + 1] = entry
		end
	end
	return { unchanged = unchanged, upload = upload }
end

-- D30 guard: every queued photo re-uploads, except that photos on Gallera in client favorites (re-uploading drops
-- them from the lists) are listed for the user's choice, each with .changed. With unknown favorites every
-- queued photo on Gallera is listed. Returns guarded and force = { [key] = true } for the other unchanged photos.
function PublishPlan.guardFavorites(result, favoritesKnown)
	local guarded, force = {}, {}
	local function consider(p, changed)
		if not p.remoteId then return end
		if p.favorites or not favoritesKnown then
			guarded[#guarded + 1] = { key = p.key, remoteId = p.remoteId, favorites = p.favorites, changed = changed }
		elseif not changed then
			force[p.key] = true
		end
	end
	for _, p in ipairs(result.unchanged) do consider(p, false) end
	for _, p in ipairs(result.upload) do consider(p, true) end
	return guarded, force
end

-- The user's checks on the guarded photos: checked unchanged photos re-upload (force); unchecked changed photos
-- are held back (hold) and stay queued, since Gallera still has their old picture.
function PublishPlan.applyGuard(guarded, checked)
	local force, hold = {}, {}
	for _, p in ipairs(guarded) do
		if checked[p.key] then
			if not p.changed then force[p.key] = true end
		elseif p.changed then
			hold[p.key] = true
		end
	end
	return force, hold
end

local function isIncomplete(list)
	local latest = type(list.latest) == 'table' and list.latest or {}
	return #latest < (tonumber(list.items_count) or 0)
end

-- True when some list's latest[] is shorter than its items_count, so favoriteIndex needs the gallery's photos.
function PublishPlan.hasIncompleteFavorites(lists)
	for _, list in ipairs(lists) do
		if isIncomplete(list) then return true end
	end
	return false
end

local function baseName(filename)
	return (filename:gsub('%.[^.]*$', '')):lower()
end

-- { [photoId] = { display titles of the lists it's in } }, each title once. A list whose latest[] is incomplete
-- also matches its lightroom_list names against galleryPhotos' original_filename (without extension, any case);
-- an ambiguous name marks every photo that has it (a warning too many beats a lost favorite).
function PublishPlan.favoriteIndex(lists, galleryPhotos)
	local index = {}
	local function add(id, title)
		local titles = index[id] or {}
		index[id] = titles
		for _, t in ipairs(titles) do
			if t == title then return end
		end
		titles[#titles + 1] = title
	end
	local byName
	for _, list in ipairs(lists) do
		local title = FavoritesSync.displayTitle(list.title)
		for _, p in ipairs(type(list.latest) == 'table' and list.latest or {}) do
			local id = type(p) == 'table' and tonumber(p.id)
			if id then add(id, title) end
		end
		if isIncomplete(list) and galleryPhotos then
			if not byName then
				byName = {}
				for _, photo in ipairs(galleryPhotos) do
					local id = tonumber(photo.id)
					if id and type(photo.original_filename) == 'string' then
						local name = baseName(photo.original_filename)
						byName[name] = byName[name] or {}
						table.insert(byName[name], id)
					end
				end
			end
			for _, name in ipairs(type(list.lightroom_list) == 'table' and list.lightroom_list or {}) do
				if type(name) == 'string' then
					for _, id in ipairs(byName[name:lower()] or {}) do add(id, title) end
				end
			end
		end
	end
	return index
end

-- count photos x the average filesize of the gallery's photos, or DEFAULT_PHOTO_BYTES each for an empty gallery.
function PublishPlan.estimateBytes(count, galleryPhotos)
	local total, n = 0, 0
	for _, p in ipairs(galleryPhotos or {}) do
		local size = tonumber(p.filesize)
		if size then
			total = total + size
			n = n + 1
		end
	end
	local each = n > 0 and total / n or PublishPlan.DEFAULT_PHOTO_BYTES
	return count * each
end

local MB = 1024 * 1024
local GB = 1024 * MB

-- Free Gallera storage in bytes from a GET user response, or nil when the plan has no limit (D23 skips the check).
function PublishPlan.freeBytes(user)
	local storage = type(user) == 'table' and user.storage
	local limit = type(storage) == 'table' and tonumber(storage.limit)
	if not limit then return nil end
	return math.max(0, limit - (tonumber(storage.used) or 0))
end

function PublishPlan.formatBytes(bytes)
	if bytes < GB then return string.format('%.0f MB', bytes / MB) end
	return string.format('%.1f GB', bytes / GB)
end

-- D23 pre-check dialog text (§6.4 step 3).
function PublishPlan.storageWarning(free, estimate, count)
	return string.format('Gallera has %s free. This publish is estimated at ~%s (%d photos).',
		PublishPlan.formatBytes(free), PublishPlan.formatBytes(estimate), count)
end

-- D23 in-loop stop: the failure message for the photos that no longer fit.
function PublishPlan.storageFullMessage(used, limit)
	return string.format('Gallera storage full (used %s of %s)', PublishPlan.formatBytes(used), PublishPlan.formatBytes(limit))
end

-- The requested ids Lightroom may forget: those Gallera confirmed deleting, plus those no longer in the
-- gallery at all (deleted on the website). Ids still in the gallery and not confirmed stay.
function PublishPlan.confirmedDeletes(requestedIds, deletedIds, remainingIds)
	local deleted, remaining = {}, {}
	for _, id in ipairs(deletedIds or {}) do deleted[tonumber(id) or id] = true end
	for _, id in ipairs(remainingIds or {}) do remaining[tonumber(id) or id] = true end
	local out = {}
	for _, id in ipairs(requestedIds) do
		local n = tonumber(id) or id
		if deleted[n] or not remaining[n] then out[#out + 1] = id end
	end
	return out
end

-- The ids (numbers) whose photo is in galleryPhotos (listPhotos objects), in the order given.
function PublishPlan.inGallery(ids, galleryPhotos)
	local present = {}
	for _, p in ipairs(galleryPhotos or {}) do
		local id = tonumber(p.id)
		if id then present[id] = true end
	end
	local out = {}
	for _, id in ipairs(ids) do
		if present[tonumber(id)] then out[#out + 1] = id end
	end
	return out
end

return PublishPlan

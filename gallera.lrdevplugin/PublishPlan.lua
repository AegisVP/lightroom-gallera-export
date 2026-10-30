--[[ Publish decisions that don't need Lightroom (DESIGN.md §6.4, §6.5). Core module: no Lightroom imports.
     classify (D30, D31), favorites index, storage estimate (D23), confirmed deletes. ]]
local FavoritesSync = require 'FavoritesSync'

local PublishPlan = {}

PublishPlan.DEFAULT_PHOTO_BYTES = 8 * 1024 * 1024

-- photos = { { key, remoteId = number|nil, fingerprint } }; fingerprints = { [key] = fingerprint at upload };
-- favoriteIndex = { [remoteId] = { titles } }.
-- unchanged: published and the picture didn't change. upload: new photos and picture changes.
-- inFavorites: re-uploads whose current Gallera photo is in a client favorites list.
function PublishPlan.classify(opts)
	local unchanged, upload, inFavorites = {}, {}, {}
	local index = opts.favoriteIndex or {}
	for _, photo in ipairs(opts.photos) do
		local stored = opts.fingerprints[photo.key]
		if photo.remoteId and stored and stored == photo.fingerprint then
			unchanged[#unchanged + 1] = photo
		else
			upload[#upload + 1] = photo
			local titles = photo.remoteId and index[tonumber(photo.remoteId)]
			if titles then inFavorites[#inFavorites + 1] = { photo = photo, titles = titles } end
		end
	end
	return { unchanged = unchanged, upload = upload, inFavorites = inFavorites }
end

-- { [photoId] = { display titles of the lists it's in } }, each title once.
function PublishPlan.favoriteIndex(lists)
	local index = {}
	for _, list in ipairs(lists) do
		local title = FavoritesSync.displayTitle(list.title)
		for _, p in ipairs(list.latest or {}) do
			local id = type(p) == 'table' and tonumber(p.id)
			if id then
				local titles = index[id] or {}
				index[id] = titles
				local present = false
				for _, t in ipairs(titles) do present = present or t == title end
				if not present then titles[#titles + 1] = title end
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

return PublishPlan

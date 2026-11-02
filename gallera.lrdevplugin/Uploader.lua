--[[ Uploads one photo: request a signed URL -> PUT the bytes -> confirm (D25, DESIGN.md §6.4 step 6).
     Core module: no Lightroom imports; sleep(seconds) is injected (LrTasks.sleep in Lightroom).
     Up to 3 attempts, each with a fresh signed URL, waiting WAITS between them. Retried: network errors
     and any failed PUT. 'auth' stops at once (the publish aborts); other 'api' errors fail the photo.
     A half-created Gallera photo is deleted after a failed attempt (best effort, once per attempt). ]]
local Uploader = {}

Uploader.WAITS = { 2, 5 }

local function cleanup(api, slug, photoId)
	api:deletePhotos(slug, { photoId })
end

-- One attempt. Returns photoId | nil, err, retryable.
local function attempt(api, photo, contentType)
	local target, err = api:requestUpload {
		galleryId = photo.galleryId,
		filename = photo.filename,
		filesize = #photo.bytes,
		filetype = contentType,
	}
	if not target then return nil, err, err.kind == 'network' end

	local ok
	ok, err = api:putFile(target.url, photo.bytes, contentType)
	if not ok then
		cleanup(api, photo.slug, target.photoId)
		return nil, err, err.kind ~= 'auth'
	end

	ok, err = api:confirmUpload(target.photoId)
	if not ok then
		cleanup(api, photo.slug, target.photoId)
		return nil, err, err.kind == 'network'
	end
	return target.photoId
end

-- photo = { galleryId, slug, filename, bytes, contentType }. Returns photoId | nil, err.
function Uploader.upload(api, photo, sleep)
	local contentType = photo.contentType or 'image/jpeg'
	local attempts = #Uploader.WAITS + 1
	local err
	for n = 1, attempts do
		if n > 1 then sleep(Uploader.WAITS[n - 1]) end
		local photoId, attemptErr, retryable = attempt(api, photo, contentType)
		if photoId then return photoId end
		err = attemptErr
		if not retryable then break end
	end
	return nil, err
end

return Uploader

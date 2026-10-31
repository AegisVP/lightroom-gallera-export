--[[ Every Gallera HTTP call (docs/gallera-api.md, DESIGN.md §5.2). Core module: no Lightroom imports.
     The HTTP adapter is injected:
       adapter.request{ method, url, headers = {[name]=value}, body = string|nil, multipart = {{name, value}}|nil }
         --> { status = number, body = string } | nil, networkMessage
     Failures return nil, err with err = { kind = 'auth'|'notFound'|'network'|'api', status, message }.
     Gallera's message is localized: it's only shown or logged, never branched on. ]]
local json = require 'dkjson'

local GalleraApi = {}
GalleraApi.__index = GalleraApi

GalleraApi.BASE_URL = 'https://api.gallera.io/api/'

-- Stops a runaway pagination loop if has_more never turns false.
local MAX_PAGES = 1000

function GalleraApi.new(opts)
	return setmetatable({ http = opts.http, token = opts.token }, GalleraApi)
end

function GalleraApi:headers(jsonBody)
	local h = {
		Accept = 'application/json',
		['X-Requested-With'] = 'XMLHttpRequest',
	}
	if jsonBody then h['Content-Type'] = 'application/json' end
	if self.token then h.Authorization = 'Bearer ' .. self.token end
	return h
end

local function fail(kind, status, message)
	return nil, { kind = kind, status = status, message = message }
end

-- Unwraps the {status, message, data} envelope and maps errors (order: auth, notFound, api).
local function unwrap(resp)
	local decoded
	if resp.body and resp.body ~= '' then
		decoded = json.decode(resp.body, 1, json.null)
	end
	if type(decoded) ~= 'table' then decoded = nil end
	local status = decoded and decoded.status
	local message = decoded and type(decoded.message) == 'string' and decoded.message
		or ('HTTP ' .. tostring(resp.status))
	if resp.status == 401 or resp.status == 403 or status == 'auth' then
		return fail('auth', resp.status, message)
	end
	if resp.status == 404 or status == 'notFound' then
		return fail('notFound', resp.status, message)
	end
	if status ~= 'success' then
		return fail('api', resp.status, message)
	end
	return decoded.data
end

-- English text for the user. A message that came from Gallera (the error has an HTTP status) is in the
-- account's language, so it's replaced by a generic text and only logged by the caller; the plugin's own
-- messages (no status) are kept. 'auth' is worded by the caller (Auth.EXPIRED_MESSAGE).
function GalleraApi.userText(err)
	if not err then return 'Gallera error.' end
	if err.kind == 'network' then return "Gallera can't be reached. Check the internet connection." end
	if err.status == nil then return tostring(err.message or 'Gallera error.') end
	if err.kind == 'notFound' then return string.format('Not found on Gallera (HTTP %s).', tostring(err.status)) end
	local code = tonumber(err.status) or 0
	if code >= 400 and code < 500 then
		return string.format('Gallera rejected the request (HTTP %d).', code)
	end
	return string.format('Gallera error (HTTP %s). Try again later.', tostring(err.status))
end

-- For callers that read fields from data: passes err through, or reports a success without usable data.
local function unexpected(err)
	if err then return nil, err end
	return fail('api', nil, 'Unexpected response from Gallera')
end

-- A JSON API call: path is relative to BASE_URL, bodyTable (optional) is sent as JSON.
function GalleraApi:call(method, path, bodyTable)
	local req = {
		method = method,
		url = GalleraApi.BASE_URL .. path,
		headers = self:headers(bodyTable ~= nil),
		body = bodyTable ~= nil and json.encode(bodyTable) or nil,
	}
	return self:send(req)
end

-- One request through the adapter. A response without a real HTTP status counts as a transport failure:
-- offline, LrHttp returns a body but no status (seen in Lightroom as "HTTP 0").
function GalleraApi:transport(req)
	local resp, networkMessage = self.http.request(req)
	if resp and not ((tonumber(resp.status) or 0) > 0) then
		return nil, networkMessage or 'No response from the server'
	end
	return resp, networkMessage
end

-- Only GET retries, once, and only on a transport failure.
function GalleraApi:send(req)
	local attempts = req.method == 'GET' and 2 or 1
	local resp, networkMessage
	for _ = 1, attempts do
		resp, networkMessage = self:transport(req)
		if resp then break end
	end
	if not resp then return fail('network', nil, networkMessage or 'network error') end
	return unwrap(resp)
end

-- Auth ------------------------------------------------------------------------

-- Returns token, user. The api uses the new token from then on.
function GalleraApi:login(email, password)
	local data, err = self:call('POST', 'auth/login', { email = email, password = password })
	if type(data) ~= 'table' then return unexpected(err) end
	self.token = data.token
	return data.token, data.user
end

function GalleraApi:logout()
	local _, err = self:call('POST', 'auth/logout')
	if err then return nil, err end
	return true
end

function GalleraApi:getUser()
	return self:call('GET', 'user')
end

-- Galleries -------------------------------------------------------------------

-- All active galleries, following v2 pagination.
function GalleraApi:listGalleries()
	local all = {}
	for page = 1, MAX_PAGES do
		local data, err = self:call('GET', 'v2/galleries/my?page=' .. page .. '&sort=created&search=')
		if type(data) ~= 'table' then return unexpected(err) end
		for _, g in ipairs(data.galleries or {}) do all[#all + 1] = g end
		if not (type(data.pagination) == 'table' and data.pagination.has_more == true) then break end
	end
	return all
end

-- {id, name}[] for the link picker.
function GalleraApi:listGalleryNames()
	return self:call('GET', 'galleries/list')
end

-- The response shape isn't documented: accept a bare array or {galleries = [...]}.
function GalleraApi:listTrashedGalleries()
	local data, err = self:call('GET', 'galleries/my/deleted')
	if type(data) ~= 'table' then return unexpected(err) end
	if type(data.galleries) == 'table' then return data.galleries end
	return data
end

-- Returns the new gallery's slug (the response has no id; use getGallery for it).
function GalleraApi:createGallery(opts)
	local data, err = self:call('POST', 'galleries/create', {
		name = opts.name,
		date = opts.date,
		storage_period = '0',
		copy_gallery_id = json.null,
	})
	if type(data) ~= 'table' then return unexpected(err) end
	return data.gallery
end

-- The full gallery object, decoded with json.null so it can be saved back unchanged.
function GalleraApi:getGallery(slug)
	return self:call('GET', 'galleries/' .. slug)
end

-- Sends the full gallery object (read-modify-write). Returns the slug, which may have changed.
function GalleraApi:saveGallery(slug, gallery)
	local data, err = self:call('POST', 'galleries/' .. slug, gallery)
	if type(data) ~= 'table' then return unexpected(err) end
	return data.slug
end

-- Never retried (DESIGN.md §8).
function GalleraApi:restoreGallery(slug)
	local _, err = self:call('POST', 'galleries/' .. slug .. '/restore')
	if err then return nil, err end
	return true
end

-- Moves an ACTIVE gallery to the trash. DELETE on a trashed gallery deletes it permanently, so this
-- looks the id up first, refuses anything not active, and never retries (CLAUDE.md, DESIGN.md §5.2).
-- No function here deletes a gallery permanently.
function GalleraApi:trashGallery(galleryId)
	local galleries, err = self:listGalleries()
	if not galleries then return nil, err end
	local slug
	for _, g in ipairs(galleries) do
		if tonumber(g.id) == tonumber(galleryId) then slug = g.slug end
	end
	if not slug then
		return fail('api', nil, 'The gallery is not active on Gallera; it was not deleted.')
	end
	local _, deleteErr = self:call('DELETE', 'galleries/' .. slug .. '/delete')
	if deleteErr then return nil, deleteErr end
	return true
end

-- Photos ----------------------------------------------------------------------

-- Photo objects in gallery order, without photos that have a deleted_at.
function GalleraApi:listPhotos(slug)
	local data, err = self:call('GET', 'photos/' .. slug)
	if type(data) ~= 'table' then return unexpected(err) end
	local photos = {}
	for _, p in ipairs(data) do
		if p.deleted_at == nil or p.deleted_at == json.null then photos[#photos + 1] = p end
	end
	return photos
end

-- Whole numbers as plain digits ('%d' overflows 32-bit longs on Windows; tostring can give 1e+15).
local function digits(n)
	return string.format('%.0f', n)
end

-- Upload step 1: a signed R2 URL (expires in 20 min) and the new photo's id.
function GalleraApi:requestUpload(opts)
	local data, err = self:send {
		method = 'POST',
		url = GalleraApi.BASE_URL .. 'photos/upload/url',
		headers = self:headers(false),
		multipart = {
			{ name = 'gallery', value = digits(opts.galleryId) },
			{ name = 'filename', value = opts.filename },
			{ name = 'filesize', value = digits(opts.filesize) },
			{ name = 'filetype', value = opts.filetype },
		},
	}
	if type(data) ~= 'table' or type(data.photo) ~= 'table' then return unexpected(err) end
	return { url = data.url, photoId = data.photo.id }
end

-- Upload step 2: PUT the bytes to R2. Only Content-Type is sent: no Authorization, no JSON envelope.
-- A rejected PUT (e.g. 403 for an expired URL) is 'api', not 'auth': the login is fine, the URL isn't.
function GalleraApi:putFile(url, bytes, contentType)
	local resp, networkMessage = self:transport {
		method = 'PUT',
		url = url,
		headers = { ['Content-Type'] = contentType },
		body = bytes,
	}
	if not resp then return fail('network', nil, networkMessage or 'network error') end
	if resp.status >= 200 and resp.status < 300 then return true end
	local code = resp.body and resp.body:match('<Code>(.-)</Code>')
	return fail('api', resp.status, 'Upload rejected: HTTP ' .. tostring(resp.status) .. (code and (' ' .. code) or ''))
end

-- Upload step 3.
function GalleraApi:confirmUpload(photoId)
	local _, err = self:call('POST', 'photos/upload/' .. digits(photoId) .. '/uploaded', { photo = photoId })
	if err then return nil, err end
	return true
end

-- Returns the ids Gallera reports as deleted. Never retried (DESIGN.md §8).
function GalleraApi:deletePhotos(slug, ids)
	local data, err = self:call('POST', 'photos/delete', { gallery = slug, photos = ids })
	if type(data) ~= 'table' then return unexpected(err) end
	return data
end

-- ids must be the COMPLETE list of the gallery's photos. folderId is nil for the whole gallery.
function GalleraApi:sortPhotos(slug, ids, folderId)
	local _, err = self:call('POST', 'photos/sort', {
		sorted = ids,
		gallery = slug,
		folder = folderId == nil and json.null or folderId,
		type = 'manual',
	})
	if err then return nil, err end
	return true
end

-- Favorites -------------------------------------------------------------------

-- One entry per client favorites list (id, title, is_finished, items_count, latest[], lightroom_list[]).
function GalleraApi:getFavorites(slug)
	local data, err = self:call('GET', 'galleries/' .. slug .. '/favorites')
	if type(data) ~= 'table' then return unexpected(err) end
	return data
end

return GalleraApi

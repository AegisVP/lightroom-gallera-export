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

-- Only GET retries, once, and only on a transport failure.
function GalleraApi:send(req)
	local attempts = req.method == 'GET' and 2 or 1
	local resp, networkMessage
	for _ = 1, attempts do
		resp, networkMessage = self.http.request(req)
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

return GalleraApi

--[[ The HTTP adapter GalleraApi expects (DESIGN.md §5.2), built on LrHttp. Must run inside a task.
       request{ method, url, headers = {[name]=value}, body, multipart = {{name, value}} }
         --> { status, body } | nil, networkMessage ]]
local LrDate = import 'LrDate'
local LrHttp = import 'LrHttp'

local Log = require 'Log'

local LrHttpAdapter = {}

local TIMEOUT = 60
local PUT_TIMEOUT = 300

local function headerList(map)
	local list = {}
	for field, value in pairs(map or {}) do list[#list + 1] = { field = field, value = value } end
	return list
end

-- The URL without its query string (signed URLs carry credentials there).
local function shortUrl(url)
	return (url:gsub('%?.*$', ''))
end

function LrHttpAdapter.request(req)
	local t0 = LrDate.currentTime()
	local body, headers
	if req.method == 'GET' then
		body, headers = LrHttp.get(req.url, headerList(req.headers), TIMEOUT)
	elseif req.multipart then
		body, headers = LrHttp.postMultipart(req.url, req.multipart, headerList(req.headers), TIMEOUT)
	else
		body, headers = LrHttp.post(req.url, req.body or '', headerList(req.headers), req.method,
			req.method == 'PUT' and PUT_TIMEOUT or TIMEOUT)
	end
	local elapsed = string.format('%.2fs', LrDate.currentTime() - t0)
	if body == nil then
		local e = headers and headers.error
		local message = (e and e.name) or 'network error'
		Log.warn(req.method, shortUrl(req.url), '-> network error', message, elapsed)
		return nil, message
	end
	local status = headers and tonumber(headers.status) or 0
	Log.info(req.method, shortUrl(req.url), '-> HTTP', status, elapsed)
	return { status = status, body = body }
end

return LrHttpAdapter

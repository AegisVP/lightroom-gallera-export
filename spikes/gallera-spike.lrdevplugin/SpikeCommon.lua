--[[ Shared helpers for the spike plugin: logging, token, minimal JSON, HTTP, JPEG inspection. ]]
local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'
local LrLogger = import 'LrLogger'
local LrPasswords = import 'LrPasswords'
local LrPathUtils = import 'LrPathUtils'

local Common = {}

Common.API = 'https://api.gallera.io/api/'
local TOKEN_KEY = 'gallera.spike.token'

-- Log ------------------------------------------------------------------------
-- Never pass tokens, passwords, signed URLs or whole gallery objects here.

local logger = LrLogger('GalleraSpike')
logger:enable('logfile')

function Common.log(...)
	local parts = {}
	for i = 1, select('#', ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	logger:info(table.concat(parts, ' '))
end

-- Token ----------------------------------------------------------------------

function Common.token()
	local t = LrPasswords.retrieve(TOKEN_KEY)
	if t == nil or t == '' then return nil end
	return t
end

-- LrPasswords.store rejects nil ("keystring or password is nil"), so logout stores ''.
function Common.setToken(token)
	LrPasswords.store(TOKEN_KEY, token or '')
end

-- JSON (decode + string quoting only; good enough for a spike) ---------------

local ESCAPES = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }

local function utf8char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
	return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

function Common.decode(s)
	local pos = 1
	local value

	local function fail(what)
		error(string.format('JSON: %s at %d', what, pos))
	end

	local function skip()
		pos = s:find('[^ \t\r\n]', pos) or #s + 1
	end

	local function str()
		pos = pos + 1
		local buf = {}
		while true do
			local j = s:find('["\\]', pos)
			if not j then fail('unterminated string') end
			buf[#buf + 1] = s:sub(pos, j - 1)
			if s:sub(j, j) == '"' then
				pos = j + 1
				return table.concat(buf)
			end
			local e = s:sub(j + 1, j + 1)
			if e == 'u' then
				buf[#buf + 1] = utf8char(tonumber(s:sub(j + 2, j + 5), 16) or 63)
				pos = j + 6
			else
				buf[#buf + 1] = ESCAPES[e] or e
				pos = j + 2
			end
		end
	end

	function value()
		skip()
		local c = s:sub(pos, pos)
		if c == '{' then
			pos = pos + 1
			local t = {}
			skip()
			if s:sub(pos, pos) == '}' then pos = pos + 1; return t end
			while true do
				skip()
				if s:sub(pos, pos) ~= '"' then fail('expected key') end
				local k = str()
				skip()
				if s:sub(pos, pos) ~= ':' then fail('expected :') end
				pos = pos + 1
				t[k] = value()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == '}' then return t end
				if d ~= ',' then fail('expected , or }') end
			end
		elseif c == '[' then
			pos = pos + 1
			local t, n = {}, 0
			skip()
			if s:sub(pos, pos) == ']' then pos = pos + 1; return t end
			while true do
				n = n + 1
				t[n] = value()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == ']' then return t end
				if d ~= ',' then fail('expected , or ]') end
			end
		elseif c == '"' then
			return str()
		elseif s:sub(pos, pos + 3) == 'true' then
			pos = pos + 4
			return true
		elseif s:sub(pos, pos + 4) == 'false' then
			pos = pos + 5
			return false
		elseif s:sub(pos, pos + 3) == 'null' then
			pos = pos + 4
			return nil
		end
		local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
		if not num then fail('unexpected character') end
		pos = pos + #num
		return tonumber(num)
	end

	return value()
end

local QUOTE_ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

-- Quotes a string as a JSON string literal.
function Common.q(s)
	local escaped = tostring(s):gsub('[%c"\\]', function(c)
		return QUOTE_ESCAPES[c] or string.format('\\u%04x', c:byte())
	end)
	return '"' .. escaped .. '"'
end

-- Gallera HTTP ---------------------------------------------------------------
-- Every call returns data, err, httpStatus. err is nil on success (data may be nil too).

local function headerList(withJsonBody)
	local h = {
		{ field = 'Accept', value = 'application/json' },
		{ field = 'X-Requested-With', value = 'XMLHttpRequest' },
	}
	if withJsonBody then
		h[#h + 1] = { field = 'Content-Type', value = 'application/json' }
	end
	local token = Common.token()
	if token then
		h[#h + 1] = { field = 'Authorization', value = 'Bearer ' .. token }
	end
	return h
end

local function finish(method, path, body, hdrs, t0)
	local status = hdrs and hdrs.status
	local elapsed = string.format('%.2fs', LrDate.currentTime() - t0)
	if body == nil then
		local e = hdrs and hdrs.error
		Common.log(method, path, '-> network error', e and e.name, e and e.nativeCode, elapsed)
		return nil, 'network error: ' .. tostring(e and e.name), status
	end
	local ok, decoded = pcall(Common.decode, body)
	if not ok or type(decoded) ~= 'table' then decoded = nil end
	Common.log(method, path, '-> HTTP', status, decoded and decoded.status, decoded and decoded.message, elapsed)
	if not decoded or decoded.status ~= 'success' then
		return nil, string.format('HTTP %s: %s', tostring(status),
			tostring(decoded and decoded.message or 'unparseable response')), status
	end
	return decoded.data, nil, status
end

function Common.api(method, path, jsonBody)
	local t0 = LrDate.currentTime()
	local url = Common.API .. path
	local body, hdrs
	if method == 'GET' then
		body, hdrs = LrHttp.get(url, headerList(false))
	else
		body, hdrs = LrHttp.post(url, jsonBody or '', headerList(jsonBody ~= nil), method)
	end
	return finish(method, path, body, hdrs, t0)
end

function Common.apiMultipart(path, parts)
	local t0 = LrDate.currentTime()
	local body, hdrs = LrHttp.postMultipart(Common.API .. path, parts, headerList(false))
	return finish('POST', path, body, hdrs, t0)
end

-- Files ----------------------------------------------------------------------

function Common.readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local data = f:read('*a')
	f:close()
	return data
end

function Common.writeFile(path, data)
	local f = assert(io.open(path, 'wb'))
	f:write(data)
	f:close()
end

-- Pictures\GalleraSpike\<sub>
function Common.outputFolder(sub)
	local dir = LrPathUtils.child(LrPathUtils.child(LrPathUtils.getStandardFilePath('pictures'), 'GalleraSpike'), sub)
	LrFileUtils.createAllDirectories(dir)
	return dir
end

-- JPEG inspection: pixel size from SOF, approximate quality from the luminance DQT -------

local STD_LUMA_SUM = 3688   -- sum of the IJG standard luminance quantization table

function Common.jpegInfo(data)
	local info = { bytes = #data }
	if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then
		info.error = 'not a JPEG'
		return info
	end
	local i = 3
	while i + 3 <= #data do
		if data:byte(i) ~= 0xFF then info.error = 'marker sync lost'; break end
		local m = data:byte(i + 1)
		if m == 0xFF then
			i = i + 1
		elseif m == 0x01 or (m >= 0xD0 and m <= 0xD7) then
			i = i + 2
		elseif m == 0xD9 or m == 0xDA then
			break
		else
			local len = data:byte(i + 2) * 256 + data:byte(i + 3)
			local seg = i + 4
			if m == 0xDB then
				local p, stop = seg, i + 2 + len
				while p < stop do
					local pq, tq = math.floor(data:byte(p) / 16), data:byte(p) % 16
					local sum = 0
					for k = 1, 64 do
						if pq == 0 then
							sum = sum + data:byte(p + k)
						else
							sum = sum + data:byte(p + 2 * k - 1) * 256 + data:byte(p + 2 * k)
						end
					end
					if tq == 0 then info.lumaSum = sum end
					p = p + 1 + (pq == 0 and 64 or 128)
				end
			elseif m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
				info.height = data:byte(seg + 1) * 256 + data:byte(seg + 2)
				info.width = data:byte(seg + 3) * 256 + data:byte(seg + 4)
			end
			i = i + 2 + len
		end
	end
	if info.lumaSum then
		local scale = info.lumaSum * 100 / STD_LUMA_SUM
		local q = scale <= 100 and (200 - scale) / 2 or 5000 / scale
		info.quality = math.floor(q + 0.5)
	end
	return info
end

function Common.describeJpeg(info)
	if info.error and not info.width then return 'ERROR ' .. info.error end
	return string.format('%sx%s px, quality ~%s (IJG scale), %d KB',
		tostring(info.width), tostring(info.height), tostring(info.quality), math.floor(info.bytes / 1024))
end

return Common

--[[ A scripted HTTP adapter for GalleraApi tests. Queue responses with respond / failNetwork;
     every request is recorded in fake.requests. A request with nothing queued raises an error. ]]
local json = require('dkjson')

local FakeHttp = {}

function FakeHttp.new()
	local fake = { requests = {}, queue = {} }

	-- body: a table (JSON-encoded), a string (sent as is) or nil (empty body).
	function fake:respond(status, body)
		if type(body) == 'table' then body = json.encode(body) end
		self.queue[#self.queue + 1] = { status = status, body = body or '' }
	end

	function fake:failNetwork(msg)
		self.queue[#self.queue + 1] = { network = msg or 'network error' }
	end

	fake.adapter = {
		request = function(req)
			fake.requests[#fake.requests + 1] = req
			local r = table.remove(fake.queue, 1)
			if not r then error('FakeHttp: no response queued for ' .. tostring(req.method) .. ' ' .. tostring(req.url), 2) end
			if r.network then return nil, r.network end
			return { status = r.status, body = r.body }
		end,
	}

	return fake
end

-- The success envelope around data.
function FakeHttp.ok(data)
	return { status = 'success', message = 'OK', data = data }
end

-- The raw text of spec/fixtures/<name>.
function FakeHttp.fixture(name)
	local f = assert(io.open('spec/fixtures/' .. name, 'rb'))
	local s = f:read('*a')
	f:close()
	return s
end

-- A success envelope (raw JSON text) around a fixture's JSON, so the fixture's own encoding is kept.
function FakeHttp.okRaw(dataJson)
	return '{"status":"success","message":"OK","data":' .. dataJson .. '}'
end

return FakeHttp

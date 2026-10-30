--[[ LrLogger wrapper (DESIGN.md §8). Every argument passes through Redact: strings lose signed URLs,
     tables lose secret fields and are written as JSON. Writes to
     %LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\Gallera.log.
     Still never pass a token, password, email or whole gallery object here. ]]
local LrLogger = import 'LrLogger'

local json = require 'dkjson'
local Redact = require 'Redact'

local logger = LrLogger('Gallera')
logger:enable('logfile')

local Log = {}

local function format(...)
	local parts = {}
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if type(v) == 'table' then
			-- exception: unsupported values (functions, Lightroom objects) become strings instead of raising.
			parts[#parts + 1] = json.encode(Redact.value(v), { exception = json.encodeexception })
		elseif type(v) == 'string' then
			parts[#parts + 1] = Redact.text(v)
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	return table.concat(parts, ' ')
end

function Log.info(...) logger:info(format(...)) end
function Log.warn(...) logger:warn(format(...)) end
function Log.error(...) logger:error(format(...)) end

return Log

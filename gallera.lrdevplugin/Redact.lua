--[[ Masks secrets before anything is logged (DESIGN.md §8). Core module: no Lightroom imports. ]]
local Redact = {}

local SECRET_KEYS = { password = true, token = true, access_token = true, public_url_with_token = true }
local MASK = '***'

-- Replaces every whitespace-delimited URL that carries an R2 signature with '<signed url>'.
function Redact.text(s)
	return (s:gsub('%S+', function(word)
		if word:find('X-Amz-Signature', 1, true) then return '<signed url>' end
	end))
end

local function copy(v, seen)
	if type(v) == 'string' then return Redact.text(v) end
	if type(v) ~= 'table' then return v end
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, item in pairs(v) do
		if type(k) == 'string' and SECRET_KEYS[k:lower()] then
			out[k] = MASK
		else
			out[k] = copy(item, seen)
		end
	end
	-- Keeps dkjson's object/array/null markers, so the copy encodes like the original.
	return setmetatable(out, getmetatable(v))
end

-- Returns a deep copy of v with secret fields masked. v itself is not modified.
function Redact.value(v)
	return copy(v, {})
end

return Redact

--[[ D30: a stable hash of what shapes a photo's rendered pixels (develop settings, orientation, render
     settings), so a metadata-only change doesn't re-upload the photo. Core module: no Lightroom imports.
     Change detection only, not security: two 32-bit rolling hashes in plain arithmetic (Lua 5.1 has no
     bit operations). ]]
local Fingerprint = {}

-- The export settings that change the rendered JPEG. The caller copies these from the export settings.
Fingerprint.RENDER_KEYS = {
	'LR_size_doConstrain', 'LR_size_resizeType', 'LR_size_maxWidth', 'LR_size_maxHeight', 'LR_size_units',
	'LR_size_resolution', 'LR_size_doNotEnlarge', 'LR_jpeg_quality', 'LR_export_colorSpace',
	'LR_outputSharpeningOn', 'LR_outputSharpeningMedia', 'LR_outputSharpeningLevel',
	'LR_useWatermark', 'LR_watermarking_id',
}

-- Top-level develop keys that change without a visible change (bookkeeping). Filled from the Task 15 findings.
Fingerprint.EXCLUDED_DEVELOP_KEYS = {}

local serialize

local function serializeTable(t, skip, out)
	local entries = {}
	for k, v in pairs(t) do
		if not (skip and skip[k]) then
			local key = {}
			serialize(k, key)
			entries[#entries + 1] = { key = table.concat(key), value = v }
		end
	end
	table.sort(entries, function(a, b) return a.key < b.key end)
	out[#out + 1] = '{'
	for _, e in ipairs(entries) do
		out[#out + 1] = e.key
		out[#out + 1] = '='
		serialize(e.value, out)
		out[#out + 1] = ';'
	end
	out[#out + 1] = '}'
end

-- Canonical text: type-tagged, keys sorted, numbers rounded to 6 significant digits (float noise).
function serialize(v, out, skip)
	local t = type(v)
	if t == 'number' then
		out[#out + 1] = 'n' .. string.format('%.6g', v)
	elseif t == 'string' then
		out[#out + 1] = 's' .. #v .. ':' .. v
	elseif t == 'boolean' then
		out[#out + 1] = v and 'T' or 'F'
	elseif t == 'table' then
		serializeTable(v, skip, out)
	elseif t == 'nil' then
		out[#out + 1] = '_'
	else
		out[#out + 1] = '?' .. t
	end
end

local TWO32 = 4294967296

-- '%x' casts to a C long, which is 32-bit on Windows; values >= 2^31 aren't safe there. Format 16 bits at a time.
local function hex32(n)
	return string.format('%04x%04x', math.floor(n / 65536), n % 65536)
end

-- of{ develop = table, orientation = string|nil, render = table } -> 16 lowercase hex characters.
function Fingerprint.of(inputs)
	local out = {}
	serialize(inputs.develop or {}, out, Fingerprint.EXCLUDED_DEVELOP_KEYS)
	out[#out + 1] = '|'
	serialize(inputs.orientation, out)
	out[#out + 1] = '|'
	serialize(inputs.render or {}, out)
	local s = table.concat(out)

	local h1, h2 = 0, 0
	for i = 1, #s do
		local b = s:byte(i)
		h1 = (h1 * 31 + b) % TWO32
		h2 = (h2 * 131 + b) % TWO32
	end
	return hex32(h1) .. hex32(h2)
end

return Fingerprint

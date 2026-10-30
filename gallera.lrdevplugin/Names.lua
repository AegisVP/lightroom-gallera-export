--[[ Names: the deleted-gallery marker (D10), Windows-safe folder names and kept-JPEG file names (D24, D27).
     Core module: no Lightroom imports. ]]
local Names = {}

Names.DELETED_SUFFIX = ' - (deleted)'

local function endsWithSuffix(name)
	return #name >= #Names.DELETED_SUFFIX and name:sub(-#Names.DELETED_SUFFIX) == Names.DELETED_SUFFIX
end

function Names.stripDeleted(name)
	while endsWithSuffix(name) do name = name:sub(1, -#Names.DELETED_SUFFIX - 1) end
	return name
end

-- Idempotent: an already marked name is returned unchanged.
function Names.markDeleted(name)
	return Names.stripDeleted(name) .. Names.DELETED_SUFFIX
end

local RESERVED = { CON = true, PRN = true, AUX = true, NUL = true }
for i = 1, 9 do
	RESERVED['COM' .. i] = true
	RESERVED['LPT' .. i] = true
end

-- A folder name Windows accepts: <>:"/\|?* and control characters become _, trailing dots and spaces
-- are dropped, reserved device names (CON, nul.txt, ...) get a leading _, and an empty name becomes _.
function Names.safeFolder(name)
	-- An explicit control range, not %c: %c follows the C locale and could hit UTF-8 bytes (Cyrillic names).
	local s = name:gsub('[%z\1-\31\127<>:"/\\|%?%*]', '_')
	s = s:gsub('[%. ]+$', '')
	if s == '' then return '_' end
	local base = s:match('^[^%.]*')
	if RESERVED[base:upper()] then s = '_' .. s end
	return s
end

-- The leaf name a photo's kept JPEG gets in the collection folder (D27).
-- jpegFiles = { [photoKey] = leaf name } for this collection; exists(leaf) checks the folder.
-- The photo's own earlier file is overwritten; a name used by another photo, or by an unknown file,
-- gets -2, -3, ... before the extension. Names compare without case, as on Windows.
function Names.jpegTarget(jpegFiles, photoKey, leafName, exists)
	local own = jpegFiles[photoKey]
	local function taken(candidate)
		local lower = candidate:lower()
		if own and own:lower() == lower then return false end
		for key, file in pairs(jpegFiles) do
			if key ~= photoKey and file:lower() == lower then return true end
		end
		return exists(candidate)
	end

	local base, ext = leafName:match('^(.*)(%.[^%.]*)$')
	if not base then base, ext = leafName, '' end
	local candidate, n = leafName, 1
	while taken(candidate) do
		n = n + 1
		candidate = base .. '-' .. n .. ext
	end
	return candidate
end

return Names

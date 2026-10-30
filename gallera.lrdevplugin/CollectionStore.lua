--[[ Plugin-owned published collection settings (DESIGN.md §6.1): orderByCapture, overrideRender, longEdge,
     jpegQuality, folderId, deleted, jpegFiles, fingerprints, favoritesColors, favoritesSeen.
     Dialog-only keys (g_*, ui_*, link_*) are never read back as truth (D3). ]]
local LrApplication = import 'LrApplication'

local CollectionStore = {}

CollectionStore.DEFAULTS = { orderByCapture = true, overrideRender = false }

-- Pass as a value to update() to remove a key (a Lua table can't carry nil).
CollectionStore.CLEAR = {}

local function copySettings(collection)
	local out = {}
	local summary = collection:getCollectionInfoSummary()
	for k, v in pairs(summary and summary.collectionSettings or {}) do out[k] = v end
	return out
end

-- A copy of the collection's settings with DEFAULTS filled in.
function CollectionStore.read(collection)
	local settings = copySettings(collection)
	for k, v in pairs(CollectionStore.DEFAULTS) do
		if settings[k] == nil then settings[k] = v end
	end
	return settings
end

-- Merges changes into the stored settings. Must not be called inside another withWriteAccessDo.
function CollectionStore.update(collection, changes)
	LrApplication.activeCatalog():withWriteAccessDo('Gallera: save collection settings', function()
		local merged = copySettings(collection)
		for k, v in pairs(changes) do
			if v == CollectionStore.CLEAR then merged[k] = nil else merged[k] = v end
		end
		collection:setCollectionSettings(merged)
	end, { timeout = 10 })
end

return CollectionStore

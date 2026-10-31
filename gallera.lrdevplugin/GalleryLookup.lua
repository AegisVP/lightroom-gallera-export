--[[ Gallery id -> state and current slug (DESIGN.md §5.2). Core module: no Lightroom imports.
     Slugs can change on the website, so callers look the slug up per operation and cache the result
     only for that operation. Ids are compared as numbers: Lightroom's remoteId is a string. ]]
local GalleryLookup = {}

local function byId(list)
	local map = {}
	for _, g in ipairs(list or {}) do
		local id = tonumber(g.id)
		if id then map[id] = g end
	end
	return map
end

-- Returns lookup(id) -> { state = 'active'|'trashed'|'gone', slug, summary }. Active wins over trashed.
function GalleryLookup.index(activeList, trashedList)
	local active, trashed = byId(activeList), byId(trashedList)
	return function(id)
		id = tonumber(id)
		local g = id and active[id]
		if g then return { state = 'active', slug = g.slug, summary = g } end
		g = id and trashed[id]
		if g then return { state = 'trashed', slug = g.slug, summary = g } end
		return { state = 'gone' }
	end
end

-- Searches the active galleries first and the trash only if needed. Returns result | nil, err.
function GalleryLookup.find(api, galleryId)
	local active, err = api:listGalleries()
	if not active then return nil, err end
	local r = GalleryLookup.index(active, {})(galleryId)
	if r.state == 'active' then return r end
	local trashed
	trashed, err = api:listTrashedGalleries()
	if not trashed then return nil, err end
	return GalleryLookup.index(active, trashed)(galleryId)
end

-- D20: true when the account's galleries (active or trashed) include one of the service's linked gallery ids,
-- or when nothing is linked yet. False means the collections belong to another Gallera account.
function GalleryLookup.ownsAny(linkedIds, activeList, trashedList)
	if #linkedIds == 0 then return true end
	local lookup = GalleryLookup.index(activeList, trashedList)
	for _, id in ipairs(linkedIds) do
		if lookup(id).state ~= 'gone' then return true end
	end
	return false
end

-- D10: what to do with a collection given its gallery's state and its `deleted` flag (nil or { state, ... }).
-- 'mark' (also when a trashed gallery is now gone), 'unmark' (active again), or nil. Never toggles (§6.9).
function GalleryLookup.reconcile(state, flagged)
	if state == 'active' then
		return flagged and 'unmark' or nil
	end
	if flagged and flagged.state == state then return nil end
	return 'mark'
end

return GalleryLookup

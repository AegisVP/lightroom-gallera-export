--[[ Client favorites -> color labels (D13-D17, DESIGN.md §5.2). Pure logic, no I/O, no Lightroom imports.
     photos = { [remotePhotoId] = { key = <local photo key>, label = <current color|nil>,
                                    applied = { listId, color } | nil } }
     choices = { [listId] = 'red'|'yellow'|'green'|'blue'|'purple' }; a list without a choice is Skip. ]]
local FavoritesSync = {}

-- '(untitled)' for an empty title or Gallera's default (the gallery URL).
function FavoritesSync.displayTitle(title)
	if type(title) ~= 'string' or title == '' or title:find('^http') then return '(untitled)' end
	return title
end

local function latestIds(list)
	local ids = {}
	for _, p in ipairs(list.latest or {}) do
		local id = type(p) == 'table' and tonumber(p.id)
		if id then ids[#ids + 1] = id end
	end
	return ids
end

local function photoFor(photos, id)
	return photos[id] or photos[tostring(id)]
end

-- Rows for the Client favorites dialog: { id, title, finished, count, matched }.
function FavoritesSync.summarize(lists, photos)
	local rows = {}
	for _, list in ipairs(lists) do
		local matched = 0
		for _, id in ipairs(latestIds(list)) do
			if photoFor(photos, id) then matched = matched + 1 end
		end
		rows[#rows + 1] = {
			id = list.id,
			title = FavoritesSync.displayTitle(list.title),
			finished = list.is_finished == true,
			count = tonumber(list.items_count) or 0,
			matched = matched,
		}
	end
	return rows
end

local function byKey(a, b) return a.key < b.key end

function FavoritesSync.plan(opts)
	local lists, choices, photos = opts.lists, opts.choices or {}, opts.photos or {}

	-- remote id -> { colors = {[color] = listId}, n = distinct colors }; only lists chosen this run.
	local targets, chosen, incomplete = {}, {}, {}
	for _, list in ipairs(lists) do
		local ids = latestIds(list)
		if #ids < (tonumber(list.items_count) or 0) then incomplete[#incomplete + 1] = list.id end
		local color = choices[list.id]
		if color then
			chosen[list.id] = true
			for _, id in ipairs(ids) do
				local t = targets[id] or { colors = {}, n = 0 }
				targets[id] = t
				if not t.colors[color] then
					t.colors[color] = list.id
					t.n = t.n + 1
				end
			end
		end
	end

	local set, remove, skipped, conflicts = {}, {}, {}, {}
	for remoteId, photo in pairs(photos) do
		local t = targets[tonumber(remoteId)]
		local applied = photo.applied
		if t and t.n > 1 then
			conflicts[#conflicts + 1] = photo.key
		elseif t then
			local color, listId = next(t.colors)
			if photo.label == nil or photo.label == color
				or (applied and photo.label == applied.color) then
				set[#set + 1] = { key = photo.key, color = color, listId = listId }
			else
				skipped[#skipped + 1] = photo.key
			end
		elseif applied and chosen[applied.listId] and photo.label == applied.color then
			remove[#remove + 1] = photo.key
		end
	end

	table.sort(set, byKey)
	table.sort(remove)
	table.sort(skipped)
	table.sort(conflicts)
	return { set = set, remove = remove, skippedOtherLabel = skipped, conflicts = conflicts, incompleteLists = incomplete }
end

-- D17: lists that are new or whose items_count / is_finished differ from what was last seen.
function FavoritesSync.changedLists(lists, seen)
	local changed = {}
	for _, list in ipairs(lists) do
		local s = seen and seen[list.id]
		if not s or s.count ~= (tonumber(list.items_count) or 0) or s.finished ~= (list.is_finished == true) then
			changed[#changed + 1] = list
		end
	end
	return changed
end

function FavoritesSync.seenFrom(lists)
	local seen = {}
	for _, list in ipairs(lists) do
		seen[list.id] = { count = tonumber(list.items_count) or 0, finished = list.is_finished == true }
	end
	return seen
end

return FavoritesSync

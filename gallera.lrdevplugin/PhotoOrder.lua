--[[ Gallery order (D12, DESIGN.md §5.2): capture date, or Lightroom's User Order. Core module: no Lightroom imports.
     compute() is the capture-date order.
     captureTimes has a key for every photo the plugin uploaded: a number, or false when the photo has
     no capture time. The result is the complete id list photos/sort needs:
       1. plugin photos with a capture time, by time, ties by remote id (= upload order)
       2. plugin photos without a capture time, in gallery order
       3. photos the plugin didn't upload, in gallery order ]]
local PhotoOrder = {}

function PhotoOrder.compute(opts)
	local timed, untimed, foreign = {}, {}, {}
	for _, id in ipairs(opts.galleryPhotoIds) do
		local t = opts.captureTimes[id]
		if type(t) == 'number' then
			timed[#timed + 1] = id
		elseif t == false then
			untimed[#untimed + 1] = id
		else
			foreign[#foreign + 1] = id
		end
	end
	table.sort(timed, function(a, b)
		local ta, tb = opts.captureTimes[a], opts.captureTimes[b]
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	local out = timed
	for _, id in ipairs(untimed) do out[#out + 1] = id end
	for _, id in ipairs(foreign) do out[#out + 1] = id end
	return out
end

-- Lightroom order: the collection's User Order (remote ids, as Lightroom passes them), then photos the
-- plugin doesn't know (added on the website) in gallery order. Ids not in the gallery are dropped.
function PhotoOrder.fromSequence(opts)
	local inGallery, used, out = {}, {}, {}
	for _, id in ipairs(opts.galleryPhotoIds) do inGallery[id] = true end
	for _, raw in ipairs(opts.sequence) do
		local id = tonumber(raw)
		if id and inGallery[id] and not used[id] then
			used[id] = true
			out[#out + 1] = id
		end
	end
	for _, id in ipairs(opts.galleryPhotoIds) do
		if not used[id] then out[#out + 1] = id end
	end
	return out
end

PhotoOrder.MODES = { capture = true, lightroom = true, none = true }

-- The collection's "Order on Gallera" setting: 'capture' (default), 'lightroom' or 'none'.
-- Collections saved before the setting existed have the orderByCapture checkbox: false means 'none'.
function PhotoOrder.mode(settings)
	local m = settings.galleryOrder
	if PhotoOrder.MODES[m] then return m end
	if settings.orderByCapture == false then return 'none' end
	return 'capture'
end

return PhotoOrder

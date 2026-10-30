--[[ Capture-date order for a gallery (D12, DESIGN.md §5.2). Core module: no Lightroom imports.
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

return PhotoOrder

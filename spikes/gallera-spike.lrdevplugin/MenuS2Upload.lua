--[[ S2: 3-step upload of a chosen JPEG (upload URL -> PUT bytes to R2 -> confirm), then checks
     that Gallera got the same bytes. Offers to delete the test photo at the end. ]]
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Common = require 'SpikeCommon'

local CHUNK = 65536

LrFunctionContext.postAsyncTaskWithContext('Gallera spike S2', function(context)
	if not Common.token() then
		LrDialogs.message('Gallera spike S2', 'Log in first: Library > Plug-in Extras > Gallera spike: log in...')
		return
	end

	local files = LrDialogs.runOpenPanel {
		title = 'S2: choose a JPEG to upload (a large one, 10+ MB, is best)',
		canChooseFiles = true,
		canChooseDirectories = false,
		allowsMultipleSelection = false,
		fileTypes = { 'jpg', 'jpeg' },
	}
	if not files or not files[1] then return end
	local path = files[1]

	local list, listErr = Common.api('GET', 'v2/galleries/my?page=1&sort=created&search=')
	if listErr then
		LrDialogs.message('Gallera spike S2', 'Could not list galleries: ' .. listErr, 'critical')
		return
	end
	local galleries = list and list.galleries or {}
	if #galleries == 0 then
		LrDialogs.message('Gallera spike S2', 'No galleries found. Create a test gallery on the website first.')
		return
	end

	local items = {}
	for i, g in ipairs(galleries) do
		items[i] = { title = string.format('%s  (/%s, %s photos)', tostring(g.name), tostring(g.slug), tostring(g.photos_count)), value = i }
	end
	local props = LrBinding.makePropertyTable(context)
	props.gallery = 1
	props.bodyMode = 'string'

	local f = LrView.osFactory()
	local bind = LrView.bind
	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:static_text { title = 'File: ' .. LrPathUtils.leafName(path) },
		f:row {
			f:static_text { title = 'Test gallery:' },
			f:popup_menu { value = bind 'gallery', items = items },
		},
		f:row {
			f:static_text { title = 'PUT body:' },
			f:popup_menu {
				value = bind 'bodyMode',
				items = {
					{ title = 'Whole file as a string', value = 'string' },
					{ title = 'Streamed (function body, 64 KB chunks)', value = 'stream' },
				},
			},
		},
		f:static_text { title = 'Use a test gallery, never a client gallery. You can delete the photo at the end.' },
	}
	if LrDialogs.presentModalDialog { title = 'Gallera spike S2: upload', contents = contents } ~= 'ok' then return end

	local g = galleries[props.gallery]
	local result = {}
	local function add(line)
		result[#result + 1] = line
		Common.log('S2', line)
	end
	local function done()
		LrDialogs.message('Gallera spike S2', table.concat(result, '\n'))
	end

	local bytes = Common.readFile(path)
	if not bytes then
		LrDialogs.message('Gallera spike S2', 'Cannot read ' .. path, 'critical')
		return
	end
	local leaf = LrPathUtils.leafName(path)
	add(string.format('File %s, %d bytes, gallery id %s, PUT body: %s', leaf, #bytes, tostring(g.id), props.bodyMode))

	-- Step 1: signed upload URL
	local up, upErr = Common.apiMultipart('photos/upload/url', {
		{ name = 'gallery', value = tostring(g.id) },
		{ name = 'filename', value = leaf },
		{ name = 'filesize', value = tostring(#bytes) },
		{ name = 'filetype', value = 'image/jpeg' },
	})
	local photoId = up and up.photo and up.photo.id
	if upErr or not (up and up.url and photoId) then
		add('Step 1 (upload URL) FAILED: ' .. tostring(upErr or 'no url/photo id in response'))
		return done()
	end
	add('Step 1 (upload URL): OK, photo id ' .. tostring(photoId))

	-- Step 2: PUT to R2 (no Authorization header)
	local t0 = LrDate.currentTime()
	local putHeaders = { { field = 'Content-Type', value = 'image/jpeg' } }
	local putBody, putHdrs
	if props.bodyMode == 'string' then
		putBody, putHdrs = LrHttp.post(up.url, bytes, putHeaders, 'PUT', 300)
	else
		local pos = 1
		local function nextChunk()
			if pos > #bytes then return nil end
			local c = bytes:sub(pos, pos + CHUNK - 1)
			pos = pos + CHUNK
			return c
		end
		putBody, putHdrs = LrHttp.post(up.url, nextChunk, putHeaders, 'PUT', 300, #bytes)
	end
	local putStatus = putHdrs and putHdrs.status
	local r2Code = putBody and putBody:match('<Code>(.-)</Code>')
	local netErr = putBody == nil and putHdrs and putHdrs.error
	add(string.format('Step 2 (PUT): HTTP %s%s%s, %.1f s', tostring(putStatus),
		r2Code and (', R2 error ' .. r2Code) or '',
		netErr and (', network error ' .. tostring(netErr.name)) or '',
		LrDate.currentTime() - t0))

	-- Step 3: confirm
	local _, confErr = Common.api('POST', 'photos/upload/' .. tostring(photoId) .. '/uploaded',
		'{"photo":' .. tostring(photoId) .. '}')
	add('Step 3 (confirm): ' .. (confErr or 'OK'))

	-- Wait for Gallera's processing
	local processed
	for _ = 1, 30 do
		local d, e = Common.api('POST', 'photos/processed', '{"photo_ids":[' .. tostring(photoId) .. ']}')
		if e then add('Processing check FAILED: ' .. e); break end
		if type(d) == 'table' and d[1] then processed = d[1]; break end
		LrTasks.sleep(2)
	end
	add(processed and 'Processing finished' or 'Processing not finished (or failed) after ~60 s')

	-- Compare the size Gallera recorded
	local photos = Common.api('GET', 'photos/' .. tostring(g.slug))
	local remote
	for _, p in ipairs(photos or {}) do
		if p.id == photoId then remote = p end
	end
	if remote then
		add(string.format('Gallera filesize %s vs local %d: %s', tostring(remote.filesize), #bytes,
			tonumber(remote.filesize) == #bytes and 'MATCH' or 'DIFFERENT'))
	else
		add('Photo not found in the gallery photo list')
	end

	-- Download image_url and compare bytes
	local imageUrl = (processed and processed.image_url) or (remote and remote.image_url)
	if imageUrl then
		local dl, dlHdrs = LrHttp.get(imageUrl)
		if dl then
			local same = dl == bytes
			add(string.format('Downloaded image_url: HTTP %s, %d bytes, %s', tostring(dlHdrs and dlHdrs.status), #dl,
				same and 'BYTE-IDENTICAL' or 'not identical'))
			if not same then
				add('  local: ' .. Common.describeJpeg(Common.jpegInfo(bytes)))
				add('  downloaded: ' .. Common.describeJpeg(Common.jpegInfo(dl)))
				Common.writeFile(LrPathUtils.child(Common.outputFolder('S2'), 'downloaded_' .. leaf), dl)
				add('  Saved to Pictures\\GalleraSpike\\S2 for a visual check')
			end
		else
			add('Download of image_url FAILED: ' .. tostring(dlHdrs and dlHdrs.error and dlHdrs.error.name))
		end
	else
		add('No image_url to download')
	end

	done()

	if LrDialogs.confirm('Delete the test photo from "' .. tostring(g.name) .. '"?', nil, 'Delete', 'Keep') == 'ok' then
		local _, delErr = Common.api('POST', 'photos/delete',
			'{"gallery":' .. Common.q(g.slug) .. ',"photos":[' .. tostring(photoId) .. ']}')
		Common.log('S2 delete test photo:', delErr or 'OK')
	end
end)

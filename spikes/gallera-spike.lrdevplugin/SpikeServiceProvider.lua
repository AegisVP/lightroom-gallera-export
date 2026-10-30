--[[ Spike publish service.
     S1: per-collection long edge + JPEG quality (variant A: change export settings before rendering;
         variant B: skipRender + our own LrExportSession).
     S3: HTTP + setRemoteId/setName from updateCollectionSettings.
     S4: async fill of collection-settings fields.
     S7: metadataThatTriggersRepublish excludes color label and the plugin field. ]]
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Common = require 'SpikeCommon'
local log = Common.log

local VARIANT_TITLES = {
	none = 'No override (service settings)',
	mutate = 'A: change export settings before rendering',
	session = 'B: skipRender + own LrExportSession',
}

local provider = {}

provider.supportsIncrementalPublish = 'only'
provider.allowFileFormats = { 'JPEG' }
provider.allowColorSpaces = { 'sRGB' }
provider.canExportVideo = false
provider.hideSections = { 'exportLocation' }
provider.hidePrintResolution = true

function provider.getCollectionBehaviorInfo(publishSettings)
	return {
		defaultCollectionName = 'Spike',
		defaultCollectionCanBeDeleted = true,
		canAddCollection = true,
		maxCollectionSetDepth = 0,
	}
end

-- S7 -------------------------------------------------------------------------

-- The rule is chosen in the S6 dialog (saved in plugin prefs), so it can change without a reload.
local S7_RULES = {
	excludeKeys = {
		default = true,
		label = false,
		colorNameForLabel = false,
		[_PLUGIN.id .. '.galleraLabelApplied'] = false,
	},
	defaultOff = {
		default = false,
		title = true,
		caption = true,
		keywords = true,
	},
}

function provider.metadataThatTriggersRepublish(publishSettings)
	local mode = LrPrefs.prefsForPlugin().s7Rule or 'excludeKeys'
	log('S7 metadataThatTriggersRepublish called, rule', mode)
	return S7_RULES[mode] or S7_RULES.excludeKeys
end

-- S4 + S1/S3 controls --------------------------------------------------------

function provider.viewForCollectionSettings(f, publishSettings, info)
	local cs = info.collectionSettings
	local bind = LrView.bind
	log('S4 viewForCollectionSettings: publishedCollection=', info.publishedCollection ~= nil)

	if cs.s1Variant == nil then cs.s1Variant = 'none' end
	if cs.s1LongEdge == nil then cs.s1LongEdge = 1000 end
	if cs.s1Quality == nil then cs.s1Quality = 50 end
	if cs.s3Run == nil then cs.s3Run = false end
	cs.s4Status = 'Loading from Gallera...'
	cs.s4Loaded = false
	cs.s4Username = ''

	LrTasks.startAsyncTask(function()
		LrTasks.sleep(2)   -- make the "Loading..." state visible
		local data, err, status = Common.api('GET', 'user')
		if err then
			cs.s4Status = 'Loaded with error (' .. err .. '). Async update itself worked if you can read this.'
		else
			cs.s4Username = tostring(data and data.username)
			cs.s4Status = 'Loaded: HTTP ' .. tostring(status)
		end
		cs.s4Loaded = true
		log('S4 async fill done:', cs.s4Status)
	end)

	return f:group_box {
		title = 'Gallera spike',
		bind_to_object = cs,
		fill_horizontal = 1,

		f:static_text { title = 'S4: this text and the field below should change after ~2 seconds.' },
		f:row {
			f:static_text { title = bind 's4Status', fill_horizontal = 1, width_in_chars = 50 },
		},
		f:row {
			f:static_text { title = 'Gallera username:' },
			f:edit_field { value = bind 's4Username', enabled = bind 's4Loaded', width_in_chars = 25 },
		},

		f:separator { fill_horizontal = 1 },
		f:static_text { title = 'S1: rendering used by the next Publish of this collection' },
		f:popup_menu {
			value = bind 's1Variant',
			items = {
				{ title = VARIANT_TITLES.none, value = 'none' },
				{ title = VARIANT_TITLES.mutate, value = 'mutate' },
				{ title = VARIANT_TITLES.session, value = 'session' },
			},
		},
		f:row {
			f:static_text { title = 'Long edge (px):' },
			f:edit_field { value = bind 's1LongEdge', min = 100, max = 10000, precision = 0, width_in_digits = 6 },
			f:static_text { title = 'JPEG quality (0-100):' },
			f:edit_field { value = bind 's1Quality', min = 0, max = 100, precision = 0, width_in_digits = 4 },
		},

		f:separator { fill_horizontal = 1 },
		f:checkbox {
			title = 'S3: on OK, call Gallera, set a remote id and add " (S3)" to this collection\'s name',
			value = bind 's3Run',
		},
	}
end

-- S3 -------------------------------------------------------------------------

-- Tries fn directly, then inside withWriteAccessDo. Returns a line describing what worked.
local function tryWrite(label, fn)
	local ok, err = LrTasks.pcall(fn)
	if ok then return label .. ': OK without withWriteAccessDo' end
	local direct = tostring(err)
	local catalog = LrApplication.activeCatalog()
	local okW, errW = LrTasks.pcall(function()
		catalog:withWriteAccessDo('Gallera spike ' .. label, fn, { timeout = 10 })
	end)
	if okW then return label .. ': OK inside withWriteAccessDo (direct failed: ' .. direct .. ')' end
	return label .. ': FAILED. direct: ' .. direct .. ' | withWriteAccessDo: ' .. tostring(errW)
end

local function s3Writes(coll, lines)
	local remoteId = 'spike-s3-' .. tostring(os.time())
	local name = coll:getName()
	local newName = name:find(' %(S3%)$') and name or (name .. ' (S3)')
	local allOk = true
	for _, step in ipairs {
		{ 'setRemoteId', function() coll:setRemoteId(remoteId) end },
		{ 'setRemoteUrl', function() coll:setRemoteUrl('https://app.gallera.io/') end },
		{ 'setName', function() coll:setName(newName) end },
	} do
		local line = tryWrite(step[1], step[2])
		lines[#lines + 1] = line
		if line:find('FAILED') then allOk = false end
	end
	lines[#lines + 1] = 'Read back: remoteId=' .. tostring(coll:getRemoteId()) .. ', name=' .. tostring(coll:getName())
	return allOk
end

local function findCollection(info)
	if info.publishedCollection then return info.publishedCollection end
	local service = info.publishService
	if not service then return nil end
	for _, c in ipairs(service:getChildCollections()) do
		if c:getName() == info.name then return c end
	end
end

function provider.updateCollectionSettings(publishSettings, info)
	local cs = info.collectionSettings
	local canYield = LrTasks.canYield()
	log('S3 updateCollectionSettings: canYield=', canYield, 'publishedCollection=', info.publishedCollection ~= nil,
		'name=', info.name, 's3Run=', cs and cs.s3Run)
	if not (cs and cs.s3Run) then return end

	local lines = {
		'canYield in callback: ' .. tostring(canYield),
		'info.publishedCollection present: ' .. tostring(info.publishedCollection ~= nil),
	}

	local function finish()
		local text = table.concat(lines, '\n')
		log('S3 result\n' .. text)
		LrDialogs.message('Gallera spike S3', text)
	end

	local function asyncPhase()
		LrTasks.startAsyncTask(function()
			LrTasks.sleep(0.5)
			lines[#lines + 1] = '-- async task, after the callback returned --'
			local data, err, status = Common.api('GET', 'user')
			lines[#lines + 1] = 'HTTP in async task: status ' .. tostring(status) .. (err and (' (' .. err .. ')') or ' OK')
			local coll = findCollection(info)
			if coll then
				s3Writes(coll, lines)
			else
				lines[#lines + 1] = 'Collection not found by name'
			end
			finish()
		end)
	end

	if not canYield then
		lines[#lines + 1] = 'Callback cannot yield: no HTTP possible inside it'
		asyncPhase()
		return
	end

	lines[#lines + 1] = '-- inside the callback --'
	local data, err, status = Common.api('GET', 'user')
	lines[#lines + 1] = 'HTTP inside callback: status ' .. tostring(status) .. (err and (' (' .. err .. ')') or ' OK')
	local coll = findCollection(info)
	if coll and s3Writes(coll, lines) then
		-- Lightroom applies the dialog's name after this callback, overwriting setName above (observed).
		-- Check whether a rename from a task that runs after the callback sticks.
		LrTasks.startAsyncTask(function()
			LrTasks.sleep(1)
			local late = tostring(info.name) .. ' (S3 late)'
			lines[#lines + 1] = '-- async task, 1 s after the callback --'
			lines[#lines + 1] = 'Name before late rename: ' .. tostring(coll:getName())
			lines[#lines + 1] = tryWrite('late setName', function() coll:setName(late) end)
			lines[#lines + 1] = 'Name right after: ' .. tostring(coll:getName())
			LrTasks.sleep(3)
			lines[#lines + 1] = 'Name 3 s later: ' .. tostring(coll:getName()) .. ' (expected "' .. late .. '")'
			finish()
		end)
	else
		if not coll then lines[#lines + 1] = 'Collection object not available inside the callback' end
		asyncPhase()
	end
end

-- S1 -------------------------------------------------------------------------

local function overrides(cs)
	local edge = tonumber(cs.s1LongEdge) or 1000
	local q = tonumber(cs.s1Quality) or 50
	return {
		LR_size_doConstrain = true,
		LR_size_resizeType = 'longEdge',
		LR_size_maxWidth = edge,
		LR_size_maxHeight = edge,
		LR_size_units = 'pixels',
		LR_size_doNotEnlarge = true,
		LR_jpeg_quality = q / 100,
		LR_jpeg_useLimitSize = false,
	}
end

local function handleRendered(variant, rendition, path, lines)
	local data = Common.readFile(path)
	local info = data and Common.jpegInfo(data) or { error = 'cannot read the rendered file' }
	local line = string.format('%s: %s', rendition.photo:getFormattedMetadata('fileName'), Common.describeJpeg(info))
	lines[#lines + 1] = line
	log('S1', variant, line)
	if data then
		local dest = LrPathUtils.child(Common.outputFolder('S1'), variant .. '_' .. LrPathUtils.leafName(path))
		Common.writeFile(dest, data)
	end
end

local function record(rendition)
	rendition:recordPublishedPhotoId('spike-' .. tostring(rendition.photo.localIdentifier))
	rendition:recordPublishedPhotoUrl('https://app.gallera.io/')
end

-- Variant A: write the overrides into the export property table, render, then restore.
local function mutate(props, ov, lines)
	local saved = {}
	for k, v in pairs(ov) do
		saved[k] = props[k]
		local ok, err = LrTasks.pcall(function() props[k] = v end)
		if not ok then lines[#lines + 1] = 'Could not set ' .. k .. ': ' .. tostring(err) end
	end
	lines[#lines + 1] = string.format('Service settings before: long edge %s, quality %s',
		tostring(saved.LR_size_maxWidth), tostring(saved.LR_jpeg_quality))
	return saved
end

local function restore(props, ov, saved, lines)
	for k in pairs(ov) do
		LrTasks.pcall(function() props[k] = saved[k] end)
	end
	lines[#lines + 1] = string.format('Service settings after restore: long edge %s, quality %s',
		tostring(props.LR_size_maxWidth), tostring(props.LR_jpeg_quality))
end

local REMOVE_KEY_PATTERNS = { 'exportServiceProvider', '[Pp]ublish', '[Ff]ilter' }

-- Variant B: export settings for our own LrExportSession (a plain export to a temp folder).
local function innerSettings(props, ov, dir, lines)
	local copy, n = {}, 0
	local function take(k, v)
		if type(k) == 'string' and k:find('^LR_') then copy[k] = v; n = n + 1 end
	end
	local how = 'props:pairs()'
	local ok = pcall(function() for k, v in props:pairs() do take(k, v) end end)
	if not ok or n == 0 then
		how = 'pairs(props)'
		pcall(function() for k, v in pairs(props) do take(k, v) end end)
	end

	local removed = {}
	for k in pairs(copy) do
		for _, p in ipairs(REMOVE_KEY_PATTERNS) do
			if k:find(p) then removed[#removed + 1] = k; break end
		end
	end
	for _, k in ipairs(removed) do copy[k] = nil end

	for k, v in pairs(ov) do copy[k] = v end
	copy.LR_format = 'JPEG'
	copy.LR_export_destinationType = 'specificFolder'
	copy.LR_export_destinationPathPrefix = dir
	copy.LR_export_useSubfolder = false
	copy.LR_collisionHandling = 'overwrite'
	copy.LR_reimportExportedPhoto = false

	lines[#lines + 1] = string.format('Copied %d LR_ settings via %s; removed: %s', n, how,
		#removed > 0 and table.concat(removed, ', ') or '(none)')
	return copy
end

local function renderWithOwnSession(exportContext, ov, lines)
	local photos = exportContext.exportSession:photosToExport()
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'GalleraSpikeS1')
	LrFileUtils.createAllDirectories(dir)
	local settings = innerSettings(exportContext.propertyTable, ov, dir, lines)

	local rendered = {}
	local ok, err = LrTasks.pcall(function()
		local inner = LrExportSession { photosToExport = photos, exportSettings = settings }
		for _, r in inner:renditions() do
			local success, pathOrMsg = r:waitForRender()
			if success then
				rendered[r.photo.localIdentifier] = pathOrMsg
			else
				lines[#lines + 1] = 'Own session render failed: ' .. tostring(pathOrMsg)
			end
		end
	end)
	if not ok then lines[#lines + 1] = 'Own export session FAILED: ' .. tostring(err) end

	local ok2, err2 = LrTasks.pcall(function()
		for _, rendition in exportContext:renditions { stopIfCanceled = true } do
			local skipOk, skipErr = LrTasks.pcall(function() rendition:skipRender() end)
			if not skipOk then lines[#lines + 1] = 'skipRender FAILED: ' .. tostring(skipErr) end
			local path = rendered[rendition.photo.localIdentifier]
			if path then
				handleRendered('session', rendition, path, lines)
				record(rendition)
				LrFileUtils.delete(path)
			else
				rendition:uploadFailed('Not rendered by own session')
			end
			local own = rendition.destinationPath
			if own and LrFileUtils.exists(own) then
				lines[#lines + 1] = 'Lightroom ALSO rendered its own file for ' .. LrPathUtils.leafName(own)
			end
		end
	end)
	if not ok2 then lines[#lines + 1] = 'Outer rendition loop FAILED: ' .. tostring(err2) end
end

function provider.processRenderedPhotos(functionContext, exportContext)
	local exportSession = exportContext.exportSession
	local props = exportContext.propertyTable
	local summary = exportContext.publishedCollection:getCollectionInfoSummary()
	local cs = summary and summary.collectionSettings or {}
	local variant = cs.s1Variant or 'none'
	local ov = overrides(cs)
	local n = exportSession:countRenditions()

	exportContext:configureProgress { title = string.format('Gallera spike S1 (%s): %d photo(s)', variant, n) }
	local lines = { 'Variant: ' .. (VARIANT_TITLES[variant] or variant) }
	if variant ~= 'none' then
		lines[#lines + 1] = string.format('Override wanted: long edge %d px, quality %d', ov.LR_size_maxWidth,
			math.floor(ov.LR_jpeg_quality * 100 + 0.5))
	end
	log('S1 start', variant, n, 'photo(s)')

	if variant == 'session' then
		renderWithOwnSession(exportContext, ov, lines)
	else
		local saved = variant == 'mutate' and mutate(props, ov, lines) or nil
		local ok, err = LrTasks.pcall(function()
			for _, rendition in exportContext:renditions { stopIfCanceled = true } do
				local success, pathOrMsg = rendition:waitForRender()
				if success then
					handleRendered(variant, rendition, pathOrMsg, lines)
					record(rendition)
				else
					lines[#lines + 1] = 'Render failed: ' .. tostring(pathOrMsg)
					rendition:uploadFailed(pathOrMsg)
				end
			end
		end)
		if saved then restore(props, ov, saved, lines) end
		if not ok then lines[#lines + 1] = 'ERROR: ' .. tostring(err) end
	end

	local text = table.concat(lines, '\n')
	log('S1 result\n' .. text)
	LrDialogs.message('Gallera spike S1', text .. '\n\nJPEG copies: Pictures\\GalleraSpike\\S1')
end

function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback)
	for _, id in ipairs(arrayOfPhotoIds) do
		deletedCallback(id)
	end
end

return provider

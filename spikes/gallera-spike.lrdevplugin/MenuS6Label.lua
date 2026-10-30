--[[ S6: set the color label of the selected photos by color, by label text, or not at all, and
     optionally write the hidden plugin field. S7: check afterwards whether published photos moved
     to "Modified Photos to Re-Publish". ]]
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Common = require 'SpikeCommon'

local LABEL_TEXT = { red = 'Red', yellow = 'Yellow', green = 'Green', blue = 'Blue', purple = 'Purple', none = '' }
local MAX_LINES = 10

-- S7b: the published-photo records of the selected photos in this plugin's collections.
local function publishedRecords(catalog, photos)
	local wanted = {}
	for _, p in ipairs(photos) do wanted[p.localIdentifier] = true end
	local records = {}
	for _, service in ipairs(catalog:getPublishServices(_PLUGIN.id)) do
		for _, coll in ipairs(service:getChildCollections()) do
			for _, pp in ipairs(coll:getPublishedPhotos()) do
				local photo = pp:getPhoto()
				if wanted[photo.localIdentifier] then
					records[#records + 1] = {
						name = photo:getFormattedMetadata('fileName'),
						pp = pp,
						editedBefore = pp:getEditedFlag(),
					}
				end
			end
		end
	end
	return records
end

local function flags(records)
	local parts = {}
	for _, r in ipairs(records) do
		parts[#parts + 1] = r.name .. '=' .. tostring(r.pp:getEditedFlag())
	end
	return table.concat(parts, ', ')
end

LrFunctionContext.postAsyncTaskWithContext('Gallera spike S6', function(context)
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	if #photos == 0 then
		LrDialogs.message('Gallera spike S6', 'Select some photos first.')
		return
	end

	local props = LrBinding.makePropertyTable(context)
	props.color = 'red'
	props.method = 'colorNameForLabel'
	props.setField = false
	props.resetEdited = true
	local prefs = LrPrefs.prefsForPlugin()
	props.s7Rule = prefs.s7Rule or 'excludeKeys'

	local f = LrView.osFactory()
	local bind = LrView.bind
	local colorItems = {}
	for _, c in ipairs { 'red', 'yellow', 'green', 'blue', 'purple', 'none' } do
		colorItems[#colorItems + 1] = { title = c, value = c }
	end
	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:static_text { title = #photos .. ' photo(s) selected' },
		f:row {
			f:static_text { title = 'Color:' },
			f:popup_menu { value = bind 'color', items = colorItems },
		},
		f:row {
			f:static_text { title = 'Method:' },
			f:popup_menu {
				value = bind 'method',
				items = {
					{ title = "setRawMetadata('colorNameForLabel', color)", value = 'colorNameForLabel' },
					{ title = "setRawMetadata('label', English label text)", value = 'label' },
					{ title = 'Do not touch the label (hidden field only)', value = 'fieldOnly' },
				},
			},
		},
		f:checkbox { title = 'Also write the hidden plugin field galleraLabelApplied (S7)', value = bind 'setField' },
		f:checkbox { title = 'S7b: afterwards, clear "modified" on photos that were published and unmodified before', value = bind 'resetEdited' },
		f:row {
			f:static_text { title = 'S7 re-publish rule:' },
			f:popup_menu {
				value = bind 's7Rule',
				items = {
					{ title = 'Exclude keys (default on; label, colorNameForLabel, field off)', value = 'excludeKeys' },
					{ title = 'Default off (only title, caption, keywords trigger)', value = 'defaultOff' },
				},
			},
		},
	}
	if LrDialogs.presentModalDialog { title = 'Gallera spike S6/S7: color label', contents = contents } ~= 'ok' then return end

	local color, method, setField = props.color, props.method, props.setField
	prefs.s7Rule = props.s7Rule
	Common.log('S6 start: method', method, 'color', color, 'field', setField, 'photos', #photos, 'S7 rule', props.s7Rule,
		'S7b reset', props.resetEdited)
	local resetEdited = props.resetEdited
	local records = {}
	if resetEdited then
		local ok, err = LrTasks.pcall(function() records = publishedRecords(catalog, photos) end)
		Common.log('S7b edited flags before:', ok and flags(records) or ('FAILED ' .. tostring(err)))
	end
	local errors = {}
	catalog:withWriteAccessDo('Gallera spike S6', function()
		for _, photo in ipairs(photos) do
			if method ~= 'fieldOnly' then
				local value = method == 'label' and LABEL_TEXT[color] or color
				local ok, err = LrTasks.pcall(photo.setRawMetadata, photo, method, value)
				if not ok then errors[photo.localIdentifier] = 'setRawMetadata: ' .. tostring(err) end
			end
			if setField or method == 'fieldOnly' then
				local fieldValue = (color ~= 'none') and ('spike:' .. color) or nil
				local ok, err = LrTasks.pcall(photo.setPropertyForPlugin, photo, _PLUGIN, 'galleraLabelApplied', fieldValue)
				if not ok then
					errors[photo.localIdentifier] = (errors[photo.localIdentifier] or '') .. ' setPropertyForPlugin: ' .. tostring(err)
				end
			end
		end
	end, { timeout = 10 })
	Common.log('S6 writes done')

	local s7bLines = {}
	if resetEdited and #records > 0 then
		LrTasks.sleep(2)   -- give Lightroom time to flag the photos
		local ok, err = LrTasks.pcall(function()
			s7bLines[#s7bLines + 1] = 'Flags 2 s after the label change: ' .. flags(records)
			local cleared = 0
			catalog:withWriteAccessDo('Gallera spike S7b', function()
				for _, r in ipairs(records) do
					if not r.editedBefore and r.pp:getEditedFlag() then
						r.pp:setEditedFlag(false)
						cleared = cleared + 1
					end
				end
			end, { timeout = 10 })
			s7bLines[#s7bLines + 1] = 'Cleared: ' .. cleared
			s7bLines[#s7bLines + 1] = 'Flags right after clearing: ' .. flags(records)
			LrTasks.sleep(3)
			s7bLines[#s7bLines + 1] = 'Flags 3 s later: ' .. flags(records)
		end)
		if not ok then s7bLines[#s7bLines + 1] = 'S7b FAILED: ' .. tostring(err) end
		for _, line in ipairs(s7bLines) do Common.log('S7b', line) end
	elseif resetEdited then
		s7bLines[1] = 'S7b: none of the selected photos is published in this service'
	end

	-- Each read is guarded: the first run wrote the labels but stopped silently somewhere after this point.
	local function read(label, fn)
		local ok, value = LrTasks.pcall(fn)
		if ok then return tostring(value) end
		Common.log('S6 read FAILED:', label, value)
		return 'ERROR(' .. tostring(value) .. ')'
	end

	local lines = { string.format('Method %s, color %s, hidden field: %s', method, color, tostring(setField or method == 'fieldOnly')) }
	for i, photo in ipairs(photos) do
		if i > MAX_LINES then
			lines[#lines + 1] = string.format('... and %d more (see the log)', #photos - MAX_LINES)
			break
		end
		lines[#lines + 1] = string.format('%s: label="%s", colorNameForLabel=%s, field=%s%s',
			read('fileName', function() return photo:getFormattedMetadata('fileName') end),
			read('label', function() return photo:getFormattedMetadata('label') end),
			read('colorNameForLabel', function() return photo:getRawMetadata('colorNameForLabel') end),
			read('field', function() return photo:getPropertyForPlugin(_PLUGIN, 'galleraLabelApplied') end),
			errors[photo.localIdentifier] and ('  ERROR ' .. errors[photo.localIdentifier]) or '')
	end
	for _, line in ipairs(s7bLines) do lines[#lines + 1] = line end
	local text = table.concat(lines, '\n')
	Common.log('S6 result\n' .. text)
	LrDialogs.message('Gallera spike S6',
		text .. '\n\nS7: if these photos are published, check whether they moved to "Modified Photos to Re-Publish".')
end)

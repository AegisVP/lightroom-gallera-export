--[[ Publish service settings: the Gallera account section and the Uploaded JPEGs section (DESIGN.md §7.1, D24).
     Dialog-only state lives in ui_* properties; only exportPresetFields keys are saved by Lightroom. ]]
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Auth = require 'Auth'
local Log = require 'Log'

local ServiceSettingsDialog = {}

local GB = 1024 * 1024 * 1024

local function gb(bytes)
	return string.format('%.1f', (tonumber(bytes) or 0) / GB)
end

local function accountText(propertyTable, user)
	local text = 'Logged in as ' .. (propertyTable.ui_username or '…')
	local storage = user and user.storage
	if type(storage) == 'table' then
		local limit = tonumber(storage.limit)
		text = text .. ' · ' .. gb(storage.used) .. ' / ' .. (limit and gb(limit) or 'unlimited') .. ' GB used'
	end
	return text
end

local function showLoggedOut(propertyTable, message)
	propertyTable.ui_loggedIn = false
	propertyTable.ui_loggedOut = true
	propertyTable.ui_account = 'Not logged in'
	propertyTable.ui_message = message or ''
end

local function showLoggedIn(propertyTable, user)
	propertyTable.ui_loggedIn = true
	propertyTable.ui_loggedOut = false
	propertyTable.ui_account = accountText(propertyTable, user)
	propertyTable.ui_message = ''
end

-- Refreshes the account line (storage use) and notices a revoked token.
local function refreshAccount(propertyTable)
	LrTasks.startAsyncTask(function()
		local api = Auth.api(propertyTable)
		if not api then return end
		local user, err = api:getUser()
		if user then
			if type(user.username) == 'string' then propertyTable.ui_username = user.username end
			showLoggedIn(propertyTable, user)
		elseif err.kind == 'auth' then
			Auth.clear(propertyTable.email)
			showLoggedOut(propertyTable, 'Your Gallera login expired. Log in again.')
		else
			propertyTable.ui_message = 'Could not reach Gallera: ' .. tostring(err.message)
		end
	end)
end

function ServiceSettingsDialog.startDialog(propertyTable)
	-- Lightroom doesn't keep includeVideoFiles in the saved settings, so it opens as true and Lightroom resets it
	-- to false (canExportVideo = false) a moment after the dialog opens. That write enabled Save and made every
	-- Save ask to re-publish all photos. Setting it first leaves nothing to change (0.5.17).
	propertyTable.LR_includeVideoFiles = false
	if Auth.token(propertyTable.email) then
		showLoggedIn(propertyTable, nil)
		refreshAccount(propertyTable)
	else
		showLoggedOut(propertyTable)
	end
end

local function logIn(propertyTable)
	LrFunctionContext.postAsyncTaskWithContext('Gallera login', function(context)
		LrDialogs.attachErrorDialogToFunctionContext(context)
		local email = propertyTable.email
		if type(email) ~= 'string' or not email:find('%S') then
			LrDialogs.message('Gallera', 'Enter your Gallera email first.', 'info')
			return
		end

		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		props.password = ''
		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:row {
				f:static_text { title = 'Email:', width = LrView.share 'label' },
				f:static_text { title = email },
			},
			f:row {
				f:static_text { title = 'Password:', width = LrView.share 'label' },
				f:password_field { value = LrView.bind 'password', width_in_chars = 30 },
			},
			f:static_text { title = 'Only the login token is stored. The password is not saved.' },
		}
		local result = LrDialogs.presentModalDialog { title = 'Log in to Gallera', contents = contents, actionVerb = 'Log in' }
		local password = props.password
		props.password = ''
		if result ~= 'ok' then return end

		propertyTable.ui_message = 'Logging in…'
		local user, err = Auth.login(email, password)
		password = nil
		if not user then
			local message = tostring(err and err.message)
			propertyTable.ui_message = 'Login failed: ' .. message
			if err and (err.kind == 'auth' or err.kind == 'api') then
				message = message .. '\n\nIf you sign in to Gallera with Google, this Gallera account has no password. Set one on the website first.'
			end
			LrDialogs.message('Gallera login failed', message, 'critical')
			return
		end
		if user.has_password == false then
			LrDialogs.message('Gallera', 'This Gallera account has no password. Set one on the website first.', 'info')
		end
		propertyTable.ui_username = type(user.username) == 'string' and user.username or ''
		showLoggedIn(propertyTable, user)
	end)
end

local function logOut(propertyTable)
	LrTasks.startAsyncTask(function()
		propertyTable.ui_message = 'Logging out…'
		Auth.logout(propertyTable.email)
		propertyTable.ui_username = ''
		showLoggedOut(propertyTable)
	end)
end

local function chooseFolder(propertyTable)
	local picked = LrDialogs.runOpenPanel {
		title = 'Folder for uploaded JPEGs',
		canChooseFiles = false,
		canChooseDirectories = true,
		canCreateDirectories = true,
		allowsMultipleSelection = false,
		initialDirectory = propertyTable.jpegFolder,
	}
	if picked and picked[1] then propertyTable.jpegFolder = picked[1] end
end

function ServiceSettingsDialog.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	return {
		{
			title = 'Gallera account',
			synopsis = bind { key = 'ui_account', object = propertyTable },
			bind_to_object = propertyTable,

			-- Everything stays visible and only 'enabled' follows the login state: 'visible' bindings never
			-- hid a row in this section (0.2.1, 0.2.2), while 'enabled' bindings work (spike S4).
			f:row {
				f:static_text { title = 'Email:' },
				f:edit_field { value = bind 'email', width_in_chars = 30, immediate = true, enabled = bind 'ui_loggedOut' },
				f:push_button { title = 'Log in…', enabled = bind 'ui_loggedOut', action = function() logIn(propertyTable) end },
				f:push_button { title = 'Log out', enabled = bind 'ui_loggedIn', action = function() logOut(propertyTable) end },
			},
			f:static_text { title = bind 'ui_account', fill_horizontal = 1, width_in_chars = 60 },
			f:static_text { title = bind 'ui_message', fill_horizontal = 1, width_in_chars = 60 },
		},
		{
			title = 'Uploaded JPEGs',
			bind_to_object = propertyTable,

			f:row {
				f:static_text { title = 'After upload:', width = LrView.share 'jpegLabel' },
				f:popup_menu {
					value = bind 'jpegHandling',
					items = {
						{ title = 'Keep, ask to remove after publish', value = 'ask' },
						{ title = 'Always keep', value = 'keep' },
						{ title = 'Always remove after upload', value = 'remove' },
					},
				},
			},
			f:row {
				f:static_text { title = 'Folder:', width = LrView.share 'jpegLabel' },
				f:edit_field { value = bind 'jpegFolder', width_in_chars = 40 },
				f:push_button { title = 'Choose…', action = function() chooseFolder(propertyTable) end },
			},
			f:static_text { title = 'Each collection gets its own subfolder.' },
		},
	}
end

return ServiceSettingsDialog

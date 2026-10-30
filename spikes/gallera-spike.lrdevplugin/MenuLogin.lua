--[[ Logs in to Gallera and stores only the token (LrPasswords). Needed by S2, and by S3/S4/S5 for a 200 instead of a 401. ]]
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrView = import 'LrView'

local Common = require 'SpikeCommon'

LrFunctionContext.postAsyncTaskWithContext('Gallera spike login', function(context)
	local props = LrBinding.makePropertyTable(context)
	props.email = ''
	props.password = ''

	local f = LrView.osFactory()
	local bind = LrView.bind
	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:row {
			f:static_text { title = 'Email:', width = LrView.share 'label' },
			f:edit_field { value = bind 'email', width_in_chars = 30 },
		},
		f:row {
			f:static_text { title = 'Password:', width = LrView.share 'label' },
			f:password_field { value = bind 'password', width_in_chars = 30 },
		},
		f:static_text { title = 'Only the token is stored. The password is not saved or logged.' },
	}
	if LrDialogs.presentModalDialog { title = 'Gallera spike: log in', contents = contents } ~= 'ok' then
		props.password = ''
		return
	end

	local body = '{"email":' .. Common.q(props.email) .. ',"password":' .. Common.q(props.password) .. '}'
	props.password = ''
	local data, err = Common.api('POST', 'auth/login', body)
	body = nil
	if err or not (data and data.token) then
		LrDialogs.message('Gallera spike: login failed', err or 'No token in the response', 'critical')
		return
	end
	Common.setToken(data.token)
	local user = data.user or {}
	local storage = user.storage or {}
	LrDialogs.message('Gallera spike: logged in', string.format('User %s. Storage used %s of %s bytes.',
		tostring(user.username), tostring(storage.used), tostring(storage.limit)))
end)

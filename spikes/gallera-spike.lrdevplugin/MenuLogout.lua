--[[ Revokes the token on Gallera (best effort) and removes it from LrPasswords. ]]
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local Common = require 'SpikeCommon'

LrTasks.startAsyncTask(function()
	if not Common.token() then
		LrDialogs.message('Gallera spike', 'Not logged in.')
		return
	end
	local _, err = Common.api('POST', 'auth/logout')
	Common.setToken(nil)
	Common.log('Logout: token cleared from LrPasswords:', Common.token() == nil)
	LrDialogs.message('Gallera spike: logged out', err and ('Token removed locally. Gallera said: ' .. err) or 'Token revoked and removed.')
end)

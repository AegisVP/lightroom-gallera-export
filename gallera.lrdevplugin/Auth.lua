--[[ Gallera login (D19, DESIGN.md §6.10). Only the token is stored, in LrPasswords under
     "gallera.token:<email>". The password is never stored or logged. Logout stores '' because
     LrPasswords.store(key, nil) throws; '' means "no token". Network calls must run inside a task. ]]
local LrPasswords = import 'LrPasswords'

local GalleraApi = require 'GalleraApi'
local LrHttpAdapter = require 'LrHttpAdapter'
local Log = require 'Log'

local Auth = {}

-- Short texts for lists and status lines (Lightroom truncates long failure messages).
Auth.LOGIN_MESSAGE = 'Log in to Gallera in the service settings.'
Auth.EXPIRED_MESSAGE = 'Your Gallera login expired. Log in again in the service settings.'
-- Descriptive texts for the dialog that asks the user to log in.
Auth.LOGIN_HELP = 'Not logged in to Gallera. Right-click the Gallera publish service, choose Edit Settings…, and log in.'
Auth.EXPIRED_HELP = 'Your Gallera login expired. Right-click the Gallera publish service, choose Edit Settings…, and log in again.'

local function key(email)
	return 'gallera.token:' .. email:lower():gsub('^%s+', ''):gsub('%s+$', '')
end

function Auth.token(email)
	if type(email) ~= 'string' or email == '' then return nil end
	local token = LrPasswords.retrieve(key(email))
	if token == nil or token == '' then return nil end
	return token
end

function Auth.store(email, token)
	LrPasswords.store(key(email), token)
end

function Auth.clear(email)
	if type(email) == 'string' and email ~= '' then LrPasswords.store(key(email), '') end
end

-- An api for the publish service's account, or nil, err{kind='auth'} when there's no token.
function Auth.api(publishSettings)
	local token = Auth.token(publishSettings and publishSettings.email)
	if not token then return nil, { kind = 'auth', message = Auth.LOGIN_MESSAGE } end
	return GalleraApi.new { http = LrHttpAdapter, token = token }
end

-- Returns user | nil, err. Stores the token on success.
function Auth.login(email, password)
	local api = GalleraApi.new { http = LrHttpAdapter }
	local token, userOrErr = api:login(email, password)
	if not token then
		local err = userOrErr
		Log.warn('login failed:', err.kind, err.status, err.message)
		return nil, err
	end
	local user = userOrErr
	Auth.store(email, token)
	Log.info('login ok')
	return user
end

-- Revokes the token on Gallera (best effort), then forgets it.
function Auth.logout(email)
	local token = Auth.token(email)
	if token then
		local ok, err = GalleraApi.new { http = LrHttpAdapter, token = token }:logout()
		if not ok then Log.warn('logout: Gallera call failed:', err and err.kind, err and err.status) end
	end
	Auth.clear(email)
	Log.info('logout done')
end

return Auth

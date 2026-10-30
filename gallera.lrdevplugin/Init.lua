--[[ LrInitPlugin. Lightroom runs it on startup and on every plugin reload (sometimes several times, S5). ]]
local Log = require 'Log'

local ok, info = pcall(require, 'Info')
local v = ok and type(info) == 'table' and info.VERSION
Log.info('Gallera plugin loaded, version', v and string.format('%d.%d.%d', v.major, v.minor, v.revision) or '?')

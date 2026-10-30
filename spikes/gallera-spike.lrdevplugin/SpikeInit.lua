--[[ S5: background task at plugin load. Lists this plugin's published collections and toggles
     " - (deleted)" on every collection whose name starts with "S5". Also calls Gallera if logged in. ]]
local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrTasks = import 'LrTasks'

local Common = require 'SpikeCommon'
local log = Common.log

local SUFFIX = ' - (deleted)'

LrTasks.startAsyncTask(function()
	local t0 = LrDate.currentTime()
	log('S5 init task started')
	local ok, err = LrTasks.pcall(function()
		local catalog = LrApplication.activeCatalog()
		local services = catalog:getPublishServices(_PLUGIN.id)
		log('S5 publish services of this plugin:', #services)
		for _, service in ipairs(services) do
			for _, coll in ipairs(service:getChildCollections()) do
				local name = coll:getName()
				log('S5 collection', name, 'remoteId', coll:getRemoteId())
				if name:find('^S5') then
					local newName
					if name:sub(-#SUFFIX) == SUFFIX then
						newName = name:sub(1, -#SUFFIX - 1)
					else
						newName = name .. SUFFIX
					end
					catalog:withWriteAccessDo('Gallera spike S5', function() coll:setName(newName) end, { timeout = 30 })
					log('S5 renamed', name, '->', newName)
				end
			end
		end
		if Common.token() then
			local _, apiErr, status = Common.api('GET', 'user')
			log('S5 GET user: status', status, apiErr or 'OK')
		else
			log('S5 not logged in; skipped the Gallera call')
		end
	end)
	log('S5 done: ok=', ok, err or '', string.format('%.2fs', LrDate.currentTime() - t0))
end)

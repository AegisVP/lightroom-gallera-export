--[[ Library > Plug-in Extras > Gallera client favorites... (D17): opens the Client favorites dialog for the
     Gallera published collection selected in the Publish Services panel. ]]
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FavoritesDialog = require 'FavoritesDialog'
local Log = require 'Log'

local function selectedCollection()
	for _, source in ipairs(LrApplication.activeCatalog():getActiveSources()) do
		local ok, isOurs = LrTasks.pcall(function()
			return type(source) == 'table' and source.type and source:type() == 'LrPublishedCollection'
				and source:getService():getPluginId() == _PLUGIN.id
		end)
		if ok and isOurs then return source end
	end
	return nil
end

LrTasks.startAsyncTask(function()
	local collection = selectedCollection()
	if not collection then
		Log.info('favorites: no Gallera collection selected')
		return LrDialogs.message('Gallera client favorites',
			'Select a Gallera published collection in the Publish Services panel first.', 'info')
	end
	FavoritesDialog.run(collection)
end)

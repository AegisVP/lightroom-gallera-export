--[[ Gallera publish service provider (DESIGN.md §5.3, §6). ]]
local Log = require 'Log'

local provider = {
	supportsIncrementalPublish = 'only',
	allowFileFormats = { 'JPEG' },
	canExportVideo = false,
	hideSections = { 'exportLocation' },
	hidePrintResolution = true,
}

-- D30: metadata never counts as a change; the fingerprint decides what re-uploads.
function provider.metadataThatTriggersRepublish(publishSettings)
	return { default = false }
end

function provider.getCollectionBehaviorInfo(publishSettings)
	return {
		defaultCollectionName = 'Gallery',
		defaultCollectionCanBeDeleted = true,
		canAddCollection = true,
		maxCollectionSetDepth = 0,
	}
end

function provider.processRenderedPhotos(functionContext, exportContext)
	Log.info('processRenderedPhotos: not implemented yet')
	for _, rendition in exportContext:renditions() do
		rendition:uploadFailed('Not implemented yet')
	end
end

return provider

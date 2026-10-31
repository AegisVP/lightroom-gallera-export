--[[ Gallera publish service for Lightroom Classic (docs/DESIGN.md). ]]
return {
	LrSdkVersion = 14.0,
	LrSdkMinimumVersion = 13.0,
	LrToolkitIdentifier = 'com.pysarenko.gallera',
	LrPluginName = 'Gallera',

	LrInitPlugin = 'Init.lua',
	LrMetadataProvider = 'GalleraMetadata.lua',

	LrLibraryMenuItems = {
		{ title = 'Gallera client favorites...', file = 'FavoritesCommand.lua' },
	},

	LrExportServiceProvider = {
		title = 'Gallera',
		file = 'PublishServiceProvider.lua',
	},

	VERSION = { major = 0, minor = 10, revision = 8 },
}

--[[ Gallera publish service for Lightroom Classic (docs/DESIGN.md). ]]
return {
	LrSdkVersion = 14.0,
	LrSdkMinimumVersion = 13.0,
	LrToolkitIdentifier = 'com.pysarenko.gallera',
	LrPluginName = 'Gallera',

	LrInitPlugin = 'Init.lua',
	LrMetadataProvider = 'GalleraMetadata.lua',

	LrExportServiceProvider = {
		title = 'Gallera',
		file = 'PublishServiceProvider.lua',
	},

	VERSION = { major = 0, minor = 8, revision = 1 },
}

--[[ Throwaway spike plugin: answers DESIGN.md §9.1 questions S1-S7. Not production code. ]]
return {
	LrSdkVersion = 14.0,
	LrSdkMinimumVersion = 13.0,
	LrToolkitIdentifier = 'com.pysarenko.gallera.spike',
	LrPluginName = 'Gallera spikes (throwaway)',

	LrInitPlugin = 'SpikeInit.lua',                 -- S5
	LrMetadataProvider = 'SpikeMetadata.lua',       -- S6/S7 hidden field

	LrExportServiceProvider = {                     -- S1, S3, S4, S7
		title = 'Gallera spike',
		file = 'SpikeServiceProvider.lua',
	},

	-- File > Plug-in Extras (every module)
	LrExportMenuItems = {
		{ title = 'Gallera spike: log in...', file = 'MenuLogin.lua' },
		{ title = 'Gallera spike: log out', file = 'MenuLogout.lua' },
		{ title = 'Gallera spike S2: upload a JPEG...', file = 'MenuS2Upload.lua' },
		{ title = 'Gallera spike S6/S7: set color label...', file = 'MenuS6Label.lua' },
	},

	-- Library > Plug-in Extras (Library module only); the real plugin's menu item goes here (§5.3)
	LrLibraryMenuItems = {
		{ title = 'Gallera spike: log in...', file = 'MenuLogin.lua' },
		{ title = 'Gallera spike: log out', file = 'MenuLogout.lua' },
		{ title = 'Gallera spike S2: upload a JPEG...', file = 'MenuS2Upload.lua' },
		{ title = 'Gallera spike S6/S7: set color label...', file = 'MenuS6Label.lua' },
	},

	VERSION = { major = 0, minor = 4, revision = 0 },
}

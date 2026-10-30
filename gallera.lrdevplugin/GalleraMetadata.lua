--[[ Hidden plugin field (no title, so it isn't shown in the Metadata panel).
     galleraLabelApplied = "<listId>:<color>": which favorites list and color the plugin applied (D14). ]]
return {
	metadataFieldsForPhotos = {
		{ id = 'galleraLabelApplied', dataType = 'string' },
	},
	schemaVersion = 1,
}

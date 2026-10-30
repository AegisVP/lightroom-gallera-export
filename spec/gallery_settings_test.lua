local lu, json = require('luaunit'), require('dkjson')
local FakeHttp = require('support.fake_http')
local GallerySettings = require('GallerySettings')

local function fixture()
	return (json.decode(FakeHttp.fixture('gallery.json'), 1, json.null))
end

TestGallerySettings = {}

function TestGallerySettings:testFieldsMatchSettingsTab()
	local expected = {
		{ 'General', 'name' }, { 'General', 'date' }, { 'General', 'slug' }, { 'General', 'language' },
		{ 'General', 'top_button_enabled' }, { 'General', 'allow_caption' }, { 'General', 'allow_tutorial' },
		{ 'General', 'autoplay_video' }, { 'General', 'face_grouping_enabled' },
		{ 'Scenes', 'allow_all_photos' }, { 'Scenes', 'allow_empty_folders' }, { 'Scenes', 'allow_list_view' },
		{ 'Favorites', 'allow_favorite' }, { 'Favorites', 'is_need_to_finish_favorites' },
		{ 'Favorites', 'allow_limit_favorites' }, { 'Favorites', 'limit_favorites' },
		{ 'Saving', 'allow_download' }, { 'Saving', 'storage_to_date' },
		{ 'Access', 'is_public' }, { 'Access', 'has_password' }, { 'Access', 'password' },
		{ 'Access', 'allow_photo_hiding' }, { 'Access', 'photo_hiding_client_email' },
	}
	local actual, byKey = {}, {}
	for _, f in ipairs(GallerySettings.FIELDS) do
		actual[#actual + 1] = { f.section, f.key }
		byKey[f.key] = f
		lu.assertIsString(f.label)
		lu.assertTrue(f.type == 'string' or f.type == 'date' or f.type == 'bool' or f.type == 'number' or f.type == 'password')
	end
	lu.assertEquals(actual, expected)
	lu.assertEquals(byKey.face_grouping_enabled.availableKey, 'face_grouping_available')
	lu.assertEquals(byKey.password.type, 'password')
	lu.assertEquals(byKey.allow_download.type, 'bool')
	lu.assertEquals(byKey.limit_favorites.type, 'number')
	lu.assertEquals(byKey.storage_to_date.type, 'date')
end

function TestGallerySettings:testToPropsTurnsNullIntoNil()
	local props = GallerySettings.toProps(fixture())
	lu.assertNil(props.storage_to_date)
	lu.assertEquals(props.name, 'Test gallery')
	lu.assertEquals(props.allow_download, false)
	lu.assertNil(props.design)
end

function TestGallerySettings:testDiffReturnsOnlyChanges()
	lu.assertEquals(GallerySettings.diff({ name = 'a', is_public = true }, { name = 'b', is_public = true }), { name = 'b' })
end

function TestGallerySettings:testDiffSendsNullForAClearedField()
	local changed = GallerySettings.diff({ storage_to_date = '2026-12-01' }, {})
	lu.assertEquals(changed.storage_to_date, json.null)
end

function TestGallerySettings:testApplyKeepsEverythingElse()
	local g = fixture()
	local out = GallerySettings.apply(g, { name = 'Новий' })
	local raw = json.encode(out)
	local back = json.decode(raw, 1, json.null)
	lu.assertEquals(back.name, 'Новий')
	lu.assertEquals(back.design.theme, 'light')
	lu.assertEquals(back.storage_to_date, json.null)
	lu.assertStrContains(raw, '"cover":{}')
	lu.assertStrContains(raw, '"extra_unknown":{"k":[]}')
	lu.assertEquals(g.name, 'Test gallery')
end

function TestGallerySettings:testApplyStartsFromFreshObject()
	local baseline = GallerySettings.toProps(fixture())
	lu.assertEquals(baseline.allow_download, false)
	local edited = GallerySettings.toProps(fixture())
	edited.name = 'b'
	local changed = GallerySettings.diff(baseline, edited)
	local fresh = fixture()
	fresh.allow_download = true
	local out = GallerySettings.apply(fresh, changed)
	lu.assertEquals(out.allow_download, true)
	lu.assertEquals(out.name, 'b')
end

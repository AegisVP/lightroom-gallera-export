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
		lu.assertTrue(f.type == 'string' or f.type == 'date' or f.type == 'bool' or f.type == 'number'
			or f.type == 'password' or f.type == 'choice')
	end
	lu.assertEquals(actual, expected)
	lu.assertEquals(byKey.face_grouping_enabled.availableKey, 'face_grouping_available')
	lu.assertEquals(byKey.password.type, 'password')
	lu.assertEquals(byKey.allow_download.type, 'bool')
	lu.assertEquals(byKey.limit_favorites.type, 'number')
	lu.assertEquals(byKey.storage_to_date.type, 'date')
end

function TestGallerySettings:testDependentFieldsRequireTheirSwitch()
	local requires = {}
	for _, f in ipairs(GallerySettings.FIELDS) do requires[f.key] = f.requires end
	lu.assertEquals(requires, {
		is_need_to_finish_favorites = 'allow_favorite',
		limit_favorites = 'allow_limit_favorites',
		password = 'has_password',
		photo_hiding_client_email = 'allow_photo_hiding',
	})
end

function TestGallerySettings:testLanguageIsAChoice()
	local language
	for _, f in ipairs(GallerySettings.FIELDS) do
		if f.key == 'language' then language = f end
	end
	lu.assertEquals(language.type, 'choice')
	lu.assertEquals(GallerySettings.choiceItems(language, 'uk'), {
		{ title = 'English', value = 'en' }, { title = 'Ukrainian', value = 'uk' }, { title = 'Polish', value = 'pl' },
		{ title = 'German', value = 'de' }, { title = 'Spanish', value = 'es' }, { title = 'Czech', value = 'cs' },
		{ title = 'French', value = 'fr' }, { title = 'Italian', value = 'it' },
	})
end

function TestGallerySettings:testUnknownChoiceValueIsKept()
	local language
	for _, f in ipairs(GallerySettings.FIELDS) do
		if f.key == 'language' then language = f end
	end
	local items = GallerySettings.choiceItems(language, 'ua')
	lu.assertEquals(#items, 9)
	lu.assertEquals(items[9], { title = 'ua', value = 'ua' })
	lu.assertEquals(GallerySettings.normalize({ language = '' }).language, nil)
	lu.assertEquals(GallerySettings.normalize({ language = 'ua' }).language, 'ua')
end

function TestGallerySettings:testAccessIsPublicOrPassword()
	lu.assertEquals(GallerySettings.accessMode { is_public = true, has_password = false }, 'public')
	lu.assertEquals(GallerySettings.accessMode { is_public = false, has_password = true }, 'password')
	lu.assertEquals(GallerySettings.accessMode {}, 'public')
	lu.assertEquals(GallerySettings.accessFields('password'), { is_public = false, has_password = true })
	lu.assertEquals(GallerySettings.accessFields('public'), { is_public = true, has_password = false })
end

function TestGallerySettings:testShowingTheCurrentAccessChangesNothing()
	-- Loading sets the radio to the gallery's current mode; that must not touch either flag.
	local props = { is_public = false, has_password = false }
	lu.assertEquals(GallerySettings.accessChanges(props, GallerySettings.accessMode(props)), {})
	props = { is_public = true, has_password = true }
	lu.assertEquals(GallerySettings.accessChanges(props, GallerySettings.accessMode(props)), {})
end

function TestGallerySettings:testChoosingAnotherAccessSetsBothFlags()
	lu.assertEquals(GallerySettings.accessChanges({ is_public = false, has_password = false }, 'password'),
		{ is_public = false, has_password = true })
	lu.assertEquals(GallerySettings.accessChanges({ is_public = false, has_password = true }, 'public'),
		{ is_public = true, has_password = false })
end

function TestGallerySettings:testSwitchingToPasswordAccessChangesBothFlags()
	local baseline = GallerySettings.normalize { is_public = true, has_password = false }
	local edited = GallerySettings.normalize { is_public = true, has_password = false }
	for k, v in pairs(GallerySettings.accessFields('password')) do edited[k] = v end
	edited.password = 'pw'
	lu.assertEquals(GallerySettings.diff(baseline, edited), { is_public = false, has_password = true, password = 'pw' })
end

function TestGallerySettings:testPhotoLimitIsBetweenOneAndThePhotoCount()
	local limit
	for _, f in ipairs(GallerySettings.FIELDS) do
		if f.key == 'limit_favorites' then limit = f end
	end
	local gallery = { photos_count = 3 }
	lu.assertEquals({ GallerySettings.check(limit, 3, gallery) }, { true, 3 })
	lu.assertEquals({ GallerySettings.check(limit, 1, gallery) }, { true, 1 })
	local ok, _, message = GallerySettings.check(limit, 4, gallery)
	lu.assertFalse(ok)
	lu.assertStrContains(message, '1')
	lu.assertStrContains(message, '3')
	ok = GallerySettings.check(limit, 0, gallery)
	lu.assertFalse(ok)
	-- An empty gallery still allows 1.
	lu.assertEquals({ GallerySettings.check(limit, 1, { photos_count = 0 }) }, { true, 1 })
end

function TestGallerySettings:testPhotoLimitHasNoMaximumBeforeTheGalleryExists()
	local limit
	for _, f in ipairs(GallerySettings.FIELDS) do
		if f.key == 'limit_favorites' then limit = f end
	end
	lu.assertEquals({ GallerySettings.check(limit, 50, {}) }, { true, 50 })
	lu.assertFalse((GallerySettings.check(limit, 0, {})))
end

function TestGallerySettings:testNewGalleryDefaults()
	local props = GallerySettings.newGalleryProps('2026-11-06')
	lu.assertEquals(props, GallerySettings.normalize {
		date = '2026-11-06',
		top_button_enabled = true, allow_caption = true,
		allow_all_photos = true, allow_empty_folders = true,
		allow_download = true,
		is_public = true,
	})
	lu.assertEquals(GallerySettings.accessMode(props), 'public')
end

function TestGallerySettings:testNewGalleryChangesSendEveryShownValue()
	local edited = GallerySettings.newGalleryProps('2026-11-06')
	edited.name = 'From the dialog'
	edited.face_grouping_enabled = true
	edited.slug = 'my-wedding'
	local changes = GallerySettings.newGalleryChanges(edited)
	-- Every field with a value, so the gallery matches the dialog.
	lu.assertEquals(changes.allow_tutorial, false)
	lu.assertEquals(changes.allow_download, true)
	lu.assertEquals(changes.is_public, true)
	lu.assertEquals(changes.has_password, false)
	lu.assertEquals(changes.date, '2026-11-06')
	lu.assertEquals(changes.slug, 'my-wedding')
	-- Empty fields keep Gallera's value (unlimited storage, generated address, its language).
	lu.assertNil(changes.storage_to_date)
	lu.assertNil(changes.password)
	lu.assertNil(changes.language)
	lu.assertNil(changes.limit_favorites)
	-- The name is the collection's; people recognition is available only on an existing gallery.
	lu.assertNil(changes.name)
	lu.assertNil(changes.face_grouping_enabled)
end

function TestGallerySettings:testCheckAcceptsFieldsWithoutRange()
	lu.assertEquals({ GallerySettings.check(GallerySettings.FIELDS[1], 'x', {}) }, { true, 'x' })
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

function TestGallerySettings:testNormalizeForDialog()
	local n = GallerySettings.normalize { allow_download = 1, is_public = 0, top_button_enabled = true,
		name = 'Весілля', slug = 'x', storage_to_date = '', photo_hiding_client_email = '', limit_favorites = '10' }
	lu.assertEquals(n.allow_download, true)
	lu.assertEquals(n.is_public, false)
	lu.assertEquals(n.top_button_enabled, true)
	lu.assertEquals(n.allow_caption, false)
	lu.assertEquals(n.name, 'Весілля')
	lu.assertEquals(n.slug, 'x')
	lu.assertNil(n.storage_to_date)
	lu.assertNil(n.photo_hiding_client_email)
	lu.assertEquals(n.limit_favorites, 10)
end

function TestGallerySettings:testUntouchedDialogHasNoChanges()
	-- Gallera sends 1/0 and ''; the dialog gives back true/false and ''. Normalized, nothing changed.
	local fromGallera = GallerySettings.toProps { allow_download = 1, photo_hiding_client_email = '', storage_to_date = json.null }
	local fromDialog = { allow_download = true, photo_hiding_client_email = '', storage_to_date = '' }
	lu.assertEquals(GallerySettings.diff(GallerySettings.normalize(fromGallera), GallerySettings.normalize(fromDialog)), {})
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

-- The collection dialog's g_*/ui_*/link_* keys must not stay in the catalog: g_password is the gallery password.
function TestGallerySettings:testWithoutDialogKeysDropsGPasswordAndUiKeys()
	local stored = {
		LR_canEditName = true, orderByCapture = true, longEdge = 1000, fingerprints = { ['1'] = 'x' },
		g_password = 'secret', g_name = 'n', ui_access = 'public', ui_en_name = true, link_mode = 'link', link_id = 1,
	}
	lu.assertEquals(GallerySettings.withoutDialogKeys(stored), {
		LR_canEditName = true, orderByCapture = true, longEdge = 1000, fingerprints = { ['1'] = 'x' },
	})
	lu.assertEquals(stored.g_password, 'secret')   -- a copy; the input is untouched
end

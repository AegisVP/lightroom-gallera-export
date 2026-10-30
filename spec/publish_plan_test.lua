local lu = require('luaunit')
local PublishPlan = require('PublishPlan')

local function keys(photos)
	local out = {}
	for _, p in ipairs(photos) do out[#out + 1] = p.key end
	return out
end

local PHOTOS = {
	{ key = 'k1', remoteId = 11, fingerprint = 'aaa' },
	{ key = 'k2', remoteId = 12, fingerprint = 'bbb' },
	{ key = 'k3', fingerprint = 'ccc' },
	{ key = 'k4', remoteId = 14, fingerprint = 'ddd' },
}
local FINGERPRINTS = { k1 = 'aaa', k2 = 'old' }

TestPublishPlan = {}

function TestPublishPlan:testClassify()
	local r = PublishPlan.classify { photos = PHOTOS, fingerprints = FINGERPRINTS, favoriteIndex = {} }
	lu.assertEquals(keys(r.unchanged), { 'k1' })
	lu.assertEquals(keys(r.upload), { 'k2', 'k3', 'k4' })
	lu.assertEquals(r.inFavorites, {})
end

function TestPublishPlan:testInFavoritesOnlyForReuploads()
	local r = PublishPlan.classify {
		photos = PHOTOS,
		fingerprints = FINGERPRINTS,
		favoriteIndex = { [11] = { 'vv' }, [12] = { 'vv', '(untitled)' } },
	}
	lu.assertEquals(#r.inFavorites, 1)
	lu.assertEquals(r.inFavorites[1].photo.key, 'k2')
	lu.assertEquals(r.inFavorites[1].titles, { 'vv', '(untitled)' })
end

function TestPublishPlan:testFavoriteIndexUsesDisplayTitles()
	local index = PublishPlan.favoriteIndex {
		{ id = 1, title = 'vv', latest = { { id = 11 }, { id = 12 } } },
		{ id = 2, title = 'https://user.gallera.io/x', latest = { { id = 12 } } },
		{ id = 3, title = 'vv', latest = { { id = 12 } } },
	}
	lu.assertEquals(index, { [11] = { 'vv' }, [12] = { 'vv', '(untitled)' } })
end

function TestPublishPlan:testEstimate()
	lu.assertEquals(PublishPlan.estimateBytes(3, { { filesize = 10 }, { filesize = 20 } }), 45)
	lu.assertEquals(PublishPlan.estimateBytes(2, {}), 2 * 8 * 1024 * 1024)
	lu.assertEquals(PublishPlan.DEFAULT_PHOTO_BYTES, 8 * 1024 * 1024)
	lu.assertEquals(PublishPlan.estimateBytes(0, { { filesize = 10 } }), 0)
end

function TestPublishPlan:testConfirmedDeletes()
	lu.assertEquals(PublishPlan.confirmedDeletes({ 1, 2, 3 }, { 1 }, { 2 }), { 1, 3 })
end

function TestPublishPlan:testConfirmedDeletesComparesAsNumbers()
	lu.assertEquals(PublishPlan.confirmedDeletes({ '1', '2', '3' }, { 1 }, { 2 }), { '1', '3' })
end

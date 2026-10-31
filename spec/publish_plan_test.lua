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

local MB = 1024 * 1024
local GB = 1024 * MB

function TestPublishPlan:testFreeBytes()
	lu.assertEquals(PublishPlan.freeBytes { storage = { used = 2 * GB, limit = 5 * GB } }, 3 * GB)
	lu.assertEquals(PublishPlan.freeBytes { storage = { used = 6 * GB, limit = 5 * GB } }, 0)
end

function TestPublishPlan:testFreeBytesWithoutALimitIsNil()
	lu.assertNil(PublishPlan.freeBytes { storage = { used = 2 * GB } })
	lu.assertNil(PublishPlan.freeBytes { storage = { used = 2 * GB, limit = require('dkjson').null } })
	lu.assertNil(PublishPlan.freeBytes {})
	lu.assertNil(PublishPlan.freeBytes(nil))
end

function TestPublishPlan:testFormatBytes()
	lu.assertEquals(PublishPlan.formatBytes(0), '0 MB')
	lu.assertEquals(PublishPlan.formatBytes(300 * MB), '300 MB')
	lu.assertEquals(PublishPlan.formatBytes(1.5 * GB), '1.5 GB')
	lu.assertEquals(PublishPlan.formatBytes(5 * GB), '5.0 GB')
end

function TestPublishPlan:testStorageWarning()
	lu.assertEquals(PublishPlan.storageWarning(300 * MB, 400 * MB, 50),
		'Gallera has 300 MB free. This publish is estimated at ~400 MB (50 photos).')
end

function TestPublishPlan:testStorageFullMessage()
	lu.assertEquals(PublishPlan.storageFullMessage(4.9 * GB, 5 * GB), 'Gallera storage full (used 4.9 GB of 5.0 GB)')
end

function TestPublishPlan:testForcedUnchangedPhotosUpload()
	local r = PublishPlan.classify {
		photos = PHOTOS, fingerprints = { k1 = 'aaa', k2 = 'bbb' }, favoriteIndex = { [12] = { 'vv' } }, force = { k2 = true },
	}
	lu.assertEquals(keys(r.unchanged), { 'k1' })
	lu.assertEquals(keys(r.upload), { 'k2', 'k3', 'k4' })
end

function TestPublishPlan:testUnchangedPhotosCarryTheirFavoriteTitles()
	local r = PublishPlan.classify {
		photos = PHOTOS, fingerprints = { k1 = 'aaa', k2 = 'bbb' }, favoriteIndex = { [11] = { 'vv', 'x' } },
	}
	lu.assertEquals(r.unchanged[1].favorites, { 'vv', 'x' })
	lu.assertNil(r.unchanged[2].favorites)
end

function TestPublishPlan:testForceDoesNotChangeChangedOrNewPhotos()
	local r = PublishPlan.classify { photos = PHOTOS, fingerprints = FINGERPRINTS, force = { k2 = true, k3 = true } }
	lu.assertEquals(keys(r.unchanged), { 'k1' })
	lu.assertEquals(keys(r.upload), { 'k2', 'k3', 'k4' })
end

-- Gallera's latest[] can be shorter than items_count (seen: 4 of 6); then lightroom_list names are matched.
function TestPublishPlan:testFavoriteIndexFallsBackToNamesForIncompleteLists()
	local lists = {
		{ id = 1, title = 'vv', items_count = 3, latest = { { id = 11 } }, lightroom_list = { 'DSC_1', 'DSC_2', 'DSC_3' } },
	}
	local galleryPhotos = {
		{ id = 11, original_filename = 'DSC_1.jpg' },
		{ id = 12, original_filename = 'DSC_2.jpg' },
		{ id = 13, original_filename = 'DSC_3.JPG' },
		{ id = 14, original_filename = 'DSC_4.jpg' },
	}
	lu.assertEquals(PublishPlan.favoriteIndex(lists, galleryPhotos), { [11] = { 'vv' }, [12] = { 'vv' }, [13] = { 'vv' } })
end

function TestPublishPlan:testFavoriteIndexNameFallbackMarksEveryPhotoWithAnAmbiguousName()
	local lists = { { id = 1, title = 'vv', items_count = 2, latest = {}, lightroom_list = { 'DSC_1' } } }
	local galleryPhotos = { { id = 11, original_filename = 'DSC_1.jpg' }, { id = 12, original_filename = 'DSC_1.jpg' } }
	lu.assertEquals(PublishPlan.favoriteIndex(lists, galleryPhotos), { [11] = { 'vv' }, [12] = { 'vv' } })
end

function TestPublishPlan:testFavoriteIndexIgnoresNamesForCompleteLists()
	local lists = { { id = 1, title = 'vv', items_count = 1, latest = { { id = 11 } }, lightroom_list = { 'DSC_2' } } }
	local galleryPhotos = { { id = 11, original_filename = 'DSC_1.jpg' }, { id = 12, original_filename = 'DSC_2.jpg' } }
	lu.assertEquals(PublishPlan.favoriteIndex(lists, galleryPhotos), { [11] = { 'vv' } })
end

function TestPublishPlan:testIncompleteFavoriteLists()
	lu.assertTrue(PublishPlan.hasIncompleteFavorites { { items_count = 2, latest = { { id = 1 } } } })
	lu.assertFalse(PublishPlan.hasIncompleteFavorites { { items_count = 1, latest = { { id = 1 } } } })
	lu.assertFalse(PublishPlan.hasIncompleteFavorites {})
end

-- The guard lists every queued photo on Gallera that is in client favorites, changed or not.
local GUARD_PHOTOS = {
	{ key = 'k1', remoteId = 11, fingerprint = 'aaa' },   -- unchanged, in favorites
	{ key = 'k2', remoteId = 12, fingerprint = 'bbb' },   -- unchanged
	{ key = 'k3', remoteId = 13, fingerprint = 'new' },   -- changed, in favorites
	{ key = 'k4', remoteId = 14, fingerprint = 'new' },   -- changed
	{ key = 'k5', fingerprint = 'eee' },                  -- new
}
local GUARD_FINGERPRINTS = { k1 = 'aaa', k2 = 'bbb', k3 = 'old', k4 = 'old' }

local function guardResult(index)
	return PublishPlan.classify { photos = GUARD_PHOTOS, fingerprints = GUARD_FINGERPRINTS, favoriteIndex = index }
end

function TestPublishPlan:testUploadsCarryTheirFavoriteTitles()
	local r = guardResult { [13] = { 'vv' } }
	lu.assertEquals(keys(r.upload), { 'k3', 'k4', 'k5' })
	lu.assertEquals(r.upload[1].favorites, { 'vv' })
	lu.assertNil(r.upload[2].favorites)
end

function TestPublishPlan:testGuardListsChangedAndUnchangedFavorites()
	local guarded, force = PublishPlan.guardFavorites(guardResult { [11] = { 'vv' }, [13] = { 'vv' } }, true)
	lu.assertEquals(keys(guarded), { 'k1', 'k3' })
	lu.assertFalse(guarded[1].changed)
	lu.assertTrue(guarded[2].changed)
	lu.assertEquals(guarded[2].favorites, { 'vv' })
	lu.assertEquals(force, { k2 = true })
end

function TestPublishPlan:testGuardListsEveryPublishedPhotoWhenFavoritesAreUnknown()
	local guarded, force = PublishPlan.guardFavorites(guardResult(nil), false)
	lu.assertEquals(keys(guarded), { 'k1', 'k2', 'k3', 'k4' })
	lu.assertEquals(force, {})
end

function TestPublishPlan:testApplyGuardForcesCheckedUnchangedAndHoldsUncheckedChanged()
	local guarded = PublishPlan.guardFavorites(guardResult { [11] = { 'vv' }, [13] = { 'vv' } }, true)
	local force, hold = PublishPlan.applyGuard(guarded, { k1 = true })
	lu.assertEquals(force, { k1 = true })
	lu.assertEquals(hold, { k3 = true })
	force, hold = PublishPlan.applyGuard(guarded, { k3 = true })
	lu.assertEquals(force, {})
	lu.assertEquals(hold, {})
end

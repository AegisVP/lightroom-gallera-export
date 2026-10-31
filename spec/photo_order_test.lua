local lu = require('luaunit')
local PhotoOrder = require('PhotoOrder')

TestPhotoOrder = {}

function TestPhotoOrder:testCaptureOrderFirst()
	lu.assertEquals(PhotoOrder.compute {
		galleryPhotoIds = { 10, 11, 12 },
		captureTimes = { [10] = 300, [11] = 100, [12] = 200 },
	}, { 11, 12, 10 })
end

function TestPhotoOrder:testTiesByRemoteId()
	lu.assertEquals(PhotoOrder.compute {
		galleryPhotoIds = { 20, 19 },
		captureTimes = { [20] = 5, [19] = 5 },
	}, { 19, 20 })
end

function TestPhotoOrder:testNoCaptureTimeKeepsGalleryOrderAfterTimed()
	lu.assertEquals(PhotoOrder.compute {
		galleryPhotoIds = { 1, 2, 3 },
		captureTimes = { [1] = false, [2] = 9, [3] = false },
	}, { 2, 1, 3 })
end

function TestPhotoOrder:testForeignPhotosLastInGalleryOrder()
	lu.assertEquals(PhotoOrder.compute {
		galleryPhotoIds = { 7, 5, 6 },
		captureTimes = { [6] = 1 },
	}, { 6, 7, 5 })
end

function TestPhotoOrder:testAllGroupsTogether()
	lu.assertEquals(PhotoOrder.compute {
		galleryPhotoIds = { 9, 4, 8, 3, 2, 1 },
		captureTimes = { [1] = 50, [2] = false, [3] = 10, [8] = false },
	}, { 3, 1, 8, 2, 9, 4 })
end

function TestPhotoOrder:testCompleteList()
	local ids = { 31, 30, 32, 33, 34 }
	local out = PhotoOrder.compute {
		galleryPhotoIds = ids,
		captureTimes = { [31] = 2, [30] = 2, [33] = false, [99] = 1 },
	}
	lu.assertEquals(#out, #ids)
	local seen = {}
	for _, id in ipairs(out) do
		lu.assertNil(seen[id])
		seen[id] = true
	end
	for _, id in ipairs(ids) do lu.assertTrue(seen[id]) end
end

-- Lightroom order (User Order, imposeSortOrderOnPublishedCollection) -------------------------

function TestPhotoOrder:testLightroomSequenceFirst()
	lu.assertEquals(PhotoOrder.fromSequence {
		galleryPhotoIds = { 1, 2, 3 },
		sequence = { 3, 1, 2 },
	}, { 3, 1, 2 })
end

function TestPhotoOrder:testSequenceIdsMissingFromGalleryAreDropped()
	lu.assertEquals(PhotoOrder.fromSequence {
		galleryPhotoIds = { 1, 2 },
		sequence = { 2, 99, 1 },
	}, { 2, 1 })
end

function TestPhotoOrder:testWebsitePhotosLastInGalleryOrder()
	lu.assertEquals(PhotoOrder.fromSequence {
		galleryPhotoIds = { 7, 1, 8, 2 },
		sequence = { 2, 1 },
	}, { 2, 1, 7, 8 })
end

function TestPhotoOrder:testSequenceStringIdsMatchNumbers()
	lu.assertEquals(PhotoOrder.fromSequence {
		galleryPhotoIds = { 5, 6 },
		sequence = { '6', '5', '6' },
	}, { 6, 5 })
end

-- Order on Gallera setting -----------------------------------------------------------------

function TestPhotoOrder:testModeDefaultsToCapture()
	lu.assertEquals(PhotoOrder.mode {}, 'capture')
end

function TestPhotoOrder:testModeFromSetting()
	lu.assertEquals(PhotoOrder.mode { galleryOrder = 'lightroom' }, 'lightroom')
	lu.assertEquals(PhotoOrder.mode { galleryOrder = 'none', orderByCapture = true }, 'none')
end

function TestPhotoOrder:testModeFromOldCheckbox()
	lu.assertEquals(PhotoOrder.mode { orderByCapture = false }, 'none')
	lu.assertEquals(PhotoOrder.mode { orderByCapture = true }, 'capture')
end

function TestPhotoOrder:testUnknownModeFallsBack()
	lu.assertEquals(PhotoOrder.mode { galleryOrder = 'random' }, 'capture')
end

local lu, json = require('luaunit'), require('dkjson')
local FakeHttp = require('support.fake_http')
local GalleraApi = require('GalleraApi')

local B = GalleraApi.BASE_URL
local ok = FakeHttp.ok

TestGalleraApiPhotos = {}

function TestGalleraApiPhotos:setUp()
	self.fake = FakeHttp.new()
	self.api = GalleraApi.new { http = self.fake.adapter, token = '1|abc' }
end

function TestGalleraApiPhotos:testRequestUploadIsMultipart()
	self.fake:respond(200, ok { url = 'https://r2/u', photo = { id = 140466391 } })
	local r = self.api:requestUpload { galleryId = 837261, filename = 'DSC_0001.jpg', filesize = 11285192, filetype = 'image/jpeg' }
	local req = self.fake.requests[1]
	lu.assertEquals(req.method, 'POST')
	lu.assertEquals(req.url, B .. 'photos/upload/url')
	lu.assertEquals(req.multipart, {
		{ name = 'gallery', value = '837261' },
		{ name = 'filename', value = 'DSC_0001.jpg' },
		{ name = 'filesize', value = '11285192' },
		{ name = 'filetype', value = 'image/jpeg' },
	})
	lu.assertNil(req.headers['Content-Type'])
	lu.assertEquals(req.headers.Authorization, 'Bearer 1|abc')
	lu.assertEquals(r, { url = 'https://r2/u', photoId = 140466391 })
end

function TestGalleraApiPhotos:testPutFileSendsOnlyContentType()
	self.fake:respond(200, '')
	local r = self.api:putFile('https://r2/u?X-Amz-Signature=s', 'BYTES', 'image/jpeg')
	lu.assertEquals(r, true)
	local req = self.fake.requests[1]
	lu.assertEquals(req.method, 'PUT')
	lu.assertEquals(req.url, 'https://r2/u?X-Amz-Signature=s')
	lu.assertEquals(req.body, 'BYTES')
	lu.assertEquals(req.headers, { ['Content-Type'] = 'image/jpeg' })
end

function TestGalleraApiPhotos:testPutFileForbiddenIsApiNotAuth()
	self.fake:respond(403, '<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>')
	local r, err = self.api:putFile('https://r2/u', 'BYTES', 'image/jpeg')
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'api')
	lu.assertEquals(err.status, 403)
	lu.assertStrContains(err.message, 'AccessDenied')
end

function TestGalleraApiPhotos:testPutFileNetworkFailureIsNetworkAndNotRetried()
	self.fake:failNetwork('timeout')
	local r, err = self.api:putFile('https://r2/u', 'BYTES', 'image/jpeg')
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'network')
	lu.assertEquals(#self.fake.requests, 1)
end

function TestGalleraApiPhotos:testConfirmUpload()
	self.fake:respond(200, ok {})
	lu.assertEquals(self.api:confirmUpload(140466391), true)
	local req = self.fake.requests[1]
	lu.assertEquals(req.method, 'POST')
	lu.assertEquals(req.url, B .. 'photos/upload/140466391/uploaded')
	lu.assertEquals(req.body, '{"photo":140466391}')
end

function TestGalleraApiPhotos:testDeletePhotosBody()
	self.fake:respond(200, ok { 140349250 })
	local deleted = self.api:deletePhotos('test-gallery', { 140349250 })
	lu.assertEquals(deleted, { 140349250 })
	local req = self.fake.requests[1]
	lu.assertEquals(req.method, 'POST')
	lu.assertEquals(req.url, B .. 'photos/delete')
	lu.assertEquals((json.decode(req.body)), { gallery = 'test-gallery', photos = { 140349250 } })
end

function TestGalleraApiPhotos:testSortPhotosBody()
	self.fake:respond(200, ok {})
	lu.assertEquals(self.api:sortPhotos('test-gallery', { 140349250, 140349246 }, nil), true)
	local req = self.fake.requests[1]
	lu.assertEquals(req.url, B .. 'photos/sort')
	lu.assertEquals((json.decode(req.body)), { sorted = { 140349250, 140349246 }, gallery = 'test-gallery', type = 'manual' })
	lu.assertStrContains(req.body, '"folder":null')
	lu.assertStrContains(req.body, '140349250')
	lu.assertNotStrContains(req.body, 'e+')
end

function TestGalleraApiPhotos:testListPhotosDropsDeleted()
	self.fake:respond(200, '{"status":"success","message":"OK","data":['
		.. '{"id":1,"deleted_at":null},{"id":2,"deleted_at":"2026-10-30"},{"id":3}]}')
	local photos = self.api:listPhotos('test-gallery')
	lu.assertEquals(self.fake.requests[1].url, B .. 'photos/test-gallery')
	lu.assertEquals(#photos, 2)
	lu.assertEquals(photos[1].id, 1)
	lu.assertEquals(photos[2].id, 3)
end

function TestGalleraApiPhotos:testGetFavorites()
	self.fake:respond(200, ok { { id = 85261, title = 'vv' } })
	local lists = self.api:getFavorites('test-gallery')
	lu.assertEquals(self.fake.requests[1].method, 'GET')
	lu.assertEquals(self.fake.requests[1].url, B .. 'galleries/test-gallery/favorites')
	lu.assertEquals(lists[1].id, 85261)
end

function TestGalleraApiPhotos:testTrashGalleryRefusesNonActive()
	self.fake:respond(200, ok { galleries = { { id = 1, slug = 'other' } }, pagination = { has_more = false } })
	local r, err = self.api:trashGallery(837261)
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'api')
	for _, req in ipairs(self.fake.requests) do
		lu.assertNotEquals(req.method, 'DELETE')
	end
end

function TestGalleraApiPhotos:testTrashGalleryDeletesActiveOnce()
	self.fake:respond(200, ok { galleries = { { id = 837261, slug = 'x' } }, pagination = { has_more = false } })
	self.fake:respond(200, ok {})
	lu.assertEquals(self.api:trashGallery('837261'), true)
	local deletes = {}
	for _, req in ipairs(self.fake.requests) do
		if req.method == 'DELETE' then deletes[#deletes + 1] = req.url end
	end
	lu.assertEquals(deletes, { B .. 'galleries/x/delete' })
end

function TestGalleraApiPhotos:testTrashGalleryNetworkFailureIsNotRetried()
	self.fake:respond(200, ok { galleries = { { id = 837261, slug = 'x' } }, pagination = { has_more = false } })
	self.fake:failNetwork('timeout')
	local r, err = self.api:trashGallery(837261)
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'network')
	local deletes = 0
	for _, req in ipairs(self.fake.requests) do
		if req.method == 'DELETE' then deletes = deletes + 1 end
	end
	lu.assertEquals(deletes, 1)
end

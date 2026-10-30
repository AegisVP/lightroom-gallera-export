local lu = require('luaunit')
local Uploader = require('Uploader')

-- A scripted api: each method takes its results from a queue (the last one repeats), and every
-- call is recorded in api.calls as { name, args... }.
local function stubApi(script)
	local api = { calls = {}, cleanups = {} }
	local counters = {}
	local function nextResult(name)
		counters[name] = (counters[name] or 0) + 1
		local queue = script[name] or {}
		local r = queue[counters[name]] or queue[#queue]
		if type(r) == 'function' then return r(counters[name]) end
		return r[1], r[2]
	end
	function api:requestUpload(opts)
		self.calls[#self.calls + 1] = { 'requestUpload', opts.galleryId, opts.filename, opts.filesize, opts.filetype }
		return nextResult('requestUpload')
	end
	function api:putFile(url, bytes, contentType)
		self.calls[#self.calls + 1] = { 'putFile', url, bytes, contentType }
		return nextResult('putFile')
	end
	function api:confirmUpload(photoId)
		self.calls[#self.calls + 1] = { 'confirmUpload', photoId }
		return nextResult('confirmUpload')
	end
	function api:deletePhotos(slug, ids)
		self.calls[#self.calls + 1] = { 'deletePhotos', slug, ids[1] }
		self.cleanups[#self.cleanups + 1] = { slug, ids }
		return ids
	end
	return api
end

local function names(api)
	local out = {}
	for _, c in ipairs(api.calls) do out[#out + 1] = c[1] end
	return out
end

-- requestUpload gives photo ids 101, 102, 103... for consecutive attempts.
local function freshUrls(n)
	return { url = 'https://r2/u' .. n, photoId = 100 + n }
end

local PHOTO = { galleryId = 837261, slug = 'test-gallery', filename = 'DSC_1.jpg', bytes = 'BYTES', contentType = 'image/jpeg' }

TestUploader = {}

function TestUploader:setUp()
	self.sleeps = {}
	self.sleep = function(s) self.sleeps[#self.sleeps + 1] = s end
end

function TestUploader:testHappyPath()
	local api = stubApi {
		requestUpload = { freshUrls },
		putFile = { { true } },
		confirmUpload = { { true } },
	}
	local id, err = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertEquals(id, 101)
	lu.assertNil(err)
	lu.assertEquals(names(api), { 'requestUpload', 'putFile', 'confirmUpload' })
	lu.assertEquals(api.calls[1], { 'requestUpload', 837261, 'DSC_1.jpg', 5, 'image/jpeg' })
	lu.assertEquals(api.calls[2], { 'putFile', 'https://r2/u1', 'BYTES', 'image/jpeg' })
	lu.assertEquals(api.calls[3], { 'confirmUpload', 101 })
	lu.assertEquals(self.sleeps, {})
end

function TestUploader:testPutFailureRetriesWithFreshUrl()
	local api = stubApi {
		requestUpload = { freshUrls },
		putFile = { { nil, { kind = 'api', status = 403 } }, { true } },
		confirmUpload = { { true } },
	}
	local id = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertEquals(id, 102)
	lu.assertEquals(names(api), { 'requestUpload', 'putFile', 'deletePhotos', 'requestUpload', 'putFile', 'confirmUpload' })
	lu.assertEquals(api.calls[5][2], 'https://r2/u2')
	lu.assertEquals(api.cleanups, { { 'test-gallery', { 101 } } })
	lu.assertEquals(self.sleeps, { 2 })
end

function TestUploader:testNetworkThreeTimesFails()
	local api = stubApi {
		requestUpload = { freshUrls },
		putFile = { { nil, { kind = 'network', message = 'timeout' } } },
	}
	local id, err = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertNil(id)
	lu.assertEquals(err.kind, 'network')
	lu.assertEquals(self.sleeps, { 2, 5 })
	local requests = 0
	for _, n in ipairs(names(api)) do if n == 'requestUpload' then requests = requests + 1 end end
	lu.assertEquals(requests, 3)
	lu.assertEquals(#api.cleanups, 3)
end

function TestUploader:testAuthStopsImmediately()
	local api = stubApi {
		requestUpload = { freshUrls },
		putFile = { { true } },
		confirmUpload = { { nil, { kind = 'auth', status = 403 } } },
	}
	local id, err = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertNil(id)
	lu.assertEquals(err.kind, 'auth')
	lu.assertEquals(names(api), { 'requestUpload', 'putFile', 'confirmUpload', 'deletePhotos' })
	lu.assertEquals(self.sleeps, {})
end

function TestUploader:testAuthOnRequestStopsWithoutCleanup()
	local api = stubApi { requestUpload = { { nil, { kind = 'auth', status = 403 } } } }
	local id, err = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertNil(id)
	lu.assertEquals(err.kind, 'auth')
	lu.assertEquals(names(api), { 'requestUpload' })
	lu.assertEquals(self.sleeps, {})
end

function TestUploader:testApiErrorOnRequestNotRetried()
	local api = stubApi { requestUpload = { { nil, { kind = 'api', message = 'Storage full' } } } }
	local id, err = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertNil(id)
	lu.assertEquals(err.kind, 'api')
	lu.assertEquals(names(api), { 'requestUpload' })
	lu.assertEquals(self.sleeps, {})
end

function TestUploader:testNetworkOnRequestIsRetried()
	local api = stubApi {
		requestUpload = { { nil, { kind = 'network' } }, freshUrls },
		putFile = { { true } },
		confirmUpload = { { true } },
	}
	local id = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertEquals(id, 102)
	lu.assertEquals(names(api), { 'requestUpload', 'requestUpload', 'putFile', 'confirmUpload' })
	lu.assertEquals(self.sleeps, { 2 })
end

function TestUploader:testApiErrorOnConfirmFailsAfterCleanupWithoutRetry()
	local api = stubApi {
		requestUpload = { freshUrls },
		putFile = { { true } },
		confirmUpload = { { nil, { kind = 'api', message = 'nope' } } },
	}
	local id, err = Uploader.upload(api, PHOTO, self.sleep)
	lu.assertNil(id)
	lu.assertEquals(err.kind, 'api')
	lu.assertEquals(names(api), { 'requestUpload', 'putFile', 'confirmUpload', 'deletePhotos' })
	lu.assertEquals(self.sleeps, {})
end

function TestUploader:testWaits()
	lu.assertEquals(Uploader.WAITS, { 2, 5 })
end

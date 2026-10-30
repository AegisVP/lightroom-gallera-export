local lu = require('luaunit')
local GalleryLookup = require('GalleryLookup')

-- A stub api: returns the given lists and counts calls.
local function stubApi(active, trashed)
	local api = { calls = {} }
	function api:listGalleries()
		self.calls[#self.calls + 1] = 'listGalleries'
		if type(active) == 'function' then return active() end
		return active
	end
	function api:listTrashedGalleries()
		self.calls[#self.calls + 1] = 'listTrashedGalleries'
		if type(trashed) == 'function' then return trashed() end
		return trashed
	end
	return api
end

TestGalleryLookup = {}

function TestGalleryLookup:testActive()
	local api = stubApi({ { id = 1, slug = 'a', name = 'A' } }, {})
	local r = GalleryLookup.find(api, 1)
	lu.assertEquals(r.state, 'active')
	lu.assertEquals(r.slug, 'a')
	lu.assertEquals(r.summary.name, 'A')
	lu.assertEquals(api.calls, { 'listGalleries' })
end

function TestGalleryLookup:testTrashed()
	local api = stubApi({ { id = 1, slug = 'a' } }, { { id = 2, slug = 't' } })
	local r = GalleryLookup.find(api, 2)
	lu.assertEquals(r.state, 'trashed')
	lu.assertEquals(r.slug, 't')
end

function TestGalleryLookup:testGone()
	local api = stubApi({ { id = 1, slug = 'a' } }, { { id = 2, slug = 't' } })
	local r = GalleryLookup.find(api, 3)
	lu.assertEquals(r.state, 'gone')
	lu.assertNil(r.slug)
	lu.assertNil(r.summary)
end

function TestGalleryLookup:testChangedSlugUsesCurrentSlug()
	local api = stubApi({ { id = 1, slug = 'renamed' } }, {})
	local r = GalleryLookup.find(api, '1')
	lu.assertEquals(r.state, 'active')
	lu.assertEquals(r.slug, 'renamed')
end

function TestGalleryLookup:testErrorsPassThrough()
	local api = stubApi(function() return nil, { kind = 'auth' } end, {})
	local r, err = GalleryLookup.find(api, 1)
	lu.assertNil(r)
	lu.assertEquals(err, { kind = 'auth' })

	api = stubApi({}, function() return nil, { kind = 'network' } end)
	r, err = GalleryLookup.find(api, 1)
	lu.assertNil(r)
	lu.assertEquals(err, { kind = 'network' })
end

function TestGalleryLookup:testIndexPrefersActive()
	local lookup = GalleryLookup.index({ { id = 1, slug = 'a' } }, { { id = 1, slug = 'old' }, { id = 2, slug = 't' } })
	lu.assertEquals(lookup('1').state, 'active')
	lu.assertEquals(lookup('1').slug, 'a')
	lu.assertEquals(lookup(2).state, 'trashed')
	lu.assertEquals(lookup(9).state, 'gone')
end

local lu, json = require('luaunit'), require('dkjson')
local FakeHttp = require('support.fake_http')
local GalleraApi = require('GalleraApi')

local B = GalleraApi.BASE_URL
local ok = FakeHttp.ok

local function decodedBody(req)
	return (json.decode(req.body, 1, json.null))
end

TestGalleraApi = {}

function TestGalleraApi:setUp()
	self.fake = FakeHttp.new()
	self.api = GalleraApi.new { http = self.fake.adapter }
end

function TestGalleraApi:testLoginSendsJsonAndNoAuthHeader()
	self.fake:respond(200, ok { token = '1|abc', user = { username = 'u' } })
	local token, user = self.api:login('a@b.c', 'pw')
	lu.assertEquals(token, '1|abc')
	lu.assertEquals(user.username, 'u')
	local req = self.fake.requests[1]
	lu.assertEquals(req.method, 'POST')
	lu.assertEquals(req.url, B .. 'auth/login')
	lu.assertEquals(req.headers, {
		Accept = 'application/json',
		['X-Requested-With'] = 'XMLHttpRequest',
		['Content-Type'] = 'application/json',
	})
	lu.assertEquals(decodedBody(req), { email = 'a@b.c', password = 'pw' })
end

function TestGalleraApi:testTokenSendsBearer()
	local api = GalleraApi.new { http = self.fake.adapter, token = '1|abc' }
	self.fake:respond(200, ok { username = 'u' })
	api:getUser()
	lu.assertEquals(self.fake.requests[1].headers.Authorization, 'Bearer 1|abc')
end

function TestGalleraApi:testAuthStatusAndHttpCodesMapToAuth()
	self.fake:respond(403, { status = 'auth', message = 'Unauthenticated.' })
	local r, err = self.api:getUser()
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'auth')
	lu.assertEquals(err.status, 403)

	self.fake:respond(401)
	r, err = self.api:getUser()
	lu.assertEquals(err.kind, 'auth')
	lu.assertEquals(err.status, 401)
end

function TestGalleraApi:testNotFound()
	self.fake:respond(404, { status = 'notFound', message = 'No query results' })
	local r, err = self.api:getGallery('x')
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'notFound')
end

function TestGalleraApi:testOtherStatusIsApiWithMessage()
	self.fake:respond(200, { status = 'error', message = 'Адреса зайнята' })
	local r, err = self.api:createGallery { name = 'a', date = '2026-10-30' }
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'api')
	lu.assertEquals(err.message, 'Адреса зайнята')
end

function TestGalleraApi:testNonJsonBodyIsApiWithHttpStatus()
	self.fake:respond(502, '<html>Bad gateway</html>')
	local r, err = self.api:createGallery { name = 'a', date = '2026-10-30' }
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'api')
	lu.assertEquals(err.message, 'HTTP 502')
end

function TestGalleraApi:testGetRetriesOnceOnNetwork()
	self.fake:failNetwork('timeout')
	self.fake:respond(200, ok { username = 'u' })
	local user = self.api:getUser()
	lu.assertEquals(user.username, 'u')
	lu.assertEquals(#self.fake.requests, 2)

	local fake = FakeHttp.new()
	local api = GalleraApi.new { http = fake.adapter }
	fake:failNetwork('timeout')
	fake:failNetwork('timeout')
	local r, err = api:getUser()
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'network')
	lu.assertEquals(#fake.requests, 2)
end

function TestGalleraApi:testNoHttpStatusIsANetworkFailure()
	-- Offline, LrHttp returns a body but no HTTP status (seen in Lightroom: "HTTP 0").
	self.fake:respond(0, '')
	local r, err = self.api:createGallery { name = 'a', date = '2026-10-30' }
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'network')
	lu.assertEquals(#self.fake.requests, 1)
end

function TestGalleraApi:testGetRetriesOnceWhenThereIsNoHttpStatus()
	self.fake:respond(0, '')
	self.fake:respond(200, ok { username = 'u' })
	lu.assertEquals(self.api:getUser().username, 'u')
	lu.assertEquals(#self.fake.requests, 2)
end

function TestGalleraApi:testPostIsNotRetried()
	self.fake:failNetwork('timeout')
	local r, err = self.api:createGallery { name = 'a', date = '2026-10-30' }
	lu.assertNil(r)
	lu.assertEquals(err.kind, 'network')
	lu.assertEquals(#self.fake.requests, 1)
end

function TestGalleraApi:testListGalleriesFollowsPagination()
	self.fake:respond(200, ok { galleries = { { id = 1 }, { id = 2 } }, pagination = { has_more = true } })
	self.fake:respond(200, ok { galleries = { { id = 3 } }, pagination = { has_more = false } })
	local galleries = self.api:listGalleries()
	lu.assertEquals(#galleries, 3)
	lu.assertEquals(galleries[3].id, 3)
	lu.assertEquals(self.fake.requests[1].url, B .. 'v2/galleries/my?page=1&sort=created&search=')
	lu.assertEquals(self.fake.requests[2].url, B .. 'v2/galleries/my?page=2&sort=created&search=')
end

function TestGalleraApi:testCreateGalleryBody()
	self.fake:respond(200, ok { gallery = 'vesillia' })
	local slug = self.api:createGallery { name = 'Весілля Олени', date = '2026-10-30' }
	lu.assertEquals(slug, 'vesillia')
	local req = self.fake.requests[1]
	lu.assertEquals(req.method, 'POST')
	lu.assertEquals(req.url, B .. 'galleries/create')
	lu.assertStrContains(req.body, '"storage_period":"0"')
	lu.assertStrContains(req.body, '"copy_gallery_id":null')
	lu.assertEquals(decodedBody(req).name, 'Весілля Олени')
	lu.assertEquals(decodedBody(req).date, '2026-10-30')
end

function TestGalleraApi:testSaveGalleryKeepsUnknownFields()
	self.fake:respond(200, FakeHttp.okRaw(FakeHttp.fixture('gallery.json')))
	self.fake:respond(200, ok { slug = 'test-gallery2' })
	local g = self.api:getGallery('test-gallery')
	lu.assertEquals(self.fake.requests[1].url, B .. 'galleries/test-gallery')
	local newSlug = self.api:saveGallery('test-gallery', g)
	lu.assertEquals(newSlug, 'test-gallery2')
	local req = self.fake.requests[2]
	lu.assertEquals(req.method, 'POST')
	lu.assertEquals(req.url, B .. 'galleries/test-gallery')
	lu.assertStrContains(req.body, '"cover":{}')
	lu.assertStrContains(req.body, '"storage_to_date":null')
	lu.assertStrContains(req.body, '"extra_unknown":{"k":[]}')
end

function TestGalleraApi:testTrashedListAcceptsBothShapes()
	self.fake:respond(200, ok { { id = 5 } })
	self.fake:respond(200, ok { galleries = { { id = 5 } } })
	local a = self.api:listTrashedGalleries()
	local b = self.api:listTrashedGalleries()
	lu.assertEquals(#a, 1)
	lu.assertEquals(#b, 1)
	lu.assertEquals(self.fake.requests[1].url, B .. 'galleries/my/deleted')
end

function TestGalleraApi:testSuccessWithoutDataStillSucceeds()
	self.fake:respond(200, { status = 'success', message = 'Gallery restored.' })
	self.fake:respond(200, { status = 'success', message = 'Logged out.' })
	lu.assertEquals(self.api:restoreGallery('x'), true)
	lu.assertEquals(self.api:logout(), true)
end

function TestGalleraApi:testGalleryNamesLogoutRestore()
	self.fake:respond(200, ok { { id = 1, name = 'A' } })
	self.fake:respond(200, ok {})
	self.fake:respond(200, ok {})
	lu.assertEquals(self.api:listGalleryNames(), { { id = 1, name = 'A' } })
	lu.assertEquals(self.api:logout(), true)
	lu.assertEquals(self.api:restoreGallery('x'), true)
	lu.assertEquals(self.fake.requests[1].url, B .. 'galleries/list')
	lu.assertEquals({ self.fake.requests[2].method, self.fake.requests[2].url }, { 'POST', B .. 'auth/logout' })
	lu.assertEquals({ self.fake.requests[3].method, self.fake.requests[3].url }, { 'POST', B .. 'galleries/x/restore' })
end

-- Error texts for the user are English: Gallera's message is in the account's language (seen: Ukrainian) --

function TestGalleraApi:testUserTextHidesGalleraMessage()
	local text = GalleraApi.userText { kind = 'api', status = 422, message = 'Адреса вашої галереї повинна бути унікальною' }
	lu.assertEquals(text, 'Gallera rejected the request (HTTP 422).')
end

function TestGalleraApi:testUserTextServerError()
	lu.assertEquals(GalleraApi.userText { kind = 'api', status = 500, message = 'x' }, 'Gallera error (HTTP 500). Try again later.')
end

function TestGalleraApi:testUserTextNotFound()
	lu.assertEquals(GalleraApi.userText { kind = 'notFound', status = 404, message = 'No query results' }, 'Not found on Gallera (HTTP 404).')
end

function TestGalleraApi:testUserTextNetwork()
	lu.assertEquals(GalleraApi.userText { kind = 'network', message = 'timeout' }, "Gallera can't be reached. Check the internet connection.")
end

function TestGalleraApi:testUserTextKeepsPluginMessagesWithoutStatus()
	lu.assertEquals(GalleraApi.userText { kind = 'api', message = 'Unexpected response from Gallera' }, 'Unexpected response from Gallera')
	lu.assertEquals(GalleraApi.userText { kind = 'storage', message = 'Gallera storage full' }, 'Gallera storage full')
end

function TestGalleraApi:testUserTextNil()
	lu.assertEquals(GalleraApi.userText(nil), 'Gallera error.')
end

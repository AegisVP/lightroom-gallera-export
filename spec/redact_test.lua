local lu, Redact = require('luaunit'), require('Redact')

TestRedact = {}

function TestRedact:testSecretFieldsAreMasked()
	local r = Redact.value({ name = 'g', password = 'p', Token = 't', access_token = 'a',
		public_url_with_token = 'u', nested = { password = 'x' } })
	lu.assertEquals(r, { name = 'g', password = '***', Token = '***', access_token = '***',
		public_url_with_token = '***', nested = { password = '***' } })
end

function TestRedact:testSignedUrlIsMasked()
	lu.assertEquals(Redact.text('PUT https://r2.example/x?X-Amz-Signature=abc&y=1'), 'PUT <signed url>')
end

function TestRedact:testInputIsNotModified()
	local t = { password = 'p' }
	Redact.value(t)
	lu.assertEquals(t.password, 'p')
end

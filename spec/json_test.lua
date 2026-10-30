local lu, json = require('luaunit'), require('dkjson')

TestJson = {}

function TestJson:testNullAndEmptyObjectSurviveRoundTrip()
	local s = '{"a":null,"design":{},"list":[],"name":"Весілля"}'
	-- decode also returns the end position; the parentheses keep it out of encode's state argument.
	local encoded = json.encode((json.decode(s, 1, json.null)))
	local back = json.decode(encoded, 1, json.null)
	lu.assertEquals(back.a, json.null)
	lu.assertStrContains(encoded, '"design":{}')
	lu.assertStrContains(encoded, '"list":[]')
	lu.assertEquals(back.name, 'Весілля')
end

function TestJson:testLargeIdsEncodeAsIntegers()
	lu.assertEquals(json.encode({ 140349250, 140466391 }), '[140349250,140466391]')
end

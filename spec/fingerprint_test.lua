local lu = require('luaunit')
local Fingerprint = require('Fingerprint')

local function inputs(overrides)
	local develop = { Exposure2012 = 0.5, Contrast2012 = 10, CropTop = 0, ToneCurvePV2012 = { 0, 0, 255, 255 } }
	local render = { LR_jpeg_quality = 0.8, LR_size_maxHeight = 2048, LR_size_doConstrain = true }
	local t = { develop = develop, orientation = 'AB', render = render }
	for k, v in pairs(overrides or {}) do t[k] = v end
	return t
end

TestFingerprint = {}

function TestFingerprint:testOrderIndependent()
	local a = { develop = {}, render = {} }
	a.develop.Exposure2012 = 0.5
	a.develop.Nested = { x = 1, y = 'two' }
	a.develop.Contrast2012 = 10
	a.render.LR_jpeg_quality = 0.8
	a.render.LR_size_maxHeight = 2048
	a.orientation = 'AB'

	local b = { orientation = 'AB', render = {}, develop = {} }
	b.render.LR_size_maxHeight = 2048
	b.render.LR_jpeg_quality = 0.8
	b.develop.Contrast2012 = 10
	b.develop.Nested = { y = 'two', x = 1 }
	b.develop.Exposure2012 = 0.5

	lu.assertEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testDevelopChangeChanges()
	local a = inputs()
	local b = inputs()
	b.develop.Exposure2012 = 0.6
	lu.assertNotEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testNestedDevelopChangeChanges()
	local a = inputs()
	local b = inputs()
	b.develop.ToneCurvePV2012 = { 0, 0, 255, 250 }
	lu.assertNotEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testOrientationAndRenderChange()
	lu.assertNotEquals(Fingerprint.of(inputs { orientation = 'AB' }), Fingerprint.of(inputs { orientation = 'BC' }))
	local a, b = inputs(), inputs()
	b.render.LR_jpeg_quality = 0.9
	lu.assertNotEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testMissingOrientationDiffersFromPresent()
	lu.assertNotEquals(Fingerprint.of(inputs { orientation = 'AB' }), Fingerprint.of { develop = inputs().develop, render = inputs().render })
end

function TestFingerprint:testFloatNoiseIgnored()
	local a, b = inputs(), inputs()
	a.develop.Exposure2012 = 0.1 + 0.2
	b.develop.Exposure2012 = 0.3
	lu.assertEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testTypesAreTagged()
	local a, b = inputs(), inputs()
	a.develop.Contrast2012 = 10
	b.develop.Contrast2012 = '10'
	lu.assertNotEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testExcludedKeysIgnored()
	Fingerprint.EXCLUDED_DEVELOP_KEYS.Noise = true
	local a, b = inputs(), inputs()
	a.develop.Noise = 1
	b.develop.Noise = 2
	local same = Fingerprint.of(a) == Fingerprint.of(b)
	Fingerprint.EXCLUDED_DEVELOP_KEYS.Noise = nil
	lu.assertTrue(same)
	lu.assertNotEquals(Fingerprint.of(a), Fingerprint.of(b))
end

function TestFingerprint:testFormat()
	local fp = Fingerprint.of(inputs())
	lu.assertStrMatches(fp, '^%x+$')
	lu.assertEquals(#fp, 16)
	lu.assertEquals(fp, fp:lower())
end

function TestFingerprint:testRenderKeys()
	lu.assertEquals(Fingerprint.RENDER_KEYS, { 'LR_size_doConstrain', 'LR_size_resizeType', 'LR_size_maxWidth',
		'LR_size_maxHeight', 'LR_size_units', 'LR_size_resolution', 'LR_size_doNotEnlarge', 'LR_jpeg_quality',
		'LR_export_colorSpace', 'LR_outputSharpeningOn', 'LR_outputSharpeningMedia', 'LR_outputSharpeningLevel',
		'LR_useWatermark', 'LR_watermarking_id' })
end

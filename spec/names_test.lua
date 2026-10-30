local lu = require('luaunit')
local Names = require('Names')

-- exists(leaf) for a folder holding the given file names.
local function folder(...)
	local files = {}
	for _, name in ipairs({ ... }) do files[name:lower()] = true end
	return function(leaf) return files[leaf:lower()] == true end
end

TestNames = {}

function TestNames:testMarkIsIdempotent()
	lu.assertEquals(Names.DELETED_SUFFIX, ' - (deleted)')
	lu.assertEquals(Names.markDeleted('A'), 'A - (deleted)')
	lu.assertEquals(Names.markDeleted('A - (deleted)'), 'A - (deleted)')
	lu.assertEquals(Names.stripDeleted('A - (deleted)'), 'A')
	lu.assertEquals(Names.stripDeleted('A'), 'A')
	lu.assertEquals(Names.stripDeleted('Весілля - (deleted) - (deleted)'), 'Весілля')
end

function TestNames:testSafeFolder()
	lu.assertEquals(Names.safeFolder('a<b>c:d"e/f\\g|h?i*j'), 'a_b_c_d_e_f_g_h_i_j')
	lu.assertEquals(Names.safeFolder('Wedding. '), 'Wedding')
	lu.assertEquals(Names.safeFolder('a/b.'), 'a_b')
	lu.assertEquals(Names.safeFolder('CON'), '_CON')
	lu.assertEquals(Names.safeFolder('con'), '_con')
	lu.assertEquals(Names.safeFolder('nul.txt'), '_nul.txt')
	lu.assertEquals(Names.safeFolder('LPT9'), '_LPT9')
	lu.assertEquals(Names.safeFolder('Console'), 'Console')
	lu.assertEquals(Names.safeFolder(''), '_')
	lu.assertEquals(Names.safeFolder('...'), '_')
	lu.assertEquals(Names.safeFolder('Весілля Олени'), 'Весілля Олени')
end

function TestNames:testSafeFolderReplacesControlCharacters()
	lu.assertEquals(Names.safeFolder('a\tb\nc'), 'a_b_c')
end

function TestNames:testJpegTargetOwnFileIsOverwritten()
	local jpegFiles = { k1 = 'DSC_1.jpg' }
	lu.assertEquals(Names.jpegTarget(jpegFiles, 'k1', 'DSC_1.jpg', folder('DSC_1.jpg')), 'DSC_1.jpg')
end

function TestNames:testJpegTargetOtherPhotoGetsSuffix()
	local jpegFiles = { k1 = 'DSC_1.jpg' }
	lu.assertEquals(Names.jpegTarget(jpegFiles, 'k2', 'DSC_1.jpg', folder('DSC_1.jpg')), 'DSC_1-2.jpg')
	lu.assertEquals(Names.jpegTarget(jpegFiles, 'k2', 'DSC_1.jpg', folder('DSC_1.jpg', 'DSC_1-2.jpg')), 'DSC_1-3.jpg')
end

function TestNames:testJpegTargetMapEntryWithoutFileStillCounts()
	local jpegFiles = { k1 = 'DSC_1.jpg' }
	lu.assertEquals(Names.jpegTarget(jpegFiles, 'k2', 'DSC_1.jpg', folder()), 'DSC_1-2.jpg')
end

function TestNames:testJpegTargetIgnoresCase()
	local jpegFiles = { k1 = 'dsc_1.JPG' }
	lu.assertEquals(Names.jpegTarget(jpegFiles, 'k2', 'DSC_1.jpg', folder()), 'DSC_1-2.jpg')
end

function TestNames:testJpegTargetKeepsOwnSuffixedName()
	local jpegFiles = { k1 = 'DSC_1.jpg', k2 = 'DSC_1-2.jpg' }
	lu.assertEquals(Names.jpegTarget(jpegFiles, 'k2', 'DSC_1.jpg', folder('DSC_1.jpg', 'DSC_1-2.jpg')), 'DSC_1-2.jpg')
end

function TestNames:testJpegTargetFreeName()
	lu.assertEquals(Names.jpegTarget({}, 'k1', 'DSC_1.jpg', folder()), 'DSC_1.jpg')
	lu.assertEquals(Names.jpegTarget({}, 'k1', 'Весілля 01.jpg', folder()), 'Весілля 01.jpg')
end

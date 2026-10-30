local lu, json = require('luaunit'), require('dkjson')
local FavoritesSync = require('FavoritesSync')

-- Lists shaped like the docs/gallera-api.md example.
local function lists()
	return {
		{ id = 85261, title = 'vv', is_finished = true, items_count = 3,
			latest = { { id = 1 }, { id = 2 }, { id = 3 } } },
		{ id = 85241, title = 'https://user.gallera.io/test-gallery', is_finished = false, items_count = 1,
			latest = { { id = 2 } } },
	}
end

local function plan(choices, photos, l)
	return FavoritesSync.plan { lists = l or lists(), choices = choices, photos = photos }
end

TestFavoritesSync = {}

function TestFavoritesSync:testSetOnEmptyLabel()
	local p = plan({ [85261] = 'red' }, { [1] = { key = 'k1' } })
	lu.assertEquals(p.set, { { key = 'k1', color = 'red', listId = 85261 } })
	lu.assertEquals(p.remove, {})
	lu.assertEquals(p.skippedOtherLabel, {})
	lu.assertEquals(p.conflicts, {})
end

function TestFavoritesSync:testChangeOwnLabel()
	local p = plan({ [85261] = 'red' },
		{ [1] = { key = 'k1', label = 'green', applied = { listId = 85261, color = 'green' } } })
	lu.assertEquals(p.set, { { key = 'k1', color = 'red', listId = 85261 } })
end

function TestFavoritesSync:testSameColorOnlyRecords()
	local p = plan({ [85261] = 'red' }, { [1] = { key = 'k1', label = 'red' } })
	lu.assertEquals(p.set, { { key = 'k1', color = 'red', listId = 85261 } })
	lu.assertEquals(p.skippedOtherLabel, {})
end

function TestFavoritesSync:testOtherLabelSkipped()
	local p = plan({ [85261] = 'red' }, { [1] = { key = 'k1', label = 'yellow' } })
	lu.assertEquals(p.set, {})
	lu.assertEquals(p.skippedOtherLabel, { 'k1' })
end

function TestFavoritesSync:testOwnLabelFromAnotherListThatTheUserRecoloredIsSkipped()
	-- The plugin applied green, but the user has since made it yellow: not ours any more.
	local p = plan({ [85261] = 'red' },
		{ [1] = { key = 'k1', label = 'yellow', applied = { listId = 85261, color = 'green' } } })
	lu.assertEquals(p.set, {})
	lu.assertEquals(p.skippedOtherLabel, { 'k1' })
end

function TestFavoritesSync:testConflict()
	local p = plan({ [85261] = 'red', [85241] = 'blue' }, { [1] = { key = 'k1' }, [2] = { key = 'k2' } })
	lu.assertEquals(p.conflicts, { 'k2' })
	lu.assertEquals(p.set, { { key = 'k1', color = 'red', listId = 85261 } })
end

function TestFavoritesSync:testTwoListsSameColorIsNoConflict()
	local p = plan({ [85261] = 'red', [85241] = 'red' }, { [2] = { key = 'k2' } })
	lu.assertEquals(p.conflicts, {})
	lu.assertEquals(#p.set, 1)
	lu.assertEquals(p.set[1].key, 'k2')
	lu.assertEquals(p.set[1].color, 'red')
end

function TestFavoritesSync:testRemoveOnlyFromChosenListWhenStillOurColor()
	local p = plan({ [85261] = 'red' },
		{ [4] = { key = 'k4', label = 'red', applied = { listId = 85261, color = 'red' } } })
	lu.assertEquals(p.remove, { 'k4' })

	p = plan({ [85261] = 'red' },
		{ [4] = { key = 'k4', label = 'blue', applied = { listId = 85261, color = 'red' } } })
	lu.assertEquals(p.remove, {})
end

function TestFavoritesSync:testSkippedListLeftAlone()
	local p = plan({}, { [4] = { key = 'k4', label = 'red', applied = { listId = 85261, color = 'red' } } })
	lu.assertEquals(p.remove, {})
	lu.assertEquals(p.set, {})
end

function TestFavoritesSync:testVanishedListLeftAlone()
	local p = plan({ [85261] = 'red', [999] = 'red' },
		{ [4] = { key = 'k4', label = 'red', applied = { listId = 999, color = 'red' } } })
	lu.assertEquals(p.remove, {})
	lu.assertEquals(p.set, {})
end

function TestFavoritesSync:testIncompleteList()
	local l = lists()
	l[1].items_count = 5
	local p = plan({}, {}, l)
	lu.assertEquals(p.incompleteLists, { 85261 })
end

function TestFavoritesSync:testSummarize()
	local rows = FavoritesSync.summarize(lists(), { [1] = { key = 'k1' }, [2] = { key = 'k2' } })
	lu.assertEquals(rows, {
		{ id = 85261, title = 'vv', finished = true, count = 3, matched = 2 },
		{ id = 85241, title = '(untitled)', finished = false, count = 1, matched = 1 },
	})
end

function TestFavoritesSync:testDisplayTitle()
	lu.assertEquals(FavoritesSync.displayTitle(nil), '(untitled)')
	lu.assertEquals(FavoritesSync.displayTitle(''), '(untitled)')
	lu.assertEquals(FavoritesSync.displayTitle(json.null), '(untitled)')
	lu.assertEquals(FavoritesSync.displayTitle('https://user.gallera.io/x'), '(untitled)')
	lu.assertEquals(FavoritesSync.displayTitle('Вибір Олени'), 'Вибір Олени')
end

function TestFavoritesSync:testChangedLists()
	local seen = { [85261] = { count = 3, finished = true } }
	local changed = FavoritesSync.changedLists(lists(), seen)
	lu.assertEquals(#changed, 1)
	lu.assertEquals(changed[1].id, 85241)

	local l = lists()
	l[1].items_count = 4
	changed = FavoritesSync.changedLists(l, seen)
	lu.assertEquals(#changed, 2)
	lu.assertEquals(changed[1].id, 85261)
end

function TestFavoritesSync:testSeenFromRoundTrip()
	local seen = FavoritesSync.seenFrom(lists())
	lu.assertEquals(seen, { [85261] = { count = 3, finished = true }, [85241] = { count = 1, finished = false } })
	lu.assertEquals(FavoritesSync.changedLists(lists(), seen), {})
end

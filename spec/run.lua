--[[ Runs every spec/*_test.lua with luaunit. Usage, from the repo root:
       tools\lua51\lua5.1.exe spec\run.lua [luaunit options, e.g. -p Pattern]
]]
package.path = 'spec/?.lua;gallera.lrdevplugin/?.lua;' .. package.path

local lu = require('luaunit')

-- Lua 5.1 can't list a directory, so ask cmd.exe (this runs on Windows only).
local listing = io.popen('dir /b /o:n spec\\*_test.lua 2>nul')
for name in listing:lines() do
	dofile('spec/' .. name)
end
listing:close()

os.exit(lu.LuaUnit.run(...))

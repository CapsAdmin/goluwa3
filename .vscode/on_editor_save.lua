local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
local ok, err = pcall(assert(loadfile("goluwa.lua")), path)

if not ok then io.write(err, "\n") end

--ANALYZE
local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
assert(loadfile(path))()

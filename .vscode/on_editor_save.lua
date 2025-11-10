--ANALYZE
local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
path = path:match("goluwa3/(.*)") or path
require("goluwa.global_environment")
assert(loadfile(path))()

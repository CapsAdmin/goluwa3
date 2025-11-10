--ANALYZE
local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
path = path:match("goluwa3/(.*)") or path
require("src.global_environment")
assert(loadfile(path))()

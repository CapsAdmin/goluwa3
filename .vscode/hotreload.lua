local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
local ok, err = pcall(assert(loadfile("glw")), "--reload", path)

if not ok then io.write(err, "\n") end

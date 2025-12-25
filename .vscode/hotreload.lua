_G.NORMAL_STDOUT = true
local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
local ok, err = xpcall(assert(loadfile("glw")), debug.traceback, "--reload", path)

if not ok then io.write(err, "\n") end

local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
path = path:match("goluwa3/(.*)") or path
require("goluwa.global_environment")
local process = require("bindings.process")
local fs = require("fs")
local pid = fs.read_file(".running_pid")

if pid and process.from_id(tonumber(pid)) then
	return
else
	assert(loadfile(path))()
end

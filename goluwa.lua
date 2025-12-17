#! /usr/bin/env luajit

require("goluwa.global_environment")
local path = ...

do
	local vfs = require("vfs")
	local wdir = vfs.GetStorageDirectory("working_directory")

	if path:starts_with(wdir) then path = path:sub(#wdir + 1, #path) end
end

assert(loadfile(path))()
require("main")()

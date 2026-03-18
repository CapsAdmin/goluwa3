local path = ...
require("goluwa.global_environment")
local fs = import("goluwa/fs.lua")
local process = import("goluwa/bindings/process.lua")

if process.from_id(tonumber(fs.read_file(".running_pid"))) then return end

import("goluwa/filewatcher.lua").Reload(path, true)

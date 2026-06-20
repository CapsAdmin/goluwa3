local path = ...
require("goluwa.global_environment")
local fs = import("goluwa/filesystem/fs.lua")
local process = import("goluwa/bindings/process.lua")

if process.from_id(tonumber(fs.read_file(".running_pid"))) then return end

import("goluwa/filesystem/watcher.lua").Reload(path, true)

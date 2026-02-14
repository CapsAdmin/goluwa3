local path = ...
require("goluwa.global_environment")
local fs = require("fs")
local process = require("bindings.process")

if process.from_id(tonumber(fs.read_file(".running_pid"))) then return end

require("filewatcher").Reload(path, true)

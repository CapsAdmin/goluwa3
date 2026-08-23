local fs = import("goluwa/filesystem/fs.lua")
local lrun = library()
lrun.environment = {}

function lrun.SetEnvironmentVariable(key, var)
	lrun.environment[key] = var
end

function lrun.Run(code_or_path, config)
	local name = nil

	if code_or_path:ends_with(".lua") then
		local vfs = import("goluwa/vfs.lua")
		local wdir = vfs.GetStorageDirectory("working_directory")

		if code_or_path:starts_with(wdir) then
			code_or_path = code_or_path:sub(#wdir + 1, #code_or_path)
		end

		name = "@" .. code_or_path
		code_or_path = assert(fs.read_file(code_or_path))
	end

	lrun.SetEnvironmentVariable("system", import("goluwa/system.lua"))
	lrun.SetEnvironmentVariable("event", import("goluwa/event.lua"))
	lrun.SetEnvironmentVariable("commands", import("goluwa/cli/commands.lua"))
	lrun.SetEnvironmentVariable("Vec3", import("goluwa/structs/vec3.lua"))
	lrun.SetEnvironmentVariable("Quat", import("goluwa/structs/quat.lua"))
	lrun.SetEnvironmentVariable("Ang3", import("goluwa/structs/ang3.lua"))
	lrun.SetEnvironmentVariable("ffi", require("ffi"))
	lrun.SetEnvironmentVariable("goluwa", _G.get_libraries().libs)

	lrun.SetEnvironmentVariable("copy", function(var)
		local clipboard = import("goluwa/bindings/clipboard.lua")
		local str = tostring(var)
		clipboard.Set(str)
		logn("copied ", str, " to clipboard")
	end)

	local lua = ""

	for k in pairs(lrun.environment) do
		lua = lua .. ("local %s = assert(_G.__lrun__env.%s);"):format(k, k)
	end

	lua = lua .. "_G.__lrun__env=nil;"
	lua = lua .. code_or_path
	local ok, err = loadstring(lua, config.name or name or code_or_path)

	if err then err = err:match("^.-:%d+:%s+(.+)") end

	_G.__lrun__env = lrun.environment
	local res = {assert(ok, err)(list.unpack(config.arguments or {}))}
	return list.unpack(res)
end

function lrun.Execute(code_or_path, config)
	local ret = {xpcall(lrun.Run, debug.traceback, code_or_path, config)}
	local ok = list.remove(ret, 1)

	if not ok then
		if config.log_error then logn(ret[1]:match(".+:%d+:%s+(.+)")) end

		return false, ret[1]
	end

	return true, unpack(ret)
end

return lrun

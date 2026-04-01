local T = import("test/environment.lua")
local fs = import("goluwa/fs.lua")

local function create_love_filesystem_env()
	local love = {_line_env = {}}
	assert(loadfile("goluwa/love/libraries/filesystem.lua"))(love)
	return love
end

T.Test("love.filesystem.getInfo reports Love-style metadata", function()
	local love = create_love_filesystem_env()
	love.filesystem.setIdentity("test_love_filesystem_getinfo")

	local file_path = "getinfo/sample.txt"
	local directory_path = "getinfo"
	local content = "hello"
	local save_directory = love.filesystem.getSaveDirectory()

	assert(fs.create_directory_recursive(save_directory .. directory_path))
	assert(fs.write_file(save_directory .. file_path, content))

	local file_info = love.filesystem.getInfo(file_path)
	T(file_info)["~="](nil)
	T(file_info.type)["=="]("file")
	T(file_info.size)["=="](#content)
	T(file_info.modtime == nil or type(file_info.modtime) == "number")["=="](true)

	local filtered_file_info = love.filesystem.getInfo(file_path, "file")
	T(filtered_file_info)["~="](nil)
	T(filtered_file_info.type)["=="]("file")
	T(love.filesystem.getInfo(file_path, "directory"))["=="](nil)

	local directory_info = love.filesystem.getInfo(directory_path)
	T(directory_info)["~="](nil)
	T(directory_info.type)["=="]("directory")
	T(directory_info.size)["=="](nil)
	T(love.filesystem.getInfo(directory_path, "directory").type)["=="]("directory")

	T(love.filesystem.getInfo("getinfo/missing.txt"))["=="](nil)
	T(love.filesystem.getLastModified(file_path))["=="](file_info.modtime)
	T(love.filesystem.getLastModified("getinfo/missing.txt"))["=="](nil)
end)
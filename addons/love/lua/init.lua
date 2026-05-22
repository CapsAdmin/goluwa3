local commands = import("goluwa/commands.lua")
local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")
local resource = import("goluwa/resource.lua")

commands.Add("love_run=string,var_arg", function(name, ...)
	local line = import("lua/line.lua")
	local found

	if vfs.IsDirectory("lovers/" .. name) then
		found = line.RunGame("lovers/" .. name, ...)
	elseif vfs.IsFile("lovers/" .. name .. ".love") then
		found = line.RunGame("lovers/" .. name .. ".love", ...)
	elseif name:find("github") then
		local url = name

		if name:starts_with("github/") then
			url = name:gsub("github/", "https://github.com/") .. "/archive/master.zip"
		else
			url = url .. "/archive/master.zip"
		end

		local args = {...}

		resource.Download(url):Then(function(full_path)
			full_path = full_path .. "/" .. name:match(".+/(.+)") .. "-master"
			logn("running downloaded löve game: ", full_path)
			line.RunGame(full_path, unpack(args))
		end)
	else
		for _, file_name in ipairs(vfs.Find("lovers/")) do
			if file_name:compare(name) and vfs.IsDirectory("lovers/" .. file_name) then
				found = line.RunGame("lovers/" .. file_name)

				break
			end
		end
	end

	if found then
		if menu then menu.Close() end
	else
		return false, "love game " .. name .. " does not exist"
	end
end)

event.AddListener("WindowDrop", "line", function(wnd, paths)
	local line = import("lua/line.lua")

	for _, path in ipairs(paths) do
		if vfs.IsDirectory(path) and vfs.IsFile(path .. "/main.lua") then
			line.RunGame(path)

			if menu then menu.Close() end

			break
		end
	end
end)

commands.Add("love=string", function(game)
	local line = import("lua/line.lua")
	line.RunGame("addons/love/games/" .. game)
end)

local T = import("test/environment.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")

T.Test("addons only import from addons they declare", function()
	local addons = {}
	local by_name = {}
	local by_folder = {}
	local files_of = {}
	local owners = {}

	for _, info in ipairs(vfs.GetMountedAddons()) do
		local folder = info.path:match("/addons/([^/]+)/$")

		if folder and not by_folder[folder] then
			addons[#addons + 1] = info
			by_folder[folder] = info
		end
	end

	for _, info in ipairs(addons) do
		by_name[info.name] = info
		files_of[info] = {}

		for _, path in ipairs(fs.get_files_recursive(info.path)) do
			if path:ends_with(".lua") then
				local relative = path:sub(#info.path + 1)
				files_of[info][#files_of[info] + 1] = path
				local lua_path = relative:match("^lua/(.+)$")

				if lua_path then
					owners[lua_path] = owners[lua_path] or {}
					owners[lua_path][info] = true
					owners[lua_path][#owners[lua_path] + 1] = info
				end
			end
		end
	end

	local allowed = {}

	for _, info in ipairs(addons) do
		local set = {[info] = true}
		local stack = {info}

		while stack[1] do
			for _, name in ipairs(table.remove(stack).dependencies or {}) do
				local dependency = by_name[name]

				if dependency and not set[dependency] then
					set[dependency] = true
					stack[#stack + 1] = dependency
				end
			end
		end

		allowed[info] = set
	end

	local offenders = {}

	for _, info in ipairs(addons) do
		for _, path in ipairs(files_of[info]) do
			local file = assert(io.open(path, "rb"))
			local source = file:read("*a")
			file:close()

			for module in source:gmatch("import%(\"([^\"]+)\"%)") do
				local target
				local lua_path = module:match("^lua/(.+)$")

				if lua_path then
					local candidates = owners[lua_path]

					if candidates and not candidates[info] then target = candidates[1] end
				else
					local folder = module:match("^addons/([^/]+)/")
					target = folder and by_folder[folder]
				end

				if target and not allowed[info][target] then
					offenders[#offenders + 1] = info.name .. " -> " .. target.name .. ": " .. path:sub(#info.path + 1) .. " imports " .. module
				end
			end
		end
	end

	table.sort(offenders)
	T(table.concat(offenders, "\n"))["=="]("")
end)

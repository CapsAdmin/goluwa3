local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local spawnmenu = gine.env.spawnmenu

do
	local default_dir = "settings/spawnlist_default/"
	local user_dir = "settings/spawnlist/"
	local lowercase_words = {["and"] = true, of = true, the = true, ["in"] = true, on = true, a = true}

	local function name_from_file_name(file_name)
		local name = file_name:gsub("%.txt$", ""):gsub("^%d+%-", ""):gsub("_s ", "'s "):gsub("_ ", ": ")
		local words = {}

		for word in name:gmatch("%S+") do
			if #words > 0 and lowercase_words[word] then
				words[#words + 1] = word
			else
				words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
			end
		end

		return list.concat(words, " ")
	end

	local function find_spawnlists(dir)
		local out = {}
		local mount_dir

		for _, full_path in ipairs(vfs.Find(dir, true)) do
			local this_dir = full_path:match("^(.*/)")

			if full_path:ends_with(".txt") then
				mount_dir = mount_dir or this_dir

				if this_dir == mount_dir then out[full_path:match("[^/]+$")] = full_path end
			end
		end

		return out
	end

	function spawnmenu.PopulateFromTextFiles(callback)
		local paths = find_spawnlists(user_dir)

		if next(paths) == nil then paths = find_spawnlists(default_dir) end

		local file_names = {}

		for file_name in pairs(paths) do
			file_names[#file_names + 1] = file_name
		end

		table.sort(file_names)

		for _, file_name in ipairs(file_names) do
			local _, info = next(steam.VDFToTable(vfs.Read(paths[file_name]), true))
			callback(
				file_name,
				info.name or name_from_file_name(file_name),
				info.contents or {},
				info.icon,
				info.id,
				info.parentid,
				info.needsapp
			)
		end
	end

	function spawnmenu.SaveToTextFiles(spawnlists)
		for file_name in vfs.Iterate(user_dir) do
			if file_name:ends_with(".txt") then vfs.Delete(user_dir .. file_name) end
		end

		vfs.CreateDirectoriesFromPath("os:" .. gine.dir .. user_dir, true)

		for key, keyvalues in pairs(spawnlists) do
			vfs.Write("os:" .. gine.dir .. user_dir .. key:lower() .. ".txt", keyvalues)
		end
	end
end

do
	function gine.env.LoadPresets()
		local out = {}

		for folder_name in vfs.Iterate("settings/presets/") do
			if vfs.IsDirectory("settings/presets/" .. folder_name) then
				out[folder_name] = {}

				for file_name in vfs.Iterate("settings/presets/" .. folder_name .. "/") do
					list.insert(
						out[folder_name],
						steam.VDFToTable(vfs.Read("settings/presets/" .. folder_name .. "/" .. file_name))
					)
				end
			end
		end

		return out
	end

	function gine.env.SavePresets() end
end

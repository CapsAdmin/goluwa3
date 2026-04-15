local steam = import("goluwa/steam.lua")
local vfs = import("goluwa/vfs.lua")

local spawnmenu = gine.env.spawnmenu

spawnmenu.content_types = spawnmenu.content_types or {}

function spawnmenu.AddContentType(name, callback)
	spawnmenu.content_types[name] = callback
	return callback
end

function spawnmenu.PopulateFromTextFiles()
	return {}
end

do -- presets
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
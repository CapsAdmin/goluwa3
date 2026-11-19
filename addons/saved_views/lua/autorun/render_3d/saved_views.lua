local commands = import("goluwa/cli/commands.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local system = import("goluwa/system.lua")
local Shot = import("goluwa/render3d/shot.lua")
local saved_views = import("lua/saved_views.lua")

commands.Add("copyview", function()
	clipboard.Set(saved_views.Format())
end)

commands.Add("saveview=string,string_rest|nil", function(name, note)
	logn("saved view ", name, " to ", saved_views.Save(name, note))
end)

commands.Add("removeview=string,string|nil", function(map_or_name, name)
	if name then
		saved_views.Remove(map_or_name, name)
	else
		saved_views.Remove(nil, map_or_name)
	end
end)

commands.Add("view=string,string|nil", function(map_or_name, name)
	if name then
		saved_views.Apply(map_or_name, name)
	else
		saved_views.Apply(nil, map_or_name)
	end
end)

commands.Add("viewoff", function()
	saved_views.Release()
end)

commands.Add("views", function()
	local current = saved_views.GetScene()

	for _, data in ipairs(saved_views.GetAllData()) do
		logn(data.scene, data.scene == current and " (current)" or "")

		for name, entry in pairs(data.views) do
			logn("\t", name, entry.note and (" - " .. entry.note) or "")
		end
	end
end)

commands.Add({
	aliases = "viewshot",
	argtypes = "string,string|nil",
	flags = {
		out = {
			type = "string",
			description = "File for one view, or a directory for 'all'",
		},
		settle = {type = "number", description = "Seconds to hold each view before capturing (2)"},
		converge = {
			type = "number",
			description = "Then wait until the mean rgb difference between captures is at most this (0-255, 0.5)",
		},
	},
}, function(map_or_name, name_or_nil, flags)
	local map = name_or_nil and map_or_name
	local name = name_or_nil or map_or_name
	local names = {name}

	if name == "all" then
		names = {}
		local data = saved_views.GetData(saved_views.FindScene(map))

		for view_name in pairs(data.views) do
			list.insert(names, view_name)
		end

		table.sort(names)
	end

	local function run(i)
		if not names[i] then system.ShutDown(0) end

		local scene, entry = saved_views.Find(map, names[i])
		saved_views.EnterScene(scene, entry.args)
		saved_views.ApplyWorld(entry)

		Shot.Capture(
			saved_views.GetProperties(entry),
			function(texture, info)
				local path = flags.out

				if name == "all" then
					path = (flags.out or "storage/logs/screenshots") .. "/" .. names[i] .. ".png"
				end

				logf("[viewshot] saved %s after %.2fs\n", texture:SaveWithoutAlpha(path), info.seconds)
				run(i + 1)
			end,
			{wait_loaded = true, settle = flags.settle, converge = flags.converge or 0.5}
		)
	end

	run(1)
end)

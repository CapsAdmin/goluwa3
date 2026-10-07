local commands = import("goluwa/cli/commands.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local codec = import("goluwa/codec.lua")
local tasks = import("goluwa/tasks.lua")
local fs = import("goluwa/filesystem/fs.lua")
local utility = import("goluwa/utility.lua")
local steam = import("goluwa/steam/steam.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/entities/entity.lua")
local bsp = import("goluwa/source_engine/bsp.lua")
local map_scene = import("goluwa/source_engine/map_scene.lua")
local lights = import("goluwa/source_engine/lights.lua")
local source_engine = {}

local function wait_for_map(path)
	local done, failed = false, false
	model_loader.LoadModel(
		path,
		function()
			done = true
		end,
		nil,
		function(err)
			wlog("failed to load map " .. path .. ": " .. err)
			done, failed = true, true
		end
	)

	while not done do
		tasks.Wait()
	end

	if failed then return nil end

	return bsp.resolved[path]
end

function source_engine.Load(name)
	if tonumber(name) then
		local workshop_id = tonumber(name)
		local info = codec.LookupInFile("luadata", "workshop_maps.cfg", workshop_id)

		if info and vfs.IsFile(info.path) then
			steam.MountSourceGame(info.appid)
			vfs.Mount(info.path, "maps/")
			return source_engine.Load(info.name)
		end

		steam.DownloadWorkshop(workshop_id, function(path, info)
			local map_name = info.publishedfiledetails[1].filename:match(".+/(.+)%.bsp")
			local appid = info.publishedfiledetails[1].creator_app_id
			codec.StoreInFile(
				"luadata",
				"workshop_maps.cfg",
				workshop_id,
				{path = path, name = map_name, appid = appid}
			)
			steam.MountSourceGame(appid)
			vfs.Mount(path, "maps/")
			source_engine.Load(map_name)
		end)

		return
	end

	local path = "maps/" .. name .. ".bsp"
	scene.Clear()
	local task = tasks.CreateTask()
	scene_loading.HoldTask(task)

	function task:OnStart()
		local data = wait_for_map(path)

		if not data then return end

		local scene_data = map_scene.Translate(data, name, path)
		scene.BeginSpawning()
		local ok, err = pcall(scene.Deserialize, scene_data, Entity.World, {yield_every = 128})
		scene.EndSpawning()

		if not ok then error(err, 0) end
	end

	task:Start()
end

commands.Add("map=string_trim|nil", function(name)
	if not name then
		for _, path in ipairs(vfs.Find("maps/.-%.bsp")) do
			print(file_path.RemoveExtensionFromPath(path))
		end

		return
	end

	utility.PushTimeWarning()
	source_engine.Load(name)
	utility.PopTimeWarning("map " .. name, nil, "cmd")
end)

commands.Add("list_maps", function(search)
	for _, name in ipairs(vfs.Find("maps/%.bsp$")) do
		if not search or name:find(search) then logn(name:sub(0, -5)) end
	end
end)

commands.Add("bsp_dump_lights", function()
	local lines = {}

	for component in pairs(lights.GetInstances()) do
		local owner = component.Owner
		local light = owner.light_spot or owner.light_point
		local pos = owner.transform:GetPosition()
		local raw = {}

		for key, value in pairs(component.Info) do
			raw[#raw + 1] = key .. "=" .. tostring(type(value) == "table" and table.concat({value.r, value.g, value.b, value.brightness}, ",") or value)
		end

		table.sort(raw)
		lines[#lines + 1] = string.format(
			"%s #%d at %.2f %.2f %.2f\n  bsp: %s\n  engine: color %.3f %.3f %.3f  lumen %.4g  candela %.4g  range %g  source radius %.2f  linear %.4g  quadratic %.4g  effective range %.2f%s",
			owner:GetName(),
			#lines + 1,
			pos.x,
			pos.y,
			pos.z,
			table.concat(raw, "  "),
			light.Color.r,
			light.Color.g,
			light.Color.b,
			light.Lumen,
			light.Lumen * light:GetInverseEmissionSolidAngle(),
			light.Range,
			light.SourceRadius,
			light.LinearFalloff,
			light.QuadraticFalloff,
			light:GetEffectiveRange(),
			light.Type == "light_spot" and
				string.format("  cone %g..%g", light.InnerCone, light.OuterCone) or
				""
		)
	end

	local path = "./storage/logs/bsp_lights.txt"
	fs.write_file(path, table.concat(lines, "\n") .. "\n")
	logf("%d bsp lights written to %s\n", #lines, path)
end)

return source_engine

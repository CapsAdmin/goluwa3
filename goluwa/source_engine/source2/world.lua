local startup = import("goluwa/startup.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local scene = import("goluwa/entities/scene.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local units = import("goluwa/source_engine/units.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local entity_lump = import("goluwa/source_engine/source2/entity_lump.lua")
local world = {}
local Color = import("goluwa/structs/color.lua")
local LIGHT_BRIGHTNESS = 300
local PROP_MOTION = {
	prop_physics = "dynamic",
	prop_physics_override = "dynamic",
	prop_physics_multiplayer = "dynamic",
	func_physbox = "dynamic",
	prop_dynamic = "static",
	prop_dynamic_override = "static",
}

-- the entity color is sRGB, the shaders multiply it into linear albedo
local function get_tint(color)
	if not color or (color[1] >= 250 and color[2] >= 250 and color[3] >= 250) then return nil end

	return {(color[1] / 255) ^ 2.2, (color[2] / 255) ^ 2.2, (color[3] / 255) ^ 2.2}
end

local axis_x = Vec3(1, 0, 0)
local axis_y = Vec3(0, 1, 0)
local axis_z = Vec3(0, 0, 1)

local function normalize_path(path)
	return (path:gsub("\\", "/"):lower())
end

function world.GetMapDirectory(info)
	return info.vdf_directory .. "maps/"
end

function world.ListMaps(info)
	local names = {}

	for _, file in ipairs(vfs.Find("os:" .. world.GetMapDirectory(info) .. "%.vpk$")) do
		local name = file:sub(1, -5)

		if not name:find("_commentary$") and not name:find("_skybox$") then
			names[#names + 1] = name
		end
	end

	table.sort(names)
	return names
end

function world.FindMap(name)
	for _, info in ipairs(steam.GetSourceGames()) do
		if
			info.source2 and
			vfs.IsFile("os:" .. world.GetMapDirectory(info) .. name .. ".vpk")
		then
			return info
		end
	end
end

local function matrix_to_transform(m)
	local s = {
		{m[1][1], m[1][2], m[1][3]},
		{m[2][1], m[2][2], m[2][3]},
		{m[3][1], m[3][2], m[3][3]},
	}
	local size = math.sqrt(s[1][1] ^ 2 + s[2][1] ^ 2 + s[3][1] ^ 2)

	if size > 0 then
		for i = 1, 3 do
			for j = 1, 3 do
				s[i][j] = s[i][j] / size
			end
		end
	end

	local C = {{0, -1, 0}, {0, 0, 1}, {-1, 0, 0}}
	local e = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}

	for i = 1, 3 do
		for j = 1, 3 do
			local sum = 0

			for k = 1, 3 do
				for l = 1, 3 do
					sum = sum + C[i][k] * s[k][l] * C[j][l]
				end
			end

			e[i][j] = sum
		end
	end

	local trace = e[1][1] + e[2][2] + e[3][3]
	local x, y, z, w

	if trace > 0 then
		local k = math.sqrt(trace + 1) * 2
		w = k / 4
		x = (e[3][2] - e[2][3]) / k
		y = (e[1][3] - e[3][1]) / k
		z = (e[2][1] - e[1][2]) / k
	elseif e[1][1] > e[2][2] and e[1][1] > e[3][3] then
		local k = math.sqrt(1 + e[1][1] - e[2][2] - e[3][3]) * 2
		w = (e[3][2] - e[2][3]) / k
		x = k / 4
		y = (e[1][2] + e[2][1]) / k
		z = (e[1][3] + e[3][1]) / k
	elseif e[2][2] > e[3][3] then
		local k = math.sqrt(1 + e[2][2] - e[1][1] - e[3][3]) * 2
		w = (e[1][3] - e[3][1]) / k
		x = (e[1][2] + e[2][1]) / k
		y = k / 4
		z = (e[2][3] + e[3][2]) / k
	else
		local k = math.sqrt(1 + e[3][3] - e[1][1] - e[2][2]) * 2
		w = (e[2][1] - e[1][2]) / k
		x = (e[1][3] + e[3][1]) / k
		y = (e[2][3] + e[3][2]) / k
		z = k / 4
	end

	return units.PositionToEngine(Vec3(m[1][4], m[2][4], m[3][4])),
	Quat(x, y, z, w),
	size
end

local function angles_to_rotation(angles)
	return QuatFromAxis(math.rad(angles[2]), axis_y) * QuatFromAxis(math.rad(-angles[1]), axis_x) * QuatFromAxis(math.rad(-angles[3]), axis_z)
end

local function parse_vector(value)
	return Vec3(value[1], value[2], value[3])
end

function world.Translate(name, has_skybox)
	local weather = import("goluwa/render3d/weather.lua")
	local records = {}
	local root = "source2:" .. name

	local function add(record)
		records[#records + 1] = record
		return record
	end

	add{guid = root, properties = {Name = name}, components = {transform = {}}}
	local atmosphere = {Climate = {}}
	add{guid = "atmosphere", components = {atmosphere_controller = atmosphere}}
	local world_data = resource.ReadKV3(resource.Load(vfs, "maps/" .. name .. "/world.vwrld_c"))
	local object_count = 0
	local lowest = math.huge
	local mins, maxs = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}

	for _, node in ipairs(world_data.m_worldNodes) do
		lowest = math.min(lowest, node.m_vMinBounds[3])

		for i = 1, 3 do
			mins[i] = math.min(mins[i], node.m_vMinBounds[i])
			maxs[i] = math.max(maxs[i], node.m_vMaxBounds[i])
		end
	end

	atmosphere.OceanLevel = lowest * units.meters - 2
	local clip_bounds = {
		-maxs[2] * units.meters,
		mins[3] * units.meters,
		-maxs[1] * units.meters,
		-mins[2] * units.meters,
		maxs[3] * units.meters,
		-mins[1] * units.meters,
	}

	for _, node in ipairs(world_data.m_worldNodes) do
		local prefix = normalize_path(node.m_worldNodePrefix)
		local data = resource.ReadKV3(resource.Load(vfs, prefix .. ".vwnod_c"))

		for _, object in ipairs(data.m_sceneObjects) do
			if object.m_renderableModel:find("_blocklight%.vmdl$") then goto skip end

			local position, rotation, size = matrix_to_transform(object.m_vTransform)
			local model_path = normalize_path(object.m_renderableModel) .. "_c"
			object_count = object_count + 1
			add{
				guid = root .. ":object:" .. object_count,
				parent = root,
				properties = {Name = "object"},
				components = {
					transform = {Position = position, Rotation = rotation, Size = size ~= 1 and size or nil},
					visual = {ModelPath = model_path},
				},
			}

			::skip::
		end

		for _, aggregate in ipairs(data.m_aggregateSceneObjects or {}) do
			wlog("aggregate scene objects are not supported yet")

			break
		end

		tasks.Wait()
	end

	add{
		guid = root .. ":physics",
		parent = root,
		properties = {Name = "world_physics"},
		components = {
			transform = {},
			rigid_body = {
				ShapeModelPath = "maps/" .. name .. "/world_physics.vphys_c",
				MotionType = "static",
				WorldGeometry = true,
			},
		},
	}
	local classes = {}

	for _, lump_path in ipairs(world_data.m_entityLumps) do
		for index, entity in ipairs(entity_lump.Load(vfs, normalize_path(lump_path) .. "_c")) do
			local class = entity.classname
			classes[class] = (classes[class] or 0) + 1

			if not entity.origin then goto continue end

			do
				local position = units.PositionToEngine(parse_vector(entity.origin))
				local rotation = entity.angles and angles_to_rotation(entity.angles) or Quat(0, 0, 0, 1)
				local guid = root .. ":ent:" .. lump_path .. index

				if class == "light_environment" then
					local pitch, yaw = math.rad(entity.angles[1]), math.rad(entity.angles[2])
					local direction = Vec3(
						math.cos(pitch) * math.sin(yaw),
						math.sin(pitch),
						math.cos(pitch) * math.cos(yaw)
					)
					atmosphere.SunRotation = weather.GetSunRotationFromDirection(direction:GetNormalized())
				elseif
					entity.model and
					(
						class:find("^prop_") or
						class:find("^item_") or
						class == "func_physbox"
					)
					and
					entity.model:find("%.vmdl$")
				then
					local motion = PROP_MOTION[class]
					local model_path = normalize_path(entity.model) .. "_c"
					add{
						guid = guid,
						parent = root,
						properties = {Name = class},
						components = {
							transform = {
								Position = position,
								Rotation = rotation,
								Size = entity.scales and entity.scales[1] ~= 1 and entity.scales[1] or nil,
							},
							visual = {ModelPath = model_path, Tint = get_tint(entity.rendercolor)},
							rigid_body = motion and
								{ShapeModelPath = model_path, MotionType = motion, WorldGeometry = motion == "static" or nil} or
								nil,
						},
					}
				elseif (class == "light_omni" or class == "light_spot") and entity.color then
					local color = entity.color
					local range = entity.range or 0
					local info = {
						_light = {
							r = color[1] / 255,
							g = color[2] / 255,
							b = color[3] / 255,
							brightness = (entity.brightness or 1) * LIGHT_BRIGHTNESS,
						},
						_fifty_percent_distance = range * 0.5,
						_zero_percent_distance = range,
					}
					local components = {
						transform = {Position = position, Rotation = rotation},
						source_light = {Info = info},
					}

					if class == "light_spot" then
						components.light_spot = {
							Color = Color(color[1] / 255, color[2] / 255, color[3] / 255, 1),
							InnerCone = math.max(entity.innerconeangle or 0, 1),
							OuterCone = entity.outerconeangle or 45,
						}
						components.transform.Rotation = QuatDeg3(-entity.angles[1], entity.angles[2], 0)
					else
						components.light_point = {Color = Color(color[1] / 255, color[2] / 255, color[3] / 255, 1)}
					end

					add{
						guid = guid,
						parent = root,
						properties = {Name = class},
						components = components,
					}
				elseif class == "info_player_start" then
					add{
						guid = guid,
						parent = root,
						properties = {Name = class},
						components = {
							transform = {
								Position = position,
								Rotation = QuatFromAxis(math.rad(entity.angles and entity.angles[2] or 0), axis_y),
							},
							spawn_point = {Group = "start"},
						},
					}
				end
			end

			::continue::

			tasks.Wait()
		end
	end

	if has_skybox then
		local sky_name = name .. "_skybox"
		local sky_world = resource.ReadKV3(resource.Load(vfs, "maps/" .. name .. "/" .. sky_name .. "/world.vwrld_c"))
		local scale, origin = 1, {0, 0, 0}

		for _, lump_path in ipairs(sky_world.m_entityLumps) do
			for _, entity in ipairs(entity_lump.Load(vfs, normalize_path(lump_path) .. "_c")) do
				if entity.classname == "sky_camera" then
					scale = entity.scale or scale
					origin = entity.origin or origin
				end
			end
		end

		local sky_count = 0

		for _, node in ipairs(sky_world.m_worldNodes) do
			local data = resource.ReadKV3(resource.Load(vfs, normalize_path(node.m_worldNodePrefix) .. ".vwnod_c"))

			for _, object in ipairs(data.m_sceneObjects) do
				if not object.m_renderableModel:find("_blocklight%.vmdl$") then
					local m = object.m_vTransform
					local position, rotation, size = matrix_to_transform({
						{m[1][1], m[1][2], m[1][3], (m[1][4] - origin[1]) * scale},
						{m[2][1], m[2][2], m[2][3], (m[2][4] - origin[2]) * scale},
						{m[3][1], m[3][2], m[3][3], (m[3][4] - origin[3]) * scale},
					})
					sky_count = sky_count + 1
					add{
						guid = root .. ":sky:" .. sky_count,
						parent = root,
						properties = {Name = "sky object"},
						components = {
							transform = {Position = position, Rotation = rotation, Size = size * scale},
							visual = {ModelPath = normalize_path(object.m_renderableModel) .. "_c", ClipBounds = clip_bounds},
						},
					}
				end
			end

			tasks.Wait()
		end
	end

	logn("translated ", #records, " source 2 records")
	return {version = scene.Version, entities = records}
end

function world.Load(name, info)
	steam.MountSourceGame(info)
	vfs.Mount(world.GetMapDirectory(info) .. name .. ".vpk/")
	local sky_path = world.GetMapDirectory(info) .. name .. "/" .. name .. "_skybox.vpk"
	local has_skybox = vfs.IsFile("os:" .. sky_path)

	if has_skybox then vfs.Mount(sky_path .. "/") end

	scene.Clear()
	local task = tasks.CreateTask()
	task:SetName("source 2 map load")
	local scene_loading = import("goluwa/render3d/scene_loading.lua")
	scene_loading.HoldTask(task)

	function task:OnStart()
		scene.BeginSpawning()
		local ok, err = pcall(function()
			startup.Begin("source 2 translate")
			local scene_data = world.Translate(name, has_skybox)
			startup.End("source 2 translate")
			scene.Deserialize(
				scene_data,
				Entity.World,
				{yield_every = 128, skip_unavailable = not RENDER_3D}
			)
		end)
		scene.EndSpawning()

		if not ok then error(err, 0) end
	end

	task:Start()
end

return world

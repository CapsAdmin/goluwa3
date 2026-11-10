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
local LIGHT_BRIGHTNESS = 64
local PROP_MOTION = {
	prop_physics = "dynamic",
	prop_physics_override = "dynamic",
	prop_physics_multiplayer = "dynamic",
	func_physbox = "dynamic",
	prop_dynamic = "static",
	prop_dynamic_override = "static",
}
-- hand pose markers and the washing machine's loader and door are set up for vr grabbing and fall apart without its logic
local BLACKLISTED_MODELS = {
	["models/props/interactive/washing_machine01a_door.vmdl"] = true,
	["models/props/interactive/washing_machine01a_loader.vmdl"] = true,
}
local BLACKLISTED_MODEL_PREFIX = "models/props/max/handposes/"
local STATIC_COLLISION_GROUP = 4

-- the entity color is sRGB, the shaders multiply it into linear albedo
local function get_tint(color)
	if not color or (color[1] >= 250 and color[2] >= 250 and color[3] >= 250) then
		return nil
	end

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

-- the map names its skybox in a skybox_reference entity, as a path under maps/ without the extension
function world.FindSkybox(name)
	local world_data = resource.ReadKV3(resource.Load(vfs, "maps/" .. name .. "/world.vwrld_c"))

	for _, lump_path in ipairs(world_data.m_entityLumps) do
		for _, entity in ipairs(entity_lump.Load(vfs, normalize_path(lump_path) .. "_c")) do
			if entity.classname == "skybox_reference" and entity.targetmapname then
				return entity.targetmapname:match("^(.+)%.vmap$")
			end
		end
	end
end

function world.Translate(name, sky_path)
	local weather = import("goluwa/render3d/weather.lua")
	local records = {}
	local root = "source2:" .. name

	local function add(record)
		records[#records + 1] = record
		return record
	end

	add{guid = root, properties = {Name = name}, components = {transform = {}}}
	local groups = {}

	local function group(key)
		local entry = groups[key]

		if not entry then
			entry = {
				count = 0,
				record = add{
					guid = root .. ":group:" .. key,
					parent = root,
					properties = {Name = key},
					components = {transform = {}},
				},
			}
			groups[key] = entry
		end

		entry.count = entry.count + 1
		return entry.record.guid
	end

	local atmosphere = {Climate = {}}
	add{guid = "atmosphere", components = {atmosphere_controller = atmosphere}}
	local world_data = resource.ReadKV3(resource.Load(vfs, "maps/" .. name .. "/world.vwrld_c"))
	local object_count = 0
	local blocklight_count = 0
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
			local position, rotation, size = matrix_to_transform(object.m_vTransform)
			local model_path = normalize_path(object.m_renderableModel) .. "_c"

			if object.m_renderableModel:find("_blocklight%.vmdl$") then
				blocklight_count = blocklight_count + 1
				add{
					guid = root .. ":blocklight:" .. blocklight_count,
					parent = group("blocklight"),
					properties = {Name = "blocklight"},
					components = {
						transform = {Position = position, Rotation = rotation, Size = size ~= 1 and size or nil},
						visual = {ModelPath = model_path, ViewHidden = true, Raycast = false},
					},
				}
			else
				object_count = object_count + 1
				add{
					guid = root .. ":object:" .. object_count,
					parent = group("world geometry"),
					properties = {Name = "object"},
					components = {
						transform = {Position = position, Rotation = rotation, Size = size ~= 1 and size or nil},
						visual = {ModelPath = model_path},
					},
				}
			end
		end

		for _, aggregate in ipairs(data.m_aggregateSceneObjects or {}) do
			wlog("aggregate scene objects are not supported yet")

			break
		end

		tasks.Wait()
	end

	add{
		guid = root .. ":physics",
		parent = group("physics"),
		properties = {Name = "world_physics"},
		components = {
			transform = {},
			rigid_body = {
				ShapeModelPath = "maps/" .. name .. "/world_physics.vphys_c",
				MotionType = "static",
				WorldGeometry = true,
				CollisionGroup = STATIC_COLLISION_GROUP,
			},
		},
	}
	local classes = {}
	local placed = {}
	local constraint_entities = {}

	for _, lump_path in ipairs(world_data.m_entityLumps) do
		for index, entity in ipairs(entity_lump.Load(vfs, normalize_path(lump_path) .. "_c")) do
			local class = entity.classname
			classes[class] = (classes[class] or 0) + 1

			if not entity.origin then goto continue end

			if class == "prop_handpose" then goto continue end

			if entity.model then
				local model = normalize_path(entity.model)

				if BLACKLISTED_MODELS[model] or model:starts_with(BLACKLISTED_MODEL_PREFIX) then
					goto continue
				end
			end

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
						parent = group(class),
						properties = {Name = entity.targetname or class},
						components = {
							transform = {
								Position = position,
								Rotation = rotation,
								Size = entity.scales and entity.scales[1] ~= 1 and entity.scales[1] or nil,
							},
							visual = {ModelPath = model_path, Tint = get_tint(entity.rendercolor)},
							rigid_body = motion and
								{
									ShapeModelPath = model_path,
									MotionType = motion,
									WorldGeometry = motion == "static" or nil,
									CollisionGroup = motion == "static" and STATIC_COLLISION_GROUP or nil,
								} or
								nil,
						},
					}

					if entity.targetname and motion then
						placed[entity.targetname] = {guid = guid, position = position, rotation = rotation}
					end
				elseif
					class == "phys_hinge_local" or
					class == "phys_slideconstraint" or
					class == "phys_constraint"
				then
					constraint_entities[#constraint_entities + 1] = {
						entity = entity,
						position = position,
						rotation = rotation,
						guid = guid,
					}
				elseif (class == "light_omni" or class == "light_spot") and entity.color then
					local color = Color(
						(entity.color[1] / 255) ^ 2.2,
						(entity.color[2] / 255) ^ 2.2,
						(entity.color[3] / 255) ^ 2.2,
						1
					)
					local range = entity.range or 0
					local info = {
						_light = {
							r = color.r,
							g = color.g,
							b = color.b,
							brightness = (entity.brightness or 1) * LIGHT_BRIGHTNESS,
						},
						_constant_attn = entity.attenuation0 or 0,
						_linear_attn = entity.attenuation1 or 0,
						_quadratic_attn = entity.attenuation2 or 0,
						_range = range,
					}
					local components = {
						transform = {Position = position, Rotation = rotation},
						source_light = {Info = info},
					}

					if class == "light_spot" then
						components.light_spot = {
							Color = color,
							InnerCone = math.max(entity.innerconeangle or 0, 1),
							OuterCone = entity.outerconeangle or 45,
						}
						components.transform.Rotation = QuatDeg3(-entity.angles[1], entity.angles[2], 0)
					else
						components.light_point = {Color = color}
					end

					add{
						guid = guid,
						parent = group(class),
						properties = {Name = entity.targetname or class},
						components = components,
					}
				elseif class == "info_player_start" then
					add{
						guid = guid,
						parent = group(class),
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

	for _, item in ipairs(constraint_entities) do
		local entity, class = item.entity, item.entity.classname
		local first = entity.attach1 and placed[entity.attach1]

		if not first then goto next_constraint end

		do
			local second = entity.attach2 and entity.attach2 ~= "" and placed[entity.attach2] or nil
			local kind, anchor, axis, friction = "weld", item.position, Vec3(0, 1, 0), 0
			local has_limits, lower, upper = false, 0, 0

			if class == "phys_hinge_local" then
				local axis_points = {}

				for point in entity.hingeaxis:gmatch("[^,]+") do
					local x, y, z = point:match("(%S+)%s+(%S+)%s+(%S+)")
					axis_points[#axis_points + 1] = item.position + item.rotation:VecMul(units.PositionToEngine(Vec3(tonumber(x), tonumber(y), tonumber(z))))
				end

				kind = "hinge"
				anchor = axis_points[1]
				axis = (axis_points[1] - axis_points[2]):GetNormalized()
				friction = entity.hingefriction or 0
				local min, max, initial = entity.min_rotation or 0, entity.max_rotation or 0, entity.initial_rotation or 0
				has_limits = min ~= 0 or max ~= 0
				lower, upper = math.rad(min - initial), math.rad(max - initial)
			elseif class == "phys_slideconstraint" then
				local x, y, z = entity.slideaxis:match("(%S+)%s+(%S+)%s+(%S+)")
				local travel_vector = units.PositionToEngine(Vec3(tonumber(x), tonumber(y), tonumber(z))) - item.position
				local travel = travel_vector:GetLength()
				local start = entity.initialoffset or 0
				kind = "slider"
				axis = travel_vector / -travel
				friction = entity.slidefriction or 0
				has_limits = true
				lower, upper = -start * travel, (1 - start) * travel
			end

			local function to_local(placement, position)
				return placement.rotation:GetConjugated():VecMul(position - placement.position)
			end

			add{
				guid = item.guid,
				parent = group(class),
				properties = {Name = entity.targetname or class},
				components = {
					transform = {},
					map_constraint = {
						Kind = kind,
						Entity0 = first.guid,
						Entity1 = second and second.guid or "",
						Anchor0 = to_local(first, anchor),
						Axis0 = first.rotation:GetConjugated():VecMul(axis),
						HasLimits = has_limits,
						Lower = lower,
						Upper = upper,
						Friction = friction,
						IgnoredGroup = STATIC_COLLISION_GROUP,
					},
				},
			}
		end

		::next_constraint::
	end

	if sky_path then
		local sky_world = resource.ReadKV3(resource.Load(vfs, sky_path .. "/world.vwrld_c"))
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
					local position, rotation, size = matrix_to_transform{
						{m[1][1], m[1][2], m[1][3], (
							m[1][4] - origin[1]
						) * scale},
						{m[2][1], m[2][2], m[2][3], (
							m[2][4] - origin[2]
						) * scale},
						{m[3][1], m[3][2], m[3][3], (
							m[3][4] - origin[3]
						) * scale},
					}
					sky_count = sky_count + 1
					add{
						guid = root .. ":sky:" .. sky_count,
						parent = group("sky objects"),
						properties = {Name = "sky object"},
						components = {
							transform = {Position = position, Rotation = rotation, Size = size * scale},
							visual = {
								ModelPath = normalize_path(object.m_renderableModel) .. "_c",
								ClipBounds = clip_bounds,
							},
						},
					}
				end
			end

			tasks.Wait()
		end
	end

	for key, entry in pairs(groups) do
		entry.record.properties.Name = key .. " (" .. entry.count .. ")"
	end

	logn("translated ", #records, " source 2 records")
	return {version = scene.Version, entities = records}
end

function world.Load(name, info)
	steam.MountSourceGame(info)
	vfs.Mount(world.GetMapDirectory(info) .. name .. ".vpk/")
	local sky_path = world.FindSkybox(name)

	if sky_path and vfs.IsFile("os:" .. info.vdf_directory .. sky_path .. ".vpk") then
		vfs.Mount(info.vdf_directory .. sky_path .. ".vpk/")
	else
		sky_path = nil
	end

	scene.Clear()
	local task = tasks.CreateTask()
	task:SetName("source 2 map load")
	local scene_loading = import("goluwa/render3d/scene_loading.lua")
	scene_loading.HoldTask(task)

	function task:OnStart()
		scene.BeginSpawning()
		local ok, err = pcall(function()
			startup.Begin("source 2 translate")
			local scene_data = world.Translate(name, sky_path)
			startup.End("source 2 translate")
			local model_paths, seen = {}, {}

			for _, record in ipairs(scene_data.entities) do
				local visual = record.components and record.components.visual
				local model_path = visual and visual.ModelPath

				if model_path and not seen[model_path] then
					seen[model_path] = true
					model_paths[#model_paths + 1] = model_path
				end
			end

			import("goluwa/render3d/model_loader.lua").Preload(model_paths)
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

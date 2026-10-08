local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local scene = import("goluwa/entities/scene.lua")
local lights = import("goluwa/source_engine/lights.lua")
local surface_properties = import("goluwa/source_engine/surface_properties.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local units = import("goluwa/source_engine/units.lua")
local bit = require("bit")
local map_scene = {}
local FOG_TINT_STRENGTH = 1
local FOG_DISTANCE_SCALE = 10
local LIGHT_INFO_KEYS = {
	"_light",
	"_lightHDR",
	"_lightscaleHDR",
	"_fifty_percent_distance",
	"_zero_percent_distance",
	"_constant_attn",
	"_linear_attn",
	"_quadratic_attn",
}
local PROP_MOTION_DYNAMIC = {
	prop_physics = true,
	prop_physics_multiplayer = true,
	prop_physics_override = true,
}
local PROP_MOTION_STATIC = {
	prop_dynamic = true,
	prop_dynamic_override = true,
	prop_static = true,
	static_entity = true,
}
local SOLID_VPHYSICS = 6
local SPAWNFLAG_MOTION_DISABLED = 8
local axis_x = Vec3(1, 0, 0)
local axis_y = Vec3(0, 1, 0)

local function is_blacklisted(path)
	if path == "models/lostcoast/effects/vollight_stainedglass.mdl" then
		return true
	end
end

local function get_prop_motion_type(info)
	if info.model_size_mult then return nil end

	if PROP_MOTION_DYNAMIC[info.classname] then
		if bit.band(info.spawnflags or 0, SPAWNFLAG_MOTION_DISABLED) ~= 0 then
			return "static"
		end

		return "dynamic"
	end

	if
		PROP_MOTION_STATIC[info.classname] and
		(
			info.solid or
			SOLID_VPHYSICS
		) == SOLID_VPHYSICS
	then
		return "static"
	end

	return nil
end

local function get_transform(info, is_light)
	local rotation = Quat()
	local angles = info.angles

	if is_light then
		rotation:SetAngles(
			Deg3(
				info.pitch or angles and angles.x or 0,
				angles and angles.y or 0,
				angles and angles.z or 0
			)
		)
	elseif angles then
		rotation = QuatFromAxis(math.rad(angles.y), axis_y) * QuatFromAxis(math.rad(-angles.x), axis_x) * QuatFromAxis(math.rad(-angles.z), Vec3(0, 0, 1))
	end

	return units.PositionToEngine(info.origin), rotation
end

local function load_models(paths)
	local results = {}
	local pending = 0

	for path in pairs(paths) do
		pending = pending + 1

		model_loader.LoadModel(
			path,
			function(model)
				results[path] = model
				pending = pending - 1
			end,
			nil,
			function()
				results[path] = false
				pending = pending - 1
			end
		)
	end

	while pending > 0 do
		tasks.Wait()
	end

	return results
end

local function clip_bounds(info)
	local box = info.sky_clip

	if not box then return nil end

	return {box.min_x, box.min_y, box.min_z, box.max_x, box.max_y, box.max_z}
end

function map_scene.Translate(data, map_name, map_path)
	assert(tasks.GetActiveTask(), "map_scene.Translate must run inside a task")
	local records = {}
	local root_guid = "bsp:" .. map_name

	local function add(record)
		records[#records + 1] = record
		return record
	end

	local atmosphere = {OceanLevel = data.ocean_level - 2}
	add{
		guid = root_guid,
		properties = {Name = map_name},
		components = {transform = {}, bsp_world = {Path = map_path}},
	}
	add{guid = "atmosphere", components = {atmosphere_controller = atmosphere}}

	if not RENDER_3D then return {version = scene.Version, entities = records} end

	local containers = {}
	local sub_groups = {}

	local function get_container(id)
		if not id then return root_guid end

		local guid = containers[id]

		if not guid then
			guid = root_guid .. "/visibility_group_" .. id
			containers[id] = guid
			add{
				guid = guid,
				parent = root_guid,
				properties = {Name = "visibility_group_" .. id},
				components = {transform = {}, visibility_group = {}},
			}
		end

		return guid
	end

	local function get_sub_group(container_guid, name)
		local guid = container_guid .. "/" .. name

		if not sub_groups[guid] then
			sub_groups[guid] = true
			add{
				guid = guid,
				parent = container_guid,
				properties = {Name = name},
				components = {},
			}
		end

		return guid
	end

	local entries = {}
	local physics_models = {}
	local handled = {}

	for index, info in pairs(data.entities) do
		if info.skyname then
			handled[info.classname] = (handled[info.classname] or 0) + 1
		elseif info.classname and info.classname:find("light_environment") then
			handled[info.classname] = (handled[info.classname] or 0) + 1
		elseif info.classname:lower():find("light") and (info._lightHDR or info._light) then
			handled[info.classname] = (handled[info.classname] or 0) + 1
			entries[#entries + 1] = {kind = "light", info = info, index = index}
		elseif info.classname == "env_fog_controller" then
			if
				bit.band(tonumber(info.spawnflags) or 0, 1) ~= 0 and
				tonumber(info.fogenable) == 1
			then
				local color = info.fogcolor
				atmosphere.Visibility = info.fogend * units.meters * FOG_DISTANCE_SCALE
				atmosphere.FogColor = Vec3(color.r ^ 2.2, color.g ^ 2.2, color.b ^ 2.2) / math.max(color.r, color.g, color.b, 1e-4) ^ 2.2 * FOG_TINT_STRENGTH
			end
		end

		if
			info.origin and
			info.angles and
			info.model and
			info.model:sub(1, 1) ~= "*" and
			not info.classname:lower():find("npc")
			and
			info.classname ~= "env_sprite"
		then
			local model_path = vfs.FindMixedCasePath(info.model)

			if model_path and not is_blacklisted(model_path) then
				handled[info.classname] = (handled[info.classname] or 0) + 1
				local motion_type = get_prop_motion_type(info)

				if motion_type then physics_models[model_path] = true end

				entries[#entries + 1] = {
					kind = "prop",
					info = info,
					index = index,
					model_path = model_path,
					motion_type = motion_type,
				}
			else
				wlog(
					"cannot spawn entity of class " .. tostring(info.classname) .. " because model file " .. tostring(info.model) .. " does not exist"
				)
			end
		end
	end

	local models = load_models(physics_models)

	for entry_index, entry in ipairs(entries) do
		local info = entry.info
		local guid = root_guid .. ":ent:" .. entry.index

		if entry.kind == "light" then
			local container = get_sub_group(get_container(info.visibility_group), "lights")
			local position, rotation = get_transform(info, true)
			local is_spot = info.classname == "light_spot"
			local light = {Color = lights.Convert(info).color}

			if is_spot then
				local inner_cone = math.clamp((tonumber(info._inner_cone) or 0) > 0 and info._inner_cone or 10, 0, 180)
				local outer_cone = math.clamp((tonumber(info._cone) or 0) > 0 and info._cone or inner_cone, inner_cone, 180)
				local exponent = tonumber(info._exponent) or 0

				if exponent > 1 then
					local mid = math.deg(math.acos(exponent / (exponent + 1)))
					inner_cone = math.min(inner_cone, mid * 0.5)
					outer_cone = math.max(math.min(outer_cone, mid * 1.5), inner_cone)
				end

				light.InnerCone = inner_cone
				light.OuterCone = outer_cone
			end

			local light_info = {}

			for _, key in ipairs(LIGHT_INFO_KEYS) do
				light_info[key] = info[key] or nil
			end

			add{
				guid = guid,
				parent = container,
				properties = {Name = info.classname},
				components = {
					transform = {Position = position, Rotation = rotation},
					[is_spot and "light_spot" or "light_point"] = light,
					source_light = {Info = light_info},
				},
			}
		else
			local container = get_sub_group(get_container(info.visibility_group), info.classname)
			local model = entry.motion_type and models[entry.model_path]
			local physics = model and model.physics
			local position, rotation = get_transform(info)

			if entry.motion_type and physics then
				local center_of_mass = physics.center_of_mass
				local surface = surface_properties.Get(physics.surface_property or "default")
				local mass = physics.mass

				if entry.motion_type == "dynamic" and (info.massscale or 0) > 0 then
					mass = mass * info.massscale
				end

				add{
					guid = guid,
					parent = container,
					properties = {Name = "prop"},
					components = {
						transform = {Position = position + rotation:VecMul(center_of_mass), Rotation = rotation},
						rigid_body = {
							ShapeModelPath = entry.model_path,
							MotionType = entry.motion_type,
							Mass = mass,
							Inertia = physics.inertia,
							AutomaticMass = false,
							Friction = surface.friction,
							Restitution = surface.elasticity,
							FrictionCombineMode = "multiply",
							RestitutionCombineMode = "multiply",
							LinearDamping = physics.damping,
							AirLinearDamping = physics.damping,
							AngularDamping = physics.rotation_damping,
							AirAngularDamping = physics.rotation_damping,
						},
					},
				}
				add{
					guid = guid .. ":visual",
					parent = guid,
					properties = {Name = "prop_visual"},
					components = {
						transform = {Position = center_of_mass * -1},
						visual = {ModelPath = entry.model_path, ClipBounds = clip_bounds(info)},
					},
				}
			elseif entry.motion_type then
				add{
					guid = guid,
					parent = container,
					properties = {Name = "prop"},
					components = {
						transform = {Position = position, Rotation = rotation},
						visual = {ModelPath = entry.model_path},
					},
				}
			else
				add{
					guid = guid,
					parent = container,
					properties = {Name = "prop"},
					components = {
						transform = {
							Position = position,
							Rotation = rotation,
							Size = info.model_size_mult,
						},
						visual = {ModelPath = entry.model_path, ClipBounds = clip_bounds(info)},
					},
				}
			end
		end

		if entry_index % 50 == 0 then tasks.Wait() end
	end

	for index, info in ipairs(data.water_volumes or {}) do
		local container = get_sub_group(get_container(info.visibility_group), "water")
		add{
			guid = root_guid .. ":water:" .. index,
			parent = container,
			properties = {Name = info.texname},
			components = {
				transform = {Position = info.position},
				water_volume = {
					Size = info.size,
					Absorption = info.absorption,
					ParticleScattering = info.scattering,
					WaveHeight = info.slime and 0 or 0.04,
					WaveLength = 1.2,
					Roughness = info.slime and 0.06 or 0.02,
					Foam = info.slime and 0.1 or 0.25,
				},
			},
		}
	end

	handled.water = data.water_volumes and #data.water_volumes or nil
	logn("translated ", #records, " bsp records")

	for classname, count in pairs(handled) do
		logn("  ", classname, ": ", count)
	end

	return {version = scene.Version, entities = records}
end

return map_scene

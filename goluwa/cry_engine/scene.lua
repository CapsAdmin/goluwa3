local level = import("goluwa/cry_engine/level.lua")
local units = import("goluwa/cry_engine/units.lua")
local cry_water = import("goluwa/cry_engine/water.lua")
local water = import("goluwa/render3d/water.lua")
local fluid = import("goluwa/physics/fluid.lua")
local scene = import("goluwa/entities/scene.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local cry_scene = {}
local LEAF_CELL_TARGET = 64
local LEAF_CHUNK_THRESHOLD = 256
local MATRIX_FIELDS = {}

for row = 0, 3 do
	for column = 0, 3 do
		MATRIX_FIELDS[#MATRIX_FIELDS + 1] = "m" .. row .. column
	end
end

local function matrix_values(matrix)
	local values = {}

	for i, field in ipairs(MATRIX_FIELDS) do
		values[i] = matrix[field]
	end

	return values
end

local function build_atmosphere_record(data)
	local terrain = data.terrain
	local editor_level = terrain and terrain.editor_level
	local water_level = terrain and terrain.water_level or 0
	local properties = {
		OceanEnabled = water_level > 0,
		OceanLevel = water_level,
	}

	if editor_level and editor_level.ocean then
		local ocean = editor_level.ocean

		if RENDER_3D then cry_water.EnableCrysisWaves() end

		local absorption, scattering = cry_water.GetMedium(ocean.fog_color, ocean.fog_color_multiplier, ocean.fog_density)
		local wind = units.ToEngine(Vec3(math.cos(ocean.wind_direction), math.sin(ocean.wind_direction), 0))
		local wind_direction = math.deg(math.atan2(wind.z, wind.x))
		properties.OceanSettings = {
			WindSpeed = math.sqrt(2 * ocean.waves_size * water.GRAVITY / 0.21),
			WindDirection = wind_direction,
			SwellHeight = ocean.waves_size * 0.5,
			SwellDirection = wind_direction + 20,
			Absorption = absorption,
			ParticleScattering = scattering,
		}
	end

	if editor_level and editor_level.fog_density then
		properties.Visibility = -math.log(0.02) / (editor_level.fog_density * 0.0025)
	end

	if editor_level and editor_level.sun_direction then
		local direction = editor_level.sun_direction:GetNormalized()
		properties.SunRotation = Quat(-direction.y, direction.x, 0, 1 + direction.z):Normalize()
	end

	return {
		guid = "atmosphere",
		components = {atmosphere_controller = properties},
	},
	properties
end

function cry_scene.Translate(data, level_name, level_path, options)
	options = options or {}
	local records = {}
	local used_guids = {}
	local level_guid = "cry:" .. level_name

	local function add(record)
		records[#records + 1] = record
		used_guids[record.guid] = true
		return record
	end

	local function add_folder(parent_guid, name)
		local guid = parent_guid .. "/" .. name
		local suffix = 1

		while used_guids[guid] do
			suffix = suffix + 1
			guid = parent_guid .. "/" .. name .. "#" .. suffix
		end

		add{guid = guid, parent = parent_guid, properties = {Name = name}, components = {}}
		return guid
	end

	local function add_object(entry, parent_guid)
		local transform_data = level.ConvertCryWorldMatrixToEngineTransform(entry.world_matrix)
		add{
			guid = level_guid .. ":obj:" .. entry.cry_index,
			parent = parent_guid,
			properties = {Name = entry.name or "cry_object"},
			components = {
				transform = {
					Position = transform_data.position,
					Rotation = transform_data.rotation,
					Scale = transform_data.scale,
				},
				visual = {
					ModelPath = entry.model_path,
					MaterialOverridePath = entry.material_path,
				},
			},
		}
	end

	local function add_vegetation(entry, parent_guid)
		local transform_data = level.ConvertCryVegetationInstanceToEngineTransform(entry)
		local transform

		if transform_data.matrix then
			transform = {Matrix = matrix_values(transform_data.matrix)}
		else
			transform = {
				Position = transform_data.position,
				Rotation = transform_data.rotation,
				Scale = transform_data.scale,
			}
		end

		add{
			guid = level_guid .. ":veg:" .. entry.cry_index,
			parent = parent_guid,
			properties = {Name = entry.name or "cry_vegetation"},
			components = {
				transform = transform,
				visual = {
					ModelPath = entry.model_path,
					MaterialOverridePath = entry.material_path,
					Billboard = entry.use_sprites == true or nil,
				},
			},
		}
	end

	local function add_leaf(leaf)
		local items = leaf.items
		local count = #items

		if count <= LEAF_CHUNK_THRESHOLD then
			for _, entry in ipairs(items) do
				leaf.add(entry, leaf.folder)
			end

			return
		end

		local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
		local xs, ys = {}, {}

		for i, entry in ipairs(items) do
			local x, y

			if entry.position then
				x, y = entry.position.x, entry.position.y
			else
				x, y = entry.world_matrix:GetTranslation()
			end

			xs[i], ys[i] = x, y
			min_x, min_y = math.min(min_x, x), math.min(min_y, y)
			max_x, max_y = math.max(max_x, x), math.max(max_y, y)
		end

		local cell_size = math.max(math.max(max_x - min_x, max_y - min_y), 1) / math.ceil(math.sqrt(count / LEAF_CELL_TARGET))
		local cells = {}
		local cell_list = {}

		for i, entry in ipairs(items) do
			local cx, cy = math.floor((xs[i] - min_x) / cell_size), math.floor((ys[i] - min_y) / cell_size)
			local key = cx * 65536 + cy
			local cell = cells[key]

			if not cell then
				cell = {
					name = string.format("x%d y%d", min_x + (cx + 0.5) * cell_size, min_y + (cy + 0.5) * cell_size),
					key = key,
					items = {},
				}
				cells[key] = cell
				cell_list[#cell_list + 1] = cell
			end

			cell.items[#cell.items + 1] = entry
		end

		table.sort(cell_list, function(a, b)
			return a.key < b.key
		end)

		for _, cell in ipairs(cell_list) do
			local cell_guid = add_folder(leaf.folder, cell.name)

			for _, entry in ipairs(cell.items) do
				leaf.add(entry, cell_guid)
			end
		end
	end

	add{
		guid = level_guid,
		properties = {Name = level_name},
		components = {cry_level = {Path = level_path}},
	}
	local atmosphere_record, atmosphere = build_atmosphere_record(data)

	if RENDER_3D then
		add(atmosphere_record)
	elseif atmosphere.OceanEnabled then
		fluid.SetOceanLevel(atmosphere.OceanLevel)

		if atmosphere.OceanSettings then water.SetOcean(atmosphere.OceanSettings) end
	end

	local water_guid

	for _, object in ipairs(data.water_objects or {}) do
		for _, volume in ipairs(cry_water.BuildVolumes(object)) do
			water_guid = water_guid or add_folder(level_guid, "Water")
			add{
				guid = level_guid .. ":water:" .. #records,
				parent = water_guid,
				properties = {Name = object.name or object.type},
				components = {
					transform = {Position = volume.position, Rotation = volume.rotation},
					water_volume = volume.config,
				},
			}
		end
	end

	if options.skip_models or not RENDER_3D then
		return {version = scene.Version, entities = records}
	end

	local objects_guid = add_folder(level_guid, "Objects")
	local layer_folders = {}
	local group_folders = {}
	local leaves = {}
	local leaf_by_folder = {}

	for index, entry in ipairs(data.entries) do
		entry.cry_index = index
		local folder = layer_folders[entry.layer or ""]

		if not folder then
			folder = add_folder(objects_guid, entry.layer or "no layer")
			layer_folders[entry.layer or ""] = folder
		end

		local chain = {}
		local group = entry.group

		while group do
			table.insert(chain, 1, group)
			group = group.parent
		end

		for _, group in ipairs(chain) do
			local group_folder = group_folders[group.key]

			if not group_folder then
				group_folder = add_folder(folder, group.name)
				group_folders[group.key] = group_folder
			end

			folder = group_folder
		end

		local leaf = leaf_by_folder[folder]

		if not leaf then
			leaf = {folder = folder, items = {}, add = add_object}
			leaf_by_folder[folder] = leaf
			leaves[#leaves + 1] = leaf
		end

		leaf.items[#leaf.items + 1] = entry
	end

	local vegetation_guid = add_folder(level_guid, "Vegetation")
	local category_folders = {}
	local prototype_leaves = {}

	for index, entry in ipairs(data.vegetation_entries or {}) do
		entry.cry_index = index
		local leaf = prototype_leaves[entry.prototype_id]

		if not leaf then
			local prototype = data.vegetation_prototypes.by_id[entry.prototype_id]
			local category = prototype.category or "uncategorized"
			local category_folder = category_folders[category]

			if not category_folder then
				category_folder = add_folder(vegetation_guid, category)
				category_folders[category] = category_folder
			end

			leaf = {
				folder = add_folder(category_folder, (prototype.name:gsub("%.%w+$", ""))),
				items = {},
				add = add_vegetation,
			}
			prototype_leaves[entry.prototype_id] = leaf
			leaves[#leaves + 1] = leaf
		end

		leaf.items[#leaf.items + 1] = entry
	end

	for _, leaf in ipairs(leaves) do
		add_leaf(leaf)
	end

	return {version = scene.Version, entities = records}
end

return cry_scene

local mtl_material = import("goluwa/cry_engine/mtl_material.lua")
local xml = import("goluwa/codecs/xml.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ffi = require("ffi")
local game = import("goluwa/cry_engine/game.lua")
local units = import("goluwa/cry_engine/units.lua")
local read_u32_le, read_u16_le, read_f32_le
local sample_terrain_height01_at_world
local f32_union = ffi.new("union { uint32_t u; float f; }")
local level = {}

local function find_child_by_tag(node, tag)
	if not (node and node.children) then return nil end

	for i = 1, node.children.n or #node.children do
		local child = node.children[i]

		if child.tag == tag then return child end
	end

	return nil
end

local function iter_children_by_tag(node, tag)
	local children = node and node.children
	local count = children and (children.n or #children) or 0
	local index = 0
	return function()
		for i = index + 1, count do
			local child = children[i]

			if child.tag == tag then
				index = i
				return child, i
			end
		end
	end
end

local function unpack_csv_numbers(str)
	local out = {}

	for value in tostring(str or ""):gmatch("[^,%s]+") do
		out[#out + 1] = tonumber(value) or 0
	end

	return out[1], out[2], out[3], out[4]
end

local function parse_vec3(str, default_x, default_y, default_z)
	local x, y, z = unpack_csv_numbers(str)
	return Vec3(x or default_x or 0, y or default_y or 0, z or default_z or 0)
end

local function parse_quat(str)
	local w, x, y, z = unpack_csv_numbers(str)
	local rotation = Quat(x or 0, y or 0, z or 0, w or 1)

	if rotation:GetLength() <= 0.000001 then return Quat(0, 0, 0, 1) end

	return rotation:GetNormalized()
end

local function parse_bool_flag(value)
	return tostring(value or "0") == "1"
end

function level.ParseCoverData(data)
	if #data < 18 or data:sub(1, 3) ~= "CRY" then
		return nil, "cover.ctc has invalid magic"
	end

	local layer_count = read_u16_le(data, 9)
	local index_offset = 17 + layer_count * 12

	if layer_count < 1 or #data < index_offset + 1 then
		return nil, "cover.ctc has an invalid layer count"
	end

	local sector_size = read_u16_le(data, 17)
	local sector_bytes = read_u32_le(data, 25)

	if sector_bytes ~= sector_size * sector_size then
		return nil,
		string.format(
			"cover.ctc diffuse sectors are %d bytes for %dx%d pixels, only DXT5 is supported",
			sector_bytes,
			sector_size,
			sector_size
		)
	end

	local entry_count = read_u16_le(data, index_offset)
	local cursor = index_offset + 2
	local index_end = cursor + entry_count * 2
	local data_offset = index_end - 1
	local nodes = {}
	local max_level = 0

	local function read_node(level, x, y)
		if cursor >= index_end then error("cover.ctc node index is truncated") end

		local id = read_u16_le(data, cursor)
		cursor = cursor + 2

		if id == 0xffff then return end

		nodes[#nodes + 1] = {
			level = level,
			x = x,
			y = y,
			offset = data_offset + id * layer_count * sector_bytes,
		}
		max_level = math.max(max_level, level)

		for slot = 0, 3 do
			read_node(level + 1, x * 2 + math.floor(slot / 2), y * 2 + slot % 2)
		end
	end

	local ok, err = pcall(read_node, 0, 0, 0)

	if not ok then return nil, err end

	if cursor ~= index_end then
		return nil, "cover.ctc node index has trailing entries"
	end

	if data_offset + #nodes * layer_count * sector_bytes > #data then
		return nil, "cover.ctc sector data is truncated"
	end

	table.sort(nodes, function(a, b)
		return a.level < b.level
	end)

	return {
		data = data,
		sector_size = sector_size,
		sector_bytes = sector_bytes,
		max_level = max_level,
		nodes = nodes,
	}
end

local function parse_surface_type_node(node)
	local attrs = node and node.attrs or {}
	local detail_scale_x = tonumber(attrs.DetailScaleX) or 1
	local detail_scale_y = tonumber(attrs.DetailScaleY) or detail_scale_x
	return {
		name = attrs.Name or "",
		detail_texture = file_path.FixPathSlashes(attrs.DetailTexture or ""),
		detail_material = file_path.FixPathSlashes(attrs.DetailMaterial or ""),
		detail_scale_x = detail_scale_x,
		detail_scale_y = detail_scale_y,
		project_axis = tonumber(attrs.ProjectAxis) or tonumber(attrs.ProjAxis) or 2,
	}
end

function level.BuildCryLocalMatrix(attrs)
	local matrix = Matrix44()
	local position = parse_vec3(attrs.Pos, 0, 0, 0)
	local scale = parse_vec3(attrs.Scale, 1, 1, 1)
	matrix:Identity()
	matrix:SetRotation(parse_quat(attrs.Rotate))
	matrix:Scale(scale.x, scale.y, scale.z)
	matrix:SetTranslation(position.x, position.y, position.z)
	return matrix
end

function level.ComposeCryWorldMatrix(parent_world, attrs)
	local local_matrix = level.BuildCryLocalMatrix(attrs)

	if parent_world then return local_matrix * parent_world end

	return local_matrix
end

function level.ConvertCryWorldMatrixToEngineTransform(world_matrix)
	local origin = world_matrix:TransformVector(Vec3(0, 0, 0))
	local cry_x = world_matrix:TransformVector(Vec3(1, 0, 0)) - origin
	local cry_y = world_matrix:TransformVector(Vec3(0, 1, 0)) - origin
	local cry_z = world_matrix:TransformVector(Vec3(0, 0, 1)) - origin
	local scale_x = cry_x:GetLength()
	local scale_y = cry_y:GetLength()
	local scale_z = cry_z:GetLength()

	if cry_x:GetCross(cry_y):GetDot(cry_z) < 0 then scale_x = -scale_x end

	local right = math.abs(scale_x) > 0.000001 and
		units.ToEngine(cry_x / scale_x) or
		Vec3(1, 0, 0)
	local up = scale_z > 0.000001 and units.ToEngine(cry_z / scale_z) or Vec3(0, 1, 0)
	local back = scale_y > 0.000001 and -units.ToEngine(cry_y / scale_y) or Vec3(0, 0, 1)
	local rotation_matrix = Matrix44()
	rotation_matrix:Identity()
	rotation_matrix.m00 = right.x
	rotation_matrix.m01 = right.y
	rotation_matrix.m02 = right.z
	rotation_matrix.m10 = up.x
	rotation_matrix.m11 = up.y
	rotation_matrix.m12 = up.z
	rotation_matrix.m20 = back.x
	rotation_matrix.m21 = back.y
	rotation_matrix.m22 = back.z
	return {
		position = units.ToEngine(origin),
		rotation = rotation_matrix:GetRotation(Quat()):GetNormalized(),
		scale = Vec3(
			math.abs(scale_x) > 0.000001 and scale_x or 1,
			scale_z > 0.000001 and scale_z or 1,
			scale_y > 0.000001 and scale_y or 1
		),
	}
end

function level.ConvertCryVegetationInstanceToEngineTransform(entry)
	local rotation = Quat(0, 0, 0, 1):Rotate(entry.yaw or 0, 0, 1, 0)
	local position = units.ToEngine(entry.position)

	if entry.fit_to_terrain and entry.terrain_normal then
		local up = entry.terrain_normal
		local slope_x = -up.x / up.y
		local slope_z = -up.z / up.y
		local matrix = Matrix44():Identity()
		matrix:SetRotation(rotation)
		matrix:Scale(entry.scale, entry.scale, entry.scale)
		matrix.m01 = matrix.m01 + slope_x * matrix.m00 + slope_z * matrix.m02
		matrix.m11 = matrix.m11 + slope_x * matrix.m10 + slope_z * matrix.m12
		matrix.m21 = matrix.m21 + slope_x * matrix.m20 + slope_z * matrix.m22
		matrix:SetTranslation(position.x, position.y, position.z)
		return {matrix = matrix}
	end

	if entry.terrain_normal then
		local up = entry.terrain_normal:GetNormalized()
		local axis = Vec3(0, 1, 0):GetCross(up)
		local sin = axis:GetLength()

		if sin > 0.000001 then
			rotation = Quat(0, 0, 0, 1):Rotate(math.atan2(sin, up.y), axis.x, axis.y, axis.z) * rotation
		end
	end

	return {
		position = position,
		rotation = rotation:GetNormalized(),
		scale = Vec3(entry.scale, entry.scale, entry.scale),
	}
end

do
	local function get_model_property(properties)
		return properties and (properties.object_Model or properties.fileModel)
	end

	function level.GetVisualGeometryPath(node, libraries)
		local attrs = node.attrs or {}
		local object_type = attrs.Type
		local path

		if object_type == "Brush" then
			path = attrs.Prefab
		elseif object_type == "GeomEntity" then
			path = attrs.Geometry
		elseif object_type == "EntityArchetype" then
			path = get_model_property(libraries.archetypes[attrs.Prototype])
		else
			local properties = find_child_by_tag(node, "Properties")
			path = get_model_property(properties and properties.attrs)
		end

		if type(path) ~= "string" or path == "" then return nil end

		path = file_path.FixPathSlashes(path)

		if not path:lower():ends_with(".cgf") then return nil end

		return path
	end
end

function level.GetPhysicsProperties(node)
	local attrs = node.attrs
	local object_type = attrs.Type

	if object_type == "Brush" or object_type == "GeomEntity" then
		return {motion = "static"}
	end

	if attrs.EntityClass ~= "BasicEntity" and attrs.EntityClass ~= "RigidBodyEx" then
		return nil
	end

	local properties = find_child_by_tag(node, "Properties")
	local physics = properties and find_child_by_tag(properties, "Physics")

	if not physics or physics.attrs.bPhysicalize ~= "1" then return nil end

	local mass = tonumber(physics.attrs.Mass)
	local density = tonumber(physics.attrs.Density)
	return {
		motion = physics.attrs.bRigidBody == "1" and "dynamic" or "static",
		mass = mass and mass > 0 and mass or nil,
		density = density and density > 0 and density or nil,
	}
end

function level.IsObjectHidden(attrs)
	return attrs.Hidden == "1" or attrs.HiddenInGame == "1"
end

local function extract_water_object(node, world_matrix)
	local attrs = node.attrs
	local points = {}

	for point in iter_children_by_tag(find_child_by_tag(node, "Points"), "Point") do
		local pos = parse_vec3(point.attrs.Pos, 0, 0, 0)
		points[#points + 1] = {
			pos = world_matrix:TransformVector(pos),
			back = world_matrix:TransformVector(parse_vec3(point.attrs.Back, pos.x, pos.y, pos.z)),
			forw = world_matrix:TransformVector(parse_vec3(point.attrs.Forw, pos.x, pos.y, pos.z)),
			width = tonumber(point.attrs.Width) or 0,
		}
	end

	if not points[2] then return nil end

	return {
		type = attrs.Type,
		name = attrs.Name,
		points = points,
		width = tonumber(attrs.Width) or 0,
		depth = tonumber(attrs.VolumeDepth) or 10,
		stream_speed = tonumber(attrs.StreamSpeed) or 0,
		fog_density = tonumber(attrs.FogDensity),
		fog_color = attrs.FogColor and parse_vec3(attrs.FogColor, 0, 0, 0),
		fog_color_multiplier = tonumber(attrs.FogColorMultiplier) or 1,
	}
end

function level.ExtractVisualObjectsFromNode(node, parent_world, out, libraries, water_out, group, layer)
	local attrs = node.attrs or {}
	layer = attrs.Layer or layer

	if level.IsObjectHidden(attrs) then return out end

	local object_type = attrs.Type
	local world_matrix = level.ComposeCryWorldMatrix(parent_world, attrs)
	local children

	if object_type == "WaterVolume" or object_type == "River" then
		water_out[#water_out + 1] = extract_water_object(node, world_matrix)
		return out
	end

	if object_type == "Group" then
		children = find_child_by_tag(node, "Objects")
	elseif object_type == "Prefab" then
		local prefab = libraries.prefabs[attrs.PrefabGUID]

		if not prefab then
			wlog(
				"missing cry prefab %s (%s)",
				tostring(attrs.PrefabName),
				tostring(attrs.PrefabGUID)
			)
			return out
		end

		children = find_child_by_tag(prefab, "Objects")
	end

	if children then
		local child_group = {
			key = (group and group.key or "") .. "/" .. (attrs.Id or attrs.Name or ""),
			name = attrs.Name or attrs.PrefabName or object_type,
			parent = group,
		}

		for child in iter_children_by_tag(children, "Object") do
			level.ExtractVisualObjectsFromNode(child, world_matrix, out, libraries, water_out, child_group, layer)
		end

		return out
	end

	local model_path = level.GetVisualGeometryPath(node, libraries)

	if model_path then
		out[#out + 1] = {
			name = attrs.Name or file_path.GetFileNameFromPath(model_path),
			model_path = model_path,
			material_path = attrs.Material ~= "" and attrs.Material or nil,
			type = object_type,
			physics = level.GetPhysicsProperties(node),
			world_matrix = world_matrix,
			layer = layer,
			group = group,
		}
	end

	return out
end

function level.ExtractVisualObjects(nodes, libraries)
	local by_id = {}
	local world_matrices = {}
	local out = {}
	local water_out = {}

	for _, node in ipairs(nodes) do
		if node.attrs.Id then by_id[node.attrs.Id] = node end
	end

	local function get_parent_group(node, depth)
		local parent = node.attrs.Parent and by_id[node.attrs.Parent]

		if not parent or depth >= 32 then return nil end

		local parent_group = get_parent_group(parent, depth + 1)
		return {
			key = (parent_group and parent_group.key or "") .. "/" .. parent.attrs.Id,
			name = parent.attrs.Name or parent.attrs.Type,
			parent = parent_group,
		}
	end

	local function get_world_matrix(node, depth)
		local world = world_matrices[node]

		if world then return world end

		local parent = node.attrs.Parent and by_id[node.attrs.Parent]
		world = level.ComposeCryWorldMatrix(parent and depth < 32 and get_world_matrix(parent, depth + 1) or nil, node.attrs)
		world_matrices[node] = world
		return world
	end

	for _, node in ipairs(nodes) do
		local parent = node.attrs.Parent and by_id[node.attrs.Parent]
		level.ExtractVisualObjectsFromNode(
			node,
			parent and get_world_matrix(parent, 0) or nil,
			out,
			libraries,
			water_out,
			get_parent_group(node, 0)
		)
	end

	return out, water_out
end

function level.LoadLibraries()
	local libraries = {prefabs = {}, archetypes = {}}

	for _, file_name in ipairs(vfs.Find("Prefabs/") or {}) do
		if file_name:lower():ends_with(".xml") then
			local ok, document = pcall(xml.Decode, assert(vfs.Read("Prefabs/" .. file_name)))
			local root = ok and document and document.children and document.children[1]

			if root then
				for prefab in iter_children_by_tag(root, "Prefab") do
					if prefab.attrs.Id then libraries.prefabs[prefab.attrs.Id] = prefab end
				end
			else
				wlog("failed to parse cry prefab library %s: %s", file_name, tostring(document))
			end
		end
	end

	for _, file_name in ipairs(vfs.Find("Libs/EntityArchetypes/") or {}) do
		if file_name:lower():ends_with(".xml") then
			local ok, document = pcall(xml.Decode, assert(vfs.Read("Libs/EntityArchetypes/" .. file_name)))
			local root = ok and document and document.children and document.children[1]

			if root then
				for prototype in iter_children_by_tag(root, "EntityPrototype") do
					local properties = find_child_by_tag(prototype, "Properties")

					if prototype.attrs.Id and properties then
						libraries.archetypes[prototype.attrs.Id] = properties.attrs
					end
				end
			else
				wlog("failed to parse cry archetype library %s: %s", file_name, tostring(document))
			end
		end
	end

	return libraries
end

function level.ParseLayerDocument(document)
	local root = document and document.children and document.children[1]
	local layer = root and find_child_by_tag(root, "Layer") or nil
	local layer_attrs = layer and layer.attrs or {}
	local layer_objects = layer and find_child_by_tag(layer, "LayerObjects") or nil
	local out = {}

	if layer_attrs.Hidden == "1" or not layer_objects then return out end

	for node in iter_children_by_tag(layer_objects, "Object") do
		out[#out + 1] = node
	end

	return out
end

function level.ParseLayerData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse layer xml"
	end

	return level.ParseLayerDocument(document)
end

function level.ParseEditorObjectsDocument(document)
	local root = document and document.children and document.children[1]
	local missions = root and find_child_by_tag(root, "Missions") or nil
	local current_mission_name = missions and missions.attrs and missions.attrs.Current or nil
	local mission

	if missions then
		for node in iter_children_by_tag(missions, "Mission") do
			local attrs = node.attrs or {}

			if not mission or attrs.Name == current_mission_name then
				mission = node

				if attrs.Name == current_mission_name then break end
			end
		end
	end

	local object_layers = mission and
		find_child_by_tag(mission, "ObjectLayers") or
		find_child_by_tag(root, "ObjectLayers")
	local objects = mission and
		find_child_by_tag(mission, "Objects") or
		find_child_by_tag(root, "Objects")
	local hidden_layers = {}
	local out = {}

	for layer in iter_children_by_tag(object_layers, "Layer") do
		local attrs = layer.attrs or {}

		if attrs.Name and attrs.Hidden == "1" then
			hidden_layers[attrs.Name] = true
		end
	end

	if not objects then return out end

	for node in iter_children_by_tag(objects, "Object") do
		local attrs = node.attrs or {}

		if not hidden_layers[attrs.Layer] then out[#out + 1] = node end
	end

	return out
end

function level.ParseEditorObjectsData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse editor level xml"
	end

	return level.ParseEditorObjectsDocument(document)
end

function level.ParseLevelDataDocument(document)
	local root = document and document.children and document.children[1]
	local info = root and find_child_by_tag(root, "LevelInfo") or nil
	local surface_types_node = root and find_child_by_tag(root, "SurfaceTypes") or nil
	local attrs = info and info.attrs or nil

	if not attrs then return nil, "missing LevelInfo" end

	local heightmap_size = tonumber(attrs.HeightmapSize) or 0
	local heightmap_unit_size = tonumber(attrs.HeightmapUnitSize) or 0
	local terrain_sector_size = tonumber(attrs.TerrainSectorSizeInMeters) or 0
	local world_size = heightmap_size * heightmap_unit_size
	local surface_types = {}

	for node in iter_children_by_tag(surface_types_node, "SurfaceType") do
		surface_types[#surface_types + 1] = parse_surface_type_node(node)
	end

	return {
		heightmap_size = heightmap_size,
		heightmap_unit_size = heightmap_unit_size,
		heightmap_max_height = tonumber(attrs.HeightmapMaxHeight) or 0,
		water_level = tonumber(attrs.WaterLevel) or 0,
		terrain_sector_size = terrain_sector_size,
		surface_types = surface_types,
		world_size = world_size,
	}
end

function level.ParseLevelData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse level xml"
	end

	return level.ParseLevelDataDocument(document)
end

function level.ParseEditorLevelDocument(document)
	local root = document and document.children and document.children[1]
	local attrs = root and root.attrs or nil
	local heightmap = root and find_child_by_tag(root, "Heightmap") or nil
	local heightmap_attrs = heightmap and heightmap.attrs or {}

	if not attrs then return nil, "missing Level root" end

	local layer_surface_types = {}

	for layer in iter_children_by_tag(find_child_by_tag(root, "Layers"), "Layer") do
		local layer_id = tonumber(layer.attrs.LayerId)

		if layer_id and layer.attrs.SurfaceType then
			layer_surface_types[layer_id] = layer.attrs.SurfaceType
		end
	end

	local sun_direction
	local fog_density
	local ocean
	local missions = find_child_by_tag(root, "Missions")

	for mission in iter_children_by_tag(missions, "Mission") do
		if mission.attrs.Name == missions.attrs.Current then
			local environment = find_child_by_tag(mission, "Environment")
			local ocean_node = environment and find_child_by_tag(environment, "Ocean")
			local animation = environment and find_child_by_tag(environment, "OceanAnimation")

			if ocean_node then
				local animation_attrs = animation and animation.attrs or {}
				ocean = {
					fog_color = parse_vec3(ocean_node.attrs.FogColor, 51, 127, 178) / 255,
					fog_color_multiplier = tonumber(ocean_node.attrs.FogColorMultiplier) or 0.2,
					fog_density = tonumber(ocean_node.attrs.FogDensity) or 0.1,
					wind_direction = tonumber(animation_attrs.WindDirection) or 1,
					wind_speed = tonumber(animation_attrs.WindSpeed) or 4,
					waves_size = tonumber(animation_attrs.WavesSize) or 0.75,
				}
			end

			local time_of_day = find_child_by_tag(mission, "TimeOfDay")
			local lighting = find_child_by_tag(mission, "Lighting")

			for variable in iter_children_by_tag(time_of_day, "Variable") do
				if variable.attrs.Name == "Volumetric fog: Global density" then
					fog_density = tonumber(variable.attrs.Value)
				end
			end

			if time_of_day and lighting then
				local time = ((tonumber(time_of_day.attrs.Time) + 12) / 24) * math.pi * 2
				local longitude = 0.5 * math.pi - math.rad(tonumber(lighting.attrs.Longitude))
				local latitude = -math.rad(tonumber(lighting.attrs.SunRotation))
				local x, y, z = math.sin(time), math.cos(time), 0
				y, z = y * math.cos(longitude), -y * math.sin(longitude)
				x, z = x * math.cos(latitude) - z * math.sin(latitude),
				x * math.sin(latitude) + z * math.cos(latitude)
				sun_direction = units.ToEngine(Vec3(x, -z, y))
			end
		end
	end

	return {
		sun_direction = sun_direction,
		fog_density = fog_density,
		ocean = ocean,
		heightmap_width = tonumber(attrs.HeightmapWidth) or 0,
		heightmap_height = tonumber(attrs.HeightmapHeight) or 0,
		tile_count_x = tonumber(attrs.TileCountX) or 0,
		tile_count_y = tonumber(attrs.TileCountY) or 0,
		tile_resolution = tonumber(attrs.TileResolution) or 0,
		texture_size = tonumber(heightmap_attrs.TextureSize) or 0,
		layer_surface_types = layer_surface_types,
	}
end

function level.ParseEditorLevelData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse editor level xml"
	end

	return level.ParseEditorLevelDocument(document)
end

function level.ParseVegetationMapDocument(document)
	local root = document and document.children and document.children[1]

	if not root then return nil, "no root" end

	local vegetation_map = find_child_by_tag(root, "VegetationMap")

	if not vegetation_map then return nil, "no VegetationMap" end

	local objects = find_child_by_tag(vegetation_map, "Objects")

	if not objects then return nil, "no Objects" end

	local prototypes = {list = {}, by_id = {}}

	for node in iter_children_by_tag(objects, "Object") do
		local attrs = node.attrs or {}
		local prototype_id = tonumber(attrs.Id)
		local model_path = file_path.FixPathSlashes(attrs.FileName or "")

		if prototype_id and model_path ~= "" and model_path:lower():ends_with(".cgf") then
			local prototype = {
				id = prototype_id,
				model_path = model_path,
				material_path = attrs.Material ~= "" and attrs.Material or nil,
				name = attrs.Name or file_path.GetFileNameFromPath(model_path),
				category = attrs.Category,
				align_to_terrain = parse_bool_flag(attrs.AlignToTerrain),
				random_rotation = parse_bool_flag(attrs.RandomRotation),
				use_terrain_color = parse_bool_flag(attrs.UseTerrainColor),
				bending = tonumber(attrs.Bending) or 0,
				use_sprites = parse_bool_flag(attrs.UseSprites),
				size = tonumber(attrs.Size) or 1,
				size_var = tonumber(attrs.SizeVar) or 0,
			}
			prototypes.list[#prototypes.list + 1] = prototype
			prototypes.by_id[prototype_id] = prototype
		end
	end

	return prototypes
end

function level.ParseVegetationMapData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse vegetation xml"
	end

	return level.ParseVegetationMapDocument(document)
end

function level.IsVegetationPrototypeSupportedFirstPass(objects, terrain)
	return objects and (not objects.align_to_terrain or terrain ~= nil)
end

function level.IsVegetationFitToTerrain(material_paths)
	local Material = import("goluwa/render3d/material.lua")

	for _, material_path in ipairs(material_paths) do
		if mtl_material.CryMTLHasGenFlag(material_path, "TERRAINHEIGHTADAPTION") then
			return true
		end
	end

	return false
end

local function sample_terrain_height_at_world(terrain, world_x, world_z)
	return sample_terrain_height01_at_world(terrain, world_x, world_z) * (
			terrain.heightmap_max_height or
			0
		)
end

level.SampleTerrainHeight = sample_terrain_height_at_world

local function sample_terrain_normal_at_world(terrain, world_x, world_z)
	if not terrain or not terrain.height_data then return Vec3(0, 1, 0) end

	local width = terrain.height_samples_width or terrain.height_samples_per_side or 0
	local height = terrain.height_samples_height or terrain.height_samples_per_side or width

	if width <= 1 or height <= 1 then return Vec3(0, 1, 0) end

	local step_x = math.max((terrain.world_size or 0) / math.max(width - 1, 1), 0.0001)
	local step_z = math.max((terrain.world_size or 0) / math.max(height - 1, 1), 0.0001)
	local left = sample_terrain_height_at_world(terrain, world_x - step_x, world_z)
	local right = sample_terrain_height_at_world(terrain, world_x + step_x, world_z)
	local down = sample_terrain_height_at_world(terrain, world_x, world_z - step_z)
	local up = sample_terrain_height_at_world(terrain, world_x, world_z + step_z)
	local normal = Vec3(left - right, step_x + step_z, down - up)

	if normal:GetLength() <= 0.000001 then return Vec3(0, 1, 0) end

	return normal:GetNormalized()
end

function level.ParseVegetationInstancesData(data, prototypes, terrain)
	if type(data) ~= "string" or data == "" then return {} end

	local entries = {}
	local stride = 19

	if #data % stride ~= 0 then
		wlog("cry vegetation instance data size %d is not a multiple of %d", #data, stride)
	end

	for index = 0, math.floor(#data / stride) - 1 do
		local offset = index * stride + 1
		local prototype_id, brightness, angle = data:byte(offset + 16, offset + 18)
		local prototype = prototypes and prototypes.by_id and prototypes.by_id[prototype_id] or nil

		if level.IsVegetationPrototypeSupportedFirstPass(prototype, terrain) then
			local position = Vec3(
				read_f32_le(data, offset) or 0,
				read_f32_le(data, offset + 4) or 0,
				read_f32_le(data, offset + 8) or 0
			)
			local terrain_normal

			if (prototype.align_to_terrain or prototype.fit_to_terrain) and terrain then
				local engine_position = units.ToEngine(position)
				terrain_normal = sample_terrain_normal_at_world(terrain, engine_position.x, engine_position.z)
			end

			entries[#entries + 1] = {
				name = string.format("vegetation_%d_%d", prototype_id, index + 1),
				model_path = prototype.model_path,
				material_path = prototype.material_path,
				prototype_id = prototype_id,
				position = position,
				scale = read_f32_le(data, offset + 12) or 1,
				yaw = angle / 255 * math.pi * 2,
				brightness = brightness,
				use_sprites = prototype.use_sprites,
				fit_to_terrain = prototype.fit_to_terrain,
				terrain_normal = terrain_normal,
			}
		end
	end

	return entries
end

read_u32_le = function(str, offset)
	local a, b, c, d = str:byte(offset, offset + 3)

	if not d then return nil end

	return a + b * 256 + c * 65536 + d * 16777216
end
read_u16_le = function(str, offset)
	local a, b = str:byte(offset, offset + 1)

	if not b then return nil end

	return a + b * 256
end
read_f32_le = function(str, offset)
	f32_union.u = read_u32_le(str, offset) or 0
	return tonumber(f32_union.f)
end

local function validate_height_tail_layout(heightmap_data, height_data_offset, height_samples_per_side)
	local total_delta = 0
	local sample_count = 0

	for y = 0, height_samples_per_side - 1, 128 do
		for x = 0, height_samples_per_side - 2, 32 do
			local left_offset = height_data_offset + ((y * height_samples_per_side + x) * 2)
			local right_offset = left_offset + 2
			local left = read_u16_le(heightmap_data, left_offset)
			local right = read_u16_le(heightmap_data, right_offset)

			if left == nil or right == nil then
				return false, "terrain height tail is truncated"
			end

			total_delta = total_delta + math.abs(right - left)
			sample_count = sample_count + 1
		end
	end

	local mean_delta = total_delta / math.max(sample_count, 1)

	if mean_delta > 4096 then
		return false,
		string.format("terrain height payload looks corrupt (mean adjacent delta %.2f)", mean_delta)
	end

	return true
end

local function rebuild_terrain_height_cache(terrain)
	local width = terrain.height_samples_width or terrain.height_samples_per_side or 0
	local height = terrain.height_samples_height or terrain.height_samples_per_side or width
	local sample_count = width * height
	terrain.height_sample_width = width
	terrain.height_sample_height = height
	terrain.height_sample_max_x = width - 1
	terrain.height_sample_max_y = height - 1
	terrain.height_world_to_sample_x = width > 1 and ((width - 1) / math.max(terrain.world_size or 0, 1)) or 0
	terrain.height_world_to_sample_y = height > 1 and ((height - 1) / math.max(terrain.world_size or 0, 1)) or 0

	if not terrain.height_data or sample_count <= 0 then
		terrain.height_samples = nil
		return
	end

	local samples = ffi.new("uint16_t[?]", sample_count)
	ffi.copy(samples, terrain.height_data, sample_count * 2)
	terrain.height_samples = samples
end

local function rebuild_terrain_surface_slot_cache(terrain)
	local width = terrain.surface_slot_width or 0
	local height = terrain.surface_slot_height or width
	local sample_count = width * height
	terrain.surface_slot_max_x = width - 1
	terrain.surface_slot_max_y = height - 1
	terrain.surface_slot_world_to_sample_x = width > 1 and ((width - 1) / math.max(terrain.world_size or 0, 1)) or 0
	terrain.surface_slot_world_to_sample_y = height > 1 and ((height - 1) / math.max(terrain.world_size or 0, 1)) or 0

	if not terrain.surface_slot_data or sample_count <= 0 then
		terrain.surface_slot_samples = nil
		return
	end

	local samples = ffi.new("uint8_t[?]", sample_count)
	ffi.copy(samples, terrain.surface_slot_data, sample_count)
	terrain.surface_slot_samples = samples
end

function level.LoadTerrainData(level_dir)
	local level_data_path = level_dir .. "level.pak/leveldata.xml"
	local level_data_xml, level_data_err = vfs.Read(level_data_path)

	if not level_data_xml then
		return nil, level_data_err or ("failed to read " .. tostring(level_data_path))
	end

	local terrain, parse_err = level.ParseLevelData(level_data_xml)

	if not terrain then return nil, parse_err end

	terrain.level_dir = level_dir
	local cry_game = select(1, game.FindCryGame())

	do
		local cover_path = level_dir .. "level.pak/terrain/cover.ctc"
		local cover_data, cover_err = vfs.Read(cover_path)

		if not cover_data then
			return nil, cover_err or ("failed to read " .. cover_path)
		end

		local cover, err = level.ParseCoverData(cover_data)

		if not cover then return nil, cover_path .. ": " .. err end

		terrain.cover = cover
	end

	local level_name = level_dir:match("/([^/]+)/$") or ""
	local editor_level_path = level_dir .. level_name .. ".cry/level.editor_xml"
	local editor_level_xml = vfs.Read(editor_level_path)

	if editor_level_xml then
		local editor_level, editor_level_err = level.ParseEditorLevelData(editor_level_xml)

		if editor_level then
			terrain.editor_level = editor_level
		else
			wlog(
				"failed to parse cry editor level xml %s: %s",
				tostring(editor_level_path),
				tostring(editor_level_err)
			)
		end
	end

	local surface_slot_path = level_dir .. level_name .. ".cry/heightmaplayeridbitmap.editor_data"
	local surface_slot_data, surface_slot_err = vfs.Read(surface_slot_path)

	if surface_slot_data then
		local surface_slot_width = terrain.editor_level and
			terrain.editor_level.heightmap_width or
			terrain.heightmap_size
		local surface_slot_height = terrain.editor_level and
			terrain.editor_level.heightmap_height or
			terrain.heightmap_size
		local expected_size = surface_slot_width * surface_slot_height

		if
			surface_slot_width > 0 and
			surface_slot_height > 0 and
			#surface_slot_data == expected_size
		then
			terrain.surface_slot_data = surface_slot_data
			terrain.surface_slot_width = surface_slot_width
			terrain.surface_slot_height = surface_slot_height
			rebuild_terrain_surface_slot_cache(terrain)
		else
			wlog(
				"cry terrain surface slot bitmap %s size mismatch: got %d expected %d (%dx%d samples)",
				tostring(surface_slot_path),
				#surface_slot_data,
				expected_size,
				surface_slot_width,
				surface_slot_height
			)
		end
	elseif surface_slot_err then
		wlog(
			"failed to read cry terrain surface slot bitmap %s: %s",
			tostring(surface_slot_path),
			tostring(surface_slot_err)
		)
	end

	local heightmap_path = level_dir .. level_name .. ".cry/heightmapdataw.editor_data"
	local heightmap_data, heightmap_err = vfs.Read(heightmap_path)

	if heightmap_data then
		local height_samples_w = terrain.editor_level and
			terrain.editor_level.heightmap_width or
			terrain.heightmap_size
		local height_samples_h = terrain.editor_level and
			terrain.editor_level.heightmap_height or
			terrain.heightmap_size
		local expected_size = height_samples_w * height_samples_h * 2

		if
			height_samples_w > 0 and
			height_samples_h > 0 and
			#heightmap_data == expected_size
		then
			terrain.height_data = heightmap_data
			terrain.height_data_offset = 1
			terrain.height_samples_per_side = height_samples_w
			terrain.height_samples_width = height_samples_w
			terrain.height_samples_height = height_samples_h
			terrain.height_sample_scale = terrain.heightmap_max_height / 65535
			rebuild_terrain_height_cache(terrain)
		else
			wlog(
				"cry terrain editor heightmap %s size mismatch: got %d expected %d (%dx%d samples)",
				tostring(heightmap_path),
				#heightmap_data,
				expected_size,
				height_samples_w,
				height_samples_h
			)
		end
	else
		wlog(
			"failed to read cry terrain editor heightmap %s: %s",
			tostring(heightmap_path),
			tostring(heightmap_err)
		)
	end

	terrain.surface_types = terrain.surface_types or {}

	for i = 1, #terrain.surface_types do
		local surface_type = terrain.surface_types[i]

		if surface_type.detail_material ~= "" then
			local material_path = surface_type.detail_material

			if not material_path:lower():ends_with(".mtl") then
				material_path = material_path .. ".mtl"
			end

			surface_type.detail_material_path = game.ResolveModelPath(level_dir, material_path)

			if
				cry_game and
				type(surface_type.detail_material_path) == "string" and
				not file_path.IsPathAbsolutePath(surface_type.detail_material_path)
			then
				local absolute_material = vfs.FindMixedCasePath(cry_game.game_dir .. "Game/GameData.pak/" .. surface_type.detail_material_path)

				if absolute_material then
					surface_type.detail_material_path = absolute_material
				end
			end
		end
	end

	if terrain.surface_slot_samples and terrain.editor_level then
		local surface_index_by_name = {}

		for i, surface_type in ipairs(terrain.surface_types) do
			surface_index_by_name[surface_type.name] = i
		end

		local surface_index_by_raw = ffi.new("uint8_t[256]")

		for raw = 0, 255 do
			local name = terrain.editor_level.layer_surface_types[bit.rshift(raw, 1)]
			surface_index_by_raw[raw] = name and surface_index_by_name[name] or 0
		end

		local count = terrain.surface_slot_width * terrain.surface_slot_height
		local raw_samples = terrain.surface_slot_samples
		local surface_indices = ffi.new("uint8_t[?]", count)

		for i = 0, count - 1 do
			surface_indices[i] = surface_index_by_raw[raw_samples[i]]
		end

		terrain.surface_indices = surface_indices
	end

	return terrain
end

local function bilerp(a, b, c, d, tx, ty)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * ty
end

local function sample_terrain_height_raw(terrain, sample_x, sample_y)
	if not terrain.height_data then return 0 end

	local width = terrain.height_sample_width or
		terrain.height_samples_width or
		terrain.height_samples_per_side or
		0
	local height = terrain.height_sample_height or
		terrain.height_samples_height or
		terrain.height_samples_per_side or
		width

	if width <= 0 or height <= 0 then return 0 end

	if sample_x < 0 then
		sample_x = 0
	elseif sample_x > width - 1 then
		sample_x = width - 1
	end

	if sample_y < 0 then
		sample_y = 0
	elseif sample_y > height - 1 then
		sample_y = height - 1
	end

	local x0 = math.floor(sample_x)
	local y0 = math.floor(sample_y)
	local x1 = math.min(x0 + 1, width - 1)
	local y1 = math.min(y0 + 1, height - 1)
	local tx = sample_x - x0
	local ty = sample_y - y0
	local raw00, raw10, raw01, raw11

	if terrain.height_samples then
		local samples = terrain.height_samples
		local row0 = y0 * width
		local row1 = y1 * width
		raw00 = samples[row0 + x0]
		raw10 = samples[row0 + x1]
		raw01 = samples[row1 + x0]
		raw11 = samples[row1 + x1]
	else
		local stride = width
		local base = terrain.height_data_offset or 1
		raw00 = read_u16_le(terrain.height_data, base + ((y0 * stride + x0) * 2)) or 0
		raw10 = read_u16_le(terrain.height_data, base + ((y0 * stride + x1) * 2)) or 0
		raw01 = read_u16_le(terrain.height_data, base + ((y1 * stride + x0) * 2)) or 0
		raw11 = read_u16_le(terrain.height_data, base + ((y1 * stride + x1) * 2)) or 0
	end

	return bilerp(raw00, raw10, raw01, raw11, tx, ty)
end

sample_terrain_height01_at_world = function(terrain, world_x, world_z)
	if not terrain.height_data then return 0 end

	local width = terrain.height_sample_width or
		terrain.height_samples_width or
		terrain.height_samples_per_side or
		0
	local height = terrain.height_sample_height or
		terrain.height_samples_height or
		terrain.height_samples_per_side or
		width

	if width <= 0 or height <= 0 then return 0 end

	local sample_x = (-world_z) * (terrain.height_world_to_sample_x or 0)
	local sample_y = world_x * (terrain.height_world_to_sample_y or 0)
	local raw = sample_terrain_height_raw(terrain, sample_x, sample_y)
	return raw / 65535
end
local loaded_levels = {}
local libraries

function level.Load(level_dir)
	game.EnsureLevelMounts(level_dir)

	if loaded_levels[level_dir] then return loaded_levels[level_dir] end

	local nodes = {}
	local layers_dir = level_dir .. "Layers/"

	for _, file_name in ipairs(vfs.Find(layers_dir) or {}) do
		if file_name:lower():ends_with(".lyr") then
			local path = layers_dir .. file_name
			local data, read_err = vfs.Read(path)

			if data then
				local layer_nodes, parse_err = level.ParseLayerData(data)

				if layer_nodes then
					list.extend(nodes, layer_nodes)
				else
					wlog("failed to parse cry layer " .. tostring(path) .. ": " .. tostring(parse_err))
				end
			else
				wlog("failed to read cry layer " .. tostring(path) .. ": " .. tostring(read_err))
			end
		end
	end

	local level_name = level_dir:match("/([^/]+)/$") or ""
	local editor_level_path = level_dir .. level_name .. ".cry/level.editor_xml"
	local editor_level_data, editor_level_err = vfs.Read(editor_level_path)

	if editor_level_data then
		local editor_nodes, parse_err = level.ParseEditorObjectsData(editor_level_data)

		if editor_nodes then
			list.extend(nodes, editor_nodes)
		else
			wlog(
				"failed to parse cry editor level objects %s: %s",
				tostring(editor_level_path),
				tostring(parse_err)
			)
		end
	elseif editor_level_err then
		wlog(
			"failed to read cry editor level objects %s: %s",
			tostring(editor_level_path),
			tostring(editor_level_err)
		)
	end

	libraries = libraries or level.LoadLibraries()
	local entries, water_objects = level.ExtractVisualObjects(nodes, libraries)

	for _, entry in ipairs(entries) do
		entry.model_path = game.ResolveModelPath(level_dir, entry.model_path)

		if entry.material_path then
			entry.material_path = game.ResolveMaterialPath(level_dir, entry.material_path)
		end
	end

	local terrain = select(1, level.LoadTerrainData(level_dir))
	local vegetation_entries = {}
	local vegetation_prototypes
	local vegetation_map_data = editor_level_data

	if vegetation_map_data then
		local prototypes, vegetation_map_err = level.ParseVegetationMapData(vegetation_map_data)
		local vegetation_instances_data, vegetation_instances_err = vfs.Read(level_dir .. level_name .. ".cry/vegetationinstancesarray.editor_data")

		if prototypes and vegetation_instances_data then
			vegetation_prototypes = prototypes

			for _, prototype in ipairs(prototypes.list) do
				prototype.model_path = game.ResolveModelPath(level_dir, prototype.model_path)

				if prototype.material_path then
					prototype.material_path = game.ResolveMaterialPath(level_dir, prototype.material_path)
				end

				local material_paths = prototype.material_path and
					{prototype.material_path} or
					import("goluwa/render3d/model_decoders/cgf.lua").GetMaterialPaths(prototype.model_path)
				prototype.material_paths = material_paths
				prototype.fit_to_terrain = level.IsVegetationFitToTerrain(material_paths)

				if
					prototype.use_terrain_color and
					not prototype.material_path and
					#material_paths == 1
				then
					prototype.material_path = material_paths[1]
				end
			end

			vegetation_entries = level.ParseVegetationInstancesData(vegetation_instances_data, prototypes, terrain)
		elseif vegetation_map_err then
			wlog(
				"failed to parse cry vegetation map %s: %s",
				tostring(editor_level_path),
				tostring(vegetation_map_err)
			)
		elseif vegetation_instances_err then
			wlog(
				"failed to read cry vegetation instances %s: %s",
				tostring(level_dir .. level_name .. ".cry/vegetationinstancesarray.editor_data"),
				tostring(vegetation_instances_err)
			)
		end
	end

	loaded_levels[level_dir] = {
		level_dir = level_dir,
		entries = entries,
		vegetation_entries = vegetation_entries,
		vegetation_prototypes = vegetation_prototypes,
		water_objects = water_objects,
		terrain = terrain,
	}
	return loaded_levels[level_dir]
end

return level

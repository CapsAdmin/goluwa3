local xml = import("goluwa/codecs/xml.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
local ffi = require("ffi")
local read_u32_le, read_u16_le, read_f32_le
local sample_terrain_height01_at_world
local f32_union = ffi.new("union { uint32_t u; float f; }")
local crylevel = {
	CRYSIS_APPID = 17300,
}

local function clear_mounts(mounts)
	for _, mount in ipairs(mounts or {}) do
		vfs.Unmount(mount.where, mount.to)
	end

	return {}
end

local function ensure_trailing_slash(path)
	path = file_path.FixPathSlashes(path or "")

	if path ~= "" and not path:ends_with("/") then path = path .. "/" end

	return path
end

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

-- CryEngine serializes quaternions as "w,x,y,z"
local function parse_quat(str)
	local w, x, y, z = unpack_csv_numbers(str)
	local rotation = Quat(x or 0, y or 0, z or 0, w or 1)

	if rotation:GetLength() <= 0.000001 then return Quat(0, 0, 0, 1) end

	return rotation:GetNormalized()
end

local function parse_bool_flag(value)
	return tostring(value or "0") == "1"
end

-- cover.ctc holds the terrain texture the game renders, the editor's terraintexture.pak is only one input to it.
-- it is a quadtree of equally sized sectors, each node stores one sector per layer, the first layer is the diffuse
function crylevel.ParseCoverData(data)
	if #data < 18 or data:sub(1, 3) ~= "CRY" then
		return nil, "cover.ctc has invalid magic"
	end

	local layer_count = read_u16_le(data, 9)
	local index_offset = 17 + layer_count * 12

	if layer_count < 1 or #data < index_offset + 1 then
		return nil, "cover.ctc has an invalid layer count"
	end

	-- each layer header: sector size in pixels (u16), reserved (u16), texture format (u32), sector size in bytes (u32)
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

	-- the index lists node ids depth first, each node is followed by its 4 child slots and 0xffff marks an empty slot
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

function crylevel.CryVec3ToEngine(vec)
	return Vec3(vec.x, vec.z, -vec.y)
end

function crylevel.BuildCryLocalMatrix(attrs)
	local matrix = Matrix44()
	local position = parse_vec3(attrs.Pos, 0, 0, 0)
	local scale = parse_vec3(attrs.Scale, 1, 1, 1)
	matrix:Identity()
	matrix:SetRotation(parse_quat(attrs.Rotate))
	matrix:Scale(scale.x, scale.y, scale.z)
	matrix:SetTranslation(position.x, position.y, position.z)
	return matrix
end

function crylevel.ComposeCryWorldMatrix(parent_world, attrs)
	local local_matrix = crylevel.BuildCryLocalMatrix(attrs)

	if parent_world then return local_matrix * parent_world end

	return local_matrix
end

function crylevel.ConvertCryWorldMatrixToEngineTransform(world_matrix)
	local origin = world_matrix:TransformVector(Vec3(0, 0, 0))
	local cry_x = world_matrix:TransformVector(Vec3(1, 0, 0)) - origin
	local cry_y = world_matrix:TransformVector(Vec3(0, 1, 0)) - origin
	local cry_z = world_matrix:TransformVector(Vec3(0, 0, 1)) - origin
	local scale_x = cry_x:GetLength()
	local scale_y = cry_y:GetLength()
	local scale_z = cry_z:GetLength()

	-- a mirrored basis cannot be expressed as a rotation, so move the mirror into the x scale
	if cry_x:GetCross(cry_y):GetDot(cry_z) < 0 then scale_x = -scale_x end

	local right = math.abs(scale_x) > 0.000001 and
		crylevel.CryVec3ToEngine(cry_x / scale_x) or
		Vec3(1, 0, 0)
	local up = scale_z > 0.000001 and crylevel.CryVec3ToEngine(cry_z / scale_z) or Vec3(0, 1, 0)
	local back = scale_y > 0.000001 and
		-crylevel.CryVec3ToEngine(cry_y / scale_y)
		or
		Vec3(0, 0, 1)
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
		position = crylevel.CryVec3ToEngine(origin),
		rotation = rotation_matrix:GetRotation(Quat()):GetNormalized(),
		scale = Vec3(
			math.abs(scale_x) > 0.000001 and scale_x or 1,
			scale_z > 0.000001 and scale_z or 1,
			scale_y > 0.000001 and scale_y or 1
		),
	}
end

function crylevel.ConvertCryVegetationInstanceToEngineTransform(entry)
	-- yaw is a rotation around cry +z, which maps to engine +y with the same handedness
	local rotation = Quat(0, 0, 0, 1):Rotate(entry.yaw or 0, 0, 1, 0)

	if entry.terrain_normal then
		local up = entry.terrain_normal:GetNormalized()
		local axis = Vec3(0, 1, 0):GetCross(up)
		local sin = axis:GetLength()

		if sin > 0.000001 then
			rotation = Quat(0, 0, 0, 1):Rotate(math.atan2(sin, up.y), axis.x, axis.y, axis.z) * rotation
		end
	end

	return {
		position = crylevel.CryVec3ToEngine(entry.position),
		rotation = rotation:GetNormalized(),
		scale = Vec3(entry.scale, entry.scale, entry.scale),
	}
end

do
	local function get_model_property(properties)
		return properties and (properties.object_Model or properties.fileModel)
	end

	function crylevel.GetVisualGeometryPath(node, libraries)
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

function crylevel.IsObjectHidden(attrs)
	return attrs.Hidden == "1" or attrs.HiddenInGame == "1"
end

function crylevel.ExtractVisualObjectsFromNode(node, parent_world, out, libraries)
	local attrs = node.attrs or {}

	if crylevel.IsObjectHidden(attrs) then return out end

	local object_type = attrs.Type
	local world_matrix = crylevel.ComposeCryWorldMatrix(parent_world, attrs)
	local children

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
		for child in iter_children_by_tag(children, "Object") do
			crylevel.ExtractVisualObjectsFromNode(child, world_matrix, out, libraries)
		end

		return out
	end

	local model_path = crylevel.GetVisualGeometryPath(node, libraries)

	if model_path then
		out[#out + 1] = {
			name = attrs.Name or file_path.GetFileNameFromPath(model_path),
			model_path = model_path,
			material_path = attrs.Material ~= "" and attrs.Material or nil,
			type = object_type,
			world_matrix = world_matrix,
		}
	end

	return out
end

-- top level objects can be attached to another object with Parent="{guid}", possibly in another layer
function crylevel.ExtractVisualObjects(nodes, libraries)
	local by_id = {}
	local world_matrices = {}
	local out = {}

	for _, node in ipairs(nodes) do
		if node.attrs.Id then by_id[node.attrs.Id] = node end
	end

	local function get_world_matrix(node, depth)
		local world = world_matrices[node]

		if world then return world end

		local parent = node.attrs.Parent and by_id[node.attrs.Parent]
		world = crylevel.ComposeCryWorldMatrix(parent and depth < 32 and get_world_matrix(parent, depth + 1) or nil, node.attrs)
		world_matrices[node] = world
		return world
	end

	for _, node in ipairs(nodes) do
		local parent = node.attrs.Parent and by_id[node.attrs.Parent]
		crylevel.ExtractVisualObjectsFromNode(node, parent and get_world_matrix(parent, 0) or nil, out, libraries)
	end

	return out
end

-- prefab and entity archetype libraries are shared by all levels
function crylevel.LoadLibraries()
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

function crylevel.ParseLayerDocument(document)
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

function crylevel.ParseLayerData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse layer xml"
	end

	return crylevel.ParseLayerDocument(document)
end

function crylevel.ParseEditorObjectsDocument(document)
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

function crylevel.ParseEditorObjectsData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse editor level xml"
	end

	return crylevel.ParseEditorObjectsDocument(document)
end

function crylevel.ParseLevelDataDocument(document)
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

function crylevel.ParseLevelData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse level xml"
	end

	return crylevel.ParseLevelDataDocument(document)
end

function crylevel.ParseEditorLevelDocument(document)
	local root = document and document.children and document.children[1]
	local attrs = root and root.attrs or nil
	local heightmap = root and find_child_by_tag(root, "Heightmap") or nil
	local heightmap_attrs = heightmap and heightmap.attrs or {}

	if not attrs then return nil, "missing Level root" end

	-- the terrain layer id bitmap stores editor layer ids, several layers can share a surface type
	local layer_surface_types = {}

	for layer in iter_children_by_tag(find_child_by_tag(root, "Layers"), "Layer") do
		local layer_id = tonumber(layer.attrs.LayerId)

		if layer_id and layer.attrs.SurfaceType then
			layer_surface_types[layer_id] = layer.attrs.SurfaceType
		end
	end

	return {
		heightmap_width = tonumber(attrs.HeightmapWidth) or 0,
		heightmap_height = tonumber(attrs.HeightmapHeight) or 0,
		tile_count_x = tonumber(attrs.TileCountX) or 0,
		tile_count_y = tonumber(attrs.TileCountY) or 0,
		tile_resolution = tonumber(attrs.TileResolution) or 0,
		texture_size = tonumber(heightmap_attrs.TextureSize) or 0,
		layer_surface_types = layer_surface_types,
	}
end

function crylevel.ParseEditorLevelData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse editor level xml"
	end

	return crylevel.ParseEditorLevelDocument(document)
end

function crylevel.ParseVegetationMapDocument(document)
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
				align_to_terrain = parse_bool_flag(attrs.AlignToTerrain),
				random_rotation = parse_bool_flag(attrs.RandomRotation),
				use_terrain_color = parse_bool_flag(attrs.UseTerrainColor),
				bending = parse_bool_flag(attrs.Bending),
				size = tonumber(attrs.Size) or 1,
				size_var = tonumber(attrs.SizeVar) or 0,
			}
			prototypes.list[#prototypes.list + 1] = prototype
			prototypes.by_id[prototype_id] = prototype
		end
	end

	return prototypes
end

function crylevel.ParseVegetationMapData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse vegetation xml"
	end

	return crylevel.ParseVegetationMapDocument(document)
end

function crylevel.IsVegetationPrototypeSupportedFirstPass(objects, terrain)
	return objects and (not objects.align_to_terrain or terrain ~= nil)
end

function crylevel.DecodeVegetationYawFromRecord(data, offset)
	local packed = read_u32_le(data, offset + (8 * 4)) or 0
	local x = bit.band(packed, 0xFF) - 128
	local y = bit.band(bit.rshift(packed, 8), 0xFF) - 128
	local length = math.sqrt(x * x + y * y)

	if length < 8 then return 0, length end

	return math.atan2(y, x), length
end

local function sample_terrain_height_at_world(terrain, world_x, world_z)
	return sample_terrain_height01_at_world(terrain, world_x, world_z) * (
			terrain.heightmap_max_height or
			0
		)
end

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

function crylevel.ParseVegetationInstancesData(data, prototypes, terrain)
	if type(data) ~= "string" or data == "" then return {} end

	local entries = {}
	local stride = 76
	local count = math.floor(#data / stride)

	for index = 0, count - 1 do
		local offset = index * stride + 1
		local prototype_bits = read_u32_le(data, offset + 16) or 0
		local prototype_id = bit.band(prototype_bits, 0xFF)
		local prototype = prototypes and prototypes.by_id and prototypes.by_id[prototype_id] or nil

		if crylevel.IsVegetationPrototypeSupportedFirstPass(prototype, terrain) then
			local yaw, yaw_strength = crylevel.DecodeVegetationYawFromRecord(data, offset)
			local position = Vec3(
				read_f32_le(data, offset) or 0,
				read_f32_le(data, offset + 4) or 0,
				read_f32_le(data, offset + 8) or 0
			)
			local terrain_normal

			if prototype.align_to_terrain and terrain then
				local engine_position = crylevel.CryVec3ToEngine(position)
				terrain_normal = sample_terrain_normal_at_world(terrain, engine_position.x, engine_position.z)
			end

			entries[#entries + 1] = {
				name = string.format("vegetation_%d_%d", prototype_id, index + 1),
				model_path = prototype.model_path,
				material_path = prototype.material_path,
				prototype_id = prototype_id,
				position = position,
				scale = read_f32_le(data, offset + 12) or 1,
				yaw = yaw,
				yaw_strength = yaw_strength,
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

function crylevel.LoadTerrainData(steam, level_dir)
	local level_data_path = level_dir .. "level.pak/leveldata.xml"
	local level_data_xml, level_data_err = vfs.Read(level_data_path)

	if not level_data_xml then
		return nil, level_data_err or ("failed to read " .. tostring(level_data_path))
	end

	local terrain, parse_err = crylevel.ParseLevelData(level_data_xml)

	if not terrain then return nil, parse_err end

	terrain.level_dir = level_dir
	local game = steam and select(1, crylevel.FindCryGame(steam)) or nil

	do
		local cover_path = level_dir .. "level.pak/terrain/cover.ctc"
		local cover_data, cover_err = vfs.Read(cover_path)

		if not cover_data then
			return nil, cover_err or ("failed to read " .. cover_path)
		end

		local cover, err = crylevel.ParseCoverData(cover_data)

		if not cover then return nil, cover_path .. ": " .. err end

		terrain.cover = cover
	end

	local level_name = level_dir:match("/([^/]+)/$") or ""
	local editor_level_path = level_dir .. level_name .. ".cry/level.editor_xml"
	local editor_level_xml = vfs.Read(editor_level_path)

	if editor_level_xml then
		local editor_level, editor_level_err = crylevel.ParseEditorLevelData(editor_level_xml)

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

			surface_type.detail_material_path = crylevel.ResolveModelPath(steam, level_dir, material_path)

			if
				game and
				type(surface_type.detail_material_path) == "string" and
				not file_path.IsPathAbsolutePath(surface_type.detail_material_path)
			then
				local absolute_material = vfs.FindMixedCasePath(game.game_dir .. "Game/GameData.pak/" .. surface_type.detail_material_path)

				if absolute_material then
					surface_type.detail_material_path = absolute_material
				end
			end
		end
	end

	-- surface type index (1 based, 0 = none) per heightmap cell, the low bit of the raw layer id is a flag
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

local function decode_terrain_surface_slot(raw_value)
	raw_value = tonumber(raw_value) or 0

	if raw_value <= 0 then return 0 end

	return math.floor(raw_value * 0.5)
end

local function get_terrain_surface_slot_sample(terrain, sample_x, sample_y)
	local width = terrain.surface_slot_width or 0
	local height = terrain.surface_slot_height or width

	if width <= 0 or height <= 0 then return 0 end

	sample_x = math.floor(sample_x + 0.5)
	sample_y = math.floor(sample_y + 0.5)

	if sample_x < 0 then
		sample_x = 0
	elseif sample_x > (terrain.surface_slot_max_x or (width - 1)) then
		sample_x = terrain.surface_slot_max_x or (width - 1)
	end

	if sample_y < 0 then
		sample_y = 0
	elseif sample_y > (terrain.surface_slot_max_y or (height - 1)) then
		sample_y = terrain.surface_slot_max_y or (height - 1)
	end

	local raw

	if terrain.surface_slot_samples then
		raw = terrain.surface_slot_samples[sample_y * width + sample_x]
	else
		raw = terrain.surface_slot_data:byte(sample_y * width + sample_x + 1) or 0
	end

	return decode_terrain_surface_slot(raw)
end

local function sample_terrain_surface_slot_at_world(terrain, world_x, world_z)
	if not terrain.surface_slot_data then return 0 end

	local sample_x = (-world_z) * (terrain.surface_slot_world_to_sample_x or 0)
	local sample_y = world_x * (terrain.surface_slot_world_to_sample_y or 0)
	return get_terrain_surface_slot_sample(terrain, sample_x, sample_y)
end

local function get_or_create_cry_height_texture(terrain)
	if terrain.height_texture and terrain.height_texture:IsValid() then
		return terrain.height_texture
	end

	terrain.height_texture = Texture.New{
		width = terrain.height_sample_width,
		height = terrain.height_sample_height,
		format = "r16_unorm",
		buffer = terrain.height_samples or terrain.height_data,
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	return terrain.height_texture
end

local get_or_create_cry_albedo_texture

do
	local AtlasNodeConstants = ffi.typeof("struct { int source; int x; int y; int span; }")
	local ATLAS_NODE_DECLARATIONS = [[
		layout(push_constant, scalar) uniform CryAtlasNode {
			int source;
			int x;
			int y;
			int span;
		} atlas_node;
	]]
	local ATLAS_NODE_GLSL = [[
		vec2 cell = uv * float(atlas_node.span) - vec2(atlas_node.x, atlas_node.y);

		if (any(lessThan(cell, vec2(0.0))) || any(greaterThanEqual(cell, vec2(1.0)))) discard;

		// cry's tex2DTerrain: red and green are the color's share of r + g + b, blue is its brightness.
		// the red tweak compensates for 565 red only reaching 30/31 for a perfect gray
		vec4 texel = texture(TEXTURE(atlas_node.source), cell);
		float red = (texel.r + 0.001012) * (31.0 / 30.0);
		vec3 color = vec3(red, texel.g, 1.0 - red - texel.g) * 3.0 * texel.b;
		// opinionated for goluwa
		color = pow(color, vec3(1.5)) * 0.5;
		return vec4(color, 1.0);
	]]
	local LINEAR_CLAMP = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	}

	-- every cover node is drawn into its square of the atlas, coarse levels first so finer ones replace them
	function get_or_create_cry_albedo_texture(terrain)
		if terrain.albedo_texture and terrain.albedo_texture:IsValid() then
			return terrain.albedo_texture
		end

		local cover = terrain.cover
		local sector_size = cover.sector_size
		local data = ffi.cast("const uint8_t *", cover.data)
		local atlas = Texture.New{
			width = sector_size * 2 ^ cover.max_level,
			height = sector_size * 2 ^ cover.max_level,
			format = "r8g8b8a8_srgb",
			mip_map_levels = 1,
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = LINEAR_CLAMP,
		}

		for i, node in ipairs(cover.nodes) do
			local source = Texture.New{
				decoded = {
					width = sector_size,
					height = sector_size,
					-- the channels are an encoding, not colors, see ATLAS_NODE_GLSL
					vulkan_format = "bc3_unorm_block",
					is_compressed = true,
					mip_count = 1,
					mip_info = {
						{
							width = sector_size,
							height = sector_size,
							depth = 1,
							size = cover.sector_bytes,
							offset = 0,
						},
					},
					data_size = cover.sector_bytes,
					data = data + node.offset,
				},
				mip_map_levels = 1,
				sampler = LINEAR_CLAMP,
			}
			local constants = AtlasNodeConstants(0, node.x, node.y, 2 ^ node.level)
			atlas:Shade(
				ATLAS_NODE_GLSL,
				{
					textures = {source},
					load_op = i == 1 and "clear" or "load",
					custom_declarations = ATLAS_NODE_DECLARATIONS,
					fragment_push_constants = {
						size = ffi.sizeof(AtlasNodeConstants),
						get_data = function(_, _, pipeline)
							constants.source = pipeline:GetTextureIndex(source)
							return constants
						end,
					},
				}
			)
			source:Remove()
		end

		terrain.albedo_texture = atlas
		return atlas
	end
end

local function get_or_create_cry_surface_index_texture(terrain)
	if terrain.surface_index_texture and terrain.surface_index_texture:IsValid() then
		return terrain.surface_index_texture
	end

	terrain.surface_index_texture = Texture.New{
		width = terrain.surface_slot_width,
		height = terrain.surface_slot_height,
		format = "r8_unorm",
		buffer = terrain.surface_indices,
		mip_map_levels = 1,
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	return terrain.surface_index_texture
end

-- the detail material of each surface type as a terrain layer, indexed like terrain.surface_types
local function get_or_create_cry_terrain_layers(terrain)
	if terrain.detail_layers then return terrain.detail_layers end

	local Material = import("goluwa/render3d/material.lua")
	local layers = {}

	for i, surface_type in ipairs(terrain.surface_types) do
		if surface_type.detail_material_path then
			local material = Material.FromCryMTL(surface_type.detail_material_path)

			-- some layers have a sub material per projection axis instead, all of ours project along z
			if not (material.cry_texture_maps and material.cry_texture_maps.Diffuse) then
				material = Material.FromCryMTL(surface_type.detail_material_path, "z")
			end

			local diffuse = material.cry_texture_maps and material.cry_texture_maps.Diffuse

			if diffuse then
				-- cry tiles the detail texture every 1 / (surface detail scale * material tiling) meters
				layers[i] = {
					-- cry's Terrain.Layer adds (detail - 0.5) * DetailTextureStrength to the terrain color, with the raw
					-- texel values, and multiplies the sum by the material's diffuse color
					albedo = diffuse.resolved and
						Texture.New{path = diffuse.resolved, srgb = false} or
						material:GetAlbedoTexture(),
					normal = material:GetNormalTexture(),
					scale = 1 / (surface_type.detail_scale_x * diffuse.tile_u),
					detail = tonumber(material.cry_public_params.DetailTextureStrength) or 1,
					additive_detail = material:GetColorMultiplier():GetLuminance(),
					-- mapped from cry's specular color the same way as for models, most layers have none
					specular = material:GetSpecularMultiplier(),
					-- cry layers say nothing about grass, grass in crysis is painted vegetation. layers named for
					-- grass grow it, except paths like road_grass_patches_brown_soil, which are mostly bare
					grass = (
							surface_type.name:lower():find("grass", 1, true) and
							not surface_type.name:lower():find("road", 1, true)
						)
						and
						1 or
						0,
					roughness = 1,
					ao = 1,
				}
			else
				wlog(
					"cry terrain detail material %s has no diffuse texture",
					surface_type.detail_material_path
				)
			end
		end
	end

	terrain.detail_layers = layers
	return layers
end

local guess_cry_surface_color
guess_cry_surface_color = function(surface_type)
	local key = (
			(
				surface_type and
				surface_type.name
			)
			or
			""
		) .. " " .. (
			(
				surface_type and
				surface_type.detail_material
			)
			or
			""
		)
	key = key:lower()

	if
		key:find("grass", 1, true) or
		key:find("fern", 1, true) or
		key:find("leaf", 1, true)
	then
		return Color(0.28, 0.40, 0.18, 1)
	end

	if key:find("sand", 1, true) or key:find("beach", 1, true) then
		return Color(0.72, 0.66, 0.46, 1)
	end

	if
		key:find("cliff", 1, true) or
		key:find("rock", 1, true) or
		key:find("stone", 1, true) or
		key:find("pep", 1, true)
	then
		return Color(0.47, 0.45, 0.42, 1)
	end

	if
		key:find("road", 1, true) or
		key:find("asphalt", 1, true) or
		key:find("con", 1, true)
	then
		return Color(0.36, 0.35, 0.33, 1)
	end

	if
		key:find("soil", 1, true) or
		key:find("earth", 1, true) or
		key:find("ground", 1, true) or
		key:find("mud", 1, true)
	then
		return Color(0.41, 0.31, 0.21, 1)
	end

	if
		key:find("river", 1, true) or
		key:find("wet", 1, true) or
		key:find("underwater", 1, true)
	then
		return Color(0.30, 0.34, 0.30, 1)
	end

	return Color(0.5, 0.48, 0.43, 1)
end

local function build_cry_terrain_source(terrain)
	local ShaderSource = import("goluwa/terrain/shader_source.lua")
	local world_size = math.max(terrain.world_size or 0, 1)
	local has_layers = terrain.surface_indices ~= nil
	local detail_layers = has_layers and get_or_create_cry_terrain_layers(terrain) or nil
	local surface_indices = terrain.surface_indices
	local index_width = terrain.surface_slot_width
	local index_height = terrain.surface_slot_height
	local cells_per_meter_x = has_layers and index_width / world_size or 0
	local cells_per_meter_y = has_layers and index_height / world_size or 0
	return ShaderSource.New{
		Textures = {
			get_or_create_cry_height_texture(terrain),
			get_or_create_cry_albedo_texture(terrain),
			has_layers and get_or_create_cry_surface_index_texture(terrain) or nil,
		},
		HeightGLSL = string.format(
			[[
			vec2 cry_terrain_uv(vec2 world) {
				// texture columns run along cry +y (engine -z), rows along cry +x (engine +x)
				return clamp(vec2(-world.y / %.6f, world.x / %.6f), vec2(0.0), vec2(1.0));
			}

			float terrain_height(vec2 world) {
				return texture(TEXTURE(terrain_bake.texture0), cry_terrain_uv(world)).r * %.6f;
			}
		]],
			world_size,
			world_size,
			terrain.heightmap_max_height
		),
		-- bilinear weights of the 4 surrounding surface cells, cells whose surface type is not
		-- one of this chunk's layers fall back to the first (most common) layer
		SplatGLSL = has_layers and
			[[
			vec4 terrain_splat(vec2 world, float h, vec3 n) {
				ivec2 size = textureSize(TEXTURE(terrain_bake.texture2), 0);
				vec2 p = cry_terrain_uv(world) * vec2(size) - 0.5;
				ivec2 base = ivec2(floor(p));
				vec2 f = p - vec2(base);
				vec4 weights = vec4(0.0);

				for (int i = 0; i < 4; i++) {
					ivec2 offset = ivec2(i & 1, i >> 1);
					ivec2 cell = clamp(base + offset, ivec2(0), size - 1);
					int id = int(texelFetch(TEXTURE(terrain_bake.texture2), cell, 0).r * 255.0 + 0.5);
					float weight = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);

					if (id == terrain_bake.layer1) {
						weights.y += weight;
					} else if (id == terrain_bake.layer2) {
						weights.z += weight;
					} else if (id == terrain_bake.layer3) {
						weights.w += weight;
					} else {
						weights.x += weight;
					}
				}

				return weights;
			}
		]] or
			nil,
		ColorGLSL = [[
			vec3 terrain_color(vec2 world, float h, vec3 n) {
				return texture(TEXTURE(terrain_bake.texture1), cry_terrain_uv(world)).rgb;
			}
		]],
		ColorFormat = "r8g8b8a8_srgb",
		-- the 4 most common surface types of the chunk, sampled from at most 64x64 cells
		SelectChunkLayers = has_layers and
			function(request)
				local first_row = math.clamp(math.floor(request.min_x * cells_per_meter_y), 0, index_height - 1)
				local last_row = math.clamp(math.ceil((request.min_x + request.size) * cells_per_meter_y), 0, index_height - 1)
				local first_column = math.clamp(math.floor(-(request.min_z + request.size) * cells_per_meter_x), 0, index_width - 1)
				local last_column = math.clamp(math.ceil(-request.min_z * cells_per_meter_x), 0, index_width - 1)
				local stride = math.max(math.floor(math.max(last_row - first_row, last_column - first_column) / 64), 1)
				local counts = {}
				local ids = {}

				for row = first_row, last_row, stride do
					for column = first_column, last_column, stride do
						local id = surface_indices[row * index_width + column]

						if id ~= 0 and detail_layers[id] then
							if not counts[id] then ids[#ids + 1] = id end

							counts[id] = (counts[id] or 0) + 1
						end
					end
				end

				table.sort(ids, function(a, b)
					return counts[a] > counts[b]
				end)

				local layers = {}

				for i = 5, #ids do
					ids[i] = nil
				end

				for i, id in ipairs(ids) do
					layers[i] = detail_layers[id]
				end

				return layers, ids
			end or
			nil,
		MinHeight = 0,
		MaxHeight = terrain.heightmap_max_height,
		Layers = {},
	}
end

function crylevel.SpawnTerrain(level_data, parent)
	local terrain = level_data and level_data.terrain

	if not terrain or not terrain.height_data then return nil end

	local Terrain = import("goluwa/terrain/terrain.lua")
	local renderer = Terrain.New{
		Name = "cry_terrain",
		Source = build_cry_terrain_source(terrain),
		Levels = 6,
		BaseChunkSize = 64,
		Samples = 65,
		DetailSize = 256,
		ColorSize = 256,
		ShadowLevels = 3,
		BuildsPerUpdate = 3,
		Physics = {
			chunk_size = 64,
			samples = 65,
			radius = 2,
		},
	}:Start()
	renderer.Root:SetName("cry_terrain")
	renderer.Root.spawned_from_cry_level = true
	parent:AddChild(renderer.Root)
	return renderer
end

function crylevel.FindCryGame(steam)
	if steam.cached_cry_game and steam.cached_cry_game.appid == crylevel.CRYSIS_APPID then
		return steam.cached_cry_game
	end

	for _, game in ipairs(steam.GetGames()) do
		if game.appid == crylevel.CRYSIS_APPID then
			steam.cached_cry_game = game
			return game
		end
	end

	return nil, "Crysis 1 not found"
end

function crylevel.ResolveLevelDirectory(steam, level)
	if type(level) ~= "string" or level == "" then
		return nil, "missing Crysis level path"
	end

	local normalized = ensure_trailing_slash(level)

	if vfs.IsDirectory(normalized) then return normalized end

	if not file_path.IsPathAbsolutePath(normalized) then
		local game, err = crylevel.FindCryGame(steam)

		if not game then return nil, err end

		local candidate = ensure_trailing_slash(game.game_dir .. "Game/Levels/" .. normalized)

		if vfs.IsDirectory(candidate) then return candidate end
	end

	return nil, "could not resolve Crysis level directory " .. tostring(level)
end

local function resolve_model_path_impl(steam, level_dir, model_path)
	local normalized = file_path.FixPathSlashes(model_path)
	local candidates = {normalized}
	local game = select(1, crylevel.FindCryGame(steam))
	local root, rest = normalized:match("^([^/]+)/(.+)$")
	local root_lower = root and root:lower() or nil
	local mounted_root = root_lower == "objects" and
		"Objects" or
		root_lower == "materials" and
		"Materials" or
		root_lower == "textures" and
		"Textures" or
		nil

	if mounted_root and rest then
		local mounted = vfs.FindMixedCasePath(mounted_root .. "/" .. rest)

		if mounted then return mounted end
	end

	if level_dir then
		candidates[#candidates + 1] = level_dir .. "level.pak/" .. normalized
		candidates[#candidates + 1] = level_dir .. "terraintexture.pak/" .. normalized
		candidates[#candidates + 1] = level_dir .. file_path.GetFileNameFromPath(level_dir:sub(1, -2)) .. ".cry/" .. normalized
	end

	if game and game.game_dir then
		candidates[#candidates + 1] = game.game_dir .. "Game/" .. normalized
		candidates[#candidates + 1] = game.game_dir .. "Game/GameData.pak/" .. normalized
		candidates[#candidates + 1] = game.game_dir .. "Game/Objects.pak/" .. normalized
		candidates[#candidates + 1] = game.game_dir .. "Game/Textures.pak/" .. normalized
	end

	for _, candidate in ipairs(candidates) do
		local found = vfs.FindMixedCasePath(candidate)

		if found and vfs.IsFile(found) then return found end

		if vfs.IsFile(candidate) then return candidate end
	end

	return normalized
end

local resolved_model_path_cache = {}

function crylevel.ResolveModelPath(steam, level_dir, model_path)
	local cache_key = (level_dir or "") .. "\0" .. model_path
	local cached = resolved_model_path_cache[cache_key]

	if cached then return cached end

	local result = resolve_model_path_impl(steam, level_dir, model_path)
	resolved_model_path_cache[cache_key] = result
	return result
end

-- level objects name their material override like "Objects/Natural/Rocks/foo", relative to the game root
function crylevel.ResolveMaterialPath(steam, level_dir, material_path)
	return crylevel.ResolveModelPath(
		steam,
		level_dir,
		file_path.FixPathSlashes(material_path):gsub("%.[mM][tT][lL]$", "") .. ".mtl"
	)
end

function crylevel.EnsureLevelMounts(steam, level_dir)
	local game, err = crylevel.FindCryGame(steam)

	if not game then error(err) end

	if steam.cry_level_mount_root == level_dir and steam.cry_level_mounts then
		return steam.cry_level_mounts
	end

	steam.cry_level_mounts = clear_mounts(steam.cry_level_mounts)
	steam.cry_level_mount_root = level_dir

	local function mount(where, to)
		where = ensure_trailing_slash(where)

		if vfs.IsDirectory(where) then
			vfs.Mount(where, to or "")
			steam.cry_level_mounts[#steam.cry_level_mounts + 1] = {where = where, to = to or ""}
		end
	end

	mount(game.game_dir .. "Game/Objects.pak/")
	mount(game.game_dir .. "Game/Textures.pak/")
	mount(game.game_dir .. "Game/GameData.pak/")
	mount(level_dir .. "level.pak/")
	mount(level_dir .. "terraintexture.pak/")
	mount(level_dir .. (level_dir:match("/([^/]+)/$") or "") .. ".cry/")
	return steam.cry_level_mounts
end

function crylevel.Apply(steam)
	steam.loaded_cry_levels = steam.loaded_cry_levels or {}

	function steam.LoadCryLevel(level)
		local level_dir, err = crylevel.ResolveLevelDirectory(steam, level)

		if not level_dir then error(err) end

		crylevel.EnsureLevelMounts(steam, level_dir)

		if steam.loaded_cry_levels[level_dir] then
			return steam.loaded_cry_levels[level_dir]
		end

		local nodes = {}
		local layers_dir = level_dir .. "Layers/"

		for _, file_name in ipairs(vfs.Find(layers_dir) or {}) do
			if file_name:lower():ends_with(".lyr") then
				local path = layers_dir .. file_name
				local data, read_err = vfs.Read(path)

				if data then
					local layer_nodes, parse_err = crylevel.ParseLayerData(data)

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

		-- objects in external layers live in the .lyr files, everything else is in the editor xml
		local level_name = level_dir:match("/([^/]+)/$") or ""
		local editor_level_path = level_dir .. level_name .. ".cry/level.editor_xml"
		local editor_level_data, editor_level_err = vfs.Read(editor_level_path)

		if editor_level_data then
			local editor_nodes, parse_err = crylevel.ParseEditorObjectsData(editor_level_data)

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

		steam.cry_libraries = steam.cry_libraries or crylevel.LoadLibraries()
		local entries = crylevel.ExtractVisualObjects(nodes, steam.cry_libraries)

		for _, entry in ipairs(entries) do
			entry.model_path = crylevel.ResolveModelPath(steam, level_dir, entry.model_path)

			if entry.material_path then
				entry.material_path = crylevel.ResolveMaterialPath(steam, level_dir, entry.material_path)
			end
		end

		local terrain = select(1, crylevel.LoadTerrainData(steam, level_dir))
		local vegetation_entries = {}
		local vegetation_map_data = editor_level_data

		if vegetation_map_data then
			local prototypes, vegetation_map_err = crylevel.ParseVegetationMapData(vegetation_map_data)
			local vegetation_instances_data, vegetation_instances_err = vfs.Read(level_dir .. level_name .. ".cry/vegetationinstancesarray.editor_data")

			if prototypes and vegetation_instances_data then
				vegetation_entries = crylevel.ParseVegetationInstancesData(vegetation_instances_data, prototypes, terrain)

				for _, entry in ipairs(vegetation_entries) do
					entry.model_path = crylevel.ResolveModelPath(steam, level_dir, entry.model_path)

					if entry.material_path then
						entry.material_path = crylevel.ResolveMaterialPath(steam, level_dir, entry.material_path)
					end
				end
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

		steam.loaded_cry_levels[level_dir] = {
			level_dir = level_dir,
			entries = entries,
			vegetation_entries = vegetation_entries,
			terrain = terrain,
		}
		return steam.loaded_cry_levels[level_dir]
	end

	-- like CryEngine, an override with sub materials replaces the model's materials per subset,
	-- and one without replaces all of them
	local function apply_material_override(visual, material_path, cache)
		local override = cache[material_path]

		if not override then
			local Material = import("goluwa/render3d/material.lua")
			local slots = Material.FromCryMTLSlots(material_path)
			override = {
				slots = slots,
				material = not slots and Material.FromCryMTL(material_path) or nil,
			}
			cache[material_path] = override
		end

		if override.slots then
			visual:SetMaterialSlotOverrides(override.slots)
		else
			visual:SetMaterialOverride(override.material)
		end
	end

	function steam.SpawnCryLevel(level, parent)
		local Entity = import("goluwa/entities/entity.lua")
		local material_overrides = {}
		local data = steam.LoadCryLevel(level)

		if steam.active_cry_terrain_renderer then
			steam.active_cry_terrain_renderer:Stop()
			steam.active_cry_terrain_renderer = nil
		end

		for _, child in ipairs(parent:GetChildrenList()) do
			if child.spawned_from_cry_level then child:Remove() end
		end

		steam.active_cry_terrain_renderer = crylevel.SpawnTerrain(data, parent)

		if not steam.cry_skip_models then
			for _, entry in ipairs(data.entries) do
				local transform_data = crylevel.ConvertCryWorldMatrixToEngineTransform(entry.world_matrix)
				local entity = Entity.New{Name = entry.name or "cry_object", Parent = parent}
				local transform = entity:AddComponent("transform")
				entity:AddComponent("visual")
				transform:SetPosition(transform_data.position)
				transform:SetRotation(transform_data.rotation)
				transform:SetScale(transform_data.scale)
				entity.visual:SetModelPath(entry.model_path)

				if entry.material_path then
					apply_material_override(entity.visual, entry.material_path, material_overrides)
				end

				entity.spawned_from_cry_level = true
			end

			for _, entry in ipairs(data.vegetation_entries or {}) do
				local transform_data = crylevel.ConvertCryVegetationInstanceToEngineTransform(entry)
				local entity = Entity.New{Name = entry.name or "cry_vegetation", Parent = parent}
				local transform = entity:AddComponent("transform")
				entity:AddComponent("visual")
				transform:SetPosition(transform_data.position)
				transform:SetRotation(transform_data.rotation)
				transform:SetScale(transform_data.scale)
				entity.visual:SetModelPath(entry.model_path)

				if entry.material_path then
					apply_material_override(entity.visual, entry.material_path, material_overrides)
				end

				entity.spawned_from_cry_level = true
			end
		end

		return data
	end

	function steam.SetCryLevel(level)
		local Entity = import("goluwa/entities/entity.lua")
		steam.cry_level_world = steam.cry_level_world or Entity.New({Name = "cry_level_world"})
		local level_dir = assert(crylevel.ResolveLevelDirectory(steam, level))
		local level_name = level_dir:match("/([^/]+)/$") or level_dir
		steam.cry_level_world:SetName(level_name)
		steam.cry_level_world:RemoveChildren()
		return steam.SpawnCryLevel(level_dir, steam.cry_level_world)
	end
end

return crylevel

local xml = import("goluwa/codecs/xml.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Texture = import("goluwa/render/texture.lua")
local ffi = require("ffi")
local read_u32_le, read_u16_le, read_f32_le
local sample_terrain_height01_at_world
local f32_union = ffi.new("union { uint32_t u; float f; }")
local mounted_case_directory_cache = {}
local mounted_case_path_cache = {}
local crylevel = {
	CRYSIS_APPID = 17300,
}

local function clear_mounted_case_lookup_cache()
	mounted_case_directory_cache = {}
	mounted_case_path_cache = {}
end

local function clear_mounts(mounts)
	clear_mounted_case_lookup_cache()

	for _, mount in ipairs(mounts or {}) do
		vfs.Unmount(mount.where, mount.to)
	end

	return {}
end

local function find_mounted_case_path(root, relative_path)
	local normalized_root = file_path.FixPathSlashes(root or "")
	local normalized_relative = file_path.FixPathSlashes(relative_path or "")

	if normalized_root == "" or normalized_relative == "" then return nil end

	local cache_key = normalized_root .. "\0" .. normalized_relative
	local cached = mounted_case_path_cache[cache_key]

	if cached ~= nil then return cached ~= false and cached or nil end

	local current = normalized_root:ends_with("/") and normalized_root or (normalized_root .. "/")
	local last_part = normalized_relative:match("[^/]+$")

	for part in normalized_relative:gmatch("[^/]+") do
		local entry_lookup = mounted_case_directory_cache[current]

		if not entry_lookup then
			entry_lookup = {}

			for _, entry in ipairs(vfs.Find(current) or {}) do
				entry_lookup[entry:lower()] = entry
			end

			mounted_case_directory_cache[current] = entry_lookup
		end

		local matched = entry_lookup[part:lower()]

		if not matched then
			local resolved = vfs.FindFileByNameRecursive(normalized_root .. "/", part)
			mounted_case_path_cache[cache_key] = resolved or false
			return resolved
		end

		current = current .. matched

		if part ~= last_part then
			current = current:ends_with("/") and current or (current .. "/")
		end
	end

	if vfs.IsFile(current) then
		mounted_case_path_cache[cache_key] = current
		return current
	end

	mounted_case_path_cache[cache_key] = false
	return nil
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

local function parse_quat(str)
	local x, y, z, w = unpack_csv_numbers(str)
	local rotation = Quat(x or 0, y or 0, z or 0, w or 1)

	if rotation:GetLength() <= 0.000001 then return Quat(0, 0, 0, 1) end

	return rotation:GetNormalized()
end

local function parse_editor_quat(str)
	local x, y, z, w = unpack_csv_numbers(str)
	local rotation = Quat(y or 0, z or 0, x or 0, w or 1)

	if rotation:GetLength() <= 0.000001 then return Quat(0, 0, 0, 1) end

	return rotation:GetNormalized()
end

local function parse_bool_flag(value)
	return tostring(value or "0") == "1"
end

local function parse_cover_ctc_metadata(data)
	if type(data) ~= "string" or #data < 0x2c then
		return nil, "cover.ctc is truncated"
	end

	local magic = string.char(data:byte(1) or 0, data:byte(2) or 0, data:byte(3) or 0)

	if magic ~= "CRY" then return nil, "cover.ctc has invalid magic" end

	local texture_resolution = read_u32_le(data, 0x11) or 0
	local surface_slot_count = read_u32_le(data, 0x15) or 0
	local cover_tile_count = read_u32_le(data, 0x29) or 0
	local transition_lookup = {}
	local lookup_offset = 0x2d
	local lookup_entry_count = surface_slot_count * surface_slot_count
	local lookup_bytes = lookup_entry_count * 2

	if surface_slot_count <= 0 then
		return nil, "cover.ctc has invalid surface slot count"
	end

	if #data >= lookup_offset + lookup_bytes - 1 then
		for row = 1, surface_slot_count do
			local row_entries = {}
			local row_base = lookup_offset + ((row - 1) * surface_slot_count * 2)

			for column = 1, surface_slot_count do
				local value = read_u16_le(data, row_base + ((column - 1) * 2)) or 0xffff
				row_entries[column] = value ~= 0xffff and value or false
			end

			transition_lookup[row] = row_entries
		end
	end

	return {
		magic = magic,
		texture_resolution = texture_resolution,
		surface_slot_count = surface_slot_count,
		cover_tile_count = cover_tile_count,
		transition_lookup = transition_lookup,
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

function crylevel.CryLevelWorldVec3ToEngine(vec)
	return Vec3(vec.y, vec.z, -vec.x)
end

function crylevel.BuildCryLocalMatrix(attrs)
	local matrix = Matrix44()
	local position = parse_vec3(attrs.Pos, 0, 0, 0)
	local rotation = parse_quat(attrs.Rotate)
	local scale = parse_vec3(attrs.Scale, 1, 1, 1)
	matrix:Identity()
	matrix:SetRotation(rotation)

	if scale.x ~= 1 or scale.y ~= 1 or scale.z ~= 1 then
		matrix:Scale(scale.x, scale.y, scale.z)
	end

	matrix:SetTranslation(position.x, position.y, position.z)
	return matrix
end

function crylevel.BuildCryEditorLocalMatrix(attrs)
	local matrix = Matrix44()
	local position = parse_vec3(attrs.Pos, 0, 0, 0)
	local rotation = parse_editor_quat(attrs.Rotate)
	local scale = parse_vec3(attrs.Scale, 1, 1, 1)
	matrix:Identity()
	matrix:SetRotation(rotation)

	if scale.x ~= 1 or scale.y ~= 1 or scale.z ~= 1 then
		matrix:Scale(scale.x, scale.y, scale.z)
	end

	matrix:SetTranslation(position.x, position.y, position.z)
	return matrix
end

function crylevel.ComposeCryWorldMatrix(parent_world, attrs, build_local_matrix)
	local local_matrix = (build_local_matrix or crylevel.BuildCryLocalMatrix)(attrs)

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
	local right = scale_x > 0.000001 and crylevel.CryVec3ToEngine(cry_x / scale_x) or Vec3(1, 0, 0)
	local up = scale_z > 0.000001 and crylevel.CryVec3ToEngine(cry_z / scale_z) or Vec3(0, 1, 0)
	local back = scale_y > 0.000001 and
		(
			-crylevel.CryVec3ToEngine(cry_y / scale_y)
		)
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
			scale_x > 0.000001 and scale_x or 1,
			scale_z > 0.000001 and scale_z or 1,
			scale_y > 0.000001 and scale_y or 1
		),
	}
end

function crylevel.ConvertCryEditorWorldMatrixToEngineTransform(world_matrix)
	local transform = crylevel.ConvertCryWorldMatrixToEngineTransform(world_matrix)
	transform.rotation = (transform.rotation * Quat():SetAngles(Ang3(0, -math.pi / 2, 0))):GetNormalized()
	transform.position = crylevel.CryLevelWorldVec3ToEngine(world_matrix:TransformVector(Vec3(0, 0, 0)))
	return transform
end

function crylevel.ConvertCryVegetationInstanceToEngineTransform(entry)
	local yaw = entry.yaw or 0
	local rotation

	if entry.terrain_normal and entry.terrain_normal:GetLength() > 0.000001 then
		local up = entry.terrain_normal:GetNormalized()
		local flat_forward = Quat():SetAngles(Ang3(0, yaw - math.pi / 2, 0)):GetForward()
		local projected_forward = flat_forward - up * flat_forward:GetDot(up)

		if projected_forward:GetLength() <= 0.000001 then
			projected_forward = Vec3(0, 0, -1) - up * Vec3(0, 0, -1):GetDot(up)
		end

		projected_forward = projected_forward:GetNormalized()
		local back = (-projected_forward):GetNormalized()
		local right = up:GetCross(back)

		if right:GetLength() <= 0.000001 then
			right = Vec3(1, 0, 0)
		else
			right = right:GetNormalized()
		end

		back = right:GetCross(up):GetNormalized()
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
		rotation = rotation_matrix:GetRotation(Quat()):GetNormalized()
	else
		rotation = (Quat():SetAngles(Ang3(0, yaw - math.pi / 2, 0))):GetNormalized()
	end

	return {
		position = crylevel.CryLevelWorldVec3ToEngine(entry.position),
		rotation = rotation,
		scale = Vec3(entry.scale, entry.scale, entry.scale),
	}
end

function crylevel.GetVisualGeometryPath(attrs)
	local path
	local object_type = attrs.Type

	if object_type == "Brush" then
		path = attrs.Prefab
	elseif object_type == "GeomEntity" then
		path = attrs.Geometry
	end

	if type(path) ~= "string" or path == "" then return nil end

	path = file_path.FixPathSlashes(path)

	if not path:lower():ends_with(".cgf") then return nil end

	return path
end

function crylevel.IsObjectHidden(attrs)
	return attrs.Hidden == "1" or attrs.HiddenInGame == "1"
end

function crylevel.ExtractVisualObjectsFromNode(node, parent_world, out, build_local_matrix)
	out = out or {}

	if not node then return out end

	local attrs = node.attrs or {}
	local object_type = attrs.Type
	local world_matrix = crylevel.ComposeCryWorldMatrix(parent_world, attrs, build_local_matrix)

	if object_type == "Group" then
		local objects = find_child_by_tag(node, "Objects")

		for child in iter_children_by_tag(objects, "Object") do
			crylevel.ExtractVisualObjectsFromNode(child, world_matrix, out, build_local_matrix)
		end

		return out
	end

	if not crylevel.IsObjectHidden(attrs) then
		local model_path = crylevel.GetVisualGeometryPath(attrs)

		if model_path then
			out[#out + 1] = {
				name = attrs.Name or file_path.GetFileNameFromPath(model_path),
				model_path = model_path,
				type = object_type,
				world_matrix = world_matrix,
			}
		end
	end

	return out
end

function crylevel.ParseLayerDocument(document)
	local root = document and document.children and document.children[1]
	local layer = root and find_child_by_tag(root, "Layer") or nil
	local layer_attrs = layer and layer.attrs or {}
	local layer_objects = layer and find_child_by_tag(layer, "LayerObjects") or nil
	local out = {}

	if layer_attrs.Hidden == "1" or not layer_objects then return out end

	for node in iter_children_by_tag(layer_objects, "Object") do
		crylevel.ExtractVisualObjectsFromNode(node, nil, out)
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

function crylevel.ParseEditorVisualObjectsDocument(document)
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

		if not hidden_layers[attrs.Layer] then
			crylevel.ExtractVisualObjectsFromNode(node, nil, out, crylevel.BuildCryEditorLocalMatrix)
		end
	end

	return out
end

function crylevel.ParseEditorVisualObjectsData(data)
	local ok, document = pcall(xml.Decode, data)

	if not ok or not document then
		return nil, document or "unable to parse editor level xml"
	end

	return crylevel.ParseEditorVisualObjectsDocument(document)
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

	return {
		heightmap_width = tonumber(attrs.HeightmapWidth) or 0,
		heightmap_height = tonumber(attrs.HeightmapHeight) or 0,
		tile_count_x = tonumber(attrs.TileCountX) or 0,
		tile_count_y = tonumber(attrs.TileCountY) or 0,
		tile_resolution = tonumber(attrs.TileResolution) or 0,
		texture_size = tonumber(heightmap_attrs.TextureSize) or 0,
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
	local vegetation_map = root and find_child_by_tag(root, "VegetationMap") or nil
	local objects = vegetation_map and find_child_by_tag(vegetation_map, "Objects") or nil
	local prototypes = {list = {}, by_id = {}}

	if not objects then return prototypes end

	for node in iter_children_by_tag(objects, "Object") do
		local attrs = node.attrs or {}
		local prototype_id = tonumber(attrs.Id)
		local model_path = file_path.FixPathSlashes(attrs.FileName or "")

		if prototype_id and model_path ~= "" and model_path:lower():ends_with(".cgf") then
			local prototype = {
				id = prototype_id,
				model_path = model_path,
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

function crylevel.IsVegetationPrototypeSupportedFirstPass(prototype, terrain)
	return prototype and (not prototype.align_to_terrain or terrain ~= nil)
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
				local engine_position = crylevel.CryLevelWorldVec3ToEngine(position)
				terrain_normal = sample_terrain_normal_at_world(terrain, engine_position.x, engine_position.z)
			end

			entries[#entries + 1] = {
				name = string.format("vegetation_%d_%d", prototype_id, index + 1),
				model_path = prototype.model_path,
				transform_space = "vegetation_world",
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

local function get_terrain_texture_tile_size(terrain)
	local tile_span = math.max(terrain.grid_width or 0, terrain.grid_height or 0, 1)
	return terrain.world_size > 0 and (terrain.world_size / tile_span) or 0
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

local function rebuild_terrain_albedo_cache(terrain)
	local tile_world_size = math.max(terrain.tile_world_size or 0, 1)
	terrain.albedo_tile_world_size = tile_world_size
	terrain.albedo_world_to_tile_x = 1 / tile_world_size
	terrain.albedo_world_to_tile_y = 1 / tile_world_size
	terrain.albedo_tile_max_x = math.max((terrain.grid_width or 1) - 1, 0)
	terrain.albedo_tile_max_y = math.max((terrain.grid_height or 1) - 1, 0)
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

local function decode_terrain_texture_tile(tile)
	if tile.rgba_buffer then return tile.rgba_buffer, tile.width, tile.height end

	local data, err = vfs.Read(tile.path)

	if not data then
		return nil, err or ("failed to read terrain tile " .. tostring(tile.path))
	end

	local width = read_u32_le(data, 1)
	local height = read_u32_le(data, 5)

	if not width or not height or width <= 0 or height <= 0 then
		return nil, "invalid terrain tile header " .. tostring(tile.path)
	end

	local expected_size = 8 + width * height * 3

	if #data < expected_size then
		return nil,
		string.format(
			"terrain tile %s is truncated: got %d bytes expected %d",
			tostring(tile.path),
			#data,
			expected_size
		)
	end

	local rgba_buffer = ffi.new("uint8_t[?]", width * height * 4)
	local src = 9
	local dst = 0

	for _ = 1, width * height do
		local b, g, r = data:byte(src, src + 2)
		rgba_buffer[dst + 0] = r or 0
		rgba_buffer[dst + 1] = g or 0
		rgba_buffer[dst + 2] = b or 0
		rgba_buffer[dst + 3] = 255
		src = src + 3
		dst = dst + 4
	end

	tile.width = width
	tile.height = height
	tile.rgba_buffer = rgba_buffer
	return rgba_buffer, width, height
end

local function get_terrain_tile_material(tile)
	if tile.material and tile.texture then return tile.material end

	local Texture = import("goluwa/render/texture.lua")
	local Material = import("goluwa/render3d/material.lua")
	local buffer, width, height = assert(decode_terrain_texture_tile(tile))
	tile.texture = tile.texture or
		Texture.New{
			width = width,
			height = height,
			format = "r8g8b8a8_srgb",
			buffer = buffer,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}

	if not tile.material then
		local material = Material.New()
		material:SetAlbedoTexture(tile.texture)
		material:SetRoughnessMultiplier(1)
		material:SetMetallicMultiplier(0)
		tile.material = material
	end

	return tile.material
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
	local tiles = {}
	local terrain_texture_dir = level_dir .. "terraintexture.pak/"
	local cover_texture_path = level_dir .. "level.pak/terrain/cover.ctc"
	local max_x = -1
	local max_y = -1
	local game = steam and select(1, crylevel.FindCryGame(steam)) or nil

	for _, file_name in ipairs(vfs.Find(terrain_texture_dir) or {}) do
		local tile_x, tile_y = file_name:match("^tile(%d+)_(%d+)%.raw$")

		if tile_x and tile_y then
			tile_x = tonumber(tile_x)
			tile_y = tonumber(tile_y)
			max_x = math.max(max_x, tile_x)
			max_y = math.max(max_y, tile_y)
			tiles[#tiles + 1] = {
				x = tile_x,
				y = tile_y,
				path = terrain_texture_dir .. file_name,
			}
		end
	end

	do
		local cover_data, cover_err = vfs.Read(cover_texture_path)

		if cover_data then
			local cover_metadata, cover_parse_err = parse_cover_ctc_metadata(cover_data)

			if cover_metadata then
				terrain.cover = cover_metadata
			else
				wlog(
					"failed to parse cry terrain cover metadata %s: %s",
					tostring(cover_texture_path),
					tostring(cover_parse_err)
				)
			end
		elseif cover_err then
			wlog(
				"failed to read cry terrain cover file %s: %s",
				tostring(cover_texture_path),
				tostring(cover_err)
			)
		end
	end

	table.sort(tiles, function(a, b)
		if a.y == b.y then return a.x < b.x end

		return a.y < b.y
	end)

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
			terrain.tile_height_resolution = math.floor(height_samples_w / math.max(max_x + 1, 1))
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

	terrain.tiles = tiles
	terrain.tile_lookup = {}
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

	for _, tile in ipairs(tiles) do
		terrain.tile_lookup[tile.y] = terrain.tile_lookup[tile.y] or {}
		terrain.tile_lookup[tile.y][tile.x] = tile
	end

	terrain.grid_width = max_x + 1
	terrain.grid_height = max_y + 1
	terrain.tile_world_size = get_terrain_texture_tile_size(terrain)
	rebuild_terrain_albedo_cache(terrain)
	return terrain
end

local function get_terrain_height_sample(terrain, sample_x, sample_y)
	if not terrain.height_data then return 0 end

	local width = terrain.height_sample_width or
		terrain.height_samples_width or
		terrain.height_samples_per_side or
		0
	local max_x = terrain.height_sample_max_x or (width - 1)
	local max_y = terrain.height_sample_max_y or
		(
			(
				terrain.height_sample_height or
				terrain.height_samples_height or
				terrain.height_samples_per_side or
				width
			) - 1
		)
	sample_x = math.floor(sample_x)
	sample_y = math.floor(sample_y)

	if sample_x < 0 then
		sample_x = 0
	elseif sample_x > max_x then
		sample_x = max_x
	end

	if sample_y < 0 then
		sample_y = 0
	elseif sample_y > max_y then
		sample_y = max_y
	end

	local raw

	if terrain.height_samples then
		raw = terrain.height_samples[sample_y * width + sample_x]
	else
		local offset = terrain.height_data_offset + (((sample_y * width) + sample_x) * 2)
		raw = read_u16_le(terrain.height_data, offset) or 0
	end

	return raw * (terrain.height_sample_scale or 1)
end

local function build_terrain_tile_heightmap(tile, terrain)
	if tile.heightmap_info then return tile.heightmap_info end

	local sample_resolution = terrain.tile_height_resolution or 0

	if sample_resolution <= 0 then return nil end

	local sample_dims = sample_resolution + 1
	local sample_origin_x = tile.x * sample_resolution
	local sample_origin_y = tile.y * sample_resolution
	local heights = {}
	local min_height = math.huge
	local max_height = -math.huge

	for y = 0, sample_resolution do
		for x = 0, sample_resolution do
			local height = get_terrain_height_sample(terrain, sample_origin_x + x, sample_origin_y + y)
			heights[y * sample_dims + x + 1] = height
			min_height = math.min(min_height, height)
			max_height = math.max(max_height, height)
		end
	end

	local height_range = max_height - min_height
	local mid_height = (min_height + max_height) * 0.5
	local heightmap = {
		width = sample_resolution,
		height = sample_resolution,
		GetSize = function(self)
			return Vec2(self.width, self.height)
		end,
		GetRawPixelColor = function(self, x, y)
			x = math.clamp(math.floor(x), 0, sample_resolution)
			y = math.clamp(math.floor(y), 0, sample_resolution)
			local value = heights[y * sample_dims + x + 1] or mid_height

			if height_range > 0.0001 then
				value = ((value - min_height) / height_range) * 255
			else
				value = 127.5
			end

			return value, value, value, value
		end,
	}
	tile.heightmap_info = {
		heightmap = heightmap,
		height_range = height_range > 0.0001 and height_range or 1,
		mid_height = mid_height,
	}
	return tile.heightmap_info
end

local function bilerp(a, b, c, d, tx, ty)
	local ab = a + (b - a) * tx
	local cd = c + (d - c) * tx
	return ab + (cd - ab) * ty
end

local function get_terrain_world_uv(terrain, world_x, world_z)
	local world_size = math.max(terrain.world_size or 0, 1)
	return math.clamp(world_x / world_size, 0, 1),
	math.clamp((-world_z) / world_size, 0, 1)
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

	local sample_x = world_x * (terrain.height_world_to_sample_x or 0)
	local sample_y = (-world_z) * (terrain.height_world_to_sample_y or 0)
	local raw = sample_terrain_height_raw(terrain, sample_x, sample_y)
	return raw / 65535
end

local function sample_terrain_tile_rgba(tile, u, v)
	local buffer, width, height = assert(decode_terrain_texture_tile(tile))

	if u < 0 then u = 0 elseif u > 1 then u = 1 end

	if v < 0 then v = 0 elseif v > 1 then v = 1 end

	local width_max = width - 1
	local height_max = height - 1
	local sample_x = u * width_max
	local sample_y = v * height_max
	local x0 = math.floor(sample_x)
	local y0 = math.floor(sample_y)
	local x1 = x0 < width_max and (x0 + 1) or width_max
	local y1 = y0 < height_max and (y0 + 1) or height_max
	local tx = sample_x - x0
	local ty = sample_y - y0
	local row0 = y0 * width * 4
	local row1 = y1 * width * 4
	local i00 = row0 + x0 * 4
	local i10 = row0 + x1 * 4
	local i01 = row1 + x0 * 4
	local i11 = row1 + x1 * 4
	local r00, g00, b00, a00 = buffer[i00 + 0], buffer[i00 + 1], buffer[i00 + 2], buffer[i00 + 3]
	local r10, g10, b10, a10 = buffer[i10 + 0], buffer[i10 + 1], buffer[i10 + 2], buffer[i10 + 3]
	local r01, g01, b01, a01 = buffer[i01 + 0], buffer[i01 + 1], buffer[i01 + 2], buffer[i01 + 3]
	local r11, g11, b11, a11 = buffer[i11 + 0], buffer[i11 + 1], buffer[i11 + 2], buffer[i11 + 3]
	return bilerp(r00, r10, r01, r11, tx, ty),
	bilerp(g00, g10, g01, g11, tx, ty),
	bilerp(b00, b10, b01, b11, tx, ty),
	bilerp(a00, a10, a01, a11, tx, ty)
end

local function sample_terrain_albedo_at_world(terrain, world_x, world_z)
	local tile_world_size = terrain.albedo_tile_world_size or math.max(terrain.tile_world_size or 0, 1)
	local tile_x = math.floor(world_x * (terrain.albedo_world_to_tile_x or (1 / tile_world_size)))
	local tile_y = math.floor((-world_z) * (terrain.albedo_world_to_tile_y or (1 / tile_world_size)))

	if tile_x < 0 then
		tile_x = 0
	elseif tile_x > (terrain.albedo_tile_max_x or 0) then
		tile_x = terrain.albedo_tile_max_x or 0
	end

	if tile_y < 0 then
		tile_y = 0
	elseif tile_y > (terrain.albedo_tile_max_y or 0) then
		tile_y = terrain.albedo_tile_max_y or 0
	end

	local row = terrain.tile_lookup and terrain.tile_lookup[tile_y] or nil
	local tile = row and row[tile_x] or nil

	if not tile then return 127, 127, 127, 255 end

	local local_x = world_x - tile_x * tile_world_size
	local local_y = (-world_z) - tile_y * tile_world_size
	return sample_terrain_tile_rgba(tile, local_x / tile_world_size, local_y / tile_world_size)
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

	local sample_x = world_x * (terrain.surface_slot_world_to_sample_x or 0)
	local sample_y = (-world_z) * (terrain.surface_slot_world_to_sample_y or 0)
	return get_terrain_surface_slot_sample(terrain, sample_x, sample_y)
end

local cry_terrain_bake_push_constant_t = ffi.typeof([[struct {
	float chunk_min_x;
	float chunk_min_z;
	float chunk_world_size;
	float texture_width;
	float texture_height;
	float sample_step_x;
	float sample_step_y;
	float normal_strength;
	float vertical_offset;
	float height_scale;
	float seed_offset_x;
	float seed_offset_y;
	int height_tex;
	int albedo_tex;
}]])
local CRY_TERRAIN_BAKE_PUSH_CONSTANT_DECLARATIONS = [[
layout(push_constant, scalar) uniform TerrainBakeConstants {
	float chunk_min_x;
	float chunk_min_z;
	float chunk_world_size;
	float texture_width;
	float texture_height;
	float sample_step_x;
	float sample_step_y;
	float normal_strength;
	float vertical_offset;
	float height_scale;
	float seed_offset_x;
	float seed_offset_y;
	int height_tex;
	int albedo_tex;
} terrain_bake;
]]

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

local function get_or_create_cry_albedo_texture(terrain)
	if terrain.albedo_texture and terrain.albedo_texture:IsValid() then
		return terrain.albedo_texture
	end

	local tile_width = 0
	local tile_height = 0

	for _, tile in ipairs(terrain.tiles or {}) do
		local _, width, height = assert(decode_terrain_texture_tile(tile))
		tile_width = math.max(tile_width, width)
		tile_height = math.max(tile_height, height)
	end

	local atlas_width = math.max(terrain.grid_width or 1, 1) * tile_width
	local atlas_height = math.max(terrain.grid_height or 1, 1) * tile_height
	local atlas_buffer = ffi.new("uint8_t[?]", atlas_width * atlas_height * 4)
	local atlas_ptr = ffi.cast("uint8_t *", atlas_buffer)
	local atlas_stride = atlas_width * 4

	for _, tile in ipairs(terrain.tiles or {}) do
		local _, width, height = assert(decode_terrain_texture_tile(tile))
		local dst_x = tile.x * tile_width * 4
		local dst_y = tile.y * tile_height

		for row = 0, tile_height - 1 do
			local v = tile_height > 1 and (row / (tile_height - 1)) or 0
			local dst = atlas_ptr + ((dst_y + row) * atlas_stride) + dst_x

			for column = 0, tile_width - 1 do
				local u = tile_width > 1 and (column / (tile_width - 1)) or 0
				local r, g, b, a = sample_terrain_tile_rgba(tile, u, v)
				local pixel = column * 4
				dst[pixel + 0] = math.floor(r + 0.5)
				dst[pixel + 1] = math.floor(g + 0.5)
				dst[pixel + 2] = math.floor(b + 0.5)
				dst[pixel + 3] = math.floor(a + 0.5)
			end
		end
	end

	terrain.albedo_texture = Texture.New{
		width = atlas_width,
		height = atlas_height,
		format = "r8g8b8a8_unorm",
		buffer = atlas_buffer,
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	return terrain.albedo_texture
end

local function get_cry_material_module()
	return import.loaded["goluwa/render3d/material.lua"] or
		import("goluwa/render3d/material.lua")
end

local guess_cry_surface_color

local function build_cry_surface_material_layer(surface_type)
	local Material = get_cry_material_module()
	local color = Color(1, 1, 1, 1)
	local roughness = 1
	local detail_strength = 1
	local effective_detail_scale = math.min(surface_type.detail_scale_x or 1, surface_type.detail_scale_y or 1)

	if surface_type.detail_material_path and surface_type.detail_material_path ~= "" then
		local material = Material.FromCryMTL(surface_type.detail_material_path)

		if material and not (material.GetError and material:GetError()) then
			if material.GetColorMultiplier then color = material:GetColorMultiplier() end

			if material.GetAlbedoTexture then
				surface_type.detail_albedo_texture = material:GetAlbedoTexture()
			end

			if material.cry_public_params and material.cry_public_params.DetailTextureStrength then
				detail_strength = tonumber(material.cry_public_params.DetailTextureStrength) or detail_strength
			end

			local diffuse_map_info = material.cry_texture_maps and material.cry_texture_maps.Diffuse or nil

			if diffuse_map_info then
				local tile_u = tonumber(diffuse_map_info.tile_u) or 1
				local tile_v = tonumber(diffuse_map_info.tile_v) or tile_u

				if tile_u > 0 and tile_v > 0 then
					effective_detail_scale = effective_detail_scale * math.sqrt(tile_u * tile_v)
				end
			end

			if material.GetRoughnessMultiplier then
				roughness = material:GetRoughnessMultiplier() or roughness
			end
		end
	end

	local checker_scale = 1 / math.max(effective_detail_scale, 0.0001)

	if color.r == 1 and color.g == 1 and color.b == 1 then
		color = guess_cry_surface_color(surface_type)
	end

	return {
		name = surface_type.name,
		detail_texture = surface_type.detail_albedo_texture,
		detail_strength = detail_strength,
		checker_scale = checker_scale,
		roughness = roughness,
		ambient_occlusion = 1,
		color_a = {color.r, color.g, color.b},
		color_b = {color.r, color.g, color.b},
	}
end

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

local function build_cry_surface_material_layers(terrain)
	if terrain.surface_material_layers then
		return terrain.surface_material_layers
	end

	local layers = {}

	for i = 1, math.min(#(terrain.surface_types or {}), 4) do
		local surface_type = terrain.surface_types[i]
		layers[i] = build_cry_surface_material_layer(surface_type)
	end

	for i = #layers + 1, 4 do
		layers[i] = {
			checker_scale = 1,
			roughness = 1,
			ambient_occlusion = 1,
			color_a = {1, 1, 1},
			color_b = {1, 1, 1},
		}
	end

	terrain.surface_material_layers = layers
	return layers
end

local function get_cry_layer_colors(layer)
	local color_a = layer.color_a or {1, 1, 1}
	local color_b = layer.color_b or color_a
	return Color(color_a[1] or 1, color_a[2] or 1, color_a[3] or 1, 1),
	Color(
		color_b[1] or color_a[1] or 1,
		color_b[2] or color_a[2] or 1,
		color_b[3] or color_a[3] or 1,
		1
	)
end

local function apply_cry_material_layers(material, layers)
	local layer1 = layers[1] or {}
	local layer2 = layers[2] or {}
	local layer3 = layers[3] or {}
	local layer4 = layers[4] or {}
	material:SetTerrainCheckerScales(
		Color(
			layer1.checker_scale or 1,
			layer2.checker_scale or 1,
			layer3.checker_scale or 1,
			layer4.checker_scale or 1
		)
	)
	material:SetTerrainLayer1ColorA(get_cry_layer_colors(layer1))
	material:SetTerrainLayer1ColorB(select(2, get_cry_layer_colors(layer1)))
	material:SetTerrainLayer1Texture(layer1.detail_texture)
	material:SetTerrainLayer2ColorA(get_cry_layer_colors(layer2))
	material:SetTerrainLayer2ColorB(select(2, get_cry_layer_colors(layer2)))
	material:SetTerrainLayer2Texture(layer2.detail_texture)
	material:SetTerrainLayer3ColorA(get_cry_layer_colors(layer3))
	material:SetTerrainLayer3ColorB(select(2, get_cry_layer_colors(layer3)))
	material:SetTerrainLayer3Texture(layer3.detail_texture)
	material:SetTerrainLayer4ColorA(get_cry_layer_colors(layer4))
	material:SetTerrainLayer4ColorB(select(2, get_cry_layer_colors(layer4)))
	material:SetTerrainLayer4Texture(layer4.detail_texture)
	material:SetTerrainLayerRoughness(
		Color(
			layer1.roughness or 0.9,
			layer2.roughness or 0.8,
			layer3.roughness or 0.7,
			layer4.roughness or 0.5
		)
	)
	material:SetTerrainLayerDetailStrength(
		Color(
			layer1.detail_strength or 1,
			layer2.detail_strength or 1,
			layer3.detail_strength or 1,
			layer4.detail_strength or 1
		)
	)
	material:SetTerrainLayerAmbientOcclusion(
		Color(
			layer1.ambient_occlusion or layer1.ao or 1,
			layer2.ambient_occlusion or layer2.ao or 1,
			layer3.ambient_occlusion or layer3.ao or 1,
			layer4.ambient_occlusion or layer4.ao or 1
		)
	)
end

local function build_cry_tile_material_weights(terrain, bounds, texture_size)
	if not terrain.surface_slot_data then return nil end

	texture_size = math.max(math.floor(texture_size or 0), 1)
	local world_size_x = math.max(bounds.max_x - bounds.min_x, 0.0001)
	local world_size_z = math.max(bounds.max_z - bounds.min_z, 0.0001)
	local slot_counts = {}

	for row = 0, texture_size - 1 do
		local v = (row + 0.5) / texture_size
		local world_z = bounds.min_z + v * world_size_z

		for column = 0, texture_size - 1 do
			local u = (column + 0.5) / texture_size
			local world_x = bounds.min_x + u * world_size_x
			local slot = sample_terrain_surface_slot_at_world(terrain, world_x, world_z)

			if slot > 0 and terrain.surface_types[slot] then
				slot_counts[slot] = (slot_counts[slot] or 0) + 1
			end
		end
	end

	local ranked_slots = {}

	for slot, count in pairs(slot_counts) do
		ranked_slots[#ranked_slots + 1] = {slot = slot, count = count}
	end

	table.sort(ranked_slots, function(a, b)
		if a.count == b.count then return a.slot < b.slot end

		return a.count > b.count
	end)

	local local_slots = {}
	local slot_to_channel = {}

	for i = 1, math.min(#ranked_slots, 4) do
		local slot = ranked_slots[i].slot
		local_slots[i] = slot
		slot_to_channel[slot] = i
	end

	if not local_slots[1] then return nil end

	local layers = {}

	for i = 1, 4 do
		local slot = local_slots[i]
		local surface_type = slot and terrain.surface_types[slot] or nil
		layers[i] = surface_type and
			build_cry_surface_material_layer(surface_type) or
			{
				checker_scale = 1,
				roughness = 1,
				ambient_occlusion = 1,
				color_a = {1, 1, 1},
				color_b = {1, 1, 1},
			}
	end

	local dominant_channel = slot_to_channel[local_slots[1]] or 1
	local buffer = ffi.new("uint8_t[?]", texture_size * texture_size * 4)
	local write_index = 0

	for row = 0, texture_size - 1 do
		local v = (row + 0.5) / texture_size
		local world_z = bounds.min_z + v * world_size_z

		for column = 0, texture_size - 1 do
			local u = (column + 0.5) / texture_size
			local world_x = bounds.min_x + u * world_size_x
			local slot = sample_terrain_surface_slot_at_world(terrain, world_x, world_z)
			local channel = slot_to_channel[slot] or dominant_channel
			buffer[write_index + 0] = channel == 1 and 255 or 0
			buffer[write_index + 1] = channel == 2 and 255 or 0
			buffer[write_index + 2] = channel == 3 and 255 or 0
			buffer[write_index + 3] = channel == 4 and 255 or 0
			write_index = write_index + 4
		end
	end

	return {
		texture = Texture.New{
			width = texture_size,
			height = texture_size,
			format = "r8g8b8a8_unorm",
			buffer = buffer,
			mip_map_levels = 1,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		},
		layers = layers,
		slots = local_slots,
	}
end

local function get_cry_chunk_bake_texture_size(terrain, chunk_world_size, minimum_size, maximum_size)
	minimum_size = minimum_size or 256
	maximum_size = maximum_size or 1024
	local world_size = math.max(terrain.world_size or 0, 1)
	local full_texture_size = terrain.editor_level and terrain.editor_level.texture_size or 0

	if full_texture_size <= 0 then return minimum_size end

	local scaled = math.ceil((chunk_world_size / world_size) * full_texture_size)
	return math.clamp(scaled, minimum_size, maximum_size)
end

local function build_cry_terrain_source(terrain)
	local ProceduralTerrainSource = import("addons/game/lua/terrain/source.lua")
	local world_size = math.max(terrain.world_size or 0, 1)
	local height_texture = get_or_create_cry_height_texture(terrain)
	local albedo_texture = get_or_create_cry_albedo_texture(terrain)
	local material_layers = build_cry_surface_material_layers(terrain)
	local source = ProceduralTerrainSource.New{
		HeightScale = terrain.heightmap_max_height,
		VerticalOffset = terrain.heightmap_max_height * 0.5,
		HasRealMaterialWeights = false,
		TerrainShaderGLSL = "",
		SceneShaderGLSL = string.format(
			[[
			vec2 getCryTerrainWorldUV(vec2 terrain_world_pos) {
				return clamp(vec2(terrain_world_pos.x / %.6f, -terrain_world_pos.y / %.6f), vec2(0.0), vec2(1.0));
			}

			float sampleSceneTerrainHeight01(vec2 _source_world_pos, vec2 terrain_world_pos) {
				return texture(TEXTURE(terrain_bake.height_tex), getCryTerrainWorldUV(terrain_world_pos)).r;
			}

			float sampleSceneTerrainSlope01(vec2 source_world_pos, vec2 terrain_world_pos, vec2 sample_step, float height_scale) {
				float h_left = sampleSceneTerrainHeight01(source_world_pos - vec2(sample_step.x, 0.0), terrain_world_pos - vec2(sample_step.x, 0.0)) * height_scale;
				float h_right = sampleSceneTerrainHeight01(source_world_pos + vec2(sample_step.x, 0.0), terrain_world_pos + vec2(sample_step.x, 0.0)) * height_scale;
				float h_down = sampleSceneTerrainHeight01(source_world_pos - vec2(0.0, sample_step.y), terrain_world_pos - vec2(0.0, sample_step.y)) * height_scale;
				float h_up = sampleSceneTerrainHeight01(source_world_pos + vec2(0.0, sample_step.y), terrain_world_pos + vec2(0.0, sample_step.y)) * height_scale;
				float dx = (h_right - h_left) / max(sample_step.x * 2.0, 0.0001);
				float dz = (h_up - h_down) / max(sample_step.y * 2.0, 0.0001);
				float slope = sqrt(dx * dx + dz * dz);
				float normal_y = 1.0 / sqrt(1.0 + slope * slope);
				return clamp(1.0 - normal_y, 0.0, 1.0);
			}

			float sampleSceneTerrainDisplacement01(vec2 _source_world_pos, vec2 _terrain_world_pos, float h01) {
				return h01;
			}

			vec4 sampleSceneTerrainMaterialWeights(vec2 _source_world_pos, vec2 _terrain_world_pos, float _elevation, float _h01, float _slope01) {
				return vec4(1.0, 0.0, 0.0, 0.0);
			}

			vec3 sampleSceneTerrainAlbedo(vec2 _source_world_pos, vec2 terrain_world_pos, float _elevation, float _h01, float _slope01) {
				return texture(TEXTURE(terrain_bake.albedo_tex), getCryTerrainWorldUV(terrain_world_pos)).rgb;
			}
		]],
			world_size,
			world_size
		),
		NormalShaderGLSL = "",
		MaterialLayers = material_layers,
	}

	function source:BuildBakeShaderExtraConfig(
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		texture_width,
		texture_height,
		normal_strength
	)
		texture_width = math.max(1, texture_width or 1)
		texture_height = math.max(1, texture_height or texture_width)
		normal_strength = normal_strength or 1
		return {
			textures = {height_texture, albedo_texture},
			custom_declarations = CRY_TERRAIN_BAKE_PUSH_CONSTANT_DECLARATIONS,
			fragment_push_constants = {
				size = ffi.sizeof(cry_terrain_bake_push_constant_t),
				get_data = function(_, _, pipeline)
					return cry_terrain_bake_push_constant_t(
						chunk_min_x,
						chunk_min_z,
						chunk_world_size,
						texture_width,
						texture_height,
						chunk_world_size / math.max(texture_width - 1, 1),
						chunk_world_size / math.max(texture_height - 1, 1),
						normal_strength,
						self.VerticalOffset,
						self.HeightScale,
						self.SeedOffset.x,
						self.SeedOffset.y,
						pipeline:GetTextureIndex(height_texture),
						pipeline:GetTextureIndex(albedo_texture)
					)
				end,
			},
		}
	end

	return source
end

local function get_procedural_terrain_hybrid_renderer()
	return import.loaded["addons/game/lua/terrain/render.lua"] or
		import("addons/game/lua/terrain/render.lua")
end

local CryTerrainHybridRenderer = {}
CryTerrainHybridRenderer.__index = CryTerrainHybridRenderer

function CryTerrainHybridRenderer.New(terrain)
	local ProceduralTerrainHybridRenderer = get_procedural_terrain_hybrid_renderer()
	setmetatable(CryTerrainHybridRenderer, {__index = ProceduralTerrainHybridRenderer})
	local chunk_world_size = math.max(
		math.floor((terrain.world_size or 0) * 0.5 + 0.5),
		terrain.tile_world_size or 512,
		512
	)
	local near_albedo_size = get_cry_chunk_bake_texture_size(
		terrain,
		math.max(chunk_world_size * 0.5, terrain.tile_world_size or 512),
		512,
		1024
	)
	local far_albedo_size = get_cry_chunk_bake_texture_size(terrain, chunk_world_size, 512, 1024)
	local self = ProceduralTerrainHybridRenderer.New{
		Name = "cry_terrain",
		Source = build_cry_terrain_source(terrain),
		ChunkWorldSize = chunk_world_size,
		UpdateInterval = 0.02,
		BuildsPerUpdate = 2,
		Roughness = 1,
		Metallic = 0,
		ChunkRings = {
			{
				chunk_world_size = math.max(chunk_world_size * 0.5, terrain.tile_world_size or 512),
				radius = 1,
				cast_shadows = true,
				mesh_resolution = Vec2() + 96,
				texture_size = near_albedo_size,
				height_texture_size = near_albedo_size + 1,
				normal_texture_size = near_albedo_size,
				material_texture_size = 32,
				normal_strength = 1,
				height_layers = 20,
				tessellation_factor = 12,
			},
			{
				chunk_world_size = chunk_world_size,
				radius = 2,
				cast_shadows = true,
				mesh_resolution = Vec2() + 72,
				texture_size = far_albedo_size,
				height_texture_size = far_albedo_size + 1,
				normal_texture_size = far_albedo_size,
				material_texture_size = 32,
				normal_strength = 1,
				height_layers = 14,
				tessellation_factor = 8,
			},
		},
	}
	setmetatable(self, CryTerrainHybridRenderer)
	self.TerrainData = terrain
	return self
end

function CryTerrainHybridRenderer:GetOrCreateTileRenderData(bounds, config, ring_index, patch_type, trim_rect)
	local render_data = get_procedural_terrain_hybrid_renderer().GetOrCreateTileRenderData(self, bounds, config, ring_index, patch_type, trim_rect)
	local terrain = self.TerrainData
	local material_info = terrain and
		build_cry_tile_material_weights(terrain, bounds, config.material_texture_size or config.texture_size or 32) or
		nil

	if material_info and render_data and render_data.material then
		if
			render_data.material_texture and
			render_data.material_texture ~= material_info.texture
		then
			render_data.material_texture:Remove()
		end

		render_data.material_texture = material_info.texture
		render_data.terrain_layer_slots = material_info.slots
		render_data.terrain_layer_names = {}

		for i = 1, 4 do
			local slot = material_info.slots and material_info.slots[i] or nil
			local surface_type = slot and terrain and terrain.surface_types and terrain.surface_types[slot] or nil
			render_data.terrain_layer_names[i] = surface_type and surface_type.name or nil
		end

		render_data.material:SetTerrainMaterialTexture(material_info.texture)
		apply_cry_material_layers(render_data.material, material_info.layers)
	elseif
		not (
			self.Source and
			self.Source.HasRealMaterialWeights
		) and
		render_data and
		render_data.material
	then
		render_data.terrain_layer_slots = nil
		render_data.terrain_layer_names = nil
		render_data.material:SetTerrainMaterialTexture(nil)
	end

	return render_data
end

function crylevel.SpawnTerrain(level_data, parent)
	local terrain = level_data and level_data.terrain

	if
		not terrain or
		not terrain.tiles or
		not terrain.tiles[1] or
		not terrain.height_data
	then
		return nil
	end

	local renderer = CryTerrainHybridRenderer.New(terrain):Start()
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

function crylevel.ResolveModelPath(steam, level_dir, model_path)
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
		local mounted = find_mounted_case_path(mounted_root, rest)

		if mounted then return mounted end

		local mounted_by_name = vfs.FindFileByNameRecursive(mounted_root .. "/", file_path.GetFileNameFromPath(rest))

		if mounted_by_name then return mounted_by_name end
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

		local entries = {}
		local layers_dir = level_dir .. "Layers/"

		for _, file_name in ipairs(vfs.Find(layers_dir) or {}) do
			if file_name:lower():ends_with(".lyr") then
				local path = layers_dir .. file_name
				local data, read_err = vfs.Read(path)

				if data then
					local layer_entries, parse_err = crylevel.ParseLayerData(data)

					if layer_entries then
						for _, entry in ipairs(layer_entries) do
							entry.model_path = crylevel.ResolveModelPath(steam, level_dir, entry.model_path)
							entries[#entries + 1] = entry
						end
					else
						wlog("failed to parse cry layer " .. tostring(path) .. ": " .. tostring(parse_err))
					end
				else
					wlog("failed to read cry layer " .. tostring(path) .. ": " .. tostring(read_err))
				end
			end
		end

		if not entries[1] then
			local level_name = level_dir:match("/([^/]+)/$") or ""
			local editor_level_path = level_dir .. level_name .. ".cry/level.editor_xml"
			local editor_level_data, editor_level_err = vfs.Read(editor_level_path)

			if editor_level_data then
				local editor_entries, parse_err = crylevel.ParseEditorVisualObjectsData(editor_level_data)

				if editor_entries then
					for _, entry in ipairs(editor_entries) do
						entry.transform_space = "editor_world"
						entry.model_path = crylevel.ResolveModelPath(steam, level_dir, entry.model_path)
						entries[#entries + 1] = entry
					end
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
		end

		local terrain = select(1, crylevel.LoadTerrainData(steam, level_dir))
		local vegetation_entries = {}
		local level_name = level_dir:match("/([^/]+)/$") or ""
		local editor_level_path = level_dir .. level_name .. ".cry/level.editor_xml"
		local vegetation_map_data = vfs.Read(editor_level_path)

		if vegetation_map_data then
			local prototypes, vegetation_map_err = crylevel.ParseVegetationMapData(vegetation_map_data)
			local vegetation_instances_data, vegetation_instances_err = vfs.Read(level_dir .. level_name .. ".cry/vegetationinstancesarray.editor_data")

			if prototypes and vegetation_instances_data then
				vegetation_entries = crylevel.ParseVegetationInstancesData(vegetation_instances_data, prototypes, terrain)

				for _, entry in ipairs(vegetation_entries) do
					entry.model_path = crylevel.ResolveModelPath(steam, level_dir, entry.model_path)
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

	function steam.SpawnCryLevel(level, parent)
		local Entity = import("goluwa/entities/entity.lua")
		local data = steam.LoadCryLevel(level)

		if steam.active_cry_terrain_renderer then
			steam.active_cry_terrain_renderer:Stop()
			steam.active_cry_terrain_renderer = nil
		end

		for _, child in ipairs(parent:GetChildrenList()) do
			if child.spawned_from_cry_level then child:Remove() end
		end

		steam.active_cry_terrain_renderer = crylevel.SpawnTerrain(data, parent)

		if true then
			for _, entry in ipairs(data.entries) do
				local transform_data = entry.transform_space == "editor_world" and
					crylevel.ConvertCryEditorWorldMatrixToEngineTransform(entry.world_matrix) or
					crylevel.ConvertCryWorldMatrixToEngineTransform(entry.world_matrix)
				local entity = Entity.New{Name = entry.name or "cry_object", Parent = parent}
				local transform = entity:AddComponent("transform")
				entity:AddComponent("visual")
				transform:SetPosition(transform_data.position)
				transform:SetRotation(transform_data.rotation)
				transform:SetScale(transform_data.scale)
				entity.visual:SetModelPath(entry.model_path)
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
		debug.trace()
		steam.cry_level_world:RemoveChildren()
		return steam.SpawnCryLevel(level_dir, steam.cry_level_world)
	end
end

return crylevel

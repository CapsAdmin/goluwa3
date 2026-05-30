local xml = import("goluwa/codecs/xml.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/helpers/file_path.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
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
	local attrs = info and info.attrs or nil

	if not attrs then return nil, "missing LevelInfo" end

	local heightmap_size = tonumber(attrs.HeightmapSize) or 0
	local heightmap_unit_size = tonumber(attrs.HeightmapUnitSize) or 0
	local terrain_sector_size = tonumber(attrs.TerrainSectorSizeInMeters) or 0
	local world_size = heightmap_size * heightmap_unit_size
	return {
		heightmap_size = heightmap_size,
		heightmap_unit_size = heightmap_unit_size,
		heightmap_max_height = tonumber(attrs.HeightmapMaxHeight) or 0,
		water_level = tonumber(attrs.WaterLevel) or 0,
		terrain_sector_size = terrain_sector_size,
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

	if not attrs then return nil, "missing Level root" end

	return {
		heightmap_width = tonumber(attrs.HeightmapWidth) or 0,
		heightmap_height = tonumber(attrs.HeightmapHeight) or 0,
		tile_count_x = tonumber(attrs.TileCountX) or 0,
		tile_count_y = tonumber(attrs.TileCountY) or 0,
		tile_resolution = tonumber(attrs.TileResolution) or 0,
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
		local r, g, b = data:byte(src, src + 2)
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

function crylevel.LoadTerrainData(level_dir)
	local level_data_path = level_dir .. "level.pak/leveldata.xml"
	local level_data_xml, level_data_err = vfs.Read(level_data_path)

	if not level_data_xml then
		return nil, level_data_err or ("failed to read " .. tostring(level_data_path))
	end

	local terrain, parse_err = crylevel.ParseLevelData(level_data_xml)

	if not terrain then return nil, parse_err end

	local tiles = {}
	local terrain_texture_dir = level_dir .. "terraintexture.pak/"
	local max_x = -1
	local max_y = -1

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

	for _, tile in ipairs(tiles) do
		terrain.tile_lookup[tile.y] = terrain.tile_lookup[tile.y] or {}
		terrain.tile_lookup[tile.y][tile.x] = tile
	end

	terrain.grid_width = max_x + 1
	terrain.grid_height = max_y + 1
	terrain.tile_world_size = get_terrain_texture_tile_size(terrain)
	return terrain
end

local function get_terrain_height_sample(terrain, sample_x, sample_y)
	if not terrain.height_data then return 0 end

	sample_x = math.clamp(
		math.floor(sample_x),
		0,
		(terrain.height_samples_width or terrain.height_samples_per_side) - 1
	)
	sample_y = math.clamp(
		math.floor(sample_y),
		0,
		(terrain.height_samples_height or terrain.height_samples_per_side) - 1
	)
	local offset = terrain.height_data_offset + (
			(
				sample_y * (
					terrain.height_samples_width or
					terrain.height_samples_per_side
				) + sample_x
			) * 2
		)
	local raw = read_u16_le(terrain.height_data, offset) or 0
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

	local width = terrain.height_samples_width or terrain.height_samples_per_side or 0
	local height = terrain.height_samples_height or terrain.height_samples_per_side or width

	if width <= 0 or height <= 0 then return 0 end

	sample_x = math.clamp(sample_x, 0, width - 1)
	sample_y = math.clamp(sample_y, 0, height - 1)
	local x0 = math.floor(sample_x)
	local y0 = math.floor(sample_y)
	local x1 = math.min(x0 + 1, width - 1)
	local y1 = math.min(y0 + 1, height - 1)
	local tx = sample_x - x0
	local ty = sample_y - y0
	local stride = width
	local base = terrain.height_data_offset or 1
	local raw00 = read_u16_le(terrain.height_data, base + ((y0 * stride + x0) * 2)) or 0
	local raw10 = read_u16_le(terrain.height_data, base + ((y0 * stride + x1) * 2)) or 0
	local raw01 = read_u16_le(terrain.height_data, base + ((y1 * stride + x0) * 2)) or 0
	local raw11 = read_u16_le(terrain.height_data, base + ((y1 * stride + x1) * 2)) or 0
	return bilerp(raw00, raw10, raw01, raw11, tx, ty)
end

sample_terrain_height01_at_world = function(terrain, world_x, world_z)
	if not terrain.height_data then return 0 end

	local width = terrain.height_samples_width or terrain.height_samples_per_side or 0
	local height = terrain.height_samples_height or terrain.height_samples_per_side or width

	if width <= 0 or height <= 0 then return 0 end

	local u, v = get_terrain_world_uv(terrain, world_x, world_z)
	local raw = sample_terrain_height_raw(terrain, u * (width - 1), v * (height - 1))
	return raw / 65535
end

local function sample_terrain_tile_rgba(tile, u, v)
	local buffer, width, height = assert(decode_terrain_texture_tile(tile))
	u = math.clamp(u, 0, 1)
	v = math.clamp(v, 0, 1)
	local sample_x = u * (width - 1)
	local sample_y = v * (height - 1)
	local x0 = math.floor(sample_x)
	local y0 = math.floor(sample_y)
	local x1 = math.min(x0 + 1, width - 1)
	local y1 = math.min(y0 + 1, height - 1)
	local tx = sample_x - x0
	local ty = sample_y - y0

	local function read_pixel(x, y)
		local index = (y * width + x) * 4
		return buffer[index + 0], buffer[index + 1], buffer[index + 2], buffer[index + 3]
	end

	local r00, g00, b00, a00 = read_pixel(x0, y0)
	local r10, g10, b10, a10 = read_pixel(x1, y0)
	local r01, g01, b01, a01 = read_pixel(x0, y1)
	local r11, g11, b11, a11 = read_pixel(x1, y1)
	return bilerp(r00, r10, r01, r11, tx, ty),
	bilerp(g00, g10, g01, g11, tx, ty),
	bilerp(b00, b10, b01, b11, tx, ty),
	bilerp(a00, a10, a01, a11, tx, ty)
end

local function sample_terrain_albedo_at_world(terrain, world_x, world_z)
	local tile_world_size = math.max(terrain.tile_world_size or 0, 1)
	local max_x = math.max((terrain.grid_width or 1) - 1, 0)
	local max_y = math.max((terrain.grid_height or 1) - 1, 0)
	local tile_x = math.clamp(math.floor(world_x / tile_world_size), 0, max_x)
	local tile_y = math.clamp(math.floor((-world_z) / tile_world_size), 0, max_y)
	local row = terrain.tile_lookup and terrain.tile_lookup[tile_y] or nil
	local tile = row and row[tile_x] or nil

	if not tile then return 127, 127, 127, 255 end

	local local_x = world_x - tile_x * tile_world_size
	local local_y = (-world_z) - tile_y * tile_world_size
	return sample_terrain_tile_rgba(tile, local_x / tile_world_size, local_y / tile_world_size)
end

local function create_cpu_texture(width, height, format, buffer, sampler)
	return Texture.New{
		width = width,
		height = height,
		format = format,
		buffer = buffer,
		mip_map_levels = 1,
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src"},
		},
		sampler = sampler or
			{
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
	}
end

local function build_cry_terrain_source(terrain)
	local white = {1, 1, 1}
	return {
		HeightScale = terrain.heightmap_max_height,
		VerticalOffset = terrain.heightmap_max_height * 0.5,
		MaterialLayers = {
			{
				checker_scale = 1,
				roughness = 1,
				ambient_occlusion = 1,
				color_a = white,
				color_b = white,
			},
			{
				checker_scale = 1,
				roughness = 1,
				ambient_occlusion = 1,
				color_a = white,
				color_b = white,
			},
			{
				checker_scale = 1,
				roughness = 1,
				ambient_occlusion = 1,
				color_a = white,
				color_b = white,
			},
			{
				checker_scale = 1,
				roughness = 1,
				ambient_occlusion = 1,
				color_a = white,
				color_b = white,
			},
		},
	}
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
				texture_size = 256,
				height_texture_size = 257,
				normal_texture_size = 256,
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
				texture_size = 192,
				height_texture_size = 193,
				normal_texture_size = 192,
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

function CryTerrainHybridRenderer:CreateTileTextures(bounds, config)
	local terrain = self.TerrainData
	local world_size_x = bounds.max_x - bounds.min_x
	local world_size_z = bounds.max_z - bounds.min_z
	local height_size = config.height_texture_size or
		config.displacement_texture_size or
		config.texture_size or
		128
	local albedo_size = config.texture_size or 128
	local normal_size = config.normal_texture_size or albedo_size
	local material_size = config.material_texture_size or 32
	local height_buffer = ffi.new("float[?]", height_size * height_size)
	local albedo_buffer = ffi.new("uint8_t[?]", albedo_size * albedo_size * 4)
	local normal_buffer = ffi.new("uint8_t[?]", normal_size * normal_size * 4)
	local material_buffer = ffi.new("uint8_t[?]", material_size * material_size * 4)

	for y = 0, height_size - 1 do
		local v = height_size > 1 and (y / (height_size - 1)) or 0
		local world_z = bounds.min_z + v * world_size_z

		for x = 0, height_size - 1 do
			local u = height_size > 1 and (x / (height_size - 1)) or 0
			local world_x = bounds.min_x + u * world_size_x
			height_buffer[y * height_size + x] = sample_terrain_height01_at_world(terrain, world_x, world_z)
		end
	end

	for y = 0, albedo_size - 1 do
		local v = albedo_size > 1 and (y / (albedo_size - 1)) or 0
		local world_z = bounds.min_z + v * world_size_z

		for x = 0, albedo_size - 1 do
			local u = albedo_size > 1 and (x / (albedo_size - 1)) or 0
			local world_x = bounds.min_x + u * world_size_x
			local r, g, b, a = sample_terrain_albedo_at_world(terrain, world_x, world_z)
			local index = (y * albedo_size + x) * 4
			albedo_buffer[index + 0] = math.floor(math.clamp(r, 0, 255) + 0.5)
			albedo_buffer[index + 1] = math.floor(math.clamp(g, 0, 255) + 0.5)
			albedo_buffer[index + 2] = math.floor(math.clamp(b, 0, 255) + 0.5)
			albedo_buffer[index + 3] = math.floor(math.clamp(a, 0, 255) + 0.5)
		end
	end

	local normal_step_x = world_size_x / math.max(normal_size - 1, 1)
	local normal_step_z = world_size_z / math.max(normal_size - 1, 1)
	local height_scale = self.HeightScale
	local normal_strength = config.normal_strength or 1

	for y = 0, normal_size - 1 do
		local v = normal_size > 1 and (y / (normal_size - 1)) or 0
		local world_z = bounds.min_z + v * world_size_z

		for x = 0, normal_size - 1 do
			local u = normal_size > 1 and (x / (normal_size - 1)) or 0
			local world_x = bounds.min_x + u * world_size_x
			local h_left = sample_terrain_height01_at_world(terrain, world_x - normal_step_x, world_z) * height_scale
			local h_right = sample_terrain_height01_at_world(terrain, world_x + normal_step_x, world_z) * height_scale
			local h_down = sample_terrain_height01_at_world(terrain, world_x, world_z - normal_step_z) * height_scale
			local h_up = sample_terrain_height01_at_world(terrain, world_x, world_z + normal_step_z) * height_scale
			local nx = (h_left - h_right) * normal_strength
			local ny = (h_down - h_up) * normal_strength
			local nz = normal_step_x + normal_step_z
			local length = math.sqrt(nx * nx + ny * ny + nz * nz)

			if length <= 0.000001 then
				nx = 0
				ny = 0
				nz = 1
				length = 1
			end

			nx = nx / length
			ny = ny / length
			nz = nz / length
			local index = (y * normal_size + x) * 4
			normal_buffer[index + 0] = math.floor(math.clamp((nx * 0.5 + 0.5) * 255, 0, 255) + 0.5)
			normal_buffer[index + 1] = math.floor(math.clamp((ny * 0.5 + 0.5) * 255, 0, 255) + 0.5)
			normal_buffer[index + 2] = math.floor(math.clamp((nz * 0.5 + 0.5) * 255, 0, 255) + 0.5)
			normal_buffer[index + 3] = 255
		end
	end

	for y = 0, material_size - 1 do
		for x = 0, material_size - 1 do
			local index = (y * material_size + x) * 4
			material_buffer[index + 0] = 255
			material_buffer[index + 1] = 0
			material_buffer[index + 2] = 0
			material_buffer[index + 3] = 0
		end
	end

	return create_cpu_texture(height_size, height_size, "r32_sfloat", height_buffer),
	create_cpu_texture(albedo_size, albedo_size, "r8g8b8a8_srgb", albedo_buffer),
	create_cpu_texture(normal_size, normal_size, "r8g8b8a8_unorm", normal_buffer),
	create_cpu_texture(material_size, material_size, "r8g8b8a8_unorm", material_buffer)
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

		local terrain = select(1, crylevel.LoadTerrainData(level_dir))
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
		local Entity = import("goluwa/ecs/entity.lua")
		local data = steam.LoadCryLevel(level)

		if steam.active_cry_terrain_renderer then
			steam.active_cry_terrain_renderer:Stop()
			steam.active_cry_terrain_renderer = nil
		end

		for _, child in ipairs(parent:GetChildrenList()) do
			if child.spawned_from_cry_level then child:Remove() end
		end

		steam.active_cry_terrain_renderer = crylevel.SpawnTerrain(data, parent)

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

		return data
	end

	function steam.SetCryLevel(level)
		local Entity = import("goluwa/ecs/entity.lua")
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

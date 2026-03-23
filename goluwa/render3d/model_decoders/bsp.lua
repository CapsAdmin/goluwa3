local codec = import("goluwa/codec.lua")
local timer = import("goluwa/timer.lua")
local steam = import("goluwa/steam.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Quat = import("goluwa/structs/quat.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local transform = import("goluwa/ecs/components/3d/transform.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local R = vfs.GetAbsolutePath
local ffi = require("ffi")
local bit = require("bit")
local Entity = import("goluwa/ecs/entity.lua")
local utility = import("goluwa/utility.lua")
local physics
local CUBEMAPS = true
steam.loaded_bsp = steam.loaded_bsp or {}
local scale = 1 / 0.0254
local skyboxes = {
	["gm_construct"] = {AABB(-400, -400, 255, 400, 400, 320) * scale, 0.003},
	["gm_construct_remaster"] = {AABB(-400, -400, 255, 400, 400, 320) * scale, 0.003},
	["gm_flatgrass"] = {AABB(-400, -400, -430, 400, 400, -360) * scale, 0.003},
	["gm_bluehills_test3"] = {AABB(130, 130, 340, 340, 320, 380) * scale, 0},
	["gm_atomic"] = {AABB(-210, -210, 40, 210, 210, 210) * scale, 0},
	["de_bank"] = {AABB(115, -74, -77, 261, 64, -28) * scale, 0.003},
	["rp_hometown1999"] = {AABB(78, -61, -1, 98, -45, 5) * scale, 0.003},
	["gm_freespace_13"] = {AABB(-500, -500, 200, 500, 500, 600) * scale, 0},
}
local BSP_LUMP_PLANES = 2
local BSP_CONTENTS_SOLID = 0x1
local BSP_CONTENTS_WINDOW = 0x2
local BSP_CONTENTS_GRATE = 0x8
local BSP_CONTENTS_PLAYERCLIP = 0x10000
local BSP_CONTENTS_MONSTERCLIP = 0x20000
local BSP_CONTENTS_DETAIL = 0x8000000
local BSP_COLLISION_CONTENTS_MASK = bit.bor(
	BSP_CONTENTS_SOLID,
	BSP_CONTENTS_WINDOW,
	BSP_CONTENTS_GRATE,
	BSP_CONTENTS_PLAYERCLIP,
	BSP_CONTENTS_MONSTERCLIP
)
local BRUSH_POINT_EPSILON = 0.01

local function get_physics_modules()
	if not physics and (PHYSICS or import.loaded["goluwa/physics.lua"]) then
		physics = import("goluwa/physics.lua")
	end

	return physics
end

local function build_bounds_from_vertices(vertices)
	if not (vertices and vertices[1]) then return nil end

	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, vertex in ipairs(vertices) do
		local pos = vertex.pos

		if type(pos) == "cdata" then
			bounds:ExpandVec3(pos)
		else
			bounds:ExpandVec3(Vec3(pos[1], pos[2], pos[3]))
		end
	end

	return bounds
end

local function source_pos_to_engine(pos)
	return Vec3(-pos.y, pos.z, -pos.x) * steam.source2meters
end

local function source_plane_to_engine(plane)
	return {
		normal = Vec3(-plane.normal.y, plane.normal.z, -plane.normal.x),
		dist = plane.dist * steam.source2meters,
	}
end

local function is_collidable_brush(brush)
	return brush and
		brush.numsides >= 4 and
		bit.band(brush.contents or 0, BSP_COLLISION_CONTENTS_MASK) ~= 0
end

local function intersect_brush_planes(plane_a, plane_b, plane_c)
	local n1 = plane_a.normal
	local n2 = plane_b.normal
	local n3 = plane_c.normal
	local n2_cross_n3 = n2:GetCross(n3)
	local determinant = n1:Dot(n2_cross_n3)

	if math.abs(determinant) <= 0.000001 then return nil end

	return (
			n2_cross_n3 * plane_a.dist + n3:GetCross(n1) * plane_b.dist + n1:GetCross(n2) * plane_c.dist
		) / determinant
end

local function is_point_inside_brush(point, planes)
	for _, plane in ipairs(planes) do
		if point:Dot(plane.normal) - plane.dist > BRUSH_POINT_EPSILON then
			return false
		end
	end

	return true
end

local function get_brush_planes(header, brush)
	local planes = {}

	for side_index = 0, brush.numsides - 1 do
		local side = header.brushsides[brush.firstside + side_index + 1]

		if side and side.planenum then
			local plane = header.planes[side.planenum + 1]

			if plane then planes[#planes + 1] = plane end
		end
	end

	return planes
end

local function build_brush_hull(header, brush, planes)
	local physics = get_physics_modules()

	if not (physics and physics.Normalize and header.planes) then return nil end

	planes = planes or get_brush_planes(header, brush)

	if #planes < 4 then return nil end

	local points = {}
	local seen = {}

	for i = 1, #planes - 2 do
		for j = i + 1, #planes - 1 do
			for k = j + 1, #planes do
				local point = intersect_brush_planes(planes[i], planes[j], planes[k])

				if point and is_point_inside_brush(point, planes) then
					local engine_point = source_pos_to_engine(point)
					local key = string.format("%.3f:%.3f:%.3f", engine_point.x, engine_point.y, engine_point.z)

					if not seen[key] then
						seen[key] = true
						points[#points + 1] = engine_point
					end
				end
			end
		end
	end

	if #points < 4 then return nil end

	return physics.Normalize(points, BRUSH_POINT_EPSILON)
end

local function build_primitive_from_hull(hull, brush_planes)
	if
		not (
			hull and
			hull.bounds_min and
			hull.bounds_max and
			brush_planes and
			brush_planes[1]
		)
	then
		return nil
	end

	return {
		brush_planes = brush_planes,
		aabb = AABB(
			hull.bounds_min.x,
			hull.bounds_min.y,
			hull.bounds_min.z,
			hull.bounds_max.x,
			hull.bounds_max.y,
			hull.bounds_max.z
		),
	}
end

local function build_source_model_from_meshes(meshes, owner)
	local source_model = {
		Owner = owner,
		Visible = true,
		WorldSpaceVertices = true,
		Primitives = {},
		AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge),
	}

	for _, data in ipairs(meshes or {}) do
		local mesh = data.mesh
		local vertices = mesh and
			mesh.Vertices or
			mesh and
			mesh.GetVertices and
			mesh:GetVertices()
			or
			mesh

		if vertices and vertices[1] then
			local polygon = mesh and mesh.Vertices and mesh or {Vertices = vertices}
			local primitive_bounds = mesh and mesh.AABB or build_bounds_from_vertices(vertices)

			if primitive_bounds then
				source_model.Primitives[#source_model.Primitives + 1] = {
					polygon3d = polygon,
					aabb = primitive_bounds,
				}
				source_model.AABB:Expand(primitive_bounds)
			end
		end
	end

	if not source_model.Primitives[1] then return nil end

	return source_model
end

local function build_bsp_brush_model(header, owner)
	local model = {
		Owner = owner,
		Visible = true,
		WorldSpaceVertices = true,
		Primitives = {},
		AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge),
	}

	for _, brush in ipairs(header.brushes or {}) do
		if is_collidable_brush(brush) then
			local source_planes = get_brush_planes(header, brush)
			local brush_planes = {}

			for i, plane in ipairs(source_planes) do
				brush_planes[i] = source_plane_to_engine(plane)
			end

			local primitive = build_primitive_from_hull(build_brush_hull(header, brush, source_planes), brush_planes)

			if primitive and primitive.aabb then
				model.Primitives[#model.Primitives + 1] = primitive
				model.AABB:Expand(primitive.aabb)
			end
		end
	end

	if not model.Primitives[1] then return nil end

	return model
end

local function build_bsp_physics_body(header, render_meshes, displacement_meshes, owner)
	local collidable_brushes = 0

	for _, brush in ipairs(header.brushes or {}) do
		if is_collidable_brush(brush) then
			collidable_brushes = collidable_brushes + 1
		end
	end

	local brush_model = build_bsp_brush_model(header, owner)
	local render_model = build_source_model_from_meshes(render_meshes, owner)
	local shapes = {}
	local mode = "empty"
	local primitive_count = 0
	local displacement_primitives = displacement_meshes and #displacement_meshes or 0

	if brush_model then
		shapes[#shapes + 1] = {Model = brush_model}
		primitive_count = primitive_count + #brush_model.Primitives
		mode = "brushes"
	end

	if displacement_meshes and displacement_meshes[1] then
		for _, shape in ipairs(displacement_meshes) do
			shapes[#shapes + 1] = shape
		end

		primitive_count = primitive_count + displacement_primitives
		mode = mode == "brushes" and "brushes+displacements" or "displacements"
	end

	if not shapes[1] and render_model then
		shapes[#shapes + 1] = {Model = render_model}
		primitive_count = #render_model.Primitives
		mode = "render_fallback"
	end

	if not shapes[1] then
		return nil,
		{
			mode = mode,
			collidable_brushes = collidable_brushes,
			displacement_primitives = displacement_primitives,
			primitives = primitive_count,
		}
	end

	return {
		Shapes = shapes,
		MotionType = "static",
		Friction = 0.85,
		Restitution = 0,
		WorldGeometry = true,
	},
	{
		mode = mode,
		collidable_brushes = collidable_brushes,
		displacement_primitives = displacement_primitives,
		primitives = primitive_count,
	}
end

local function get_displacement_corners(header, info)
	local base_face = header.faces[1 + info.MapFace]
	local start_corner_dist = math.huge
	local start_corner = 0
	local corners = {}

	for j = 1, 4 do
		local surfedge = header.surfedges[1 + base_face.firstedge + (j - 1)]
		local edge = header.edges[1 + math.abs(surfedge)]
		local vertex = edge[1 + (surfedge < 0 and 1 or 0)]
		local corner = header.vertices[1 + vertex]
		local distance = corner:Distance(info.startPosition)

		if distance < start_corner_dist then
			start_corner_dist = distance
			start_corner = j - 1
		end

		corners[j] = corner
	end

	return corners, start_corner
end

local function build_displacement_heightmap_shape(header, info, lerp_corners)
	local corners, start_corner = get_displacement_corners(header, info)
	local dims = 2 ^ info.power + 1
	local resolution = dims - 1
	local top_left = source_pos_to_engine(corners[1 + (start_corner + 0) % 4])
	local top_right = source_pos_to_engine(corners[1 + (start_corner + 1) % 4])
	local bottom_left = source_pos_to_engine(corners[1 + (start_corner + 3) % 4])
	local bottom_right = source_pos_to_engine(corners[1 + (start_corner + 2) % 4])
	local right_vector = ((top_right - top_left) + (bottom_right - bottom_left)) * 0.5
	local forward_vector = ((bottom_left - top_left) + (bottom_right - top_right)) * 0.5
	local width = right_vector:GetLength()
	local depth = forward_vector:GetLength()

	if width <= 0.0001 or depth <= 0.0001 then return nil end

	local right = right_vector / width
	local up = forward_vector:GetCross(right):GetNormalized()

	if up:GetLength() <= 0.0001 then return nil end

	local forward = right:GetCross(up):GetNormalized()
	local center = (top_left + top_right + bottom_left + bottom_right) / 4
	local heights = {}
	local min_height = math.huge
	local max_height = -math.huge

	for y = 1, dims do
		for x = 1, dims do
			local source_pos = select(1, lerp_corners(dims, corners, start_corner, info, x, y))
			local world_pos = source_pos_to_engine(source_pos)
			local u = (x - 1) / resolution
			local v = (y - 1) / resolution
			local plane_pos = center + right * ((u - 0.5) * width) + forward * ((v - 0.5) * depth)
			local height = (world_pos - plane_pos):Dot(up)
			heights[(y - 1) * dims + x] = height
			min_height = math.min(min_height, height)
			max_height = math.max(max_height, height)
		end
	end

	local height_range = max_height - min_height
	local mid_height = (min_height + max_height) * 0.5
	local pixels = {}

	for i = 1, #heights do
		local normalized = 0.5

		if height_range > 0.0001 then
			normalized = (heights[i] - min_height) / height_range
		end

		pixels[i] = normalized * 255
	end

	local heightmap = {
		width = resolution,
		height = resolution,
		GetSize = function(self)
			return Vec2(self.width, self.height)
		end,
		GetRawPixelColor = function(self, x, y)
			x = math.clamp(math.floor(x), 0, resolution)
			y = math.clamp(math.floor(y), 0, resolution)
			local value = pixels[y * dims + x + 1] or 127.5
			return value, value, value, value
		end,
	}
	local rotation_matrix = Matrix33()
	rotation_matrix.m00 = right.x
	rotation_matrix.m01 = right.y
	rotation_matrix.m02 = right.z
	rotation_matrix.m10 = up.x
	rotation_matrix.m11 = up.y
	rotation_matrix.m12 = up.z
	rotation_matrix.m20 = forward.x
	rotation_matrix.m21 = forward.y
	rotation_matrix.m22 = forward.z
	return {
		Heightmap = heightmap,
		Size = Vec2(width, depth),
		Resolution = Vec2(resolution, resolution),
		Height = height_range > 0.0001 and height_range or 1,
		Pow = 1,
		Position = center + up * mid_height,
		Rotation = rotation_matrix:GetRotation(Quat()):GetNormalized(),
	}
end

function steam.SetMap(name)
	if
		steam.bsp_world and
		steam.bsp_world.IsValid and
		steam.bsp_world:IsValid() and
		steam.bsp_world:HasComponent("rigid_body")
	then
		steam.bsp_world:RemoveComponent("rigid_body")
	end

	if tonumber(name) then
		local workshop_id = tonumber(name)
		local info = codec.LookupInFile("luadata", "workshop_maps.cfg", workshop_id)

		if info and vfs.IsFile(info.path) then
			steam.MountSourceGame(info.appid)
			vfs.Mount(info.path, "maps/")
			steam.SetMap(info.name)
		else
			steam.DownloadWorkshop(workshop_id, function(path, info)
				local name = info.publishedfiledetails[1].filename:match(".+/(.+)%.bsp")
				local appid = info.publishedfiledetails[1].creator_app_id
				codec.StoreInFile(
					"luadata",
					"workshop_maps.cfg",
					workshop_id,
					{
						path = path,
						name = name,
						appid = appid,
					}
				)
				steam.MountSourceGame(appid)
				vfs.Mount(path, "maps/")
				steam.SetMap(name)
			end)
		end

		return
	end

	local path = "maps/" .. name .. ".bsp"
	steam.bsp_world = steam.bsp_world or Entity.New({Name = "bsp_world"})
	steam.bsp_world:SetName(name)
	steam.bsp_world:AddComponent("transform")
	steam.bsp_world:AddComponent("model")
	steam.bsp_world.model:SetModelPath(path)
	-- Note: SetPhysicsModelPath removed - physics component not yet ported
	steam.bsp_world:RemoveChildren()
	-- Store the relative path for later lookup
	steam.bsp_world.bsp_relative_path = path

	-- hack because promises will force SetModelPath to run one frame later
	timer.Delay(0.1, function()
		tasks.WaitForTask(path, function()
			utility.PushTimeWarning()

			-- The resolved path will be available after the model is loaded
			if steam.bsp_world.bsp_resolved_path then
				steam.SpawnMapEntities(steam.bsp_world.bsp_resolved_path, steam.bsp_world)
			else
				wlog("BSP model loaded but no resolved path available")
			end

			utility.PopTimeWarning("spawning map entities")
		end)
	end)
end

do
	local function init()
		do
			return
		end

		--print("NYI")
		local tex = Texture.New("cube_map")
		tex:SetMinFilter("linear")
		tex:SetMagFilter("linear")
		tex:SetWrapS("clamp_to_edge")
		tex:SetWrapT("clamp_to_edge")
		tex:SetWrapR("clamp_to_edge")
		return tex
	end

	function steam.LoadSkyTexture(name)
		do
			return
		end

		if not name or name == "painted" then name = "sky_wasteland02" end

		steam.sky_tex = init()
		logn("using ", name, " as sky texture")
		steam.sky_tex:LoadCubemap("materials/skybox/" .. name .. ".vmt")
	end

	function steam.GetSkyTexture()
		do
			return nil
		end

		if not steam.sky_tex then
			steam.sky_tex = init()
			steam.LoadSkyTexture()
		end

		return steam.sky_tex
	end
end

local function read_lump_data(what, bsp_file, header, index, size, struct)
	local out = {}
	local lump = header.lumps[index]

	if lump.filelen == 0 then return end

	local length = lump.filelen / size
	bsp_file:SetPosition(lump.fileofs)

	if type(struct) == "function" then
		for i = 1, length do
			out[i] = struct()

			if i % 1000 == 0 then
				tasks.ReportProgress(what, length)
				tasks.Wait()
			end
		end
	else
		for i = 1, length do
			out[i] = bsp_file:ReadStructure(struct)

			if i % 1000 == 0 then
				tasks.ReportProgress(what, length)
				tasks.Wait()
			end
		end
	end

	tasks.ReportProgress(what, length)
	tasks.Wait()
	return out
end

function steam.LoadMap(path)
	path = assert(R(path) or nil)

	-- Check if already loaded
	if steam.loaded_bsp[path] then
		logn("map already loaded: ", path)
		return steam.loaded_bsp[path]
	end

	logn("loading map: ", path)
	local bsp_file = assert(vfs.Open(path))

	if bsp_file:GetSize() == 0 then error("map is empty? (size is 0)") end

	local header = bsp_file:ReadStructure([[
	long ident; // BSP file identifier
	long version; // BSP file version
	]])

	do
		local info = skyboxes[path:match(".+/(.+)%.bsp")]

		if info then
			header.sky_aabb = info[1]
			header.sky_scale = info[2]
		end
	end

	do
		local struct = [[
			int	fileofs;	// offset into file (bytes)
			int	filelen;	// length of lump (bytes)
			int	version;	// lump format version
			char fourCC[4];	// lump ident code
		]]
		local struct_21 = [[
			int	version;	// lump format version
			int	fileofs;	// offset into file (bytes)
			int	filelen;	// length of lump (bytes)
			char fourCC[4];	// lump ident code
		]]

		if header.version > 21 then struct = struct_21 end

		header.lumps = {}

		for i = 1, 64 do
			header.lumps[i] = bsp_file:ReadStructure(struct)
		end

		tasks.ReportProgress("reading lumps", 64)
		tasks.Wait()
	end

	header.map_revision = bsp_file:ReadLong()

	if steam.debug then
		logn("BSP ", header.ident)
		logn("VERSION ", header.version)
		logn("REVISION ", header.map_revision)
	end

	do
		tasks.Wait()
		tasks.Report("mounting pak") -- pak
		local lump = header.lumps[41]
		local length = lump.filelen
		bsp_file:SetPosition(lump.fileofs)
		local pak = bsp_file:ReadBytes(length)
		local name = "os:cache/temp_bsp.zip"
		vfs.Write(name, pak)
		local ok, err = vfs.Mount(R(name))

		if not vfs.IsDirectory(R(name)) then
			wlog("cannot mount bsp zip " .. name .. " because the zip file is not a directory")
			wlog("assets from this map will be missing")
		end
	end

	do
		tasks.Wait()

		local function unpack_numbers(str)
			str = str:gsub("%s+", " ")
			local t = str:split(" ")

			for k, v in ipairs(t) do
				t[k] = tonumber(v)
			end

			return unpack(t)
		end

		local entities = {}
		local i = 1
		bsp_file:PushPosition(header.lumps[1].fileofs)

		for vdf in bsp_file:ReadString():gmatch("{(.-)}") do
			local ent = {}

			for k, v in vdf:gmatch([["(.-)" "(.-)"]]) do
				if k == "angles" then
					v = Ang3(unpack_numbers(v))
				elseif k == "_light" or k == "_ambient" then
					-- Source _light format: "R G B brightness" where R,G,B are 0-255 sRGB, brightness is intensity
					local r, g, b, brightness = unpack_numbers(v)
					-- Convert sRGB (0-255) to linear (0-1) using gamma 2.2 approximation
					v = {
						r = ((r or 0) / 255) ^ 2.2,
						g = ((g or 0) / 255) ^ 2.2,
						b = ((b or 0) / 255) ^ 2.2,
						brightness = brightness or 300,
					}
				elseif k:find("color", nil, true) then
					v = Color.FromBytes(unpack_numbers(v))
				elseif
					k == "origin" or
					k:find("dir", nil, true) or
					k:find("mins", nil, true) or
					k:find("maxs", nil, true)
				then
					v = Vec3(unpack_numbers(v))
				end

				ent[k] = tonumber(v) or v
			end

			ent.vdf = vdf
			ent.classname = ent.classname or "unknown"

			if header.sky_aabb and ent.classname == "sky_camera" then
				header.sky_origin = ent.origin
				header.sky_scale = header.sky_scale + ent.scale
			end

			entities[i] = ent
			i = i + 1

			if i % 100 == 0 then tasks.Wait() end
		end

		bsp_file:PopPosition()
		header.entities = entities
	end

	do
		tasks.Wait()
		tasks.Report("reading game lump")
		local lump = header.lumps[36]
		bsp_file:SetPosition(lump.fileofs)
		local game_lumps = bsp_file:ReadLong()

		for _ = 1, game_lumps do
			local id = bsp_file:ReadBytes(4)
			local flags = bsp_file:ReadShort()
			local version = bsp_file:ReadShort()
			local fileofs = bsp_file:ReadLong()
			local filelen = bsp_file:ReadLong()

			if id == "prps" then
				bsp_file:PushPosition(fileofs)
				local count
				count = bsp_file:ReadLong()
				local paths = {}

				for i = 1, count do
					local str = bsp_file:ReadString(128, true)

					if str ~= "" then paths[i] = str end
				end

				count = bsp_file:ReadLong()
				local leafs = {}

				for i = 1, count do
					leafs[i] = bsp_file:ReadShort()
				end

				count = bsp_file:ReadLong()
				local lump_size = ((filelen + fileofs) - bsp_file:GetPosition()) / count

				for i = 1, count do
					local pos = bsp_file:GetPosition()
					local lump = bsp_file:ReadStructure([[
						vec3 origin; // origin
						ang3 angles; // orientation (pitch yaw roll)

						unsigned short prop_type; // index into model name dictionary
						unsigned short first_leaf; // index into leaf array
						unsigned short leaf_count; // solidity type
						byte solid;
						byte flags; // model skin numbers

						int skin;
						float fade_min_dist;
						float fade_max_dist;

						vec3 lighting_origin; // for lighting
					]])

					if version >= 5 then lump.forced_fade_scale = bsp_file:ReadFloat() end

					if version == 6 or version == 7 then
						lump.min_dx_level = bsp_file:ReadUnsignedShort()
						lump.max_dx_level = bsp_file:ReadUnsignedShort()
					end

					if version >= 8 then
						lump.min_cpu_level = bsp_file:ReadUnsignedByte()
						lump.max_cpu_level = bsp_file:ReadUnsignedByte()
						lump.min_gpu_level = bsp_file:ReadUnsignedByte()
						lump.max_gpu_level = bsp_file:ReadUnsignedByte()
					end

					if version >= 7 then lump.rendercolor = bsp_file:ReadByteColor() end

					if version == 11 then
						-- not sure what this padding is
						bsp_file:Advance(4)

						if version == 9 or version == 10 then
							lump.disable_xbox360 = bsp_file:ReadBoolean()
						end

						if version >= 10 then
							lump.flags_ex = bsp_file:ReadUnsignedLong()
						end

						if version >= 11 then lump.uniform_scale = bsp_file:ReadFloat() end
					else
						local remaining = tonumber(lump_size - (bsp_file:GetPosition() - pos))
						bsp_file:Advance(remaining)
					--local bytes = bsp_file:ReadBytes(remaining)
					end

					lump.model = paths[lump.prop_type + 1] or paths[1]
					lump.classname = "static_entity"
					list.insert(header.entities, lump)

					if i % 100 == 0 then
						tasks.Wait()
						tasks.ReportProgress("reading static props", count)
					end
				end

				bsp_file:PopPosition()
			end
		--[[if id == "prpd" then
				bsp_file:PushPosition(fileofs)

				local count = bsp_file:ReadLong()
				local paths = {}
				logf("prpd paths = %s\n", count)

				-- for i = 1, count do
					-- local str = bsp_file:ReadString()
					-- if str ~= "" then
						-- paths[i] = str
					-- end
				-- end

				bsp_file:PopPosition()
			end

			if id == "tlpd" then
				bsp_file:PushPosition(fileofs)

				local count = bsp_file:ReadLong()
				logf("tlpd paths = %s\n", count)
				--for i = 1, count do
				--	local a = bsp_file:ReadBytes(4)
				--	local b = bsp_file:ReadByte()
				--
				--end

				bsp_file:PopPosition()
			end]]
		end
	end

	if CUBEMAPS then
		header.cubemaps = read_lump_data(
			"reading cubemaps",
			bsp_file,
			header,
			43,
			16,
			[[
			int origin[3];
			int size;
		]]
		)

		if not header.cubemaps then
			print("no cubemaps found in map")
		else
			print("found ", #header.cubemaps, " cubemaps in map")
		end

		if header.cubemaps then
			for k, v in ipairs(header.cubemaps) do
				v.origin = Vec3(-v.origin[2], v.origin[3], -v.origin[1])
			end
		end
	end

	header.brushes = read_lump_data(
		"reading brushes",
		bsp_file,
		header,
		19,
		12,
		[[
		int	firstside;	// first brushside
		int	numsides;	// number of brushsides
		int	contents;	// contents flags
	]]
	)
	header.brushsides = read_lump_data(
		"reading brushsides",
		bsp_file,
		header,
		20,
		8,
		[[
		unsigned short	planenum;	// facing out of the leaf
		short		texinfo;	// texture info
		short		dispinfo;	// displacement info
		short		bevel;		// is the side a bevel plane?
	]]
	)
	header.planes = read_lump_data(
		"reading planes",
		bsp_file,
		header,
		BSP_LUMP_PLANES,
		20,
		[[
		vec3 normal;
		float dist;
		int type;
	]]
	)
	header.vertices = read_lump_data("reading verticies", bsp_file, header, 4, 12, "vec3")
	header.surfedges = read_lump_data("reading surfedges", bsp_file, header, 14, 4, "long")
	header.edges = read_lump_data(
		"reading edges",
		bsp_file,
		header,
		13,
		4,
		function()
			return {bsp_file:ReadUnsignedShort(), bsp_file:ReadUnsignedShort()}
		end
	)
	header.faces = read_lump_data(
		"reading faces",
		bsp_file,
		header,
		8,
		56,
		[[
		unsigned short	planenum;		// the plane number
		byte		side;			// header.faces opposite to the node's plane direction
		byte		onNode;			// 1 of on node, 0 if in leaf
		int		firstedge;		// index into header.surfedges
		short		numedges;		// number of header.surfedges
		short		texinfo;		// texture info
		short		dispinfo;		// displacement info
		short		render2dFogVolumeID;	// ?
		byte		styles[4];		// switchable lighting info
		int		lightofs;		// offset into lightmap lump
		float		area;			// face area in units^2
		int		LightmapTextureMinsInLuxels[2];	// texture lighting info
		int		LightmapTextureSizeInLuxels[2];	// texture lighting info
		int		origFace;		// original face this was split from
		unsigned short	numPrims;		// primitives
		unsigned short	firstPrimID;
		unsigned int	smoothingGroups;	// lightmap smoothing group
	]]
	)
	header.texinfos = read_lump_data(
		"reading texinfo",
		bsp_file,
		header,
		7,
		72,
		[[
		float textureVecs[8];
		float lightmapVecs[8];
		int flags;
		int texdata;
	]]
	)
	header.texdatas = read_lump_data(
		"reading texdata",
		bsp_file,
		header,
		3,
		32,
		[[
		vec3 reflectivity;
		int nameStringTableID;
		int width;
		int height;
		int view_width;
		int view_height;
	]]
	)
	local texdatastringtable = read_lump_data("reading texdatastringtable", bsp_file, header, 45, 4, "int")
	local lump = header.lumps[44]
	header.texdatastringdata = {}

	for i = 1, #texdatastringtable do
		bsp_file:SetPosition(lump.fileofs + texdatastringtable[i])
		header.texdatastringdata[i] = bsp_file:ReadString()
		tasks.Wait()
	end

	do
		local structure = [[
			vec3 startPosition; // start position used for orientation
			int DispVertStart; // Index into LUMP_DISP_VERTS.
			int DispTriStart; // Index into LUMP_DISP_TRIS.
			int power; // power - indicates size of render2d (2^power	1)
			int minTess; // minimum tesselation allowed
			float smoothingAngle; // lighting smoothing angle
			int contents; // render2d contents
			unsigned short MapFace; // Which map face this displacement comes from.
			char asdf[2];
			int LightmapAlphaStart;	// Index into ddisplightmapalpha.
			int LightmapSamplePositionStart; // Index into LUMP_DISP_LIGHTMAP_SAMPLE_POSITIONS.

			padding byte padding[128];
		]]
		local lump = header.lumps[27]
		local length = lump.filelen / 176
		bsp_file:SetPosition(lump.fileofs)
		header.displacements = {}

		for i = 1, length do
			local data = bsp_file:ReadStructure(structure)
			local lump = header.lumps[34]
			data.heightmap = {}
			bsp_file:PushPosition(lump.fileofs + (data.DispVertStart * 20))

			for i = 1, ((2 ^ data.power) + 1) ^ 2 do
				local pos = bsp_file:ReadVec3()
				local dist = bsp_file:ReadFloat()
				local alpha = bsp_file:ReadFloat()
				data.heightmap[i] = {pos = pos, dist = dist, alpha = alpha}
			end

			bsp_file:PopPosition()
			header.displacements[i] = data
			tasks.ReportProgress("reading displacements", length)
			tasks.Wait()
		end
	end

	header.models = read_lump_data(
		"reading models",
		bsp_file,
		header,
		15,
		48,
		[[
		vec3 mins;
		vec3 maxs;
		vec3 origin;
		int headnode;
		int firstface;
		int numfaces;
	]]
	)

	--for i = 1, #header.brushes do
	--	local brush = header.brushes[i]
	--end
	local function sky_to_world(pos)
		if header.sky_aabb:IsPointInside(pos) then
			return (pos - header.sky_origin) * header.sky_scale, header.sky_scale
		end

		return pos
	end

	if header.sky_aabb then
		for _, v in ipairs(header.entities) do
			if v.origin then v.origin, v.model_size_mult = sky_to_world(v.origin) end
		end
	end

	local models = {}
	local displacement_collision_meshes = {}

	do
		local function add_vertex(model, texinfo, texdata, pos, blend)
			local a = texinfo.textureVecs

			if blend then blend = blend / 255 else blend = 0 end

			blend = math.clamp(blend, 0, 1)
			local uv_scale

			if header.sky_aabb then
				pos, uv_scale = sky_to_world(pos)

				if uv_scale then uv_scale = 1 / uv_scale end
			end

			uv_scale = uv_scale or 1
			local vertex = {
				-- Convert from Source Z-up to engine Y-up
				-- Source: X=forward, Y=left, Z=up
				-- Engine: X=right, Y=up, Z=forward
				-- Transformation: engine(x, y, z) = source(-y, z, -x) * scale
				pos = Vec3(-pos.y, pos.z, -pos.x) * steam.source2meters,
				texture_blend = blend,
				uv = Vec2(
					uv_scale * (a[1] * pos.x + a[2] * pos.y + a[3] * pos.z + a[4]) / texdata.width,
					uv_scale * (a[5] * pos.x + a[6] * pos.y + a[7] * pos.z + a[8]) / texdata.height
				),
			}

			if model.AddVertex then
				model:AddVertex(vertex)
			else
				list.insert(model, vertex)
			end
		end

		local function lerp_corners(dims, corners, start_corner, dispinfo, x, y)
			local index = (y - 1) * dims + x
			local data = dispinfo.heightmap[index]
			return math3d.BilerpVec3(
					corners[1 + (start_corner + 0) % 4],
					corners[1 + (start_corner + 1) % 4],
					corners[1 + (start_corner + 3) % 4],
					corners[1 + (start_corner + 2) % 4],
					(y - 1) / (dims - 1),
					(x - 1) / (dims - 1)
				) + (
					data.pos * data.dist
				),
			data.alpha
		end

		local meshes = {}

		for _, model in ipairs(header.models) do
			for i = 1, model.numfaces do
				local face = header.faces[model.firstface + i]
				local texinfo = header.texinfos[1 + face.texinfo]
				local texdata = texinfo and header.texdatas[1 + texinfo.texdata]
				local texname = header.texdatastringdata[1 + texdata.nameStringTableID]

				if texname:lower():find("skyb", nil, true) then goto continue end

				if texname:lower():find("water", nil, true) then goto continue end

				-- split the world up into sub models by texture
				if not meshes[texname] then
					local mesh = GRAPHICS and Polygon3D.New() or {}
					local material_path = "materials/" .. texname .. ".vmt"
					local material = GRAPHICS and Material.FromVMT(material_path)
					meshes[texname] = {mesh = mesh, material = material}

					if GRAPHICS then
						mesh:SetName(path .. ": " .. texname)
						mesh.material = Material.FromVMT("materials/" .. texname .. ".vmt")
					end

					list.insert(models, meshes[texname])
				end

				do
					local mesh = meshes[texname].mesh

					if face.dispinfo == -1 then
						local first, previous

						for j = 1, face.numedges do
							local surfedge = header.surfedges[face.firstedge + j]
							local edge = header.edges[1 + math.abs(surfedge)]
							local current = edge[surfedge < 0 and 2 or 1] + 1

							if j >= 3 then
								if header.vertices[first] and header.vertices[current] and header.vertices[previous] then
									local a = header.vertices[first]
									local b = header.vertices[previous]
									local c = header.vertices[current]
									-- CW winding (matches coordinate transform from Source)
									add_vertex(mesh, texinfo, texdata, a)
									add_vertex(mesh, texinfo, texdata, b)
									add_vertex(mesh, texinfo, texdata, c)
								end
							elseif j == 1 then
								first = current
							end

							previous = current
						end
					else
						local info = header.displacements[face.dispinfo + 1]
						local corners, start_corner = get_displacement_corners(header, info)
						local dims = 2 ^ info.power + 1

						for x = 1, dims - 1 do
							for y = 1, dims - 1 do
								local a, a_blend = lerp_corners(dims, corners, start_corner, info, x, y + 1)
								local b, b_blend = lerp_corners(dims, corners, start_corner, info, x, y)
								local c, c_blend = lerp_corners(dims, corners, start_corner, info, x + 1, y + 1)
								local d, d_blend = lerp_corners(dims, corners, start_corner, info, x + 1, y)

								do
									-- CW winding (matches coordinate transform from Source)
									add_vertex(mesh, texinfo, texdata, a, a_blend)
									add_vertex(mesh, texinfo, texdata, c, c_blend)
									add_vertex(mesh, texinfo, texdata, b, b_blend)
									-- 
									add_vertex(mesh, texinfo, texdata, c, c_blend)
									add_vertex(mesh, texinfo, texdata, d, d_blend)
									add_vertex(mesh, texinfo, texdata, b, b_blend)
								end
							end
						end

						do
							local collision_shape = build_displacement_heightmap_shape(header, info, lerp_corners)

							if collision_shape then
								list.insert(displacement_collision_meshes, collision_shape)
							end
						end

						mesh.smooth_normals = true
					end
				end

				::continue::

				tasks.ReportProgress("building meshes", model.numfaces)
				tasks.Wait()
			end

			-- only world needed
			break
		end
	end

	if GRAPHICS then
		for i, data in ipairs(models) do
			local mesh = data.mesh
			-- BSP uses CW winding due to coordinate transform, so build normals accordingly
			local vertices = mesh:GetVertices()

			for i = 1, #vertices, 3 do
				local a = vertices[i + 0]
				local b = vertices[i + 1]
				local c = vertices[i + 2]
				-- For CW winding: (C-A) × (B-A) to get outward normal
				local normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
				a.normal = normal
				b.normal = normal
				c.normal = normal

				if i % 3000 == 0 then tasks.Wait() end
			end

			tasks.ReportProgress("generating normals", #models)
			tasks.Wait()
		end

		for _, data in ipairs(models) do
			data.mesh:BuildBoundingBox()
			tasks.Wait()
		end

		for _, data in ipairs(models) do
			if data.mesh.smooth_normals then data.mesh:SmoothNormals() end

			tasks.Report("smoothing displacements", #models)
			tasks.Wait()
		end

		for _, data in ipairs(models) do
			data.mesh:BuildTangents()
			data.mesh:Upload()
			tasks.ReportProgress("creating meshes", #models)
			tasks.Wait()
		end
	end

	local render_meshes = {}

	for _, v in ipairs(models) do
		if GRAPHICS and v.mesh and v.mesh.Vertices then
			list.insert(render_meshes, v)
		elseif SERVER and type(v.mesh) == "table" and v.mesh[1] and v.mesh[1].pos then
			list.insert(render_meshes, v)
		end
	end

	local physics_body, physics_body_info = build_bsp_physics_body(header, render_meshes, displacement_collision_meshes, steam.bsp_world)
	steam.loaded_bsp[path] = {
		render_meshes = render_meshes,
		entities = header.entities,
		physics_body = physics_body,
		physics_body_info = physics_body_info,
		cubemaps = header.cubemaps,
		path = path, -- Store the absolute path
	}

	if physics_body_info then
		logn(
			"BSP physics body for ",
			path,
			": mode=",
			physics_body_info.mode,
			", collidable_brushes=",
			physics_body_info.collidable_brushes or 0,
			", displacement_primitives=",
			physics_body_info.displacement_primitives or 0,
			", primitives=",
			physics_body_info.primitives or 0
		)
	end

	tasks.ReportProgress("finished reading " .. path)
	return steam.loaded_bsp[path]
end

function steam.SpawnMapEntities(path, parent)
	-- path should already be absolute
	local data = steam.loaded_bsp[path]

	if not data then
		logf("cannot spawn map entities because %s is not loaded\n", path)
		logf("available loaded BSPs:\n")

		for k, v in pairs(steam.loaded_bsp) do
			logf("  %s\n", tostring(k))
		end

		return
	end

	local thread = tasks.CreateTask()
	logn("spawning map entities: ", path)

	function thread:OnStart()
		for _, v in ipairs(parent:GetChildrenList()) do
			if v.spawned_from_bsp then v:Remove() end
		end

		if data.cubemaps then
			logn("emitting ", #data.cubemaps, " BSP cubemaps")

			for k, v in pairs(data.cubemaps) do
				local position = v.origin * steam.source2meters
				event.Call("SpawnProbe", position)
			end
		end

		local count = table.count(data.entities)
		logn("spawning ", count, " entities from BSP")
		local handled = {}

		for i, info in pairs(data.entities) do
			if GRAPHICS then
				if info.skyname then
					--steam.LoadSkyTexture(info.skyname)
					handled[info.classname] = (handled[info.classname] or 0) + 1
				elseif info.classname and info.classname:find("light_environment") then
					handled[info.classname] = (handled[info.classname] or 0) + 1
				--local p, y = info.pitch, info.angles.y
				--parent.world_params:SetSunAngles(Deg3(p or 0, y+180, 0))
				--info._light.a = 1
				--parent.world_params:SetSunColor(Color(info._light.r, info._light.g, info._light.b))
				--parent.world_params:SetSunIntensity(1)
				elseif info.classname:lower():find("light") and info._light then
					handled[info.classname] = (handled[info.classname] or 0) + 1
					parent.light_group = parent.light_group or Entity.New{Name = "lights", Parent = parent}
					parent.light_group:SetName("lights")
					local ent = Entity.New{Name = "light", Parent = parent.light_group}
					local tr = ent:AddComponent("transform")
					local position = Vec3(-info.origin.y, info.origin.z, -info.origin.x) * steam.source2meters
					tr:SetPosition(position)
					local light = ent:AddComponent("light")
					light:SetName("point")
					light:SetLightType("point")
					-- Color is already in linear space from parsing
					light:SetColor(Color(info._light.r, info._light.g, info._light.b, 1))
					local brightness = info._light.brightness
					-- Source intensity formula with quadratic attenuation: I = brightness / d²
					-- Scale intensity for our renderer (empirically tuned)
					light:SetIntensity(math.clamp(brightness / 800, 1, 100))
					-- Calculate range where light drops below ~1% intensity
					-- At threshold 0.01: d = sqrt(brightness / 0.01) Source units
					-- Then convert to meters
					local threshold = 0.01
					local range_source_units = math.sqrt(brightness / threshold)
					local range = range_source_units * steam.source2meters

					if info._zero_percent_distance and info._zero_percent_distance > 0 then
						-- Source allows explicit cutoff distance (in Source units)
						range = info._zero_percent_distance * steam.source2meters
					elseif info._fifty_percent_distance and info._fifty_percent_distance > 0 then
						-- 50% distance: intensity = brightness/d² = 0.5*brightness
						-- So cutoff is roughly 2x this distance
						range = info._fifty_percent_distance * steam.source2meters * 2
					end

					light:SetRange(math.clamp(range * 4, 1, 150))
					ent.spawned_from_bsp = true
				elseif info.classname == "env_fog_controller" then

				--parent.world_params:SetFogColor(Color(info.fogcolor.r, info.fogcolor.g, info.fogcolor.b, info.fogcolor.a * (info.fogmaxdensity or 1)/4))
				--parent.world_params:SetFogStart(info.fogstart* steam.source2meters)
				--parent.world_params:SetFogEnd(info.fogend * steam.source2meters)
				end
			end

			if
				info.origin and
				info.angles and
				info.model and
				not info.classname:lower():find("npc")
				and
				info.classname ~= "env_sprite"
			then
				if vfs.IsFile(info.model) then
					handled[info.classname] = (handled[info.classname] or 0) + 1
					parent[info.classname .. "_group"] = parent[info.classname .. "_group"] or
						Entity.New{Name = info.classname, Parent = parent}
					parent[info.classname .. "_group"]:SetName(info.classname)
					local ent = Entity.New{Name = "prop", Parent = parent[info.classname .. "_group"]}
					local rotation = Quat()
					rotation:SetAngles(Deg3(info.angles.x, info.angles.y, info.angles.r))
					local position = Vec3(-info.origin.y, info.origin.z, -info.origin.x) * steam.source2meters
					local tr = ent:AddComponent("transform")
					tr:SetPosition(position)
					tr:SetRotation(rotation)

					if info.model_size_mult then
						ent.transform:SetSize(info.model_size_mult)
					end

					ent:AddComponent("model")
					ent.model:SetModelPath(info.model)

					if false then
						logf(
							"Spawning prop: %s at %s / %s with model %s\n",
							info.classname,
							tostring(position),
							tostring(rotation),
							info.model
						)
					end

					if false and info.rendercolor and not info.rendercolor:IsZero() then
						ent:SetColor(info.rendercolor)
					end

					ent.spawned_from_bsp = true
				else
					wlog(
						"cannot spawn entity of class " .. tostring(info.classname) .. " because model file " .. tostring(info.model) .. " does not exist"
					)
				end
			end

			tasks.ReportProgress("spawning entities", count)

			if i % 50 == 0 then tasks.Wait() end
		end

		local unhandled = {}

		for i, info in pairs(data.entities) do
			if info.classname and not handled[info.classname] then
				unhandled[info.classname] = (unhandled[info.classname] or 0) + 1
			end
		end

		logn("finished spawning map entities: ", path)
		logn("spawned entities:")

		for k, v in pairs(handled) do
			logn("  ", k, ": ", v)
		end

		if table.count(unhandled) > 0 then
			logn("unhandled BSP entity classes:")

			for k, v in pairs(unhandled) do
				logn("  ", k, ": ", v)
			end
		end
	end

	thread:Start()
end

model_loader.AddModelDecoder("bsp", function(path, full_path, mesh_callback)
	local ok, result = pcall(steam.LoadMap, full_path)

	if not ok then error("Failed to load BSP map: " .. tostring(result)) end

	if not result or not result.render_meshes then
		error("BSP LoadMap returned invalid data")
	end

	-- Store the resolved path on the world entity for later use
	if steam.bsp_world and steam.bsp_world:IsValid() then
		steam.bsp_world.bsp_resolved_path = full_path
	end

	if steam.bsp_world and steam.bsp_world:IsValid() then
		if steam.bsp_world:HasComponent("rigid_body") then
			steam.bsp_world:RemoveComponent("rigid_body")
		end

		if result.physics_body then
			steam.bsp_world:AddComponent("rigid_body", result.physics_body)
		end
	end

	for _, prim in ipairs(result.render_meshes) do
		mesh_callback(prim.mesh, prim.material)
	end
end)

event.AddListener("PreLoad3DModel", "bsp_mount_games", steam.MountGamesFromMapPath)

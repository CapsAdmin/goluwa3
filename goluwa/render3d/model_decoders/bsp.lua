local codec = import("goluwa/codec.lua")
local timer = import("goluwa/timer.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local render3d = import("goluwa/render3d/render3d.lua")
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
local commands = import("goluwa/cli/commands.lua")
local fs = import("goluwa/filesystem/fs.lua")
local transform = import("goluwa/entities/components/transform.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local brush_hull = import("goluwa/physics/brush_hull.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local R = vfs.GetAbsolutePath
local ffi = require("ffi")
local bit = require("bit")
local Entity = import("goluwa/entities/entity.lua")
local utility = import("goluwa/utility.lua")
local CUBEMAPS = true
steam.loaded_bsp = steam.loaded_bsp or {}
-- how far past the world's bounds, in metres, the 3D skybox is cut away
local SKY_CUT_MARGIN = 0.5
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
local BSP_LIGHT_INTENSITY_SCALE = 0.0025

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

local function source_height_to_engine_y(height)
	return height * steam.source2meters
end

local function set_transform(tr, info)
	local rotation = Quat()
	rotation:SetAngles(
		Deg3(
			info.pitch or info.angles and info.angles.x or 0,
			info.angles and info.angles.y or 0,
			info.angles and info.angles.z or 0
		)
	)
	local position = Vec3(-info.origin.y, info.origin.z, -info.origin.x) * steam.source2meters
	tr:SetPosition(position)
	tr:SetRotation(rotation)
end

-- vrad lights a surface d units away with brightness / (c + l*d + q*d^2)
-- (SetLightFalloffParams). Without _fifty_percent_distance it scales the
-- brightness by c + 100*l + 100^2*q, so a light is as bright as its brightness
-- 100 units away whatever its attenuation. With it, c, l and q are fitted
-- through 1 at 0, 2 at _fifty_percent_distance and 256 at
-- _zero_percent_distance. The engine's lights fall off with
-- 1 / (d^2 + r^2), so the intensity (candela) and source radius r are fitted
-- to vrad's falloff at FIT_NEAR and FIT_FAR units, then scaled to metres and
-- to the engine's light units by BSP_LIGHT_INTENSITY_SCALE. That's exact for
-- constant + quadratic attenuation and within about 2x between 25 and 1600
-- units for linear ones, which vrad's fitted falloffs mostly are.
--
-- The range is left to the light's brightness (Light:GetEffectiveRange)
-- unless _hardfalloff fades the light out at _zero_percent_distance.
local convert_source_light_to_engine

do
	local FIT_NEAR = 100
	local FIT_FAR = 800

	-- vrad's SolveInverseQuadratic: a*x^2 + b*x + c through the three points
	local function solve_quadratic(x1, y1, x2, y2, x3, y3)
		local det = (x1 - x2) * (x1 - x3) * (x2 - x3)
		local a = (x3 * (y2 - y1) + x2 * (y1 - y3) + x1 * (y3 - y2)) / det
		local b = (x3 * x3 * (y1 - y2) + x1 * x1 * (y2 - y3) + x2 * x2 * (y3 - y1)) / det
		local c = (
				x1 * x3 * (
					x3 - x1
				) * y2 + x2 * x2 * (
					x3 * y1 - x1 * y3
				) + x2 * (
					x1 * x1 * y3 - x3 * x3 * y1
				)
			) / det
		return a, b, c
	end

	-- vrad's SolveInverseQuadraticMonotonic, for 1 at 0, 2 at d50, 256 at d0:
	-- moves the middle point towards the line between the ends until the
	-- curve rises
	local function solve_fifty_percent(d50, d0)
		local a, b, c

		for i = 0, 20 do
			local t = i / 20
			a, b, c = solve_quadratic(0, 1, d50, (1 - t) * 2 + t * (1 + 255 * d50 / d0), d0, 256)

			if 2 * a + b >= 0 then break end
		end

		local scale = 2 / (c + d50 * (b + d50 * a))
		return c * scale, b * scale, a * scale
	end

	function convert_source_light_to_engine(info)
		local light = info._lightHDR or info._light
		local brightness = light.brightness * (info._lightscaleHDR or 1)
		local d50 = tonumber(info._fifty_percent_distance) or 0
		local d0 = tonumber(info._zero_percent_distance) or 0
		local c, l, q

		if d50 > 0 then
			if d0 < d50 then d0 = 2 * d50 end

			c, l, q = solve_fifty_percent(d50, d0)
		else
			c = math.max(tonumber(info._constant_attn) or 0, 0)
			l = math.max(tonumber(info._linear_attn) or 0, 0)
			q = math.max(tonumber(info._quadratic_attn) or 0, 0)

			if c + l + q == 0 then c = 1 end

			brightness = brightness * (c + 100 * l + 100 ^ 2 * q)
		end

		local near = brightness / (c + l * FIT_NEAR + q * FIT_NEAR ^ 2)
		local far = brightness / (c + l * FIT_FAR + q * FIT_FAR ^ 2)
		-- only constant attenuation doesn't fall off at all in vrad, so it
		-- stays flat out to FIT_FAR instead
		local radius_sq = near > far and
			math.max((far * FIT_FAR ^ 2 - near * FIT_NEAR ^ 2) / (near - far), 0) or
			FIT_FAR ^ 2
		local range = 0

		if d50 > 0 and tonumber(info._hardfalloff) == 1 then
			range = d0 * steam.source2meters
		end

		return Color(light.r, light.g, light.b, 1),
		near * (
				FIT_NEAR ^ 2 + radius_sq
			) * steam.source2meters ^ 2 * BSP_LIGHT_INTENSITY_SCALE,
		range,
		math.sqrt(radius_sq) * steam.source2meters
	end
end

local function get_model_lowest_point(model)
	if not model or not model.mins then return nil end

	return source_height_to_engine_y(model.mins.z)
end

local function get_face_first_source_height(header, face)
	if face.dispinfo ~= -1 then
		local info = header.displacements[face.dispinfo + 1]

		if info then
			local base_face = header.faces[1 + info.MapFace]

			if base_face then
				local surfedge = header.surfedges[1 + base_face.firstedge]
				local edge = surfedge and header.edges[1 + math.abs(surfedge)]
				local vertex_index = edge and edge[1 + (surfedge < 0 and 1 or 0)]
				local vertex = vertex_index and header.vertices[1 + vertex_index]

				if vertex then return vertex.z end
			end
		end
	end

	for j = 1, face.numedges do
		local surfedge = header.surfedges[face.firstedge + j]
		local edge = surfedge and header.edges[1 + math.abs(surfedge)]
		local current = edge and edge[surfedge < 0 and 2 or 1] and edge[surfedge < 0 and 2 or 1] + 1
		local vertex = current and header.vertices[current]

		if vertex then return vertex.z end
	end

	return nil
end

local function is_collidable_brush(brush)
	return brush and
		brush.numsides >= 4 and
		bit.band(brush.contents or 0, BSP_COLLISION_CONTENTS_MASK) ~= 0
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

local function build_brush_hull(planes)
	if not (planes and planes[1] and planes[4]) then return nil end

	return brush_hull.BuildHullFromPlanes(planes, BRUSH_POINT_EPSILON)
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

			local primitive = build_primitive_from_hull(build_brush_hull(brush_planes), brush_planes)

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
	local samples = HeightmapShape.SamplesFromFunction(dims, dims, function(x, z)
		local world_pos = source_pos_to_engine(select(1, lerp_corners(dims, corners, start_corner, info, x + 1, z + 1)))
		local plane_pos = center + right * (
				(
					x / resolution - 0.5
				) * width
			) + forward * (
				(
					z / resolution - 0.5
				) * depth
			)
		return (world_pos - plane_pos):Dot(up)
	end)
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
		Heightmap = {
			Samples = samples,
			SamplesX = dims,
			SamplesZ = dims,
			Size = Vec2(width, depth),
		},
		Position = center,
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
	steam.bsp_world:AddComponent("visual")
	steam.bsp_world.visual:SetModelPath(path)
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

	header.map_revision = bsp_file:ReadI32()

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
				elseif k == "_light" or k == "_lightHDR" or k == "_ambient" or k == "_ambientHDR" then
					-- "R G B brightness" with R G B in 0-255 gamma 2.2, read like
					-- vrad's LightForString: one value is grey, no brightness is
					-- 255, and eight values carry the HDR ones after the LDR ones.
					-- A negative value (the "-1 -1 -1 1" default of _lightHDR)
					-- means unset.
					local r, g, b, brightness, r_hdr, g_hdr, b_hdr, brightness_hdr = unpack_numbers(v)

					if brightness_hdr then
						r, g, b, brightness = r_hdr, g_hdr, b_hdr, brightness_hdr
					end

					g = g or r
					b = b or r
					brightness = brightness or 255

					if not r or r < 0 or g < 0 or b < 0 or brightness < 0 then
						v = false
					else
						v = {
							r = (r / 255) ^ 2.2,
							g = (g / 255) ^ 2.2,
							b = (b / 255) ^ 2.2,
							brightness = brightness,
						}
					end
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

			if ent.classname == "sky_camera" then header.sky_camera = ent end

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
		local game_lumps = bsp_file:ReadI32()

		for _ = 1, game_lumps do
			local id = bsp_file:ReadBytes(4)
			local flags = bsp_file:ReadI16()
			local version = bsp_file:ReadI16()
			local fileofs = bsp_file:ReadI32()
			local filelen = bsp_file:ReadI32()

			if id == "prps" then
				bsp_file:PushPosition(fileofs)
				local count
				count = bsp_file:ReadI32()
				local paths = {}

				for i = 1, count do
					local str = bsp_file:ReadString(128, true)

					if str ~= "" then paths[i] = str end
				end

				count = bsp_file:ReadI32()
				local leafs = {}

				for i = 1, count do
					leafs[i] = bsp_file:ReadU16()
				end

				header.static_prop_leafs = leafs
				count = bsp_file:ReadI32()
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
						lump.min_dx_level = bsp_file:ReadU16()
						lump.max_dx_level = bsp_file:ReadU16()
					end

					if version >= 8 then
						lump.min_cpu_level = bsp_file:ReadU8()
						lump.max_cpu_level = bsp_file:ReadU8()
						lump.min_gpu_level = bsp_file:ReadU8()
						lump.max_gpu_level = bsp_file:ReadU8()
					end

					if version >= 7 then lump.rendercolor = bsp_file:ReadByteColor() end

					if version == 11 then
						-- not sure what this padding is
						bsp_file:Advance(4)

						if version == 9 or version == 10 then
							lump.disable_xbox360 = bsp_file:ReadBoolean()
						end

						if version >= 10 then lump.flags_ex = bsp_file:ReadU32() end

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

				local count = bsp_file:ReadI32()
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

				local count = bsp_file:ReadI32()
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
			return {bsp_file:ReadU16(), bsp_file:ReadU16()}
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
	-- The 3D skybox is a sealed room somewhere in the map that Source draws
	-- scaled up by sky_camera's scale around sky_camera's origin. vbsp gives
	-- every sealed region its own area, so the skybox is the area sky_camera
	-- is in plus the areas areaportals join to it, and anything in those
	-- areas is moved out into the world.
	local sky_origin, sky_scale, sky_cut_min, sky_cut_max, is_sky_face

	if header.sky_camera then
		local nodes = read_lump_data(
			"reading nodes",
			bsp_file,
			header,
			6,
			32,
			function()
				local node = {bsp_file:ReadI32(), bsp_file:ReadI32(), bsp_file:ReadI32()}
				bsp_file:Advance(20)
				return node
			end
		)
		local leaf_size = header.lumps[11].version == 0 and 56 or 32
		local leafs = read_lump_data(
			"reading leafs",
			bsp_file,
			header,
			11,
			leaf_size,
			function()
				local contents = bsp_file:ReadI32()
				bsp_file:Advance(2)
				-- the low 9 bits of a bitfield, the rest are flags
				local area = bit.band(bsp_file:ReadU16(), 0x1FF)
				local mins = Vec3(bsp_file:ReadI16(), bsp_file:ReadI16(), bsp_file:ReadI16())
				local maxs = Vec3(bsp_file:ReadI16(), bsp_file:ReadI16(), bsp_file:ReadI16())
				bsp_file:Advance(leaf_size - 20)
				return {contents = contents, area = area, mins = mins, maxs = maxs}
			end
		)
		local areas = read_lump_data(
				"reading areas",
				bsp_file,
				header,
				21,
				8,
				"int numareaportals; int firstareaportal;"
			) or
			{}
		local areaportals = read_lump_data(
				"reading areaportals",
				bsp_file,
				header,
				22,
				12,
				function()
					bsp_file:Advance(2)
					local other_area = bsp_file:ReadU16()
					bsp_file:Advance(8)
					return other_area
				end
			) or
			{}
		local headnode = header.models[1].headnode

		local function point_leaf(pos)
			local node = headnode

			while node >= 0 do
				local n = nodes[node + 1]
				local plane = header.planes[n[1] + 1]
				node = plane.normal:Dot(pos) >= plane.dist and n[2] or n[3]
			end

			return leafs[-node]
		end

		local sky_areas = {}

		do
			local stack = {point_leaf(header.sky_camera.origin).area}

			while stack[1] do
				local area = list.remove(stack)

				if not sky_areas[area] then
					sky_areas[area] = true
					local info = areas[area + 1]

					if info then
						for i = 1, info.numareaportals do
							list.insert(stack, areaportals[info.firstareaportal + i])
						end
					end
				end
			end
		end

		-- a face lies on the boundary between leafs, so look just in front of
		-- it, or behind it when that's solid. A displacement's face is its base
		-- face.
		function is_sky_face(face)
			local center = Vec3()

			for j = 1, face.numedges do
				local surfedge = header.surfedges[face.firstedge + j]
				center = center + header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and
					2 or
					1]]
			end

			center = center / face.numedges
			local normal = header.planes[face.planenum + 1].normal

			if face.side ~= 0 then normal = normal * -1 end

			local leaf = point_leaf(center + normal)

			if bit.band(leaf.contents, BSP_CONTENTS_SOLID) ~= 0 then
				leaf = point_leaf(center - normal)
			end

			return sky_areas[leaf.area] == true
		end

		sky_origin = header.sky_camera.origin
		sky_scale = header.sky_camera.scale

		-- Source draws the skybox behind the world, so its walls and ground
		-- that end up in the world's place never show there. Here they would,
		-- in doorways out to the skybox for example, so everything in the
		-- skybox within the world's bounds is cut away.
		do
			local world_min = Vec3(math.huge, math.huge, math.huge)
			local world_max = Vec3(-math.huge, -math.huge, -math.huge)

			for _, leaf in ipairs(leafs) do
				if
					bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 and
					leaf.area ~= 0 and
					not sky_areas[leaf.area]
				then
					for _, axis in ipairs({"x", "y", "z"}) do
						world_min[axis] = math.min(world_min[axis], leaf.mins[axis])
						world_max[axis] = math.max(world_max[axis], leaf.maxs[axis])
					end
				end
			end

			local margin = SKY_CUT_MARGIN / steam.source2meters
			sky_cut_min = (world_min - Vec3(margin, margin, margin)) / sky_scale + sky_origin
			sky_cut_max = (world_max + Vec3(margin, margin, margin)) / sky_scale + sky_origin
			print("SKYCHECK cut", world_min, world_max, sky_cut_min, sky_cut_max)
		end

		for _, ent in ipairs(header.entities) do
			if ent.origin then
				local in_sky = false

				-- a static prop's origin is often inside the ground, but it
				-- knows which leafs it touches
				if ent.classname == "static_entity" and ent.leaf_count > 0 then
					for i = 1, ent.leaf_count do
						if sky_areas[leafs[header.static_prop_leafs[ent.first_leaf + i] + 1].area] then
							in_sky = true

							break
						end
					end
				else
					in_sky = sky_areas[point_leaf(ent.origin).area] == true
				end

				if in_sky then
					ent.origin = (ent.origin - sky_origin) * sky_scale
					ent.model_size_mult = sky_scale
				end
			end
		end
	end

	local models = {}
	local displacement_collision_meshes = {}
	header.lowest_point = get_model_lowest_point(header.models and header.models[1])
	header.ocean_level = nil

	do
		local function add_vertex(model, texinfo, texdata, in_sky, pos, blend)
			local a = texinfo.textureVecs

			if blend then blend = blend / 255 else blend = 0 end

			blend = math.clamp(blend, 0, 1)
			local uv = Vec2(
				(a[1] * pos.x + a[2] * pos.y + a[3] * pos.z + a[4]) / texdata.width,
				(a[5] * pos.x + a[6] * pos.y + a[7] * pos.z + a[8]) / texdata.height
			)

			if in_sky then pos = (pos - sky_origin) * sky_scale end

			local vertex = {
				-- Convert from Source Z-up to engine Y-up
				-- Source: X=forward, Y=left, Z=up
				-- Engine: X=right, Y=up, Z=forward
				-- Transformation: engine(x, y, z) = source(-y, z, -x) * scale
				pos = Vec3(-pos.y, pos.z, -pos.x) * steam.source2meters,
				texture_blend = blend,
				uv = uv,
			}

			if model.AddVertex then
				model:AddVertex(vertex)
			else
				list.insert(model, vertex)
			end
		end

		-- adds what's outside the skybox cut of a convex polygon of
		-- {pos = pos, blend = blend} vertices
		local add_sky_polygon

		do
			-- the parts of a polygon below and above an axis aligned plane
			local function split_polygon(polygon, axis, value)
				local below, above = {}, {}
				local prev = polygon[#polygon]
				local prev_d = prev.pos[axis] - value

				for _, vertex in ipairs(polygon) do
					local d = vertex.pos[axis] - value

					if (prev_d < 0) ~= (d < 0) then
						local t = prev_d / (prev_d - d)
						local mid = {
							pos = prev.pos + (vertex.pos - prev.pos) * t,
							blend = prev.blend + (vertex.blend - prev.blend) * t,
						}
						list.insert(below, mid)
						list.insert(above, mid)
					end

					list.insert(d < 0 and below or above, vertex)
					prev, prev_d = vertex, d
				end

				return below, above
			end

			local function add_polygon(mesh, texinfo, texdata, polygon)
				for i = 2, #polygon - 1 do
					add_vertex(mesh, texinfo, texdata, true, polygon[1].pos, polygon[1].blend)
					add_vertex(mesh, texinfo, texdata, true, polygon[i].pos, polygon[i].blend)
					add_vertex(mesh, texinfo, texdata, true, polygon[i + 1].pos, polygon[i + 1].blend)
				end
			end

			function add_sky_polygon(mesh, texinfo, texdata, polygon)
				for _, axis in ipairs({"x", "y", "z"}) do
					local outside
					outside, polygon = split_polygon(polygon, axis, sky_cut_min[axis])
					add_polygon(mesh, texinfo, texdata, outside)

					if not polygon[3] then return end

					polygon, outside = split_polygon(polygon, axis, sky_cut_max[axis])
					add_polygon(mesh, texinfo, texdata, outside)

					if not polygon[3] then return end
				end
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
				local in_sky = is_sky_face and is_sky_face(face)
				local texinfo = header.texinfos[1 + face.texinfo]
				local texdata = texinfo and header.texdatas[1 + texinfo.texdata]
				local texname = header.texdatastringdata[1 + texdata.nameStringTableID]
				local texname_lower = texname:lower()

				if texname_lower:find("skyb", nil, true) then goto continue end

				if texname_lower:find("water", nil, true) then
					if header.ocean_level == nil then
						local source_height = get_face_first_source_height(header, face)

						if source_height ~= nil then
							if in_sky then
								source_height = (source_height - sky_origin.z) * sky_scale
							end

							header.ocean_level = source_height_to_engine_y(source_height)
						end
					end

					goto continue
				end

				-- split the world up into sub models by texture
				if not meshes[texname] then
					local mesh = RENDER_2D and Polygon3D.New() or {}
					local material_path = "materials/" .. texname .. ".vmt"
					local material = RENDER_2D and Material.FromVMT(material_path)
					meshes[texname] = {mesh = mesh, material = material}

					if RENDER_2D then
						mesh:SetName(path .. ": " .. texname)
						mesh.material = material
					end

					list.insert(models, meshes[texname])
				end

				do
					local mesh = meshes[texname].mesh

					if face.dispinfo == -1 and in_sky then
						local polygon = {}

						for j = 1, face.numedges do
							local surfedge = header.surfedges[face.firstedge + j]
							polygon[j] = {
								pos = header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and 2 or 1]],
								blend = 0,
							}
						end

						add_sky_polygon(mesh, texinfo, texdata, polygon)
					elseif face.dispinfo == -1 then
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
									add_vertex(mesh, texinfo, texdata, false, a)
									add_vertex(mesh, texinfo, texdata, false, b)
									add_vertex(mesh, texinfo, texdata, false, c)
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

								if in_sky then
									add_sky_polygon(
										mesh,
										texinfo,
										texdata,
										{
											{pos = a, blend = a_blend},
											{pos = c, blend = c_blend},
											{pos = b, blend = b_blend},
										}
									)
									add_sky_polygon(
										mesh,
										texinfo,
										texdata,
										{
											{pos = c, blend = c_blend},
											{pos = d, blend = d_blend},
											{pos = b, blend = b_blend},
										}
									)
								else
									-- CW winding (matches coordinate transform from Source)
									add_vertex(mesh, texinfo, texdata, false, a, a_blend)
									add_vertex(mesh, texinfo, texdata, false, c, c_blend)
									add_vertex(mesh, texinfo, texdata, false, b, b_blend)
									-- 
									add_vertex(mesh, texinfo, texdata, false, c, c_blend)
									add_vertex(mesh, texinfo, texdata, false, d, d_blend)
									add_vertex(mesh, texinfo, texdata, false, b, b_blend)
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

	if RENDER_2D then
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
			data.mesh:Upload(nil)
			tasks.ReportProgress("creating meshes", #models)
			tasks.Wait()
		end
	end

	local render_meshes = {}

	for _, v in ipairs(models) do
		if RENDER_2D and v.mesh and v.mesh.Vertices then
			list.insert(render_meshes, v)
		elseif SERVER and type(v.mesh) == "table" and v.mesh[1] and v.mesh[1].pos then
			list.insert(render_meshes, v)
		end
	end

	local physics_body, physics_body_info = build_bsp_physics_body(header, render_meshes, displacement_collision_meshes, steam.bsp_world)
	local ocean_level = header.ocean_level

	if ocean_level == nil then ocean_level = header.lowest_point or 0 end

	render3d.SetOceanLevel(ocean_level - 2)
	render3d.SetOceanEnabled(true)
	steam.loaded_bsp[path] = {
		render_meshes = render_meshes,
		entities = header.entities,
		physics_body = physics_body,
		physics_body_info = physics_body_info,
		cubemaps = header.cubemaps,
		ocean_level = ocean_level,
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

		local count = table.count(data.entities)
		logn("spawning ", count, " entities from BSP")
		local handled = {}

		for i, info in pairs(data.entities) do
			if RENDER_2D then
				if info.skyname then
					--steam.LoadSkyTexture(info.skyname)
					handled[info.classname] = (handled[info.classname] or 0) + 1
				elseif info.classname and info.classname:find("light_environment") then
					handled[info.classname] = (handled[info.classname] or 0) + 1
				--local p, y = info.pitch, info.angles.y
				--parent.world_params:SetSunAngles(Deg3(p or 0, y+180, 0))
				--info._light.a = 1
				--parent.world_params:SetSunColor(Color(info._light.r, info._light.g, info._light.b))
				--parent.world_params:SetSunIlluminance(126000)
				elseif info.classname:lower():find("light") and (info._lightHDR or info._light) then
					handled[info.classname] = (handled[info.classname] or 0) + 1
					parent.light_group = parent.light_group or Entity.New{Name = "lights", Parent = parent}
					parent.light_group:SetName("lights")
					local ent = Entity.New{Name = info.classname, Parent = parent.light_group}
					local tr = ent:AddComponent("transform")
					set_transform(tr, info)
					local is_spot = info.classname == "light_spot"
					local light = ent:AddComponent(is_spot and "light_spot" or "light_point")
					local color, intensity, range, source_radius = convert_source_light_to_engine(info)
					light:SetColor(color)

					if is_spot then
						-- like vrad's ParseLightSpot, 0 counts as unset
						local inner_cone = math.clamp((tonumber(info._inner_cone) or 0) > 0 and info._inner_cone or 10, 0, 180)
						local outer_cone = math.clamp((tonumber(info._cone) or 0) > 0 and info._cone or inner_cone, inner_cone, 180)
						local exponent = tonumber(info._exponent) or 0

						-- vrad also scales the whole cone by cos(angle)^_exponent.
						-- The engine's cone is a smoothstep, so it's narrowed around
						-- the angle whose cap has the same flux, 1 - cos = 1 / (n + 1)
						if exponent > 1 then
							local mid = math.deg(math.acos(exponent / (exponent + 1)))
							inner_cone = math.min(inner_cone, mid * 0.5)
							outer_cone = math.max(math.min(outer_cone, mid * 1.5), inner_cone)
						end

						light:SetInnerCone(inner_cone)
						light:SetOuterCone(outer_cone)
					end

					light:SetRange(range)
					light:SetSourceRadius(source_radius)
					light:SetLumen(intensity * light:GetEmissionSolidAngle())
					--light:SetCastShadows{shadow_update_mode = "on_move"}
					ent.spawned_from_bsp = true
					ent.bsp_info = info
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
					local tr = ent:AddComponent("transform")
					set_transform(tr, info)

					if info.model_size_mult then
						ent.transform:SetSize(info.model_size_mult)
					end

					ent:AddComponent("visual")
					ent.visual:SetModelPath(info.model)

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

		if data.cubemaps then
			logn("emitting ", #data.cubemaps, " BSP cubemaps")

			for _, v in pairs(data.cubemaps) do
				local position = v.origin * steam.source2meters
				event.Call("SpawnProbe", position)
			end
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

-- every light spawned from a map: the entity's keys as the map has them, then
-- what the engine made of them
commands.Add("bsp_dump_lights", function()
	local lines = {}

	for _, light in ipairs(render3d.GetLights()) do
		local ent = light.Owner

		if ent.spawned_from_bsp then
			local pos = ent.transform:GetPosition()
			local raw = {}

			for k, v in ent.bsp_info.vdf:gmatch([["(.-)" "(.-)"]]) do
				if k ~= "classname" and k ~= "origin" and k ~= "hammerid" then
					raw[#raw + 1] = k .. "=" .. v
				end
			end

			lines[#lines + 1] = string.format(
				"%s #%d at %.2f %.2f %.2f\n  bsp: %s\n  engine: color %.3f %.3f %.3f  lumen %.4g  candela %.4g  range %g  source radius %.2f  effective range %.2f%s",
				ent.bsp_info.classname,
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
				light:GetEffectiveRange(),
				light.Type == "light_spot" and
					string.format("  cone %g..%g", light.InnerCone, light.OuterCone) or
					""
			)
		end
	end

	local path = "./storage/logs/bsp_lights.txt"
	fs.write_file(path, table.concat(lines, "\n") .. "\n")
	logf("%d bsp lights written to %s\n", #lines, path)
end)

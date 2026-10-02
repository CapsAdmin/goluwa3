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
local R = vfs.GetAbsolutePath
local ffi = require("ffi")
local bit = require("bit")
local Entity = import("goluwa/entities/entity.lua")
local VisibilityGroup = import("goluwa/entities/components/visibility_group.lua")
local utility = import("goluwa/utility.lua")
local CUBEMAPS = true
steam.loaded_bsp = steam.loaded_bsp or {}
-- how far past the world's bounds, in metres, the 3D skybox is cut away
local SKY_CUT_MARGIN = 0.5
-- how far outside a visibility group, in source units, the camera still
-- counts as inside one of the group's walls
local GROUP_WALL_MARGIN = 256
local BSP_LUMP_PLANES = 2
local BSP_CONTENTS_SOLID = 0x1
local BSP_CONTENTS_WINDOW = 0x2
local BSP_CONTENTS_GRATE = 0x8
local BSP_CONTENTS_SLIME = 0x10
local BSP_CONTENTS_WATER = 0x20
local BSP_CONTENTS_PLAYERCLIP = 0x10000
local BSP_CONTENTS_DETAIL = 0x8000000
local BSP_COLLISION_CONTENTS_MASK = bit.bor(
	BSP_CONTENTS_SOLID,
	BSP_CONTENTS_WINDOW,
	BSP_CONTENTS_GRATE,
	BSP_CONTENTS_PLAYERCLIP
)
local BRUSH_POINT_EPSILON = 0.01
local BSP_LIGHT_INTENSITY_SCALE = 2.8

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

local set_transform

do
	local axis_x = Vec3(1, 0, 0)
	local axis_y = Vec3(0, 1, 0)
	local axis_z = Vec3(0, 0, 1)

	function set_transform(tr, info, is_light)
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
			-- source rotates yaw about up, pitch about left and roll about forward,
			-- all right handed in source space, which maps to engine -x for pitch
			-- (positive looks down) and -z for roll
			rotation = QuatFromAxis(math.rad(angles.y), axis_y) * QuatFromAxis(math.rad(-angles.x), axis_x) * QuatFromAxis(math.rad(-angles.z), axis_z)
		end

		tr:SetPosition(Vec3(-info.origin.y, info.origin.z, -info.origin.x) * steam.source2meters)
		tr:SetRotation(rotation)
	end
end

-- vrad lights a surface d units away with brightness / (c + l*d + q*d^2)
-- (SetLightFalloffParams). Without _fifty_percent_distance it scales the
-- brightness by c + 100*l + 100^2*q, so a light is as bright as its brightness
-- 100 units away whatever its attenuation. With it, c, l and q are fitted
-- through 1 at 0, 2 at _fifty_percent_distance and 256 at
-- _zero_percent_distance. The engine's lights fall off the same way (see
-- Light's SourceRadius, LinearFalloff and QuadraticFalloff): with the distance
-- d in metres, d / s units, multiplying through by s^2 gives the coefficients
-- c * s^2, l * s and q and the intensity brightness * s^2 (all divided by q
-- when there is one), which BSP_LIGHT_INTENSITY_SCALE scales to the engine's
-- light units.
--
-- Mappers flatten a light's falloff with a large constant attenuation, which
-- would make it a source metres across. The source radius is capped at
-- MAX_SOURCE_RADIUS, which only brightens the light close to it: far away it
-- falls off with d^2 (or d) and gives off the same light as before.
--
-- A light with _fifty_percent_distance ends at _zero_percent_distance, where
-- vrad has it at 1/256 of its brightness at the light. Other lights are left
-- to their brightness (Light:GetEffectiveRange).
local convert_source_light_to_engine

do
	local MAX_SOURCE_RADIUS = 0.25

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
			-- a far _zero_percent_distance can fit a slightly negative q,
			-- which would make the falloff reach zero and turn negative
			q = math.max(q, 0)
		else
			c = math.max(tonumber(info._constant_attn) or 0, 0)
			l = math.max(tonumber(info._linear_attn) or 0, 0)
			q = math.max(tonumber(info._quadratic_attn) or 0, 0)

			if c + l + q == 0 then c = 1 end

			brightness = brightness * (c + 100 * l + 100 ^ 2 * q)
		end

		-- divided through by q, so the light falls off as d^2 far away and
		-- its lumen is what it gives off. Only linear and constant lights
		-- keep q = 0, and their lumen is relative to their falloff.
		if q > 0 then
			brightness = brightness / q
			c = c / q
			l = l / q
			q = 1
		end

		local s = steam.source2meters
		local source_radius = math.sqrt(c) * s

		-- a constant only light has nothing but its constant to fall off with
		if l + q > 0 then
			source_radius = math.min(source_radius, MAX_SOURCE_RADIUS)
		end

		return {
			color = Color(light.r, light.g, light.b, 1),
			intensity = brightness * s ^ 2 * BSP_LIGHT_INTENSITY_SCALE,
			range = d50 > 0 and d0 * s or 0,
			source_radius = source_radius,
			linear_falloff = l * s,
			quadratic_falloff = q,
		}
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
		brush_hull = hull,
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

-- the brushes of one model (0 is the world, "*n" entities are the others), by
-- walking its tree: a brush is listed in every leaf it touches, so the set is
-- what keeps a trigger's or a door's brushes out of the world's collision
local function get_model_brush_set(header, model_index)
	local set = {}
	local stack = {header.models[model_index + 1].headnode}
	local visited_leafs = {}

	while #stack > 0 do
		local node = table.remove(stack)

		if node >= 0 then
			local n = header.nodes[node + 1]
			stack[#stack + 1] = n[2]
			stack[#stack + 1] = n[3]
		else
			local leaf_index = -node

			if not visited_leafs[leaf_index] then
				visited_leafs[leaf_index] = true
				local leaf = header.leafs[leaf_index]

				for i = leaf.first_leaf_brush, leaf.first_leaf_brush + leaf.leaf_brush_count - 1 do
					set[header.leaf_brushes[i + 1]] = true
				end
			end
		end
	end

	return set
end

-- The world model's brushes that block movement. Brush entities (triggers,
-- doors, clips, effect volumes) have brushes of their own in the same lump,
-- often with solid contents, but they are not part of the world and this
-- loader does not draw them either, so they would be invisible walls. A brush
-- that is in no leaf of any model is never collided with by Source.
local function get_world_collision_brushes(header)
	local indices = {}

	for index in pairs(get_model_brush_set(header, 0)) do
		indices[#indices + 1] = index
	end

	table.sort(indices)
	local brushes = {}

	for _, index in ipairs(indices) do
		local brush = header.brushes[index + 1]

		if is_collidable_brush(brush) then brushes[#brushes + 1] = brush end
	end

	return brushes
end

local function build_bsp_brush_model(header, owner)
	local model = {
		Owner = owner,
		Visible = true,
		WorldSpaceVertices = true,
		Primitives = {},
		AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge),
	}

	for _, brush in ipairs(get_world_collision_brushes(header)) do
		local brush_planes = {}

		for i, plane in ipairs(get_brush_planes(header, brush)) do
			brush_planes[i] = source_plane_to_engine(plane)
		end

		local primitive = build_primitive_from_hull(build_brush_hull(brush_planes), brush_planes)

		if primitive and primitive.aabb then
			model.Primitives[#model.Primitives + 1] = primitive
			model.AABB:Expand(primitive.aabb)
		end
	end

	if not model.Primitives[1] then return nil end

	return model
end

local function build_bsp_physics_body(header, render_meshes, displacement_meshes, owner)

	local collidable_brushes = #get_world_collision_brushes(header)

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

-- Water: vbsp keeps water as brushes with water contents, split up wherever
-- the bsp cut them. Each becomes a box, the box's top is the surface, and
-- boxes of the same water at the same level that together fill a rectangle are
-- merged back into one, since the renderer only draws a few volumes. Merging
-- into a bounding box would cover the dry land between them.
local collect_water_volumes

do
	local water = import("goluwa/render3d/water.lua")
	-- a volume whose Source fog makes it this dense, per meter, at most
	local MAX_EXTINCTION = 4

	local function read_vmt(path)
		local str = vfs.Read(path) or vfs.Read(vfs.FindMixedCasePath(path) or path)

		if not str then return nil end

		local vmt = steam.VDFToTable(str, function(key)
			return (key:lower():gsub("%$", ""))
		end)
		local shader, params = next(vmt or {})

		if type(params) ~= "table" then return nil end

		if shader == "patch" and params.include then
			local base = read_vmt(params.include)

			if not base then return params.replace or params.insert end

			table.merge(base, params.insert or {})
			table.merge(base, params.replace or {})
			return base
		end

		return params
	end

	-- the vdf decoder makes "{r g b}" a Color, "[r g b]" stays a string in
	-- 0..1. both are gamma encoded
	local function parse_color(value)
		if type(value) == "string" then
			local r, g, b = value:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")

			if not r then return nil end

			value = Color(tonumber(r), tonumber(g), tonumber(b), 1)
		elseif value == nil then
			return nil
		end

		return Vec3(value.r ^ 2.2, value.g ^ 2.2, value.b ^ 2.2)
	end

	-- Source water fogs linearly to $fogcolor until $fogend, taken as where
	-- the water is 95% opaque
	local function water_from_vmt(texname, contents)
		local vmt = read_vmt("materials/" .. texname .. ".vmt") or {}
		local fog_color = parse_color(vmt.fogcolor)
		local fog_end = tonumber(vmt.fogend)

		if not fog_color or not fog_end or fog_end <= 0 then
			local preset = bit.band(contents, BSP_CONTENTS_SLIME) ~= 0 and
				water.presets.swamp or
				water.presets.lake
			return preset.Absorption:Copy(), preset.ParticleScattering:Copy()
		end

		return water.MediumFromFog(
			fog_color,
			math.min(3 / math.max(fog_end * steam.source2meters, 0.5), MAX_EXTINCTION),
			4
		)
	end

	-- the texture of the brush's upward facing side, the water surface
	local function get_surface_texture(header, brush)
		local best, best_up = nil, -math.huge

		for side_index = 0, brush.numsides - 1 do
			local side = header.brushsides[brush.firstside + side_index + 1]
			local plane = side and header.planes[side.planenum + 1]
			local texinfo = plane and side.texinfo >= 0 and header.texinfos[side.texinfo + 1]

			if texinfo and plane.normal.z > best_up then
				local texdata = header.texdatas[texinfo.texdata + 1]
				best = texdata and header.texdatastringdata[texdata.nameStringTableID + 1]
				best_up = plane.normal.z
			end
		end

		return best
	end

	local function area(box)
		return (box.max.x - box.min.x) * (box.max.z - box.min.z)
	end

	-- two boxes whose union is filled by them, within a few percent
	local function try_merge(a, b)
		if a.key ~= b.key then return nil end

		local min = Vec3(math.min(a.min.x, b.min.x), math.min(a.min.y, b.min.y), math.min(a.min.z, b.min.z))
		local max = Vec3(math.max(a.max.x, b.max.x), a.max.y, math.max(a.max.z, b.max.z))
		local union = {min = min, max = max}
		local overlap_x = math.max(math.min(a.max.x, b.max.x) - math.max(a.min.x, b.min.x), 0)
		local overlap_z = math.max(math.min(a.max.z, b.max.z) - math.max(a.min.z, b.min.z), 0)
		local covered = area(a) + area(b) - overlap_x * overlap_z

		if covered < area(union) * 0.98 then return nil end

		return {
			min = min,
			max = max,
			key = a.key,
			texname = a.texname,
			contents = a.contents,
			visibility_group = a.visibility_group,
		}
	end

	-- to_engine_box moves a box in the 3D skybox out into the world, and says
	-- which visibility group it's in
	function collect_water_volumes(header, to_engine_box)
		local boxes = {}

		for _, brush in ipairs(header.brushes or {}) do
			local contents = brush.contents or 0

			if bit.band(contents, BSP_CONTENTS_WATER + BSP_CONTENTS_SLIME) ~= 0 then
				local planes = {}

				for i, plane in ipairs(get_brush_planes(header, brush)) do
					planes[i] = source_plane_to_engine(plane)
				end

				local hull = build_brush_hull(planes)
				local texname = get_surface_texture(header, brush)

				if hull and hull.bounds_min and texname then
					local min, max, visibility_group = to_engine_box(hull.bounds_min, hull.bounds_max)

					if max.x - min.x > 0.01 and max.z - min.z > 0.01 then
						list.insert(
							boxes,
							{
								min = min,
								max = max,
								texname = texname,
								contents = contents,
								visibility_group = visibility_group,
								-- surfaces within a centimeter are the same water
								key = texname:lower() .. math.floor(max.y * 100 + 0.5) .. " " .. tostring(visibility_group),
							}
						)
					end
				end
			end
		end

		local merged = true

		while merged do
			merged = false

			for i = 1, #boxes do
				for j = i + 1, #boxes do
					local union = try_merge(boxes[i], boxes[j])

					if union then
						boxes[i] = union
						list.remove(boxes, j)
						merged = true

						break
					end
				end

				if merged then break end
			end
		end

		local volumes = {}
		local materials = {}

		for _, box in ipairs(boxes) do
			local material = materials[box.texname]

			if not material then
				material = {water_from_vmt(box.texname, box.contents)}
				materials[box.texname] = material
			end

			list.insert(
				volumes,
				{
					position = Vec3((box.min.x + box.max.x) / 2, box.max.y, (box.min.z + box.max.z) / 2),
					size = box.max - box.min,
					absorption = material[1],
					scattering = material[2],
					slime = bit.band(box.contents, BSP_CONTENTS_SLIME) ~= 0,
					texname = box.texname,
					visibility_group = box.visibility_group,
				}
			)
		end

		return volumes
	end
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

-- A displacement is not a heightmap: each vertex is the flat grid position
-- plus an arbitrary offset vector times a distance, so a patch can overhang or
-- curve back on itself. The collider is the triangle mesh of the grid, built
-- from the same vertices the visual mesh uses, so the two cannot disagree.
-- positions are the Source space vertices in the visual's (y * dims + x)
-- order; the triangles keep the visual's diagonal and face the same way.
local function build_displacement_collision_shape(positions, dims)
	local scale = steam.source2meters
	local poly = Polygon3D.New()
	local vertices = poly.Vertices

	for i = 1, dims * dims do
		local pos = positions[i]
		vertices[i] = {pos = Vec3(-pos.y * scale, pos.z * scale, -pos.x * scale)}
	end

	local indices = {}
	local count = 0

	for x = 1, dims - 1 do
		for y = 1, dims - 1 do
			local a = y * dims + x
			local b = (y - 1) * dims + x
			local c = a + 1
			local d = b + 1
			indices[count + 1], indices[count + 2], indices[count + 3] = a - 1, b - 1, c - 1
			indices[count + 4], indices[count + 5], indices[count + 6] = c - 1, b - 1, d - 1
			count = count + 6
		end
	end

	poly.indices = indices
	poly:BuildBoundingBox()
	return {Polygon3D = poly}
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
	steam.bsp_world:RemoveChildren()
	-- Store the relative path for later lookup
	steam.bsp_world.bsp_relative_path = path

	-- the world's meshes are spawned along with the map's entities, split up by
	-- visibility group
	model_loader.LoadModel(
		path,
		function()
			timer.Delay(0, function()
				utility.PushTimeWarning()
				steam.SpawnMapEntities(steam.bsp_world.bsp_resolved_path, steam.bsp_world)
				utility.PopTimeWarning("spawning map entities")
			end)
		end,
		nil,
		function(err)
			wlog("failed to load map " .. path .. ": " .. err)
		end
	)
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

	header.overlays = read_lump_data(
		"reading overlays",
		bsp_file,
		header,
		46,
		352,
		[[
		int id;
		short texinfo;
		unsigned short face_count_and_render_order;
		int faces[64];
		float u_range[2];
		float v_range[2];
		float uv_points[12];
		vec3 origin;
		vec3 normal;
	]]
	)

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
	-- vbsp gives every region that is sealed off from the rest of the map its
	-- own area, and splits regions further at areaportals. Areas joined by
	-- areaportals can see into each other, so together they make up one
	-- visibility group, and nothing of one group can be seen from another.
	--
	-- The 3D skybox is one of these regions, somewhere in the map, that Source
	-- draws scaled up by sky_camera's scale around sky_camera's origin. Its
	-- areas are the group sky_camera is in, and anything in them is moved out
	-- into the world, where it belongs to no group.
	local sky_origin, sky_scale, sky_cut_min, sky_cut_max, point_leaf_in_sky
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
			local first_leaf_face = bsp_file:ReadU16()
			local leaf_face_count = bsp_file:ReadU16()
			local first_leaf_brush = bsp_file:ReadU16()
			local leaf_brush_count = bsp_file:ReadU16()
			bsp_file:Advance(leaf_size - 28)
			return {
				contents = contents,
				area = area,
				mins = mins,
				maxs = maxs,
				first_leaf_face = first_leaf_face,
				leaf_face_count = leaf_face_count,
				first_leaf_brush = first_leaf_brush,
				leaf_brush_count = leaf_brush_count,
			}
		end
	)
	local leaf_faces = read_lump_data(
			"reading leaf faces",
			bsp_file,
			header,
			17,
			2,
			function()
				return bsp_file:ReadU16()
			end
		) or
		{}
	local leaf_brushes = read_lump_data(
			"reading leaf brushes",
			bsp_file,
			header,
			18,
			2,
			function()
				return bsp_file:ReadU16()
			end
		) or
		{}
	header.nodes = nodes
	header.leafs = leafs
	header.leaf_brushes = leaf_brushes
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

	-- the area of the open leaf nearest to pos, for what is in a wall and
	-- doesn't touch any open leaf nearby
	local function nearest_area(pos)
		local best_area, best_distance = 0, math.huge

		for _, leaf in ipairs(leafs) do
			if leaf.area ~= 0 and bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then
				local dx = math.max(leaf.mins.x - pos.x, 0, pos.x - leaf.maxs.x)
				local dy = math.max(leaf.mins.y - pos.y, 0, pos.y - leaf.maxs.y)
				local dz = math.max(leaf.mins.z - pos.z, 0, pos.z - leaf.maxs.z)
				local distance = dx * dx + dy * dy + dz * dz

				if distance < best_distance then
					best_area, best_distance = leaf.area, distance
				end
			end
		end

		return best_area
	end

	-- the areas areaportals join to area, and area itself
	local function get_joined_areas(area)
		local out = {}
		local stack = {area}

		while stack[1] do
			local area = list.remove(stack)

			if not out[area] then
				out[area] = true
				local info = areas[area + 1]

				if info then
					for i = 1, info.numareaportals do
						list.insert(stack, areaportals[info.firstareaportal + i])
					end
				end
			end
		end

		return out
	end

	local sky_areas = header.sky_camera and
		get_joined_areas(point_leaf(header.sky_camera.origin).area) or
		{}
	-- area 0 is the solid space outside of every area
	local area_groups = {}
	local group_count = 0

	for area = 1, #areas - 1 do
		if not area_groups[area] and not sky_areas[area] then
			group_count = group_count + 1

			for joined in pairs(get_joined_areas(area)) do
				area_groups[joined] = group_count
			end
		end
	end

	logn("found ", group_count, " visibility groups in ", #areas - 1, " areas")
	-- the box around a group's open leafs, grown by as much as a thick wall,
	-- tells being inside one of its walls from being outside of it
	local group_bounds = {}

	for _, leaf in ipairs(leafs) do
		local id = area_groups[leaf.area]

		if id and bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then
			local bounds = group_bounds[id]

			if not bounds then
				bounds = {
					min = Vec3(math.huge, math.huge, math.huge),
					max = Vec3(-math.huge, -math.huge, -math.huge),
				}
				group_bounds[id] = bounds
			end

			for _, axis in ipairs({"x", "y", "z"}) do
				bounds.min[axis] = math.min(bounds.min[axis], leaf.mins[axis] - GROUP_WALL_MARGIN)
				bounds.max[axis] = math.max(bounds.max[axis], leaf.maxs[axis] + GROUP_WALL_MARGIN)
			end
		end
	end

	-- the leafs a face can be seen from list it
	local face_areas = {}

	for _, leaf in ipairs(leafs) do
		if leaf.area ~= 0 then
			for j = 1, leaf.leaf_face_count do
				local index = leaf_faces[leaf.first_leaf_face + j] + 1
				face_areas[index] = face_areas[index] or leaf.area
			end
		end
	end

	-- displacements aren't listed. Their base face can be buried below the
	-- surface they make, so look in front of it, or behind it when that's
	-- solid, a little further away each time, and failing that take the
	-- nearest open leaf
	local probe_distances = {1, 16, 64, 256}

	local function get_face_area(index)
		if face_areas[index] then return face_areas[index] end

		local face = header.faces[index]
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

		for _, distance in ipairs(probe_distances) do
			local leaf = point_leaf(center + normal * distance)

			if bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then return leaf.area end

			leaf = point_leaf(center - normal * distance)

			if bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then return leaf.area end
		end

		return nearest_area(center)
	end

	if header.sky_camera then
		sky_origin = header.sky_camera.origin
		sky_scale = header.sky_camera.scale

		function point_leaf_in_sky(pos)
			return sky_areas[point_leaf(pos).area] == true
		end

		-- Source draws the skybox behind the world, so its walls and ground
		-- that end up in the world's place never show there. Here they would,
		-- in doorways out to the skybox for example, so everything in the
		-- skybox within the world's bounds is cut away.
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
	end

	do
		-- an entity inside a wall (a model's origin often is) looks around it
		local probe_offsets = {
			Vec3(0, 0, 16),
			Vec3(0, 0, -16),
			Vec3(16, 0, 0),
			Vec3(-16, 0, 0),
			Vec3(0, 16, 0),
			Vec3(0, -16, 0),
		}

		for _, ent in ipairs(header.entities) do
			if ent.origin then
				local area = 0

				-- a static prop knows which leafs it touches, the skybox's first
				if ent.classname == "static_entity" and ent.leaf_count > 0 then
					for i = 1, ent.leaf_count do
						local leaf_area = leafs[header.static_prop_leafs[ent.first_leaf + i] + 1].area

						if sky_areas[leaf_area] then
							area = leaf_area

							break
						end

						if area == 0 then area = leaf_area end
					end
				else
					area = point_leaf(ent.origin).area

					for _, offset in ipairs(probe_offsets) do
						if area ~= 0 then break end

						area = point_leaf(ent.origin + offset).area
					end

					if area == 0 then area = nearest_area(ent.origin) end
				end

				ent.visibility_group = area_groups[area]

				if sky_areas[area] then
					ent.origin = (ent.origin - sky_origin) * sky_scale
					ent.model_size_mult = sky_scale
				end
			end
		end
	end

	header.visibility = {
		point_leaf = point_leaf,
		area_groups = area_groups,
		group_count = group_count,
		group_bounds = group_bounds,
	}

	do
		-- engine space box corners back to source space, through the skybox
		-- transform if they're in it, and out again
		local function engine_to_source(pos)
			return Vec3(-pos.z, -pos.x, pos.y) / steam.source2meters
		end

		header.water_volumes = collect_water_volumes(header, function(min, max)
			local center = (engine_to_source(min) + engine_to_source(max)) / 2
			local area = point_leaf(center).area

			if area == 0 then area = nearest_area(center) end

			if not sky_areas[area] then return min, max, area_groups[area] end

			local a = source_pos_to_engine((engine_to_source(min) - sky_origin) * sky_scale)
			local b = source_pos_to_engine((engine_to_source(max) - sky_origin) * sky_scale)
			return Vec3(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z)),
			Vec3(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z))
		end)
		logn("found ", #header.water_volumes, " water volumes in map")
	end

	local models = {}
	local displacement_collision_meshes = {}
	header.lowest_point = get_model_lowest_point(header.models and header.models[1])
	header.ocean_level = nil

	do
		local function add_vertex(model, texinfo, texdata, in_sky, pos, blend, uv_pos, disp_normal)
			local a = texinfo.textureVecs
			-- displacements are mapped as the flat surface they displace
			local uv_source = uv_pos or pos

			if blend then blend = blend / 255 else blend = 0 end

			blend = math.clamp(blend, 0, 1)
			local uv = Vec2(
				(
						a[1] * uv_source.x + a[2] * uv_source.y + a[3] * uv_source.z + a[4]
					) / texdata.width,
				(
						a[5] * uv_source.x + a[6] * uv_source.y + a[7] * uv_source.z + a[8]
					) / texdata.height
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
				disp_normal = disp_normal,
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
							flat = prev.flat and prev.flat + (vertex.flat - prev.flat) * t,
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
					add_vertex(
						mesh,
						texinfo,
						texdata,
						true,
						polygon[1].pos,
						polygon[1].blend,
						polygon[1].flat,
						polygon[1].dn
					)
					add_vertex(
						mesh,
						texinfo,
						texdata,
						true,
						polygon[i].pos,
						polygon[i].blend,
						polygon[i].flat,
						polygon[i].dn
					)
					add_vertex(
						mesh,
						texinfo,
						texdata,
						true,
						polygon[i + 1].pos,
						polygon[i + 1].blend,
						polygon[i + 1].flat,
						polygon[i + 1].dn
					)
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
			local flat = math3d.BilerpVec3(
				corners[1 + (start_corner + 0) % 4],
				corners[1 + (start_corner + 1) % 4],
				corners[1 + (start_corner + 3) % 4],
				corners[1 + (start_corner + 2) % 4],
				(y - 1) / (dims - 1),
				(x - 1) / (dims - 1)
			)
			return flat + data.pos * data.dist, data.alpha, flat
		end

		-- Displacement normals come from the displacement's own grid instead of
		-- smoothing the merged mesh: each patch adds the area weighted normals of
		-- its triangles to its grid vertices, and vertices on a patch's edge
		-- share one accumulator with the coincident vertices of its neighbours.
		local welded_normals = {}
		local disp_x, disp_y, disp_z = {}, {}, {}
		local disp_nx, disp_ny, disp_nz = {}, {}, {}

		local function accumulate_triangle(i, j, k)
			local ux, uy, uz = disp_x[k] - disp_x[i], disp_y[k] - disp_y[i], disp_z[k] - disp_z[i]
			local vx, vy, vz = disp_x[j] - disp_x[i], disp_y[j] - disp_y[i], disp_z[j] - disp_z[i]
			local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
			disp_nx[i], disp_ny[i], disp_nz[i] = disp_nx[i] + nx, disp_ny[i] + ny, disp_nz[i] + nz
			disp_nx[j], disp_ny[j], disp_nz[j] = disp_nx[j] + nx, disp_ny[j] + ny, disp_nz[j] + nz
			disp_nx[k], disp_ny[k], disp_nz[k] = disp_nx[k] + nx, disp_ny[k] + ny, disp_nz[k] + nz
		end

		local meshes = {}

		for _, model in ipairs(header.models) do
			for i = 1, model.numfaces do
				local face = header.faces[model.firstface + i]
				local area = get_face_area(model.firstface + i)
				local in_sky = sky_areas[area] == true
				local group = area_groups[area]
				local texinfo = header.texinfos[1 + face.texinfo]
				local texdata = texinfo and header.texdatas[1 + texinfo.texdata]
				local texname = header.texdatastringdata[1 + texdata.nameStringTableID]
				local texname_lower = texname:lower()
				-- the world is split up into sub models by visibility group and
				-- texture
				local key = (group or 0) .. " " .. texname

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

				if not meshes[key] then
					local mesh = RENDER_2D and Polygon3D.New() or {}
					local material_path = "materials/" .. texname .. ".vmt"
					local material = RENDER_2D and Material.FromVMT(material_path)
					meshes[key] = {
						mesh = mesh,
						material = material,
						visibility_group = group,
					}

					if RENDER_2D then
						mesh:SetName(path .. ": " .. texname)
						mesh.material = material
					end

					list.insert(models, meshes[key])
				end

				do
					local mesh = meshes[key].mesh

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
						local positions, blends, flats, normals = {}, {}, {}, {}
						local scale = steam.source2meters

						for y = 1, dims do
							for x = 1, dims do
								local i = (y - 1) * dims + x
								local pos, blend, flat = lerp_corners(dims, corners, start_corner, info, x, y)
								positions[i], blends[i], flats[i] = pos, blend, flat
								disp_x[i], disp_y[i], disp_z[i] = -pos.y * scale, pos.z * scale, -pos.x * scale
								disp_nx[i], disp_ny[i], disp_nz[i] = 0, 0, 0
							end
						end

						for x = 1, dims - 1 do
							for y = 1, dims - 1 do
								local a = y * dims + x
								local b = (y - 1) * dims + x
								local c = a + 1
								local d = b + 1
								accumulate_triangle(a, c, b)
								accumulate_triangle(c, d, b)
							end
						end

						for y = 1, dims do
							for x = 1, dims do
								local i = (y - 1) * dims + x

								if x == 1 or y == 1 or x == dims or y == dims then
									local pos = positions[i]
									local key = (
											(
												math.floor(pos.x * 4 + 0.5) + 65536
											) * 131072 + math.floor(pos.y * 4 + 0.5) + 65536
										) * 131072 + math.floor(pos.z * 4 + 0.5) + 65536
									local normal = welded_normals[key]

									if not normal then
										normal = Vec3(0, 0, 0)
										welded_normals[key] = normal
									end

									normal.x = normal.x + disp_nx[i]
									normal.y = normal.y + disp_ny[i]
									normal.z = normal.z + disp_nz[i]
									normals[i] = normal
								else
									normals[i] = Vec3(disp_nx[i], disp_ny[i], disp_nz[i])
								end
							end
						end

						for x = 1, dims - 1 do
							for y = 1, dims - 1 do
								local a = y * dims + x
								local b = (y - 1) * dims + x
								local c = a + 1
								local d = b + 1

								if in_sky then
									add_sky_polygon(
										mesh,
										texinfo,
										texdata,
										{
											{pos = positions[a], blend = blends[a], flat = flats[a], dn = normals[a]},
											{pos = positions[c], blend = blends[c], flat = flats[c], dn = normals[c]},
											{pos = positions[b], blend = blends[b], flat = flats[b], dn = normals[b]},
										}
									)
									add_sky_polygon(
										mesh,
										texinfo,
										texdata,
										{
											{pos = positions[c], blend = blends[c], flat = flats[c], dn = normals[c]},
											{pos = positions[d], blend = blends[d], flat = flats[d], dn = normals[d]},
											{pos = positions[b], blend = blends[b], flat = flats[b], dn = normals[b]},
										}
									)
								else
									-- CW winding (matches coordinate transform from Source)
									add_vertex(mesh, texinfo, texdata, false, positions[a], blends[a], flats[a], normals[a])
									add_vertex(mesh, texinfo, texdata, false, positions[c], blends[c], flats[c], normals[c])
									add_vertex(mesh, texinfo, texdata, false, positions[b], blends[b], flats[b], normals[b])
									add_vertex(mesh, texinfo, texdata, false, positions[c], blends[c], flats[c], normals[c])
									add_vertex(mesh, texinfo, texdata, false, positions[d], blends[d], flats[d], normals[d])
									add_vertex(mesh, texinfo, texdata, false, positions[b], blends[b], flats[b], normals[b])
								end
							end
						end

						do
							local collision_shape = build_displacement_collision_shape(positions, dims)

							if collision_shape then
								list.insert(displacement_collision_meshes, collision_shape)
							end
						end
					end
				end

				::continue::

				tasks.ReportProgress("building meshes", model.numfaces)
				tasks.Wait()
			end

			-- only world needed
			break
		end

		-- overlays and decals are rectangles of a material laid over faces. one
		-- fragment is the part of a face inside the rectangle, which is given
		-- by two axes in the plane and its extents along them from origin
		local add_decal_fragment

		do
			local offset_from_surface = 0.3
			local edges = {
				{"x", 1},
				{"x", -1},
				{"y", 1},
				{"y", -1},
			}

			function add_decal_fragment(
				face_index,
				origin,
				normal,
				u_axis,
				v_axis,
				min_x,
				max_x,
				min_y,
				max_y,
				u_range,
				v_range,
				texname
			)
				local face = header.faces[1 + face_index]

				if face.dispinfo ~= -1 then return end

				local area = get_face_area(face_index + 1)

				if sky_areas[area] then return end

				local polygon = {}

				for j = 1, face.numedges do
					local surfedge = header.surfedges[face.firstedge + j]
					local position = header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and
					2 or
					1]]
					local offset = position - origin
					polygon[j] = {x = offset:Dot(u_axis), y = offset:Dot(v_axis), pos = position}
				end

				for _, edge in ipairs(edges) do
					local axis, sign = edge[1], edge[2]
					local limit = axis == "x" and (sign == 1 and min_x or max_x) or (sign == 1 and min_y or max_y)
					local clipped = {}
					local previous = polygon[#polygon]
					local previous_d = (previous[axis] - limit) * sign

					for _, vertex in ipairs(polygon) do
						local d = (vertex[axis] - limit) * sign

						if (previous_d < 0) ~= (d < 0) then
							local t = previous_d / (previous_d - d)
							list.insert(
								clipped,
								{
									x = previous.x + (vertex.x - previous.x) * t,
									y = previous.y + (vertex.y - previous.y) * t,
									pos = previous.pos + (vertex.pos - previous.pos) * t,
								}
							)
						end

						if d >= 0 then list.insert(clipped, vertex) end

						previous, previous_d = vertex, d
					end

					polygon = clipped

					if #polygon < 3 then return end
				end

				local group = area_groups[area]
				local key = (group or 0) .. " overlay " .. texname

				if not meshes[key] then
					local mesh = Polygon3D.New()
					mesh:SetName(path .. ": overlay " .. texname)
					local material = Material.FromVMT("materials/" .. texname .. ".vmt")
					mesh.material = material
					meshes[key] = {mesh = mesh, material = material, visibility_group = group}
					list.insert(models, meshes[key])
				end

				local mesh = meshes[key].mesh

				for j = 2, #polygon - 1 do
					for _, vertex in ipairs{polygon[1], polygon[j], polygon[j + 1]} do
						local position = vertex.pos + normal * offset_from_surface
						mesh:AddVertex{
							pos = Vec3(-position.y, position.z, -position.x) * steam.source2meters,
							texture_blend = 0,
							uv = Vec2(
								u_range[1] + (u_range[2] - u_range[1]) * (vertex.x - min_x) / (max_x - min_x),
								v_range[1] + (v_range[2] - v_range[1]) * (vertex.y - min_y) / (max_y - min_y)
							),
						}
					end
				end
			end
		end

		-- the overlay lump stores a quad's corners as offsets along the overlay's
		-- own u and v axes, and which way u points as its coefficients along the
		-- two axes of a frame built from the normal (the z of the first two
		-- corners). the frame's axes are world axes, not the viewer's right and
		-- up, so walls facing the other way come out upside down until the
		-- flipped u and v ranges turn them
		if RENDER_2D and header.overlays then
			for _, overlay in ipairs(header.overlays) do
				local normal = overlay.normal
				local points = overlay.uv_points
				local dominant_x, dominant_y = math.abs(normal.x), math.abs(normal.y)
				local axis_a, axis_b

				if dominant_x > dominant_y and dominant_x >= math.abs(normal.z) then
					axis_b = (Vec3(0, 1, 0) - normal * normal.y):GetNormalized()
					axis_a = axis_b:GetCross(normal)
				else
					axis_a = (Vec3(1, 0, 0) - normal * normal.x):GetNormalized()
					axis_b = normal:GetCross(axis_a)
				end

				local u_axis = (axis_a * points[3] + axis_b * points[6]):GetNormalized()
				local v_axis = normal:GetCross(u_axis)
				local texinfo = header.texinfos[1 + overlay.texinfo]
				local texname = header.texdatastringdata[1 + header.texdatas[1 + texinfo.texdata].nameStringTableID]

				for i = 1, bit.band(overlay.face_count_and_render_order, 0x3fff) do
					local face_index = overlay.faces[i]

					-- the overlay's normal is its face's plane normal as stored, whatever
					-- the face's side. a face at an angle to it, like a stair riser
					-- under a runner, would only smear it
					if
						header.planes[header.faces[1 + face_index].planenum + 1].normal:Dot(normal) >= 0.5
					then
						add_decal_fragment(
							face_index,
							overlay.origin,
							normal,
							u_axis,
							v_axis,
							points[1],
							points[7],
							points[2],
							points[5],
							overlay.u_range,
							overlay.v_range,
							texname
						)
					end
				end
			end
		end

		-- an infodecal is only a texture and an origin on a surface. it covers
		-- the texture's size times the material's $decalscale, laid over the
		-- faces the origin is on along their own texture axes
		if RENDER_2D then
			local unit_range = {0, 1}
			local decal_sizes = {}
			local world = header.models[1]
			local decal_count = 0

			for _, ent in ipairs(header.entities) do
				if ent.classname ~= "infodecal" or ent.model_size_mult or not ent.texture then
					goto next_decal
				end

				do
					local size = decal_sizes[ent.texture]

					if size == nil then
						size = false
						local material = Material.FromVMT("materials/" .. ent.texture .. ".vmt")
						local vmt = material.vmt
						local data = vmt and vmt.basetexture and vfs.Read(vmt.basetexture)

						if data then
							-- width and height are 16 bit little endian at byte 16 of a vtf header
							local scale = tonumber(vmt.decalscale) or 1
							size = {
								(
									data:byte(17) + data:byte(18) * 256
								) * scale,
								(
									data:byte(19) + data:byte(20) * 256
								) * scale,
							}
						end

						decal_sizes[ent.texture] = size
					end

					if not size then goto next_decal end

					local half_width, half_height = size[1] / 2, size[2] / 2

					for i = 1, world.numfaces do
						local face = header.faces[world.firstface + i]
						local plane = header.planes[face.planenum + 1]

						if math.abs(plane.normal:Dot(ent.origin) - plane.dist) < 1.5 then
							local normal = plane.normal
							local vecs = header.texinfos[1 + face.texinfo].textureVecs
							local u_axis = (
								Vec3(vecs[1], vecs[2], vecs[3]) - normal * (
									vecs[1] * normal.x + vecs[2] * normal.y + vecs[3] * normal.z
								)
							):GetNormalized()
							local v_axis = Vec3(vecs[5], vecs[6], vecs[7])
							v_axis = (
								v_axis - u_axis * u_axis:Dot(v_axis) - normal * normal:Dot(v_axis)
							):GetNormalized()
							add_decal_fragment(
								world.firstface + i - 1,
								ent.origin,
								normal,
								u_axis,
								v_axis,
								-half_width,
								half_width,
								-half_height,
								half_height,
								unit_range,
								unit_range,
								ent.texture
							)
						end
					end

					decal_count = decal_count + 1
					tasks.Wait()
				end

				::next_decal::
			end

			logn("placed ", decal_count, " infodecals")
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

				for k = 0, 2 do
					local vertex = vertices[i + k]
					local disp_normal = vertex.disp_normal

					if disp_normal and (disp_normal.x ~= 0 or disp_normal.y ~= 0 or disp_normal.z ~= 0) then
						disp_normal:Normalize()
						vertex.normal = disp_normal
					end
				end

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
	--render3d.SetOceanEnabled(true)
	steam.loaded_bsp[path] = {
		render_meshes = render_meshes,
		entities = header.entities,
		physics_body = physics_body,
		physics_body_info = physics_body_info,
		cubemaps = header.cubemaps,
		visibility = header.visibility,
		water_volumes = header.water_volumes,
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

		VisibilityGroup.SetLocator(nil)
		VisibilityGroup.SetActive(nil)
		local groups = {}

		-- what belongs to no group (the skybox, what's inside walls) goes
		-- straight under the world
		local function get_container(id)
			if not id then return parent end

			if not groups[id] then
				local group = Entity.New{Name = "visibility_group_" .. id, Parent = parent}
				group:AddComponent("transform")
				group:AddComponent("visibility_group")
				group.spawned_from_bsp = true
				groups[id] = group
			end

			return groups[id]
		end

		-- lights, water and each class of prop are kept together in a container
		local sub_groups = {}

		local function get_sub_group(container, name)
			sub_groups[container] = sub_groups[container] or {}
			local sub_group = sub_groups[container][name]

			if not sub_group then
				sub_group = Entity.New{Name = name, Parent = container}
				sub_group.spawned_from_bsp = true
				sub_groups[container][name] = sub_group
			end

			return sub_group
		end

		if RENDER_2D then
			local worlds = {}

			for _, prim in ipairs(data.render_meshes) do
				local container = get_container(prim.visibility_group)
				local world = worlds[container]

				if not world then
					world = Entity.New{Name = "world", Parent = container}
					world:AddComponent("transform")
					world:AddComponent("visual")
					world.spawned_from_bsp = true
					worlds[container] = world
				end

				world.visual:CreatePrimitiveEntity(prim.mesh, prim.material, "world_primitive")
			end

			for _, world in pairs(worlds) do
				world.visual:BuildAABB()
			end
		end

		if data.visibility.group_count > 0 then
			local point_leaf = data.visibility.point_leaf
			local area_groups = data.visibility.area_groups
			local group_bounds = data.visibility.group_bounds
			local group_ids = {}

			-- every group, so being in one that has nothing in it still hides
			-- the others
			for id = 1, data.visibility.group_count do
				group_ids[get_container(id).visibility_group] = id
			end

			-- in solid space the camera is either in a wall of the group it's in,
			-- and keeps it, or outside of the map, where it sees every group
			VisibilityGroup.SetLocator(function(pos)
				local source = Vec3(-pos.z, -pos.x, pos.y) / steam.source2meters
				local area = point_leaf(source).area

				if area ~= 0 then
					local id = area_groups[area]
					return id and groups[id].visibility_group or false
				end

				local active = VisibilityGroup.GetActive()
				local bounds = active and group_bounds[group_ids[active]]

				if
					bounds and
					source.x >= bounds.min.x and
					source.y >= bounds.min.y and
					source.z >= bounds.min.z and
					source.x <= bounds.max.x and
					source.y <= bounds.max.y and
					source.z <= bounds.max.z
				then
					return nil
				end

				return false
			end)
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
					local ent = Entity.New{
						Name = info.classname,
						Parent = get_sub_group(get_container(info.visibility_group), "lights"),
					}
					local tr = ent:AddComponent("transform")
					set_transform(tr, info, true)
					local is_spot = info.classname == "light_spot"
					local light = ent:AddComponent(is_spot and "light_spot" or "light_point")
					local params = convert_source_light_to_engine(info)
					light:SetColor(params.color)

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

					light:SetRange(params.range)
					light:SetSourceRadius(params.source_radius)
					light:SetLinearFalloff(params.linear_falloff)
					light:SetQuadraticFalloff(params.quadratic_falloff)
					-- the colour is vrad's radiance, not a tint: its luminance is part of the brightness
					light:SetLumen(params.intensity * params.color:GetLuminance() * light:GetEmissionSolidAngle())
					--light:SetCastShadows{shadow_update_mode = "on_move"}
					ent.spawned_from_bsp = true
					ent.bsp_info = info
				elseif info.classname == "env_fog_controller" then

				--parent.world_params:SetFogColor(Color(info.fogcolor.r, info.fogcolor.g, info.fogcolor.b, info.fogcolor.a * (info.fogmaxdensity or 1)/4))
				--parent.world_params:SetFogStart(info.fogstart* steam.source2meters)
				--parent.world_params:SetFogEnd(info.fogend * steam.source2meters)
				end
			end

			-- "*n" models are the map's brush entities, their faces are already part of the world
			if
				info.origin and
				info.angles and
				info.model and
				info.model:sub(1, 1) ~= "*" and
				not info.classname:lower():find("npc")
				and
				info.classname ~= "env_sprite"
			then
				-- source's file system ignores case, the entity lump and static props don't match the vpks
				local model_path = vfs.FindMixedCasePath(info.model)

				if model_path then
					handled[info.classname] = (handled[info.classname] or 0) + 1
					local ent = Entity.New{
						Name = "prop",
						Parent = get_sub_group(get_container(info.visibility_group), info.classname),
					}
					local tr = ent:AddComponent("transform")
					set_transform(tr, info)

					if info.model_size_mult then
						ent.transform:SetSize(info.model_size_mult)
					end

					ent:AddComponent("visual")
					ent.visual:SetModelPath(model_path)

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

		if RENDER_3D and data.water_volumes and data.water_volumes[1] then
			for _, info in ipairs(data.water_volumes) do
				local ent = Entity.New{
					Name = info.texname,
					Parent = get_sub_group(get_container(info.visibility_group), "water"),
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
				}
				ent.spawned_from_bsp = true
			end

			handled.water = #data.water_volumes
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
				"%s #%d at %.2f %.2f %.2f\n  bsp: %s\n  engine: color %.3f %.3f %.3f  lumen %.4g  candela %.4g  range %g  source radius %.2f  linear %.4g  quadratic %.4g  effective range %.2f%s",
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
				light.LinearFalloff,
				light.QuadraticFalloff,
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

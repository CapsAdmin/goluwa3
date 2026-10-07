local vdf = import("goluwa/codecs/vdf.lua")
local vmt_loader = import("goluwa/source_engine/vmt.lua")
local vfs = import("goluwa/vfs.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local brush_hull = import("goluwa/physics/brush_hull.lua")
local bit = require("bit")
local units = import("goluwa/source_engine/units.lua")

local collision = {}
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

local source_pos_to_engine = units.PositionToEngine
local source_plane_to_engine = units.PlaneToEngine
local source_height_to_engine_y = units.LengthToEngine

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

local collect_water_volumes

do
	local water = import("goluwa/render3d/water.lua")
	local MAX_EXTINCTION = 4

	local function read_vmt(path)
		local str = vfs.Read(path) or vfs.Read(vfs.FindMixedCasePath(path) or path)

		if not str then return nil end

		local vmt = vdf.Decode(str, "vmt")

		if vmt then vmt_loader.ConvertTypedValues(vmt) end

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
			math.min(3 / math.max(fog_end * units.meters, 0.5), MAX_EXTINCTION),
			4
		)
	end

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

local function build_displacement_collision_shape(positions, dims)
	local scale = units.meters
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


collision.BSP_CONTENTS_SOLID = BSP_CONTENTS_SOLID
collision.build_bsp_physics_body = build_bsp_physics_body
collision.build_displacement_collision_shape = build_displacement_collision_shape
collision.get_displacement_corners = get_displacement_corners
collision.collect_water_volumes = collect_water_volumes
collision.get_model_lowest_point = get_model_lowest_point
collision.get_face_first_source_height = get_face_first_source_height
collision.source_pos_to_engine = source_pos_to_engine
collision.source_height_to_engine_y = source_height_to_engine_y

return collision

local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local collision = import("goluwa/source_engine/bsp_collision.lua")
local units = import("goluwa/source_engine/units.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local tasks = import("goluwa/tasks.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local static_geometry = {}
static_geometry.SIDE_STRIDE = 7

local function weld_key(position)
	return (
			(
				math.floor(position.x * 4 + 0.5) + 65536
			) * 131072 + math.floor(position.y * 4 + 0.5) + 65536
		) * 131072 + math.floor(position.z * 4 + 0.5) + 65536
end

function static_geometry.AddVertex(mesh, texinfo, position, blend, uv_position, normal)
	local vecs = texinfo.vecs
	local uv_source = uv_position or position
	mesh:AddVertex{
		pos = units.PositionToEngine(position),
		texture_blend = math.clamp(blend, 0, 1),
		uv = Vec2(
			vecs[1] * uv_source.x + vecs[2] * uv_source.y + vecs[3] * uv_source.z + vecs[4],
			vecs[5] * uv_source.x + vecs[6] * uv_source.y + vecs[7] * uv_source.z + vecs[8]
		),
		normal = normal,
	}
end

-- A record is the runtime form of one static source:
-- brush: {sides = {{normal, dist, texname, vecs, visible}}, group, collide}
-- displacement: {dims, positions (source space Vec3), alphas, corners, texname, vecs, normal, group}
-- mesh: {positions (source space Vec3, three per triangle), uvs (flat u, v), blends, normals (engine space Vec3, may be nil), texname, group, collide}
-- group is whatever identifies the visibility group of the source, it only has to be usable as a table key.
-- mins, maxs and spans are filled in by the Emit functions.
function static_geometry.NewState(name)
	return {
		batches = {},
		by_key = {},
		group_ids = {},
		group_count = 0,
		name = name or "static world",
		render = RENDER_2D,
	}
end

function static_geometry.GetBatch(state, texname, group, kind)
	local group_id = 0

	if group then
		group_id = state.group_ids[group]

		if not group_id then
			state.group_count = state.group_count + 1
			group_id = state.group_count
			state.group_ids[group] = group_id
		end
	end

	local key = group_id .. " " .. (kind or "") .. " " .. texname
	local batch = state.by_key[key]

	if not batch then
		local mesh = Polygon3D.New()
		local material = vmt_material.FromVMT("materials/" .. texname .. ".vmt")
		mesh:SetName(state.name .. ": " .. texname)
		mesh.material = material
		batch = {mesh = mesh, material = material, visibility_group = group}
		state.by_key[key] = batch
		list.insert(state.batches, batch)
		batch.is_new = true
	end

	return batch
end

function static_geometry.ExpandBrush(world, index)
	local brush = world.Brushes[index]
	local flat = brush.Sides
	local stride = static_geometry.SIDE_STRIDE
	local sides = {}
	local group

	for side_index = 1, #flat / stride do
		local o = (side_index - 1) * stride
		local texinfo = flat[o + 5] > 0 and world.Texinfos[flat[o + 5]]
		sides[side_index] = {
			normal = Vec3(flat[o + 1], flat[o + 2], flat[o + 3]),
			dist = flat[o + 4],
			texname = texinfo and texinfo.texname,
			vecs = texinfo and texinfo.vecs,
			visible = flat[o + 7] == 1,
		}

		if flat[o + 7] == 1 and flat[o + 6] > 0 then group = group or flat[o + 6] end
	end

	return {
		kind = "brush",
		index = index,
		sides = sides,
		group = group,
		spans = {},
		collide = brush.Collide,
		mins = Vec3(math.huge, math.huge, math.huge),
		maxs = Vec3(-math.huge, -math.huge, -math.huge),
	}
end

function static_geometry.UpdateDisplacementBounds(record)
	local mins = Vec3(math.huge, math.huge, math.huge)
	local maxs = Vec3(-math.huge, -math.huge, -math.huge)

	for _, position in ipairs(record.positions) do
		for _, axis in ipairs({"x", "y", "z"}) do
			mins[axis] = math.min(mins[axis], position[axis])
			maxs[axis] = math.max(maxs[axis], position[axis])
		end
	end

	record.mins, record.maxs = mins, maxs
end

function static_geometry.ExpandDisplacement(world, index)
	local displacement = world.Displacements[index]
	local texinfo = world.Texinfos[displacement.Texinfo]
	local dims = 2 ^ displacement.Power + 1
	local flat = displacement.Positions
	local positions = {}

	for i = 1, dims * dims do
		positions[i] = Vec3(flat[i * 3 - 2], flat[i * 3 - 1], flat[i * 3])
	end

	local record = {
		kind = "displacement",
		index = index,
		dims = dims,
		positions = positions,
		alphas = displacement.Alphas,
		corners = displacement.Corners,
		texname = texinfo.texname,
		vecs = texinfo.vecs,
		normal = displacement.Normal,
		group = displacement.Group > 0 and displacement.Group or nil,
		spans = {},
	}
	static_geometry.UpdateDisplacementBounds(record)
	return record
end

function static_geometry.ExpandMesh(world, index)
	local mesh = world.Meshes[index]
	local flat = mesh.Vertices
	local positions, uvs, blends, normals = {}, {}, {}, {}

	for i = 1, #flat / 9 do
		local o = (i - 1) * 9
		positions[i] = Vec3(flat[o + 1], flat[o + 2], flat[o + 3])
		uvs[i * 2 - 1], uvs[i * 2] = flat[o + 4], flat[o + 5]
		blends[i] = flat[o + 6]
		normals[i] = Vec3(flat[o + 7], flat[o + 8], flat[o + 9])
	end

	local record = {
		kind = "mesh",
		index = index,
		positions = positions,
		uvs = uvs,
		blends = blends,
		normals = normals,
		texname = world.Texinfos[mesh.Texinfo].texname,
		group = mesh.Group > 0 and mesh.Group or nil,
		collide = mesh.Collide ~= false,
		spans = {},
	}
	static_geometry.UpdateDisplacementBounds(record)
	return record
end

-- the records of the importer's world data
function static_geometry.ExpandWorld(world)
	local brushes, displacements, meshes = {}, {}, {}

	for index = 1, #world.Meshes do
		meshes[index] = static_geometry.ExpandMesh(world, index)
	end

	for index = 1, #world.Brushes do
		brushes[index] = static_geometry.ExpandBrush(world, index)
	end

	for index = 1, #world.Displacements do
		displacements[index] = static_geometry.ExpandDisplacement(world, index)
	end

	return brushes, displacements, meshes
end

function static_geometry.UpdateBrushBounds(record)
	record.mins = Vec3(math.huge, math.huge, math.huge)
	record.maxs = Vec3(-math.huge, -math.huge, -math.huge)

	for side_index in ipairs(record.sides) do
		local polygon = brush_geometry.ClipSide(record.sides, side_index)

		if polygon then
			for _, point in ipairs(polygon) do
				for _, axis in ipairs({"x", "y", "z"}) do
					record.mins[axis] = math.min(record.mins[axis], point[axis])
					record.maxs[axis] = math.max(record.maxs[axis], point[axis])
				end
			end
		end
	end
end

-- updates the bounds and, when rendering, appends the triangles of a brush to the batches
function static_geometry.EmitBrush(state, record)
	record.spans = {}
	record.visible = nil
	record.mins = Vec3(math.huge, math.huge, math.huge)
	record.maxs = Vec3(-math.huge, -math.huge, -math.huge)

	for side_index, side in ipairs(record.sides) do
		local polygon = brush_geometry.ClipSide(record.sides, side_index)

		if polygon then
			for _, point in ipairs(polygon) do
				for _, axis in ipairs({"x", "y", "z"}) do
					record.mins[axis] = math.min(record.mins[axis], point[axis])
					record.maxs[axis] = math.max(record.maxs[axis], point[axis])
				end
			end

			if state.render and side.visible then
				local batch = static_geometry.GetBatch(state, side.texname, record.group)
				local mesh = batch.mesh
				local first = mesh.i

				for j = 2, #polygon - 1 do
					local first_index = mesh.i
					static_geometry.AddVertex(mesh, side, polygon[1], 0)
					static_geometry.AddVertex(mesh, side, polygon[j], 0)
					static_geometry.AddVertex(mesh, side, polygon[j + 1], 0)
					local vertices = mesh.Vertices
					local a, b, c = vertices[first_index], vertices[first_index + 1], vertices[first_index + 2]
					local normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
					a.normal, b.normal, c.normal = normal, normal, normal
				end

				record.visible = true
				list.insert(record.spans, {entry = batch, first = first, count = mesh.i - first})
			end
		end
	end
end

-- appends the triangles of a mesh to the batches. Without normals every triangle is shaded flat.
function static_geometry.EmitMesh(state, record)
	record.spans = {}
	record.visible = nil

	if not state.render then return end

	local batch = static_geometry.GetBatch(state, record.texname, record.group)
	local mesh = batch.mesh
	local first = mesh.i
	local positions, uvs, blends, normals = record.positions, record.uvs, record.blends, record.normals

	for i = 1, #positions, 3 do
		local first_index = mesh.i

		for j = i, i + 2 do
			mesh:AddVertex{
				pos = units.PositionToEngine(positions[j]),
				uv = Vec2(uvs[j * 2 - 1], uvs[j * 2]),
				texture_blend = blends[j],
				normal = normals and normals[j],
			}
		end

		if not normals then
			local vertices = mesh.Vertices
			local a, b, c = vertices[first_index], vertices[first_index + 1], vertices[first_index + 2]
			local normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
			a.normal, b.normal, c.normal = normal, normal, normal
		end
	end

	if mesh.i > first then
		record.visible = true
		list.insert(record.spans, {entry = batch, first = first, count = mesh.i - first})
	end
end

-- the summed, unnormalized vertex normals of one displacement, indexed like record.positions
function static_geometry.ComputeDisplacementNormals(record)
	local dims, positions = record.dims, record.positions
	local points, nx, ny, nz = {}, {}, {}, {}

	for i = 1, dims * dims do
		points[i] = units.PositionToEngine(positions[i])
		nx[i], ny[i], nz[i] = 0, 0, 0
	end

	for x = 1, dims - 1 do
		for y = 1, dims - 1 do
			local a = y * dims + x
			local b = (y - 1) * dims + x
			local c = a + 1
			local d = b + 1

			for _, triangle in ipairs{{a, c, b}, {c, d, b}} do
				local i, j, k = triangle[1], triangle[2], triangle[3]
				local normal = (points[k] - points[i]):Cross(points[j] - points[i])

				for _, vertex in ipairs(triangle) do
					nx[vertex], ny[vertex], nz[vertex] = nx[vertex] + normal.x, ny[vertex] + normal.y, nz[vertex] + normal.z
				end
			end
		end
	end

	local normals = {}

	for i = 1, dims * dims do
		normals[i] = Vec3(nx[i], ny[i], nz[i])
	end

	return normals
end

-- appends the triangles of a displacement to the batches. weld_groups maps the normals of tile edge vertices
-- to every normal sharing that position so the shading is smooth across tiles, it may be nil.
function static_geometry.EmitDisplacement(state, record, normals, weld_groups)
	record.spans = {}
	record.visible = nil

	if not state.render then return end

	local dims, positions = record.dims, record.positions
	local corners = record.corners
	local batch = static_geometry.GetBatch(state, record.texname, record.group)
	local mesh = batch.mesh
	local first = mesh.i
	local flats, smooth = {}, {}

	for y = 1, dims do
		for x = 1, dims do
			local i = (y - 1) * dims + x
			flats[i] = math3d.BilerpVec3(
				corners[1],
				corners[2],
				corners[3],
				corners[4],
				(y - 1) / (dims - 1),
				(x - 1) / (dims - 1)
			)
			local own = normals[i]
			local group = weld_groups and weld_groups[own]
			local own_normalized = own:GetNormalized()

			if group then
				local sum = Vec3(0, 0, 0)

				for _, other in ipairs(group) do
					if other:GetNormalized():Dot(own_normalized) > 0.5 then sum = sum + other end
				end

				smooth[i] = sum:GetNormalized()
			else
				smooth[i] = own_normalized
			end
		end
	end

	for x = 1, dims - 1 do
		for y = 1, dims - 1 do
			local a = y * dims + x
			local b = (y - 1) * dims + x
			local c = a + 1
			local d = b + 1

			for _, vertex in ipairs{a, c, b, c, d, b} do
				static_geometry.AddVertex(
					mesh,
					record,
					positions[vertex],
					record.alphas[vertex] / 255,
					flats[vertex],
					smooth[vertex]
				)
			end
		end
	end

	record.visible = true
	list.insert(record.spans, {entry = batch, first = first, count = mesh.i - first})
end

-- Builds the render batches of every record. Returns {state, batches, brushes, displacements}.
function static_geometry.Build(brushes, displacements, meshes, name)
	local state = static_geometry.NewState(name)

	for index, record in ipairs(brushes) do
		static_geometry.EmitBrush(state, record)

		if index % 200 == 0 then
			tasks.ReportProgress("building brushes", #brushes)
			tasks.Wait()
		end
	end

	local weld_groups = {}
	local welded = {}
	local tiles = {}

	for index, record in ipairs(displacements) do
		local dims, positions = record.dims, record.positions
		local normals = static_geometry.ComputeDisplacementNormals(record)

		for y = 1, dims do
			for x = 1, dims do
				if x == 1 or y == 1 or x == dims or y == dims then
					local i = (y - 1) * dims + x
					local key = weld_key(positions[i])
					local group = welded[key]

					if not group then
						group = {}
						welded[key] = group
					end

					weld_groups[normals[i]] = group
					group[#group + 1] = normals[i]
				end
			end
		end

		tiles[index] = normals

		if index % 50 == 0 then tasks.Wait() end
	end

	for index, record in ipairs(displacements) do
		static_geometry.EmitDisplacement(state, record, tiles[index], weld_groups)
	end

	for _, record in ipairs(meshes) do
		static_geometry.EmitMesh(state, record)
	end

	return {
		state = state,
		batches = state.batches,
		brushes = brushes,
		displacements = displacements,
		meshes = meshes,
	}
end

function static_geometry.UploadBatch(batch)
	batch.mesh:BuildBoundingBox()
	batch.mesh:BuildTangents()
	batch.mesh:Upload(nil)
	batch.is_new = nil
end

-- Uploads every batch that has vertices and drops the empty ones.
function static_geometry.Finalize(result)
	local non_empty = {}

	for _, batch in ipairs(result.state.batches) do
		if #batch.mesh.Vertices > 0 then
			static_geometry.UploadBatch(batch)
			list.insert(non_empty, batch)
		end

		tasks.Wait()
	end

	result.batches = non_empty
	return result
end

-- Appends a convex polygon of {pos, u, v} (source space positions) to a batch mesh as a flat shaded triangle fan,
-- returns the first vertex index and the vertex count.
function static_geometry.AddPolygon(mesh, polygon)
	local first = mesh.i

	for j = 2, #polygon - 1 do
		local first_index = mesh.i

		for _, vertex in ipairs{polygon[1], polygon[j], polygon[j + 1]} do
			mesh:AddVertex{
				pos = units.PositionToEngine(vertex.pos),
				texture_blend = 0,
				uv = Vec2(vertex.u, vertex.v),
			}
		end

		local vertices = mesh.Vertices
		local a, b, c = vertices[first_index], vertices[first_index + 1], vertices[first_index + 2]
		local normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
		a.normal, b.normal, c.normal = normal, normal, normal
	end

	return first, mesh.i - first
end

-- Builds the collision shapes of the records: the brush model with one primitive per collidable brush, plus a shape per
-- displacement. Returns shapes, model, a record to brush primitive map; displacement records get a collision_shape.
function static_geometry.BuildColliders(brushes, displacements, meshes)
	local model = {
		Visible = true,
		WorldSpaceVertices = true,
		Primitives = {},
		AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge),
	}
	local brush_primitives = {}
	local shapes = {}

	for _, record in ipairs(brushes) do
		if record.collide then
			local planes = {}

			for i, side in ipairs(record.sides) do
				planes[i] = units.PlaneToEngine(side)
			end

			local primitive = collision.build_brush_primitive(planes)

			if primitive and primitive.aabb then
				brush_primitives[record] = primitive
				list.insert(model.Primitives, primitive)
				model.AABB:Expand(primitive.aabb)
			end
		end
	end

	if model.Primitives[1] then list.insert(shapes, {Model = model}) end

	for _, record in ipairs(displacements) do
		record.collision_shape = collision.build_displacement_collision_shape(record.positions, record.dims)
		list.insert(shapes, record.collision_shape)
	end

	for _, record in ipairs(meshes) do
		if record.collide then
			record.collision_shape = collision.build_triangle_soup_shape(record.positions)
			list.insert(shapes, record.collision_shape)
		end
	end

	return shapes, model, brush_primitives
end

return static_geometry

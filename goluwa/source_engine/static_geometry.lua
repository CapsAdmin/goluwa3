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

function static_geometry.GetBatch(state, texname, group, kind)
	local key = (group or 0) .. " " .. (kind and (kind .. " ") or "") .. texname
	local batch = state.by_key[key]

	if not batch then
		local mesh = Polygon3D.New()
		local material = vmt_material.FromVMT("materials/" .. texname .. ".vmt")
		mesh:SetName(state.name .. ": " .. texname)
		mesh.material = material
		batch = {mesh = mesh, material = material, visibility_group = group, sky = kind == "sky"}
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

	for side_index = 1, #flat / stride do
		local o = (side_index - 1) * stride
		local texinfo = flat[o + 5] > 0 and world.Texinfos[flat[o + 5]]
		sides[side_index] = {
			normal = Vec3(flat[o + 1], flat[o + 2], flat[o + 3]),
			dist = flat[o + 4],
			texname = texinfo and texinfo.texname,
			vecs = texinfo and texinfo.vecs,
			visible = flat[o + 7] == 1,
			group = flat[o + 6] > 0 and flat[o + 6] or nil,
		}
	end

	return {
		index = index,
		sides = sides,
		spans = {},
		collide = brush.Collide,
		sky = brush.Sky,
		mins = Vec3(math.huge, math.huge, math.huge),
		maxs = Vec3(-math.huge, -math.huge, -math.huge),
	}
end

function static_geometry.ExpandDisplacement(world, index)
	local displacement = world.Displacements[index]
	local texinfo = world.Texinfos[displacement.Texinfo]
	local dims = 2 ^ displacement.Power + 1
	local flat = displacement.Positions
	local positions = {}
	local mins = Vec3(math.huge, math.huge, math.huge)
	local maxs = Vec3(-math.huge, -math.huge, -math.huge)

	for i = 1, dims * dims do
		local position = Vec3(flat[i * 3 - 2], flat[i * 3 - 1], flat[i * 3])
		positions[i] = position

		for _, axis in ipairs({"x", "y", "z"}) do
			mins[axis] = math.min(mins[axis], position[axis])
			maxs[axis] = math.max(maxs[axis], position[axis])
		end
	end

	return {
		index = index,
		power = displacement.Power,
		dims = dims,
		positions = positions,
		alphas = displacement.Alphas,
		corners = displacement.Corners,
		texname = texinfo.texname,
		vecs = texinfo.vecs,
		normal = displacement.Normal,
		group = displacement.Group > 0 and displacement.Group or nil,
		sky = displacement.Sky,
		mins = mins,
		maxs = maxs,
		spans = {},
	}
end

-- Builds render batches and per record runtime tables from the stored world data.
-- Returns {batches, brushes, displacements}; batches are {mesh, material, visibility_group}.
function static_geometry.Build(world, name)
	local render = RENDER_2D
	local state = {batches = {}, by_key = {}, name = name or "static world"}
	local result = {batches = state.batches, brushes = {}, displacements = {}}

	for index = 1, #world.Brushes do
		local record = static_geometry.ExpandBrush(world, index)
		result.brushes[index] = record

		for side_index, side in ipairs(record.sides) do
			local polygon = brush_geometry.ClipSide(record.sides, side_index)

			if polygon then
				for _, point in ipairs(polygon) do
					for _, axis in ipairs({"x", "y", "z"}) do
						record.mins[axis] = math.min(record.mins[axis], point[axis])
						record.maxs[axis] = math.max(record.maxs[axis], point[axis])
					end
				end

				if render and side.visible then
					local batch = static_geometry.GetBatch(state, side.texname, side.group, record.sky and "sky" or nil)
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
					record.group = record.group or side.group
					list.insert(record.spans, {entry = batch, first = first, count = mesh.i - first})
				end
			end
		end

		if index % 200 == 0 then
			tasks.ReportProgress("building brushes", #world.Brushes)
			tasks.Wait()
		end
	end

	local weld_groups = {}
	local welded = {}
	local tiles = {}

	for index = 1, #world.Displacements do
		local record = static_geometry.ExpandDisplacement(world, index)
		result.displacements[index] = record
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

		for y = 1, dims do
			for x = 1, dims do
				local i = (y - 1) * dims + x
				normals[i] = Vec3(nx[i], ny[i], nz[i])

				if x == 1 or y == 1 or x == dims or y == dims then
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

	for index = 1, #world.Displacements do
		local record = result.displacements[index]
		local normals = tiles[index]

		if render then
			local dims, positions = record.dims, record.positions
			local corners = record.corners
			local batch = static_geometry.GetBatch(state, record.texname, record.group, record.sky and "sky" or nil)
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
					local group = weld_groups[own]
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
	end

	result.state = state
	return result
end

do
	local MARGIN = 0.5 / units.meters

	-- the bounds of everything that is not sky, in engine space as {min xyz, max xyz}, sky geometry is clipped away inside of it
	function static_geometry.GetSkyClip(result)
		local mins = Vec3(math.huge, math.huge, math.huge)
		local maxs = Vec3(-math.huge, -math.huge, -math.huge)
		local has_sky = false

		for _, records in ipairs{result.brushes, result.displacements} do
			for _, record in ipairs(records) do
				if record.sky then
					has_sky = true
				elseif record.mins.x <= record.maxs.x then
					for _, axis in ipairs({"x", "y", "z"}) do
						mins[axis] = math.min(mins[axis], record.mins[axis])
						maxs[axis] = math.max(maxs[axis], record.maxs[axis])
					end
				end
			end
		end

		if not has_sky or mins.x > maxs.x then return nil end

		local margin = Vec3(MARGIN, MARGIN, MARGIN)
		local a = units.PositionToEngine(mins - margin)
		local b = units.PositionToEngine(maxs + margin)
		return {
			math.min(a.x, b.x),
			math.min(a.y, b.y),
			math.min(a.z, b.z),
			math.max(a.x, b.x),
			math.max(a.y, b.y),
			math.max(a.z, b.z),
		}
	end
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

-- Builds the static physics body config from the runtime records, plus a brush index to primitive map.
function static_geometry.BuildPhysics(result)
	local model = {
		Visible = true,
		WorldSpaceVertices = true,
		Primitives = {},
		AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge),
	}
	local brush_primitives = {}
	local shapes = {}

	for index, record in ipairs(result.brushes) do
		if record.collide then
			local planes = {}

			for i, side in ipairs(record.sides) do
				planes[i] = units.PlaneToEngine(side)
			end

			local primitive = collision.build_brush_primitive(planes)

			if primitive and primitive.aabb then
				primitive.brush_index = index
				brush_primitives[index] = primitive
				list.insert(model.Primitives, primitive)
				model.AABB:Expand(primitive.aabb)
			end
		end
	end

	if model.Primitives[1] then list.insert(shapes, {Model = model}) end

	for _, record in ipairs(result.displacements) do
		record.collision_shape = collision.build_displacement_collision_shape(record.positions, record.dims)
		list.insert(shapes, record.collision_shape)
	end

	if not shapes[1] then return nil end

	return {
		Shapes = shapes,
		MotionType = "static",
		Friction = 0.85,
		Restitution = 0,
		WorldGeometry = true,
	},
	model,
	brush_primitives
end

return static_geometry

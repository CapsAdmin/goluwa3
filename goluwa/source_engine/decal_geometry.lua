local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local units = import("goluwa/source_engine/units.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
local decal_geometry = {}
local OFFSET_FROM_SURFACE = 0.3
local EDGES = {{"x", 1}, {"x", -1}, {"y", 1}, {"y", -1}}

local function weld_key(position)
	return (
			(
				math.floor(position.x * 4 + 0.5) + 65536
			) * 131072 + math.floor(position.y * 4 + 0.5) + 65536
		) * 131072 + math.floor(position.z * 4 + 0.5) + 65536
end

-- polygon is a list of {x, y, pos}, clips it to the decal rectangle and appends {group, polygon of {pos, u, v}}
local function add_fragment(fragments, polygon, group, frame)
	for _, edge in ipairs(EDGES) do
		local axis, sign = edge[1], edge[2]
		local limit = axis == "x" and
			(
				sign == 1 and
				frame.min_x or
				frame.max_x
			)
			or
			(
				sign == 1 and
				frame.min_y or
				frame.max_y
			)
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

	local out = {}
	local u_range, v_range = frame.u_range, frame.v_range
	local u_min, u_size = u_range.x, u_range.y - u_range.x
	local v_min, v_size = v_range.x, v_range.y - v_range.x

	for i, vertex in ipairs(polygon) do
		out[i] = {
			pos = vertex.pos,
			u = u_min + u_size * (
					vertex.x - frame.min_x
				) / (
					frame.max_x - frame.min_x
				),
			v = v_min + v_size * (
					vertex.y - frame.min_y
				) / (
					frame.max_y - frame.min_y
				),
		}
	end

	list.insert(fragments, {group = group, polygon = out})
end

local function project_brush_side(fragments, record, side_index, origin, normal, u_axis, v_axis, frame)
	local points = brush_geometry.ClipSide(record.sides, side_index)

	if not points then return end

	local polygon = {}

	for j, point in ipairs(points) do
		local offset = point - origin
		polygon[j] = {
			x = offset:Dot(u_axis),
			y = offset:Dot(v_axis),
			pos = point + normal * OFFSET_FROM_SURFACE,
		}
	end

	add_fragment(fragments, polygon, record.group, frame)
end

local function project_displacements(fragments, records, origin, normal, u_axis, v_axis, frame)
	local verts = {}
	local vert_count = 0
	local tris = {}
	local edge_tris = {}

	for _, record in ipairs(records) do
		local positions, dims = record.positions, record.dims
		local grid = {}

		for i = 1, dims * dims do
			local position = positions[i]
			local key = weld_key(position)
			local vert = verts[key]

			if not vert then
				vert_count = vert_count + 1
				local offset = position - origin
				vert = {
					id = vert_count,
					pos = position,
					x0 = offset:Dot(u_axis),
					y0 = offset:Dot(v_axis),
					sum = Vec3(0, 0, 0),
				}
				verts[key] = vert
			end

			grid[i] = vert
		end

		for x = 1, dims - 1 do
			for y = 1, dims - 1 do
				local a = y * dims + x
				local b = (y - 1) * dims + x
				local c = a + 1
				local d = b + 1

				for _, corners in ipairs{{a, c, b}, {c, d, b}} do
					local v1, v2, v3 = grid[corners[1]], grid[corners[2]], grid[corners[3]]
					local tri_normal = (v2.pos - v1.pos):Cross(v3.pos - v1.pos):GetNormalized()

					if tri_normal:Dot(record.normal) < 0 then tri_normal = -tri_normal end

					v1.sum = v1.sum + tri_normal
					v2.sum = v2.sum + tri_normal
					v3.sum = v3.sum + tri_normal
					local tri = {v1, v2, v3, normal = tri_normal, group = record.group}
					list.insert(tris, tri)

					for k = 1, 3 do
						local p, q = tri[k], tri[k % 3 + 1]
						local edge_key = math.min(p.id, q.id) * 1048576 + math.max(p.id, q.id)
						local shared = edge_tris[edge_key]

						if not shared then
							shared = {}
							edge_tris[edge_key] = shared
						end

						list.insert(shared, tri)
					end
				end
			end
		end
	end

	if #tris == 0 then return end

	local center_x, center_y = (frame.min_x + frame.max_x) / 2, (frame.min_y + frame.max_y) / 2
	local seeds = {}

	for _, tri in ipairs(tris) do
		if tri.normal:Dot(normal) >= 0.2 then
			local v1, v2, v3 = tri[1], tri[2], tri[3]
			local dx = (v1.x0 + v2.x0 + v3.x0) / 3 - center_x
			local dy = (v1.y0 + v2.y0 + v3.y0) / 3 - center_y
			tri.seed_distance = dx * dx + dy * dy
			list.insert(seeds, tri)
		end
	end

	table.sort(seeds, function(a, b)
		return a.seed_distance < b.seed_distance
	end)

	local queue = {}

	for _, seed in ipairs(seeds) do
		if not seed.visited then
			seed.visited = true

			for k = 1, 3 do
				local vert = seed[k]

				if not vert.x then vert.x, vert.y = vert.x0, vert.y0 end
			end

			local head, tail = 1, 0

			for k = 1, 3 do
				local p, q, o = seed[k], seed[k % 3 + 1], seed[(k + 1) % 3 + 1]
				local edge_key = math.min(p.id, q.id) * 1048576 + math.max(p.id, q.id)

				for _, neighbor in ipairs(edge_tris[edge_key]) do
					if not neighbor.visited then
						tail = tail + 1
						queue[tail] = {neighbor, p, q, o}
					end
				end
			end

			while head <= tail do
				local entry = queue[head]
				queue[head] = nil
				head = head + 1
				local tri, va, vb, vo = entry[1], entry[2], entry[3], entry[4]

				if not tri.visited then
					tri.visited = true

					if tri.normal:Dot(normal) < -0.2 then
						tri.skip = true
					else
						local vc

						for k = 1, 3 do
							if tri[k] ~= va and tri[k] ~= vb then vc = tri[k] end
						end

						if not vc.x then
							local ab = (vb.pos - va.pos):GetLength()
							local ac = (vc.pos - va.pos):GetLength()
							local bc = (vc.pos - vb.pos):GetLength()
							local dir_x, dir_y = vb.x - va.x, vb.y - va.y
							local dir_length = math.sqrt(dir_x * dir_x + dir_y * dir_y)

							if dir_length < 1e-6 then
								dir_x, dir_y = 1, 0
							else
								dir_x, dir_y = dir_x / dir_length, dir_y / dir_length
							end

							local along = ab > 1e-6 and (ac * ac + ab * ab - bc * bc) / (2 * ab) or 0
							local height = math.sqrt(math.max(ac * ac - along * along, 0))
							local side = (dir_x * (vo.y - va.y) - dir_y * (vo.x - va.x)) > 0 and -1 or 1
							vc.x = va.x + dir_x * along - dir_y * height * side
							vc.y = va.y + dir_y * along + dir_x * height * side
						end

						for k = 1, 3 do
							local p, q = tri[k], tri[k % 3 + 1]
							local o = tri[(k + 1) % 3 + 1]
							local edge_key = math.min(p.id, q.id) * 1048576 + math.max(p.id, q.id)

							for _, neighbor in ipairs(edge_tris[edge_key]) do
								if not neighbor.visited then
									tail = tail + 1
									queue[tail] = {neighbor, p, q, o}
								end
							end
						end
					end
				end
			end
		end
	end

	for _, tri in ipairs(tris) do
		if tri.visited and not tri.skip then
			local polygon = {}

			for k = 1, 3 do
				local vert = tri[k]

				if not vert.out then
					vert.out = {
						x = vert.x,
						y = vert.y,
						pos = vert.pos + vert.sum:GetNormalized() * OFFSET_FROM_SURFACE,
					}
				end

				polygon[k] = vert.out
			end

			add_fragment(fragments, polygon, tri.group, frame)
		end
	end
end

local function get_infodecal_axes(normal, vecs)
	local u_axis = (
		Vec3(vecs[1], vecs[2], vecs[3]) - normal * (
			vecs[1] * normal.x + vecs[2] * normal.y + vecs[3] * normal.z
		)
	):GetNormalized()
	local v_axis = Vec3(vecs[5], vecs[6], vecs[7])
	v_axis = (
		v_axis - u_axis * u_axis:Dot(v_axis) - normal * normal:Dot(v_axis)
	):GetNormalized()
	return u_axis, v_axis
end

local function get_overlay_axes(normal, points)
	local dominant_x, dominant_y = math.abs(normal.x), math.abs(normal.y)
	local axis_a, axis_b

	if dominant_x > dominant_y and dominant_x >= math.abs(normal.z) then
		axis_b = (Vec3(0, 1, 0) - normal * normal.y):GetNormalized()
		axis_a = axis_b:GetCross(normal)
	else
		axis_a = (Vec3(1, 0, 0) - normal * normal.x):GetNormalized()
		axis_b = normal:GetCross(axis_a)
	end

	return (axis_a * points[3] + axis_b * points[6]):GetNormalized()
end

-- the orientation of an imported decal from the stored world data, returns normal, u_axis in source space
function decal_geometry.GetInitialAxes(decal, world)
	if decal.Mode == "overlay" then
		return decal.Normal, get_overlay_axes(decal.Normal, decal.UVPoints)
	end

	local target = decal.Targets[1]
	local normal, texinfo

	if target.Brush then
		local o = (target.Side - 1) * static_geometry.SIDE_STRIDE
		local sides = world.Brushes[target.Brush].Sides
		normal = Vec3(sides[o + 1], sides[o + 2], sides[o + 3])
		texinfo = world.Texinfos[sides[o + 5]]
	else
		local displacement = world.Displacements[target.Displacements[1]]
		normal = displacement.Normal
		texinfo = world.Texinfos[displacement.Texinfo]
	end

	return normal, (get_infodecal_axes(normal, texinfo.vecs))
end

do
	local matrix = Matrix44()

	-- the decal frame is u, v = normal x u, normal as the transform's right, up, backward axes
	function decal_geometry.AxesToRotation(normal, u_axis)
		local right = units.PositionToEngine(u_axis):GetNormalized()
		local backward = units.PositionToEngine(normal):GetNormalized()
		local up = backward:GetCross(right)
		matrix:Identity()
		matrix.m00, matrix.m01, matrix.m02 = right.x, right.y, right.z
		matrix.m10, matrix.m11, matrix.m12 = up.x, up.y, up.z
		matrix.m20, matrix.m21, matrix.m22 = backward.x, backward.y, backward.z
		return matrix:GetRotation(Quat()):GetNormalized()
	end
end

function decal_geometry.RotationToAxes(rotation)
	local right = rotation:VecMul(Vec3(1, 0, 0))
	local backward = rotation:VecMul(Vec3(0, 0, 1))
	return units.PositionFromEngine(backward):GetNormalized(),
	units.PositionFromEngine(right):GetNormalized()
end

local function get_frame(decal)
	return {
		min_x = decal.Frame.x,
		min_y = decal.Frame.y,
		max_x = decal.Frame.z,
		max_y = decal.Frame.w,
		u_range = decal.URange,
		v_range = decal.VRange,
	}
end

-- decal fields: Frame (min x, min y, max x, max y), URange, VRange, and the derived Origin, Normal, UAxis, Targets. Returns a list of {group, polygon}.
function decal_geometry.Project(decal)
	local fragments = {}
	local origin, normal = decal.Origin, decal.Normal
	local u_axis = decal.UAxis
	local v_axis = normal:GetCross(u_axis)
	local frame = get_frame(decal)
	local displaced = {}

	for _, target in ipairs(decal.Targets) do
		if target.Brush then
			project_brush_side(
				fragments,
				target.Brush,
				target.Side,
				origin,
				normal,
				u_axis,
				v_axis,
				frame
			)
		else
			for _, record in ipairs(target.Displacements) do
				list.insert(displaced, record)
			end
		end
	end

	if displaced[1] then
		project_displacements(fragments, displaced, origin, normal, u_axis, v_axis, frame)
	end

	return fragments
end

do
	local SURFACE_DEPTH = 8

	-- finds the surfaces the decal rectangle lies on, returns a target list like the importer produces
	function decal_geometry.FindTargets(decal, brush_records, displacement_records)
		local frame = get_frame(decal)
		local origin, normal = decal.Origin, decal.Normal
		local u_axis = decal.UAxis
		local v_axis = normal:GetCross(u_axis)
		local center_x, center_y = (frame.min_x + frame.max_x) / 2, (frame.min_y + frame.max_y) / 2
		local half_x, half_y = (frame.max_x - frame.min_x) / 2, (frame.max_y - frame.min_y) / 2
		local center = origin + u_axis * center_x + v_axis * center_y
		local radius = math.sqrt(half_x * half_x + half_y * half_y) + SURFACE_DEPTH
		local targets = {}

		local function near(record)
			local mins, maxs = record.mins, record.maxs
			local dx = math.max(mins.x - center.x, 0, center.x - maxs.x)
			local dy = math.max(mins.y - center.y, 0, center.y - maxs.y)
			local dz = math.max(mins.z - center.z, 0, center.z - maxs.z)
			return dx * dx + dy * dy + dz * dz <= radius * radius
		end

		for _, record in ipairs(brush_records) do
			if record.visible and near(record) then
				for side_index, side in ipairs(record.sides) do
					if
						side.visible and
						side.normal:Dot(normal) > 0.5 and
						math.abs(side.normal:Dot(center) - side.dist) <= SURFACE_DEPTH
					then
						list.insert(targets, {Brush = record, Side = side_index})
					end
				end
			end
		end

		local displacements = {}

		for _, record in ipairs(displacement_records) do
			if record.visible and near(record) then list.insert(displacements, record) end
		end

		if displacements[1] then
			list.insert(targets, {Displacements = displacements})
		end

		return targets
	end
end

return decal_geometry

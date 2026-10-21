local Vec3 = import("goluwa/structs/vec3.lua")
local decal_projection = {}
decal_projection.RADIAL_FADE = -1
local TERRAIN_STEP = 1
local TERRAIN_MAX_CELLS = 48
local GRADIENT_STEP = 0.5
local ROAD_MAX_STEP = 1
local ROAD_ACROSS_STEP = 1.5
local ROAD_MAX_ACROSS = 8
local CELL_SIZE = 128

local function get_cell(x, z)
	return math.floor(x / CELL_SIZE) .. "," .. math.floor(z / CELL_SIZE)
end

local function orient(polygon, normal)
	local a, b, c = polygon[1].pos, polygon[2].pos, polygon[3].pos
	local abx, aby, abz = b.x - a.x, b.y - a.y, b.z - a.z
	local acx, acy, acz = c.x - a.x, c.y - a.y, c.z - a.z
	local cx, cy, cz = aby * acz - abz * acy, abz * acx - abx * acz, abx * acy - aby * acx

	if cx * normal.x + cy * normal.y + cz * normal.z > 0 then
		local count = #polygon

		for i = 1, math.floor(count / 2) do
			polygon[i], polygon[count - i + 1] = polygon[count - i + 1], polygon[i]
		end
	end

	return polygon
end

local function lerp_uv(frame, local_x, local_y)
	local u_range, v_range = frame.u_range, frame.v_range
	return u_range.x + (u_range.y - u_range.x) * (local_x / frame.half_x * 0.5 + 0.5),
	v_range.x + (v_range.y - v_range.x) * (local_y / frame.half_y * 0.5 + 0.5)
end

function decal_projection.Planar(frame)
	local origin, right, up, back = frame.origin, frame.right, frame.up, frame.back
	local center = origin + back * frame.offset
	local hx, hy = frame.half_x, frame.half_y
	local polygon = {}

	for i, corner in ipairs{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}} do
		local u, v = lerp_uv(frame, corner[1] * hx, corner[2] * hy)
		polygon[i] = {
			pos = center + right * (corner[1] * hx) + up * (corner[2] * hy),
			normal = back,
			u = u,
			v = v,
		}
	end

	return {{cell = get_cell(origin.x, origin.z), polygon = orient(polygon, back)}}
end

do
	local function sample_normal(height, x, z)
		local dx = height(x + GRADIENT_STEP, z) - height(x - GRADIENT_STEP, z)
		local dz = height(x, z + GRADIENT_STEP) - height(x, z - GRADIENT_STEP)
		return Vec3(-dx, GRADIENT_STEP * 2, -dz):GetNormalized()
	end

	function decal_projection.Terrain(frame, height)
		local origin = frame.origin
		local delta = origin.y - height(origin.x, origin.z)

		if delta >= frame.half_z or delta <= -0.5 then return {} end

		local right = Vec3(frame.right.x, 0, frame.right.z)
		local up = Vec3(frame.up.x, 0, frame.up.z)
		local right_length, up_length = right:GetLength(), up:GetLength()

		if right_length < 1e-4 or up_length < 1e-4 then return {} end

		right, up = right / right_length, up / up_length
		local hx, hy = frame.half_x, frame.half_y
		local cells_x = math.clamp(math.ceil(hx * 2 / TERRAIN_STEP), 1, TERRAIN_MAX_CELLS)
		local cells_y = math.clamp(math.ceil(hy * 2 / TERRAIN_STEP), 1, TERRAIN_MAX_CELLS)
		local grid = {}

		for j = 0, cells_y do
			for i = 0, cells_x do
				local lx, ly = (i / cells_x * 2 - 1) * hx, (j / cells_y * 2 - 1) * hy
				local x = origin.x + right.x * lx + up.x * ly
				local z = origin.z + right.z * lx + up.z * ly
				local normal = sample_normal(height, x, z)
				local u, v = lerp_uv(frame, lx, ly)
				grid[j * (cells_x + 1) + i] = {
					pos = Vec3(x, height(x, z), z) + normal * frame.offset,
					normal = normal,
					u = u,
					v = v,
					fade = decal_projection.RADIAL_FADE,
				}
			end
		end

		local cell = get_cell(origin.x, origin.z)
		local fragments = {}

		for j = 0, cells_y - 1 do
			for i = 0, cells_x - 1 do
				local a = grid[j * (cells_x + 1) + i]
				local b = grid[j * (cells_x + 1) + i + 1]
				local c = grid[(j + 1) * (cells_x + 1) + i + 1]
				local d = grid[(j + 1) * (cells_x + 1) + i]
				list.insert(fragments, {cell = cell, polygon = orient({a, b, c}, a.normal)})
				list.insert(fragments, {cell = cell, polygon = orient({a, c, d}, a.normal)})
			end
		end

		return fragments
	end

	local function bezier(a, b, c, d, t)
		local s = 1 - t
		return a * (s * s * s) + b * (3 * s * s * t) + c * (3 * s * t * t) + d * (t * t * t)
	end

	function decal_projection.Road(road, height, offset)
		local points = road.points
		local samples = {}
		local step = math.min(road.step, ROAD_MAX_STEP)

		for i = 1, #points - 1 do
			local p0, p1 = points[i], points[i + 1]
			local length = (p1.pos - p0.pos):GetLength()
			local pieces = math.max(math.ceil(length / step), 1)

			for piece = i == 1 and 0 or 1, pieces do
				local t = piece / pieces
				local width_a = p0.width > 0 and p0.width or road.width
				local width_b = p1.width > 0 and p1.width or road.width
				list.insert(
					samples,
					{
						pos = bezier(p0.pos, p0.forw, p1.back, p1.pos, t),
						width = math.lerp(t, width_a, width_b),
					}
				)
			end
		end

		local distance = 0
		local across_cells = 1

		for i, sample in ipairs(samples) do
			local previous, following = samples[i - 1] or sample, samples[i + 1] or sample
			local tangent = Vec3(following.pos.x - previous.pos.x, 0, following.pos.z - previous.pos.z)

			if tangent:GetLength() < 1e-5 then
				tangent = i > 1 and samples[i - 1].tangent or Vec3(1, 0, 0)
			end

			sample.tangent = tangent:GetNormalized()
			sample.side = Vec3(sample.tangent.z, 0, -sample.tangent.x)

			if i > 1 then
				distance = distance + (sample.pos - samples[i - 1].pos):GetLength()
			end

			sample.distance = distance
			across_cells = math.max(
				across_cells,
				math.clamp(math.ceil(sample.width / ROAD_ACROSS_STEP), 1, ROAD_MAX_ACROSS)
			)
		end

		local rows = {}
		local total_distance = samples[#samples].distance

		for i, sample in ipairs(samples) do
			local row = {}
			local fade = 1 - math.min(
					math.min(sample.distance / road.fade_length, 1),
					math.min((total_distance - sample.distance) / road.fade_length, 1)
				)

			for k = 0, across_cells do
				local across = k / across_cells - 0.5
				local x = sample.pos.x + sample.side.x * sample.width * across
				local z = sample.pos.z + sample.side.z * sample.width * across
				local normal = sample_normal(height, x, z)
				row[k] = {
					pos = Vec3(x, height(x, z), z) + normal * offset,
					normal = normal,
					u = sample.distance / road.tile_length,
					v = 1 - k / across_cells,
					fade = fade,
				}
			end

			rows[i] = row
		end

		local fragments = {}

		for i = 1, #rows - 1 do
			local cell = get_cell(samples[i].pos.x, samples[i].pos.z)

			for k = 0, across_cells - 1 do
				local a, b = rows[i][k], rows[i][k + 1]
				local c, d = rows[i + 1][k + 1], rows[i + 1][k]
				list.insert(fragments, {cell = cell, polygon = orient({a, b, c}, a.normal)})
				list.insert(fragments, {cell = cell, polygon = orient({a, c, d}, a.normal)})
			end
		end

		return fragments
	end
end

do
	local CLIP_PLANES = {
		{1, 0, 0, "half_x"},
		{-1, 0, 0, "half_x"},
		{0, 1, 0, "half_y"},
		{0, -1, 0, "half_y"},
		{0, 0, 1, "half_z"},
		{0, 0, -1, "half_z"},
	}

	local function clip_polygon(polygon, frame)
		for _, plane in ipairs(CLIP_PLANES) do
			local limit = frame[plane[4]]
			local sign_x, sign_y, sign_z = plane[1], plane[2], plane[3]
			local clipped = {}
			local previous = polygon[#polygon]
			local previous_d = limit - (previous[4] * sign_x + previous[5] * sign_y + previous[6] * sign_z)

			for _, vertex in ipairs(polygon) do
				local d = limit - (vertex[4] * sign_x + vertex[5] * sign_y + vertex[6] * sign_z)

				if (previous_d < 0) ~= (d < 0) then
					local t = previous_d / (previous_d - d)
					local interpolated = {}

					for k = 1, 6 do
						interpolated[k] = previous[k] + (vertex[k] - previous[k]) * t
					end

					clipped[#clipped + 1] = interpolated
				end

				if d >= 0 then clipped[#clipped + 1] = vertex end

				previous, previous_d = vertex, d
			end

			polygon = clipped

			if #polygon < 3 then return nil end
		end

		return polygon
	end

	local function add_triangle(frame, ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz)
		local back = frame.back

		if nx * back.x + ny * back.y + nz * back.z < frame.min_facing then return end

		local origin, right, up = frame.origin, frame.right, frame.up
		local polygon = {}
		local positions = {ax, ay, az, bx, by, bz, cx, cy, cz}

		for i = 0, 2 do
			local x, y, z = positions[i * 3 + 1], positions[i * 3 + 2], positions[i * 3 + 3]
			local dx, dy, dz = x - origin.x, y - origin.y, z - origin.z
			polygon[i + 1] = {
				x,
				y,
				z,
				dx * right.x + dy * right.y + dz * right.z,
				dx * up.x + dy * up.y + dz * up.z,
				dx * back.x + dy * back.y + dz * back.z,
			}
		end

		polygon = clip_polygon(polygon, frame)

		if not polygon then return end

		local normal = Vec3(nx, ny, nz)
		local out = {}

		for i, vertex in ipairs(polygon) do
			local u, v = lerp_uv(frame, vertex[4], vertex[5])
			out[i] = {
				pos = Vec3(vertex[1], vertex[2], vertex[3]) + normal * frame.offset,
				normal = normal,
				u = u,
				v = v,
				fade = decal_projection.RADIAL_FADE,
			}
		end

		list.insert(frame.fragments, {cell = frame.cell, polygon = out})
	end

	function decal_projection.Objects(frame, receivers)
		local origin, right, up, back = frame.origin, frame.right, frame.up, frame.back
		local hx, hy, hz = frame.half_x, frame.half_y, frame.half_z
		local extent_x = math.abs(right.x) * hx + math.abs(up.x) * hy + math.abs(back.x) * hz
		local extent_y = math.abs(right.y) * hx + math.abs(up.y) * hy + math.abs(back.y) * hz
		local extent_z = math.abs(right.z) * hx + math.abs(up.z) * hy + math.abs(back.z) * hz
		frame.fragments = {}
		frame.cell = get_cell(origin.x, origin.z)
		receivers:ForEachTriangle(
			origin.x - extent_x,
			origin.y - extent_y,
			origin.z - extent_z,
			origin.x + extent_x,
			origin.y + extent_y,
			origin.z + extent_z,
			add_triangle,
			frame
		)
		local fragments = frame.fragments
		frame.fragments = nil
		return fragments
	end
end

return decal_projection

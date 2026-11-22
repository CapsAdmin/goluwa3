local ffi = require("ffi")
local mvt = import("goluwa/codecs/mvt.lua")
local geo = import("lua/earth/geo.lua")
local road_grid = import("lua/earth/road_grid.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
-- roads as ribbons lying on the terrain, built on the thread pool: Decode turns a transportation tile into the lines of
-- its roads on the ground, Build turns the lines crossing one cell into ribbons over the terrain's own heights there
local road_mesh = {}
-- the marking styles, one material each: none (tinted by the class), a centre line, edge lines and a centre line,
-- edge lines and lanes
road_mesh.PLAIN = 1
road_mesh.CENTER = 2
road_mesh.MAIN = 3
road_mesh.HIGHWAY = 4
road_mesh.STYLES = 4
road_mesh.STYLE = {
	motorway = road_mesh.HIGHWAY,
	trunk = road_mesh.HIGHWAY,
	primary = road_mesh.MAIN,
	secondary = road_mesh.MAIN,
	tertiary = road_mesh.CENTER,
}
-- meters of road one repeat of the texture covers along it
road_mesh.V_PERIOD = 24
-- how far a ribbon lies above the ground, and how much higher each class above the last lies, so the larger road is on
-- top where two meet
road_mesh.LIFT = 0.05
road_mesh.CLASS_LIFT = 0.004
-- the longest piece a ribbon is cut into along and across, meters
road_mesh.PIECE = 3
local FloatArray = ffi.typeof("float[?]")
local RAIL = #road_grid.CLASSES

local function by_start(a, b)
	return a[1] < b[1]
end

-- the polyline between two fractions of a line's length
local function cut(line, from, to)
	local total = 0

	for i = 3, #line, 2 do
		total = total + math.sqrt((line[i] - line[i - 2]) ^ 2 + (line[i + 1] - line[i - 1]) ^ 2)
	end

	if total * (to - from) < 1e-6 then return end

	local out = {}
	local along = 0

	for i = 3, #line, 2 do
		local ax, ay, bx, by = line[i - 2], line[i - 1], line[i], line[i + 1]
		local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
		local t0 = (from * total - along) / math.max(length, 1e-9)
		local t1 = (to * total - along) / math.max(length, 1e-9)

		if t1 > 0 and t0 < 1 then
			if not out[1] then
				local t = math.max(t0, 0)
				out[1], out[2] = math.lerp(t, ax, bx), math.lerp(t, ay, by)
			end

			local t = math.min(t1, 1)
			out[#out + 1], out[#out + 2] = math.lerp(t, ax, bx), math.lerp(t, ay, by)
		end

		along = along + length
	end

	return out
end

-- the runs of a polyline inside [0, extent) on both axes (Liang-Barsky per segment), so a road in two tiles' buffers
-- is kept once
local function clip(line, extent, out)
	local run

	for i = 3, #line, 2 do
		local ax, ay, bx, by = line[i - 2], line[i - 1], line[i], line[i + 1]
		local dx, dy = bx - ax, by - ay
		local t0, t1 = 0, 1
		local inside = true

		for _, edge in ipairs{{-dx, ax}, {dx, extent - ax}, {-dy, ay}, {dy, extent - ay}} do
			local p, q = edge[1], edge[2]

			if p == 0 then
				if q < 0 then inside = false end
			else
				local r = q / p

				if p < 0 then
					if r > t1 then inside = false elseif r > t0 then t0 = r end
				else
					if r < t0 then inside = false elseif r < t1 then t1 = r end
				end
			end
		end

		if inside and t1 > t0 then
			local px, py = ax + dx * t0, ay + dy * t0

			if not run or t0 > 0 then
				run = {px, py}
				out[#out + 1] = run
			end

			run[#run + 1], run[#run + 2] = ax + dx * t1, ay + dy * t1

			if t1 < 1 then run = nil end
		else
			run = nil
		end
	end
end

-- input: data (the tile's mvt), x, y, zoom, anchor_lat, anchor_lon; returns meta {lines} and a blob of floats per line:
-- the class value (road_grid's, plus UNPAVED), the point count, then x, z per point in the world
function road_mesh.Decode(input)
	local layer = #input.data > 0 and mvt.Decode(input.data).segment
	local anchor = geo.NewAnchor(input.anchor_lat, input.anchor_lon)
	local values = {}
	local lines = 0

	for _, feature in ipairs(layer and layer.features or {}) do
		local p = feature.properties
		local id = feature.type == mvt.LINESTRING and road_grid.Classify(p)

		if id and id ~= RAIL then
			local value = id + (road_grid.IsUnpaved(p, id) and road_grid.UNPAVED or 0)
			local ranges = road_grid.GetOffGround(p)
			table.sort(ranges, by_start)

			for _, line in ipairs(feature.rings) do
				local grounded = {}
				local from = 0

				for _, range in ipairs(ranges) do
					if range[1] > from then grounded[#grounded + 1] = cut(line, from, range[1]) end

					from = math.max(from, range[2])
				end

				if from < 1 then grounded[#grounded + 1] = cut(line, from, 1) end

				local runs = {}

				for _, part in ipairs(grounded) do
					clip(part, layer.extent, runs)
				end

				for _, run in ipairs(runs) do
					values[#values + 1] = value
					values[#values + 1] = #run / 2

					for i = 1, #run, 2 do
						local lat, lon = geo.FromMercator(input.x + run[i] / layer.extent, input.y + run[i + 1] / layer.extent, input.zoom, 1)
						local wx, wz = geo.LatLonToWorld(anchor, lat, lon)
						values[#values + 1] = wx
						values[#values + 1] = wz
					end

					lines = lines + 1
				end
			end
		end
	end

	local blob = FloatArray(math.max(#values, 1))

	for i, v in ipairs(values) do
		blob[i - 1] = v
	end

	return {lines = lines}, blob
end

road_mesh.DECODE_JOB = [[
	return import("lua/earth/road_mesh.lua").Decode(...)
]]

-- input: min_x, min_z, size (the cell in the world), grid_x, grid_z, grid_samples (the terrain's heights around it at a
-- meter apart, floats as a string, rows along z), lines (floats as a string, as Decode writes them, of every line near
-- the cell); returns meta {counts per style: vertices, indices} and a blob of each style's vertices then indices, in
-- style order, positions from the cell's min corner
function road_mesh.Build(input)
	local heights = ffi.cast("const float *", input.heights)
	local n = input.grid_samples
	local gx0, gz0 = input.grid_x, input.grid_z
	local min_x, min_z, max_x, max_z = input.min_x, input.min_z, input.min_x + input.size, input.min_z + input.size
	local lines = ffi.cast("const float *", input.lines)
	local line_floats = #input.lines / 4
	local meshes = {}

	for style = 1, road_mesh.STYLES do
		meshes[style] = tint_mesh.New()
	end

	local function height(x, z)
		local fx = math.clamp(x - gx0, 0, n - 1.001)
		local fz = math.clamp(z - gz0, 0, n - 1.001)
		local ix, iz = math.floor(fx), math.floor(fz)
		fx, fz = fx - ix, fz - iz
		local o = iz * n + ix
		return math.lerp(
			fz,
			math.lerp(fx, heights[o], heights[o + 1]),
			math.lerp(fx, heights[o + n], heights[o + n + 1])
		)
	end

	local function normal(x, z)
		local nx, nz = height(x - 1, z) - height(x + 1, z), height(x, z - 1) - height(x, z + 1)
		local length = math.sqrt(nx * nx + 4 + nz * nz)
		return nx / length, 2 / length, nz / length
	end

	local function vertex(mesh, x, z, lift, u, v, tx, tz)
		local nx, ny, nz = normal(x, z)
		return tint_mesh.AddVertex(mesh, x - min_x, height(x, z) + lift, z - min_z, nx, ny, nz, u, v, tx, tz)
	end

	-- front faces wind so that (b - a) x (c - a) points away from their normal: down, for ground facing up
	local function triangle(mesh, a, b, c)
		local pa, pb, pc = mesh.vertices[a].position, mesh.vertices[b].position, mesh.vertices[c].position
		local cross_y = (pb[2] - pa[2]) * (pc[0] - pa[0]) - (pb[0] - pa[0]) * (pc[2] - pa[2])

		if cross_y > 0 then
			tint_mesh.AddTriangle(mesh, a, c, b)
		else
			tint_mesh.AddTriangle(mesh, a, b, c)
		end
	end

	local function inside(x, z)
		return x >= min_x and x < max_x and z >= min_z and z < max_z
	end

	local i = 0

	while i < line_floats do
		local value = lines[i]
		local count = lines[i + 1]
		local points = lines + i + 2
		i = i + 2 + count * 2
		local id = value % road_grid.UNPAVED
		local class = road_grid.CLASSES[id]
		local half = class[2]
		local unpaved = value >= road_grid.UNPAVED
		local style = unpaved and road_mesh.PLAIN or road_mesh.STYLE[class[1]] or road_mesh.PLAIN
		local mesh = meshes[style]
		local color = unpaved and road_grid.UNPAVED_COLOR or class[4]

		if style == road_mesh.PLAIN then
			tint_mesh.SetColor(mesh, color[1], color[2], color[3])
		else
			tint_mesh.SetColor(mesh, 1, 1, 1)
		end

		local lift = road_mesh.LIFT + (#road_grid.CLASSES - id) * road_mesh.CLASS_LIFT
		local columns = math.max(1, math.ceil(2 * half / road_mesh.PIECE))
		-- the left edge at each point (miter), and the distance along the line
		local left_x, left_z, along = {}, {}, {}
		local distance = 0

		for k = 0, count - 1 do
			local x, z = points[k * 2], points[k * 2 + 1]

			if k > 0 then
				distance = distance + math.sqrt((x - points[k * 2 - 2]) ^ 2 + (z - points[k * 2 - 1]) ^ 2)
			end

			along[k] = distance
			local nx, nz = 0, 0

			for side = -1, 0 do
				local a, b = k + side, k + side + 1

				if a >= 0 and b < count then
					local dx, dz = points[b * 2] - points[a * 2], points[b * 2 + 1] - points[a * 2 + 1]
					local length = math.sqrt(dx * dx + dz * dz)

					if length > 1e-6 then nx, nz = nx - dz / length, nz + dx / length end
				end
			end

			local length = math.sqrt(nx * nx + nz * nz)

			if length > 1e-6 then nx, nz = nx / length, nz / length end

			-- the miter is longer where the line turns, up to twice the half width at sharp turns
			local scale = half

			if k > 0 and k < count - 1 then
				local dx, dz = x - points[k * 2 - 2], z - points[k * 2 - 1]
				local d = math.sqrt(dx * dx + dz * dz)

				if d > 1e-6 then
					scale = half / math.max(math.abs(-dz / d * nx + dx / d * nz), 0.5)
				end
			end

			left_x[k], left_z[k] = x + nx * scale, z + nz * scale
		end

		for k = 0, count - 2 do
			local ax, az = points[k * 2], points[k * 2 + 1]
			local bx, bz = points[k * 2 + 2], points[k * 2 + 3]
			local length = along[k + 1] - along[k]

			if length > 1e-6 then
				local tx, tz = (bx - ax) / length, (bz - az) / length
				local pieces = math.max(1, math.ceil(length / road_mesh.PIECE))

				for piece = 0, pieces - 1 do
					local t0, t1 = piece / pieces, (piece + 1) / pieces

					if inside(math.lerp((t0 + t1) / 2, ax, bx), math.lerp((t0 + t1) / 2, az, bz)) then
						local first = mesh.count
						tint_mesh.Reserve(mesh, (columns + 1) * 2, columns * 6)

						for end_ = 0, 1 do
							local t = end_ == 0 and t0 or t1
							local cx, cz = math.lerp(t, ax, bx), math.lerp(t, az, bz)
							local lx, lz = math.lerp(t, left_x[k], left_x[k + 1]), math.lerp(t, left_z[k], left_z[k + 1])
							-- the right edge mirrors the left through the centre
							local rx, rz = 2 * cx - lx, 2 * cz - lz
							local v = math.lerp(t, along[k], along[k + 1]) / road_mesh.V_PERIOD

							for column = 0, columns do
								local s = column / columns
								vertex(mesh, math.lerp(s, lx, rx), math.lerp(s, lz, rz), lift, s, v, tx, tz)
							end
						end

						for column = 0, columns - 1 do
							local a, b = first + column, first + column + 1
							local c, d = a + columns + 1, b + columns + 1
							triangle(mesh, a, c, b)
							triangle(mesh, b, c, d)
						end
					end
				end
			end
		end

		-- round ends, so the ends of segments meeting at a junction close over it
		for _, k in ipairs{0, count - 1} do
			local x, z = points[k * 2], points[k * 2 + 1]

			if inside(x, z) and count > 1 then
				local o = k == 0 and 1 or count - 2
				local dx, dz = x - points[o * 2], z - points[o * 2 + 1]
				local d = math.sqrt(dx * dx + dz * dz)

				if d > 1e-6 then
					dx, dz = dx / d, dz / d
					local steps = 6
					local v = along[k] / road_mesh.V_PERIOD
					tint_mesh.Reserve(mesh, steps + 2, steps * 3)
					local center = vertex(mesh, x, z, lift, 0.5, v, k == 0 and -dx or dx, k == 0 and -dz or dz)
					local previous

					for step = 0, steps do
						local angle = math.pi * step / steps
						-- from the left edge around the end to the right edge
						local sx, sz = dz, -dx
						local ox = sx * math.cos(angle) + dx * math.sin(angle)
						local oz = sz * math.cos(angle) + dz * math.sin(angle)
						local s = 0.5 + 0.5 * math.cos(angle) * (k == 0 and 1 or -1)
						local current = vertex(
							mesh,
							x + ox * half,
							z + oz * half,
							lift,
							s,
							v + math.sin(angle) * half / road_mesh.V_PERIOD * (k == 0 and -1 or 1),
							k == 0 and -dx or dx,
							k == 0 and -dz or dz
						)

						if previous then triangle(mesh, center, previous, current) end

						previous = current
					end
				end
			end
		end
	end

	local meta = {}
	local bytes = 0

	for style, mesh in ipairs(meshes) do
		local aabb = {math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge}

		for i = 0, mesh.count - 1 do
			local p = mesh.vertices[i].position

			for k = 0, 2 do
				aabb[k + 1] = math.min(aabb[k + 1], p[k])
				aabb[k + 4] = math.max(aabb[k + 4], p[k])
			end
		end

		meta[style] = {vertices = mesh.count, indices = mesh.index_count, aabb = aabb, offset = bytes}
		bytes = bytes + mesh.count * (
				vertex_layout.CoreStride + vertex_layout.ExtrasStride
			) + mesh.index_count * 4
	end

	local blob = ffi.new("uint8_t[?]", math.max(bytes, 1))

	for style, mesh in ipairs(meshes) do
		local core = blob + meta[style].offset
		local extras = core + mesh.count * vertex_layout.CoreStride
		vertex_layout.SplitInto(mesh.vertices, mesh.count, core, extras)
		ffi.copy(
			extras + mesh.count * vertex_layout.ExtrasStride,
			mesh.indices,
			mesh.index_count * 4
		)
	end

	return {styles = meta}, blob
end

road_mesh.JOB = [[
	return import("lua/earth/road_mesh.lua").Build(...)
]]
return road_mesh

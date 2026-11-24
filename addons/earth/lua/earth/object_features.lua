local ffi = require("ffi")
local mvt = import("goluwa/codecs/mvt.lua")
local planet = import("goluwa/planet.lua")
local geo = import("lua/earth/geo.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
local object_features = {}
local NO_DATA = -32768
-- kind of instance by layer and class; a row of trees is trees every TREE_ROW_SPACING meters
object_features.POINTS = {
	infrastructure = {
		power_tower = "power_tower",
		power_pole = "power_pole",
		street_lamp = "street_lamp",
		traffic_signals = "traffic_signals",
		bus_stop = "bus_stop",
		communication_tower = "mast",
		communication_mast = "mast",
	},
	land = {tree = "tree"},
}
object_features.TREE_ROW_SPACING = 8
-- lines by class: wires (height of the top wire, count, spread across, sag as a share of the span) or a barrier
-- (height, half width, linear colour)
object_features.WIRES = {
	power_line = {height = 26, count = 3, spread = 5, sag = 0.03, radius = 0.05},
	minor_line = {height = 8, count = 2, spread = 0.5, sag = 0.02, radius = 0.02},
}
object_features.BARRIERS = {
	fence = {height = 1.6, half_width = 0.04, color = {0.18, 0.18, 0.17}},
	wall = {height = 2, half_width = 0.12, color = {0.55, 0.5, 0.42}},
	retaining_wall = {height = 1.5, half_width = 0.2, color = {0.45, 0.43, 0.4}},
	hedge = {height = 1.4, half_width = 0.45, color = {0.08, 0.16, 0.05}},
	jersey_barrier = {height = 0.8, half_width = 0.3, color = {0.6, 0.6, 0.58}},
	city_wall = {height = 5, half_width = 1.2, color = {0.45, 0.4, 0.33}},
}
object_features.WIRE_COLOR = {0.03, 0.03, 0.03}
object_features.WIRE_PIECES = 10

local function hash(x, z)
	local h = math.sin(x * 12.9898 + z * 78.233) * 43758.5453
	return h - math.floor(h)
end

-- returns place(layer, tx, ty): x, the ground's y there, z; nil behind the origin's frame
function object_features.NewPlacer(input)
	local anchor = geo.NewAnchor(input.anchor_lat, input.anchor_lon)
	local dem = input.dem
	local pixels = ffi.cast("const float *", dem.pixels)

	local function ground(lat, lon)
		local px, py = geo.ToMercator(lat, lon, dem.zoom, dem.tile_size)
		px = math.clamp(px - dem.x0 - 0.5, 0, dem.width - 1.001)
		py = math.clamp(py - dem.y0 - 0.5, 0, dem.height - 1.001)
		local ix, iy = math.floor(px), math.floor(py)
		local fx, fy = px - ix, py - iy
		local o = iy * dem.width + ix
		local a, b, c, d = pixels[o], pixels[o + 1], pixels[o + dem.width], pixels[o + dem.width + 1]
		a, b, c, d = a == NO_DATA and 0 or a,
		b == NO_DATA and 0 or b,
		c == NO_DATA and 0 or c,
		d == NO_DATA and 0 or d
		return math.lerp(fy, math.lerp(fx, a, b), math.lerp(fx, c, d))
	end

	local function place(layer, tx, ty)
		local lat, lon = geo.FromMercator(input.x + tx / layer.extent, input.y + ty / layer.extent, input.zoom, 1)
		local x, z = geo.LatLonToWorld(anchor, lat, lon)

		if not x then return end

		return x, ground(lat, lon) - planet.GetDrop(x, z), z
	end

	return place
end

-- input: data, x, y, zoom, anchor_lat, anchor_lon, dem; returns meta {origin_x, origin_z, points ({[kind] = {x, y, z,
-- yaw, scale (0 for the kind's own range), ...}}), vertices, indices} and a blob of the line mesh's vertices then indices
function object_features.Build(input)
	local layers = mvt.Decode(input.data)
	local origin_x, origin_z = geo.LatLonToWorld(
		geo.NewAnchor(input.anchor_lat, input.anchor_lon),
		geo.FromMercator(input.x + 0.5, input.y + 0.5, input.zoom, 1)
	)
	local place = object_features.NewPlacer(input)
	local points = {}

	local function add_point(kind, x, y, z)
		points[kind] = points[kind] or {}
		local list = points[kind]
		list[#list + 1] = x
		list[#list + 1] = y
		list[#list + 1] = z
		list[#list + 1] = hash(x, z) * math.pi * 2
		list[#list + 1] = 0
	end

	local mesh = tint_mesh.New()

	-- features in the tile's buffer are drawn by the tile next to it too, so only what starts inside it is kept
	local function inside(layer, tx, ty)
		return tx >= 0 and ty >= 0 and tx < layer.extent and ty < layer.extent
	end

	for layer_name, kinds in pairs(object_features.POINTS) do
		local layer = layers[layer_name]

		if layer then
			for _, feature in ipairs(layer.features) do
				local kind = kinds[feature.properties.class]
				local ring = feature.rings[1]

				if kind and feature.type == mvt.POINT and ring and inside(layer, ring[1], ring[2]) then
					local x, y, z = place(layer, ring[1], ring[2])

					if x then add_point(kind, x, y, z) end
				end
			end
		end
	end

	local land = layers.land

	if land then
		for _, feature in ipairs(land.features) do
			if feature.type == mvt.LINESTRING and feature.properties.class == "tree_row" then
				for _, line in ipairs(feature.rings) do
					local carry = 0

					for i = 3, #line, 2 do
						local ax, ay, az = place(land, line[i - 2], line[i - 1])
						local bx, by, bz = place(land, line[i], line[i + 1])

						if
							ax and
							bx and
							inside(land, (line[i - 2] + line[i]) / 2, (line[i - 1] + line[i + 1]) / 2)
						then
							local length = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
							local at = carry

							while at < length do
								local t = at / length
								add_point("tree", math.lerp(t, ax, bx), math.lerp(t, ay, by), math.lerp(t, az, bz))
								at = at + object_features.TREE_ROW_SPACING
							end

							carry = at - length
						end
					end
				end
			end
		end
	end

	local infrastructure = layers.infrastructure

	if infrastructure then
		for _, feature in ipairs(infrastructure.features) do
			local class = feature.properties.class
			local wires = object_features.WIRES[class]
			local barrier = object_features.BARRIERS[class]

			if feature.type == mvt.LINESTRING and (wires or barrier) then
				local color = wires and object_features.WIRE_COLOR or barrier.color
				tint_mesh.SetColor(mesh, color[1], color[2], color[3])

				for _, line in ipairs(feature.rings) do
					for i = 3, #line, 2 do
						if
							inside(infrastructure, (line[i - 2] + line[i]) / 2, (line[i - 1] + line[i + 1]) / 2)
						then
							local ax, ay, az = place(infrastructure, line[i - 2], line[i - 1])
							local bx, by, bz = place(infrastructure, line[i], line[i + 1])

							if ax and bx then
								ax, az, bx, bz = ax - origin_x, az - origin_z, bx - origin_x, bz - origin_z

								if barrier then
									tint_mesh.AddWall(mesh, ax, ay, az, bx, by, bz, barrier.height, barrier.half_width)
								else
									local dx, dz = bx - ax, bz - az
									local length = math.sqrt(dx * dx + dz * dz)

									if length > 1 then
										local sx, sz = dz / length, -dx / length
										local pieces = object_features.WIRE_PIECES

										for wire = 0, wires.count - 1 do
											local offset = (wire / math.max(wires.count - 1, 1) - 0.5) * 2 * wires.spread
											local px, py, pz

											for k = 0, pieces do
												local t = k / pieces
												local x = math.lerp(t, ax, bx) + sx * offset
												local z = math.lerp(t, az, bz) + sz * offset
												local y = math.lerp(t, ay, by) + wires.height - 4 * wires.sag * length * t * (1 - t)

												if px then
													tint_mesh.AddWall(
														mesh,
														px,
														py - wires.radius,
														pz,
														x,
														y - wires.radius,
														z,
														wires.radius * 2,
														wires.radius
													)
												end

												px, py, pz = x, y, z
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local vertex_bytes = mesh.count * tint_mesh.VERTEX_SIZE
	local blob = ffi.new("uint8_t[?]", math.max(vertex_bytes + mesh.index_count * 4, 1))
	ffi.copy(blob, mesh.vertices, vertex_bytes)
	ffi.copy(blob + vertex_bytes, mesh.indices, mesh.index_count * 4)
	return {
		origin_x = origin_x,
		origin_z = origin_z,
		points = points,
		vertices = mesh.count,
		indices = mesh.index_count,
	},
	blob
end

-- input as Build plus sink (how much the bake lowers the ground by the blurred canopy) and tree_height; output as Build
object_features.MIN_TREE = 4

function object_features.BuildCanopyTrees(input)
	local size = #input.data > 0 and math.floor(math.sqrt(#input.data / 2)) or 0
	local grid = ffi.cast("const uint8_t *", input.data)
	local place = object_features.NewPlacer(input)
	local layer = {extent = size}
	local list = {}

	for y = 1, size - 2 do
		for x = 1, size - 2 do
			local v = grid[(y * size + x) * 2]

			if v >= object_features.MIN_TREE then
				local peak = true

				for dy = -1, 1 do
					for dx = -1, 1 do
						local w = grid[((y + dy) * size + x + dx) * 2]

						if (dx ~= 0 or dy ~= 0) and (w > v or w == v and (dy < 0 or dy == 0 and dx < 0)) then
							peak = false
						end
					end
				end

				if peak then
					local jx, jy = hash(x, y) - 0.5, hash(y, x) - 0.5
					local wx, wy, wz = place(layer, x + 0.5 + jx * 0.8, y + 0.5 + jy * 0.8)

					if wx then
						local blurred = grid[(y * size + x) * 2 + 1]
						list[#list + 1] = wx
						list[#list + 1] = wy - math.min(input.sink * blurred, math.max(wy - 0.5, 0))
						list[#list + 1] = wz
						list[#list + 1] = hash(wx, wz) * math.pi * 2
						list[#list + 1] = v / input.tree_height
					end
				end
			end
		end
	end

	return {origin_x = 0, origin_z = 0, points = {tree = list}, vertices = 0, indices = 0},
	ffi.new("uint8_t[1]")
end

object_features.CANOPY_JOB = [[
	return import("lua/earth/object_features.lua").BuildCanopyTrees(...)
]]
object_features.JOB = [[
	return import("lua/earth/object_features.lua").Build(...)
]]
return object_features

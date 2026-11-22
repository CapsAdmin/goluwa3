local ffi = require("ffi")
local mvt = import("goluwa/codecs/mvt.lua")
local geo = import("lua/earth/geo.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
local road_grid = import("lua/earth/road_grid.lua")
local object_features = import("lua/earth/object_features.lua")
-- the bridges of one transportation tile (the parts of segments marked as bridges or above level 0, which the road grid
-- leaves out) as decks from one end's ground to the other's, lifted over the ground between, with railings and piers;
-- the same output as object_features.Build, built on the thread pool
local bridge_features = {}
bridge_features.CLEARANCE = 1.5
bridge_features.DECK = 1
bridge_features.RAILING = 1
bridge_features.PIER_SPACING = 25
bridge_features.PIECE = 6
bridge_features.DECK_COLOR = {0.16, 0.16, 0.155}
bridge_features.CONCRETE_COLOR = {0.36, 0.35, 0.33}

-- the polyline between two fractions of a line's length (tile units), nil when it is shorter than a unit
local function cut(line, from, to)
	local total = 0

	for i = 3, #line, 2 do
		total = total + math.sqrt((line[i] - line[i - 2]) ^ 2 + (line[i + 1] - line[i - 1]) ^ 2)
	end

	if total * (to - from) < 1 then return end

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

function bridge_features.Build(input)
	local layers = mvt.Decode(input.data)
	local layer = layers.segment
	local origin_x, origin_z = geo.LatLonToWorld(
		geo.NewAnchor(input.anchor_lat, input.anchor_lon),
		geo.FromMercator(input.x + 0.5, input.y + 0.5, input.zoom, 1)
	)
	local place = object_features.NewPlacer(input)
	local mesh = tint_mesh.New()

	for _, feature in ipairs(layer and layer.features or {}) do
		local p = feature.properties
		local id = feature.type == mvt.LINESTRING and road_grid.Classify(p)

		if id then
			local half_width = road_grid.CLASSES[id][2] + 0.5

			for _, range in ipairs(road_grid.GetOffGround(p)) do
				if range.raised then
					for _, line in ipairs(feature.rings) do
						local part = cut(line, range[1], range[2])
						local middle = part and math.floor(#part / 4) * 2 + 1

						if
							part and
							part[middle] >= 0 and
							part[middle + 1] >= 0 and
							part[middle] < layer.extent and
							part[middle + 1] < layer.extent
						then
							-- samples along the bridge: x, ground, z, distance from its start
							local samples = {}
							local distance = 0

							for i = 1, #part - 2, 2 do
								local ax, ay, az = place(layer, part[i], part[i + 1])
								local bx, by, bz = place(layer, part[i + 2], part[i + 3])

								if not ax or not bx then
									samples = nil

									break
								end

								local length = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
								local pieces = math.max(1, math.ceil(length / bridge_features.PIECE))

								for k = i == 1 and 0 or 1, pieces do
									local t = k / pieces
									local _, ground = place(layer, math.lerp(t, part[i], part[i + 2]), math.lerp(t, part[i + 1], part[i + 3]))
									samples[#samples + 1] = {
										math.lerp(t, ax, bx) - origin_x,
										ground,
										math.lerp(t, az, bz) - origin_z,
										distance + length * t,
									}
								end

								distance = distance + length
							end

							if samples and distance > 2 then
								local first, last = samples[1][2], samples[#samples][2]
								local rise = 0

								for _, s in ipairs(samples) do
									local base = math.lerp(s[4] / distance, first, last)
									rise = math.max(rise, s[2] + bridge_features.CLEARANCE - base)
								end

								for _, s in ipairs(samples) do
									s[5] = math.lerp(s[4] / distance, first, last) + rise * math.sin(math.pi * s[4] / distance)
								end

								local next_pier = bridge_features.PIER_SPACING

								for i = 2, #samples do
									local a, b = samples[i - 1], samples[i]
									local dx, dz = b[1] - a[1], b[3] - a[3]
									local length = math.sqrt(dx * dx + dz * dz)

									if length > 1e-4 then
										local sx, sz = dz / length, -dx / length
										local deck = bridge_features.DECK
										tint_mesh.SetColor(
											mesh,
											bridge_features.DECK_COLOR[1],
											bridge_features.DECK_COLOR[2],
											bridge_features.DECK_COLOR[3]
										)
										tint_mesh.AddWall(mesh, a[1], a[5] - deck, a[3], b[1], b[5] - deck, b[3], deck, half_width)
										tint_mesh.SetColor(
											mesh,
											bridge_features.CONCRETE_COLOR[1],
											bridge_features.CONCRETE_COLOR[2],
											bridge_features.CONCRETE_COLOR[3]
										)

										for side = -1, 1, 2 do
											local ox, oz = sx * side * (half_width - 0.1), sz * side * (half_width - 0.1)
											tint_mesh.AddWall(
												mesh,
												a[1] + ox,
												a[5],
												a[3] + oz,
												b[1] + ox,
												b[5],
												b[3] + oz,
												bridge_features.RAILING,
												0.1
											)
										end

										while next_pier < b[4] and next_pier < distance - bridge_features.PIER_SPACING / 2 do
											local t = (next_pier - a[4]) / (b[4] - a[4])
											local x, z = math.lerp(t, a[1], b[1]), math.lerp(t, a[3], b[3])
											local ground = math.lerp(t, a[2], b[2])
											local top = math.lerp(t, a[5], b[5]) - deck

											if top > ground + 0.5 then
												tint_mesh.AddTaperedBox(mesh, x, z, ground - 1, top, 0.7, 0.7, 0.6, 0.6)
											end

											next_pier = next_pier + bridge_features.PIER_SPACING
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
		points = {},
		vertices = mesh.count,
		indices = mesh.index_count,
	},
	blob
end

bridge_features.JOB = [[
	return import("lua/earth/bridge_features.lua").Build(...)
]]
return bridge_features

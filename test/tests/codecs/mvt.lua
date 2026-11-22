local T = import("test/environment.lua")
local mvt = import("goluwa/codecs/mvt.lua")

local function varint(n)
	local out = {}

	repeat
		local byte = n % 128
		n = math.floor(n / 128)
		out[#out + 1] = string.char(n > 0 and byte + 128 or byte)	
	until n == 0

	return table.concat(out)
end

local function field(number, wire, payload)
	if wire == 0 then return varint(number * 8) .. varint(payload) end

	return varint(number * 8 + 2) .. varint(#payload) .. payload
end

local function zigzag(n)
	return n >= 0 and n * 2 or -n * 2 - 1
end

local function packed(values)
	local out = {}

	for i, v in ipairs(values) do
		out[i] = varint(v)
	end

	return table.concat(out)
end

-- rings of {x, y, ...} as move to, line to and close path commands
local function geometry(rings)
	local commands = {}
	local cx, cy = 0, 0

	for _, ring in ipairs(rings) do
		commands[#commands + 1] = 1 + 8
		commands[#commands + 1] = zigzag(ring[1] - cx)
		commands[#commands + 1] = zigzag(ring[2] - cy)
		cx, cy = ring[1], ring[2]
		commands[#commands + 1] = 2 + 8 * (#ring / 2 - 1)

		for i = 3, #ring, 2 do
			commands[#commands + 1] = zigzag(ring[i] - cx)
			commands[#commands + 1] = zigzag(ring[i + 1] - cy)
			cx, cy = ring[i], ring[i + 1]
		end

		commands[#commands + 1] = 7 + 8
	end

	return packed(commands)
end

local function double(v)
	local ffi = require("ffi")
	local box = ffi.new("double[1]", v)
	return ffi.string(box, 8)
end

local TILE = field(
	3,
	2,
	table.concat{
		field(15, 0, 2),
		field(1, 2, "building"),
		field(5, 0, 4096),
		field(3, 2, "height"),
		field(3, 2, "class"),
		field(4, 2, varint(3 * 8 + 1) .. double(12.5)),
		field(4, 2, field(1, 2, "house")),
		field(
			2,
			2,
			table.concat{
				field(1, 0, 7),
				field(2, 2, packed{0, 0, 1, 1}),
				field(3, 0, 3),
				field(
					4,
					2,
					geometry{{0, 0, 100, 0, 100, 100, 0, 100}, {25, 25, 25, 75, 75, 75, 75, 25}}
				),
			}
		),
	}
)

T.Test("mvt decodes layers, properties and polygon rings", function()
	local layer = mvt.Decode(TILE).building
	T(layer.extent)["=="](4096)
	T(#layer.features)["=="](1)
	local feature = layer.features[1]
	T(feature.id)["=="](7)
	T(feature.type)["=="](mvt.POLYGON)
	T(feature.properties.height)["=="](12.5)
	T(feature.properties.class)["=="]("house")
	T(#feature.rings)["=="](2)
	T(feature.rings[1][3])["=="](100)
	T(feature.rings[2][4])["=="](75)
	local polygons = mvt.GetPolygons(feature)
	T(#polygons)["=="](1)
	T(#polygons[1])["=="](2)
	T(mvt.GetRingArea(feature.rings[1]))["=="](10000)
	T(mvt.GetRingArea(feature.rings[2]))["=="](-2500)
end)

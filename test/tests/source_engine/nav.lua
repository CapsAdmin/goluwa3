local T = import("test/environment.lua")
local nav = import("goluwa/codecs/nav.lua")

local function area(id, x1, y1, x2, y2, z, connections, flags)
	return {
		id = id,
		flags = flags or 0,
		nw = {x1, y1, z},
		se = {x2, y2, z},
		ne_z = z,
		sw_z = z,
		connections = {
			[nav.NORTH] = connections.north or {},
			[nav.EAST] = connections.east or {},
			[nav.SOUTH] = connections.south or {},
			[nav.WEST] = connections.west or {},
		},
		hiding_spots = {},
		place = 0,
		ladders = {[0] = {}, [1] = {}},
		inherit_visibility_from = 0,
	}
end

local function create_data(areas)
	return {version = nav.VERSION, sub_version = 0, bsp_size = 1234, analyzed = true, places = {}, areas = areas, ladders = {}}
end


T.Test("nav codec writes and reads areas, connections and ladders", function()
	local data = create_data{
		area(1, 0, 0, 100, 100, 10, {east = {2}}, nav.ATTRIBUTE.STAIRS),
		area(2, 100, 0, 200, 100, 20, {west = {1}, south = {3}}),
		area(3, 100, 100, 200, 300, 20, {north = {2}}),
	}
	data.places = {"kitchen", "hall"}
	data.areas[2].ne_z = 30
	data.areas[2].sw_z = 25
	data.ladders[1] = {
		id = 1,
		width = 32,
		top = {1, 2, 3},
		bottom = {4, 5, 6},
		length = 100,
		direction = 2,
		top_forward = 1,
		top_left = 2,
		top_right = 3,
		top_behind = 0,
		bottom_area = 3,
	}
	local decoded = assert(nav.Decode(nav.Encode(data)))
	T(decoded.version)["=="](nav.VERSION)
	T(decoded.trailing_bytes)["=="](0)
	T(decoded.analyzed)["=="](true)
	T(decoded.bsp_size)["=="](1234)
	T(decoded.places[1])["=="]("kitchen")
	T(decoded.places[2])["=="]("hall")
	T(#decoded.areas)["=="](3)
	T(decoded.areas[1].flags)["=="](nav.ATTRIBUTE.STAIRS)
	T(decoded.areas[2].nw[1])["=="](100)
	T(decoded.areas[2].se[2])["=="](100)
	T(decoded.areas[2].ne_z)["=="](30)
	T(decoded.areas[2].sw_z)["=="](25)
	T(decoded.areas[1].connections[nav.EAST][1])["=="](2)
	T(decoded.areas[2].connections[nav.WEST][1])["=="](1)
	T(decoded.areas[2].connections[nav.SOUTH][1])["=="](3)
	T(#decoded.areas[3].connections[nav.EAST])["=="](0)
	T(#decoded.ladders)["=="](1)
	T(decoded.ladders[1].bottom_area)["=="](3)
	T(decoded.ladders[1].bottom[3])["=="](6)
end)

T.Test("nav codec rejects data that is not a nav file or is cut off", function()
	T(nav.Decode("not a nav file at all"))["=="](nil)
	local data = nav.Encode(create_data{area(1, 0, 0, 100, 100, 0, {})})
	T(pcall(nav.Decode, data:sub(1, #data - 10)))["=="](false)
	local old = data:sub(1, 4) .. string.char(99, 0, 0, 0) .. data:sub(9)
	T(select(2, nav.Decode(old)))["=="]("unsupported nav version 99")
end)

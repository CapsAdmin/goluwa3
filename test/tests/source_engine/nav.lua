local T = import("test/environment.lua")
local nav = import("goluwa/codecs/nav.lua")
local nav_mesh = import("goluwa/source_engine/nav_mesh.lua")
local units = import("goluwa/source_engine/units.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

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

local function to_engine(x, y, z)
	return units.PositionToEngine(Vec3(x, y, z))
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

T.Test("nav mesh turns source areas into engine space and connects them in every direction", function()
	local mesh = nav_mesh.FromData(create_data{
		area(1, 0, 0, 100, 100, 10, {east = {2}}),
		area(2, 100, 0, 200, 100, 10, {west = {1}, south = {3}}),
		area(3, 100, 100, 200, 300, 10, {north = {2}, east = {4}}),
		area(4, 200, 100, 300, 300, 10, {west = {3}}),
	})
	T(#mesh:GetAreas())["=="](4)

	for id, point in pairs{
		[1] = to_engine(50, 50, 10),
		[2] = to_engine(150, 50, 10),
		[3] = to_engine(150, 200, 10),
		[4] = to_engine(250, 200, 10),
	} do
		T(mesh:GetAreaAt(point))["=="](mesh:GetArea(id))
	end

	T(#mesh:GetArea(2).links)["=="](2)
	local path = assert(mesh:FindPath(to_engine(50, 50, 10), to_engine(250, 200, 10)))
	T(#path.areas)["=="](4)
	T(path.areas[2])["=="](mesh:GetArea(2))
	T(path.areas[3])["=="](mesh:GetArea(3))
	T(path.length >= to_engine(50, 50, 10):Distance(to_engine(250, 200, 10)))["=="](true)
	local back = assert(mesh:FindPath(to_engine(250, 200, 10), to_engine(50, 50, 10)))
	T(#back.areas)["=="](4)
end)

T.Test("nav mesh interpolates the height between the corners of an area", function()
	local ramp = area(1, 0, 0, 100, 100, 0, {})
	ramp.se[3] = 100
	ramp.ne_z = 50
	ramp.sw_z = 50
	local mesh = nav_mesh.FromData(create_data{ramp})
	local middle = mesh:GetArea(1)
	T(math.abs(mesh:GetHeight(middle, to_engine(50, 50, 0).x, to_engine(50, 50, 0).z) - 50 * units.meters) < 1e-3)["=="](true)
	T(math.abs(mesh:GetHeight(middle, to_engine(100, 100, 0).x, to_engine(100, 100, 0).z) - 100 * units.meters) < 1e-3)["=="](true)
end)

T.Test("nav mesh blocks areas that need a jump or a crouch and makes avoid areas expensive", function()
	local mesh = nav_mesh.FromData(create_data{
		area(1, 0, 0, 100, 100, 0, {east = {2}}),
		area(2, 100, 0, 200, 100, 0, {west = {1}, east = {3}}, nav.ATTRIBUTE.CROUCH),
		area(3, 200, 0, 300, 100, 0, {west = {2}}, nav.ATTRIBUTE.AVOID),
	})
	T(mesh:GetArea(1).Blocked)["=="](false)
	T(mesh:GetArea(2).Blocked)["=="](true)
	T(mesh:GetArea(3).Blocked)["=="](false)
	T(mesh:GetArea(3).Cost)["=="](nav_mesh.AVOID_COST)
	T(mesh:FindPath(to_engine(50, 50, 0), to_engine(250, 50, 0)))["=="](nil)
end)

T.Test("nav mesh of gm_construct loads and connects the map", function()
	if not steam.MountSourceGame("gmod", true) or not vfs.IsFile("maps/gm_construct.nav") then
		return T.Unavailable("gmod content not mounted")
	end

	local data = assert(nav.Decode(assert(vfs.Read("maps/gm_construct.nav"))))
	T(data.trailing_bytes)["=="](0)
	T(#data.areas)["=="](2271)
	local mesh = nav_mesh.FromData(data)
	local first = mesh:GetArea(1)
	local reachable = mesh:GetReachableAreas(
		Vec3(first.center_x, first.center_y, first.center_z),
		{MaxClimb = 0.45, MaxDrop = 3}
	)
	local count = 0

	for _ in pairs(reachable) do
		count = count + 1
	end

	T(count)[">"](500)
	local start = mesh:GetRandomPoint(nil, nil, reachable)
	local goal = mesh:GetRandomPoint(nil, nil, reachable)
	local path = assert(mesh:FindPath(start, goal, {Radius = 0.3, MaxClimb = 0.45, MaxDrop = 3}))
	T(path.length >= start:Distance(goal) - 1e-3)["=="](true)
end)

local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function raises(fn, text)
	local ok, err = pcall(fn)
	T(ok)["=="](false)
	T(tostring(err))["contains"](text)
end

local function build_prototype(overrides)
	local definition = {model = "unused.cgf"}

	for k, v in pairs(overrides or {}) do
		definition[k] = v
	end

	return ScatterSet.New{Name = "test_registry", Prototypes = {definition}}.protos[1]
end

T.Test("scatter set prototypes get their defaults", function()
	local proto = build_prototype()
	T(proto.density)["=="](1)
	T(proto.scale_min)["=="](1)
	T(proto.scale_max)["=="](1)
	T(proto.align)["=="](0)
	T(proto.layers[1])["=="](1)
	T(proto.state)["=="]("unloaded")
end)

T.Test("scatter set ranges and angles are converted", function()
	local proto = build_prototype{
		scale = {0.5, 2},
		height = 1.5,
		slope = {10, 45, 5},
		yaw = 180,
		tilt = 90,
		sink = {0.1, 0.3},
		color = {surface = 0.5, tint = {{2, 1, 1}, {1, 1, 2}}},
		cluster = {scale = 4, amount = 0.25},
	}
	T(proto.scale_min)["=="](0.5)
	T(proto.scale_max)["=="](2)
	T(proto.height_min)["=="](1.5)
	T(proto.height_max)["=="](1.5)
	T(proto.slope_min)["~"](math.rad(10))
	T(proto.slope_max)["~"](math.rad(45))
	T(proto.slope_fade)["~"](math.rad(5))
	T(proto.yaw)["~"](math.pi)
	T(proto.tilt)["~"](math.pi / 2)
	T(proto.sink_max)["=="](0.3)
	T(proto.color_surface)["=="](0.5)
	T(proto.color_variation)["=="](0.1)
	T(proto.tint_a[1])["=="](2)
	T(proto.tint_b[3])["=="](2)
	T(proto.cluster_scale)["=="](4)
	T(proto.cluster_amount)["=="](0.25)
end)

T.Test("scatter set prototypes reject what they do not know", function()
	raises(function()
		build_prototype{densty = 3}
	end, "unknown prototype key densty")

	raises(function()
		build_prototype{color = {surfce = 1}}
	end, "unknown color key surfce")

	raises(function()
		build_prototype{cluster = {size = 1}}
	end, "unknown cluster key size")

	raises(function()
		build_prototype{scale = "big"}
	end, "scale is a number or")

	raises(function()
		build_prototype{density = 0}
	end, "density must be above zero")

	raises(function()
		ScatterSet.New{Name = "test_registry", Prototypes = {{density = 1}}}
	end, "has no model")

	raises(function()
		ScatterSet.New{Name = "test_registry", Prototypes = {}}
	end, "has no prototypes")

	raises(function()
		ScatterSet.New{Name = "test_registry", Prototyps = {}}
	end, "unknown scatter set key Prototyps")
end)

T.Test("scatter sets in use have their prototypes indexed", function()
	local function model()
		return {}
	end

	local set_a = ScatterSet.New{Name = "test_a", Prototypes = {{model = model}, {model = model}}}
	local set_b = ScatterSet.New{Name = "test_b", Prototypes = {{model = model}}}
	local version = ScatterSet.version
	set_b:Use()
	T(ScatterSet.version)[">"](version)
	local protos = ScatterSet.GetPrototypes()
	local first_index = protos[#protos].index
	T(protos[#protos].name)["=="]("test_b.1")
	set_a:Use()
	protos = ScatterSet.GetPrototypes()

	for i, proto in ipairs(protos) do
		T(proto.index)["=="](i - 1)
	end

	T(protos[#protos - 2].name)["=="]("test_a.1")
	T(protos[#protos - 1].name)["=="]("test_a.2")
	T(first_index)["<="](protos[#protos].index)
	set_a:Remove()
	set_b:Remove()

	for _, proto in ipairs(ScatterSet.GetPrototypes()) do
		T(proto.name:find("test_", 1, true))["=="](nil)
	end
end)

T.Test("scatter set multipliers default to one and can be changed", function()
	local set = ScatterSet.New{Name = "test_multipliers", Prototypes = {{model = "unused.cgf"}}, DistanceMultiplier = 2}
	T(set:GetDensityMultiplier())["=="](1)
	T(set:GetDistanceMultiplier())["=="](2)
	T(set.protos[1].set)["=="](set)
	set:SetDensityMultiplier(3)
	T(set:GetDensityMultiplier())["=="](3)
	T(set:GetDistanceMultiplier())["=="](2)
	T(set.protos[1].density_multiplier)["=="](3)
	raises(function()
		ScatterSet.New{Name = "test_multipliers", Prototypes = {{model = "unused.cgf"}}, density = 2}
	end, "unknown scatter set key density")
end)

T.Test("scatter prototypes take part of the set's distance multiplier by their response", function()
	local set = ScatterSet.New{
		Name = "test_response",
		Prototypes = {{model = "unused.cgf"}, {model = "unused.cgf", distance_response = 0.1, density_response = 3}},
		DistanceMultiplier = 10,
		DensityMultiplier = 2,
	}
	T(set.protos[1].density_multiplier)["=="](2)
	T(set.protos[2].density_multiplier)["=="](4)
	T(set.protos[1].distance_multiplier)["=="](10)
	T(math.abs(set.protos[2].distance_multiplier - 1.9))["<"](1e-9)
	set:SetDistanceMultiplier(1)
	T(set.protos[1].distance_multiplier)["=="](1)
	T(set.protos[2].distance_multiplier)["=="](1)
end)

T.Test("scatter prototypes conform to the ground only when asked", function()
	T(build_prototype().conform)["=="](false)
	T(build_prototype{conform = true}.conform)["=="](true)
end)

T.Test("scatter set billboards are normalized and need a path", function()
	local proto = build_prototype{billboard = true}
	T(proto.billboard_distance)["=="](150)
	T(proto.billboard_fade)["=="](0.15)
	proto = build_prototype{billboard = {distance = 80, fade = 0.3}}
	T(proto.billboard_distance)["=="](80)
	T(proto.billboard_fade)["=="](0.3)
	T(build_prototype().billboard_distance)["=="](0)
	raises(function()
		build_prototype{model = function() return {} end, billboard = true}
	end, "model is not a path")
	raises(function()
		build_prototype{billboard = {fade = 1}}
	end, "needs a distance and a fade")
end)

T.Test("the builtin grass set is one object", function()
	local set = ScatterSet.GetGrass()
	T(set)["=="](ScatterSet.GetGrass())
	T(set:GetName())["=="]("grass")
	T(#set.protos)[">"](1)
end)

local function create_ground(material, tilt)
	local plane = Polygon3D.New()
	shapes.BuildPlane(plane, Vec3(0, 0, 0), Vec3(0, 1, 0), 10, 10, 1, 8, 8, Vec3(0, 0, -1))
	plane:BuildBoundingBox()
	plane:Upload()
	local ground = Entity.New{Name = "scatter_ground"}
	ground:AddComponent("transform")
	ground.transform:SetRotation(Quat():SetAngles(Deg3(0, 0, tilt or 0)))
	ground:AddComponent("visual")
	local primitive = Entity.New{Name = "scatter_ground_primitive", Parent = ground}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(plane)
	visual_primitive:SetMaterial(material)
	ground.visual:BuildAABB()
	ground.visual:SetUseOcclusionCulling(false)
	return ground
end

local cube_count = 0

local function create_red_cubes(overrides)
	-- a cube of its own size, meshes with the same vertices are shared and a mesh of an earlier test may be on its way out
	cube_count = cube_count + 1
	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 0.25 + cube_count * 0.001)
	local indices = {}

	for i = 1, #cube.Vertices do
		indices[i] = i
	end

	cube:Upload(indices)
	local material = Material.New{ColorMultiplier = Color(1, 0, 0, 1)}
	local definition = {
		model = function()
			return {{mesh = cube, material = material}}
		end,
		density = 6,
		max_distance = 40,
		full_density_distance = 40,
	}

	for k, v in pairs(overrides or {}) do
		definition[k] = v
	end

	return ScatterSet.New{Name = "test_cubes_" .. cube_count, Prototypes = {definition}}
end

-- the share of the pixels around the center of the view of the ground that are red
local function draw_red_share(draw, set, tilt)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(60))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 6, 0))
	camera:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
	local ground = create_ground(Material.New{ColorMultiplier = Color(1, 1, 1, 1), ScatterSet = set}, tilt)
	local ok, err = pcall(function()
		-- a test body gets 16 draws in all, and the first ones find the surface and load the set
		for _ = 1, 4 do
			draw()
		end
	end)

	local red, total = 0, 0
	local texture = gbuffer_layout.GetTexture("albedo")
	local size = render.GetRenderImageSize()

	for y = -8, 8 do
		for x = -8, 8 do
			local r, g = texture:GetPixel(math.floor(size.x / 2) + x * 8, math.floor(size.y / 2) + y * 8)
			total = total + 1

			if r > 150 and g < 100 then red = red + 1 end
		end
	end

	ground:Remove()

	if not ok then error(err, 0) end

	return red / total
end

T.Test3D("Graphics render3d scatter grows a set on a surface", function(draw)
	local set = create_red_cubes()
	T(draw_red_share(draw, set))[">"](0.15)
	set:Remove()
end)

T.Test3D("Graphics render3d scatter keeps off slopes it is not set to grow on", function(draw)
	local set = create_red_cubes{slope = {0, 20, 0}}
	T(draw_red_share(draw, set, 0))[">"](0.15)
	T(draw_red_share(draw, set, 50))["=="](0)
	set:Remove()
end)

local scatter_proxy = import("goluwa/render3d/scatter_proxy.lua")
local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")

local function triangle_template()
	local vertices = Polygon3D.VertexType(3)
	local positions = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}

	for i, p in ipairs(positions) do
		vertices[i - 1].position[0], vertices[i - 1].position[1], vertices[i - 1].position[2] = p[1], p[2], p[3]
		vertices[i - 1].normal[0], vertices[i - 1].normal[1], vertices[i - 1].normal[2] = 0, 0, 1
		vertices[i - 1].uv[0], vertices[i - 1].uv[1] = p[1], p[2]
		vertices[i - 1].tangent[0], vertices[i - 1].tangent[1], vertices[i - 1].tangent[2], vertices[i - 1].tangent[3] = 1, 0, 0, 1
	end

	local indices = ffi.new("uint32_t[3]", {0, 1, 2})
	return {vertices = vertices, vertex_count = 3, indices = indices, index_count = 3}
end

T.Test("scatter proxies are copies of the template moved by the instance matrices", function()
	-- two instances, the first scaled by 2 along x and 3 along y and 4 along z and moved to (10, 20, 30), the second
	-- turned a quarter around y (the x axis goes to -z, the z axis to x) and moved to (-1, 0, 0)
	local instances = ffi.new("float[32]", {
		2, 0, 0, 0.5,
		0, 3, 0, 0,
		0, 0, 4, 0,
		10, 20, 30, 1,
		0, 0, -1, 0,
		0, 1, 0, 0,
		1, 0, 0, 0,
		-1, 0, 0, 1,
	})
	local selected = ffi.new("int32_t[2]", {1, 0})
	local vertices, vertex_count, indices, index_count = scatter_proxy.Build(triangle_template(), instances, selected, 2)
	T(vertex_count)["=="](6)
	T(index_count)["=="](6)
	-- the first selected is the second instance
	T(vertices[1].position[0])["~"](-1)
	T(vertices[1].position[2])["~"](-1)
	T(vertices[2].position[1])["~"](1)
	-- the normal of the template (0, 0, 1) is the z axis, which went to x
	T(vertices[0].normal[0])["~"](1)
	T(vertices[0].normal[2])["~"](0)
	-- the second selected is the first instance, with its vertices after the first's
	T(vertices[4].position[0])["~"](12)
	T(vertices[4].position[1])["~"](20)
	T(vertices[5].position[1])["~"](23)
	T(vertices[3].normal[2])["~"](1)
	T(indices[3])["=="](3)
	T(indices[5])["=="](5)
	T(vertices[4].uv[0])["~"](1)
end)

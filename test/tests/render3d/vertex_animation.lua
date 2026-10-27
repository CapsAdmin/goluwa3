local T = import("test/environment.lua")
local ffi = require("ffi")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Block = ffi.typeof(model_pipeline.GetVertexAnimationUniformBufferDecl())

T.Test3D("vertex animation motion is what the wind moves a plant, in units of the standing still pixels", function()
	local block = Block()
	local polygon = Polygon3D.New()
	polygon:SetBendHeight(10)
	render3d.SetCurrentPolygon3D(polygon)
	local wind = atmosphere.GetWind():Copy()
	local pixels = pvars.Get("r_wind_still_pixels")
	local ok, err = pcall(function()
		atmosphere.SetWind(Vec3(8, 0, 0))
		pvars.SetSession("r_wind_still_pixels", 2)
		local tree = Material.New{Bending = 1, DetailBending = "leaves"}
		model_pipeline.FillVertexAnimationData(block, tree)
		local motion = block.Motion
		T(motion)[">"](0)
		pvars.SetSession("r_wind_still_pixels", 4)
		model_pipeline.FillVertexAnimationData(block, tree)
		T(block.Motion)["=="](motion / 2)
		local leaves = Material.New{DetailBending = "leaves"}
		model_pipeline.FillVertexAnimationData(block, leaves)
		local flutter = block.Motion
		T(flutter)[">"](0)
		atmosphere.SetWind(Vec3(20, 0, 0))
		model_pipeline.FillVertexAnimationData(block, leaves)
		T(block.Motion)[">"](flutter)
		model_pipeline.FillVertexAnimationData(block, Material.New())
		T(block.Motion)["=="](0)
		pvars.SetSession("r_wind_still_pixels", 0)
		model_pipeline.FillVertexAnimationData(block, tree)
		T(block.Motion)["=="](1e9)
	end)
	pvars.SetSession("r_wind_still_pixels", pixels)
	atmosphere.SetWind(wind)
	render3d.SetCurrentPolygon3D(nil)
	polygon:Remove()

	if not ok then error(err, 0) end
end)

T.Test3D("the animation version follows the standing still setting", function()
	local pixels = pvars.Get("r_wind_still_pixels")
	local before = model_pipeline.GetVertexAnimationVersion()
	pvars.SetSession("r_wind_still_pixels", pixels + 1)
	local after = model_pipeline.GetVertexAnimationVersion()
	pvars.SetSession("r_wind_still_pixels", pixels)
	T(after)["~="](before)
end)

local render = import("goluwa/render/render.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Entity = import("goluwa/entities/entity.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local HEIGHT = 20

local function create_plate(divisions)
	divisions = divisions or 1
	local polygon = Polygon3D.New()
	local normal = Vec3(0, 0, 1)

	local function corner(x, y)
		return Vec3(-3 + 6 * x / divisions, HEIGHT * y / divisions, 0)
	end

	for x = 0, divisions - 1 do
		for y = 0, divisions - 1 do
			local quad = {corner(x, y), corner(x + 1, y), corner(x + 1, y + 1), corner(x, y + 1)}

			for _, i in ipairs{1, 2, 3, 1, 3, 4} do
				polygon:AddVertex{
					pos = quad[i],
					uv = Vec2(quad[i].x, quad[i].y),
					normal = normal,
					tangent = Vec3(1, 0, 0),
				}
			end
		end
	end

	polygon:SetBendHeight(HEIGHT)
	polygon:BuildBoundingBox()
	polygon:Upload()
	return polygon
end

local function cover(draw, polygon, material, distance, elapsed)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(5000)
	camera:SetPosition(Vec3(0, HEIGHT / 2, 0))
	camera:SetRotation(Quat():Identity())
	local entity = Entity.New{Name = "vertex_animation_plate"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -distance))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "vertex_animation_plate_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	local library = Visual.Library
	local was_noculling = library.noculling
	library.noculling = true
	system.SetElapsedTime(elapsed)
	local ok, err = pcall(function()
		for _ = 1, 3 do
			draw()
		end
	end)
	library.noculling = was_noculling
	entity:Remove()

	if not ok then error(err, 0) end

	local image = gbuffer_layout.GetTexture("albedo"):Download()
	local covered, count = {}, 0

	for y = 0, image.height - 1 do
		for x = 0, image.width - 1 do
			if image:GetPixel(x, y) > 128 then
				covered[y * image.width + x] = true
				count = count + 1
			end
		end
	end

	return covered, count
end

local function differing(a, b)
	local n = 0

	for k in pairs(a) do
		if not b[k] then n = n + 1 end
	end

	for k in pairs(b) do
		if not a[k] then n = n + 1 end
	end

	return n
end

T.Test3D("vertex animation moves a plant that is near and leaves one that is far standing", function(draw)
	local polygon = create_plate()
	local material = Material.New{ColorMultiplier = Color(1, 0, 0, 1), DoubleSided = true, Bending = 1}
	local wind = atmosphere.GetWind():Copy()
	local pixels = pvars.Get("r_wind_still_pixels")
	local ok, err = pcall(function()
		atmosphere.SetWind(Vec3(10, 0, 0))
		pvars.SetSession("r_wind_still_pixels", 2)
		local block = Block()
		render3d.SetCurrentPolygon3D(polygon)
		model_pipeline.FillVertexAnimationData(block, material)
		render3d.GetCamera():SetFOV(math.rad(90))
		local _, scale = model_pipeline.GetVertexAnimationView()
		local near, far = block.Motion * scale / 4, block.Motion * scale / 0.3
		local still, still_count = cover(draw, polygon, material, far, 1000)
		local still_later, later_count = cover(draw, polygon, material, far, 1003)
		local moving, moving_count = cover(draw, polygon, material, near, 1000)
		local moving_later = cover(draw, polygon, material, near, 1003)
		T(still_count)[">"](20)
		T(moving_count)[">"](20)
		T(differing(moving, moving_later))[">"](4)
		T(differing(still, still_later))["=="](0)
		pvars.SetSession("r_wind_still_pixels", 0)
		local free = cover(draw, polygon, material, far, 1000)
		local free_later = cover(draw, polygon, material, far, 1003)
		T(differing(free, free_later))[">"](0)
	end)
	pvars.SetSession("r_wind_still_pixels", pixels)
	atmosphere.SetWind(wind)
	render3d.SetCurrentPolygon3D(nil)
	polygon:Remove()

	if not ok then error(err, 0) end
end)

local event = import("goluwa/event.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")

T.Test3D("vertex animation pushes the parts of a plant a body is touching", function(draw)
	local polygon = create_plate(60)
	local material = Material.New{
		ColorMultiplier = Color(1, 0, 0, 1),
		DoubleSided = true,
		Bending = 1,
		DetailBending = "leaves",
	}
	local wind = atmosphere.GetWind():Copy()
	local body_entity
	local ok, err = pcall(function()
		atmosphere.SetWind(Vec3(0, 0, 0))
		render3d.SetCurrentPolygon3D(polygon)
		local before, before_count = cover(draw, polygon, material, 4, 1000)
		T(before_count)[">"](20)
		body_entity = Entity.New{Name = "vertex_animation_pusher"}
		body_entity:AddComponent("transform")
		body_entity.transform:SetPosition(Vec3(2.8, 10, -4))
		body_entity:AddComponent("rigid_body", {Shape = SphereShape.New(0.5), MotionType = "kinematic"})
		event.Call("LateUpdate", 0)
		local pushed = cover(draw, polygon, material, 4, 1000)
		T(differing(before, pushed))[">"](4)
		body_entity:Remove()
		body_entity = nil
		event.Call("LateUpdate", 0)
		local after = cover(draw, polygon, material, 4, 1000)
		T(differing(before, after))["=="](0)
	end)

	if body_entity then body_entity:Remove() end

	atmosphere.SetWind(wind)
	render3d.SetCurrentPolygon3D(nil)
	polygon:Remove()

	if not ok then error(err, 0) end
end)

local vegetation_pushers = import("goluwa/render3d/vegetation_pushers.lua")

T.Test3D("vegetation pushers hand the shader the recent poses of a body, weighted like a spring", function()
	vegetation_pushers.GetAddress()
	local data = vegetation_pushers.GetData()
	local first
	local entity = Entity.New{Name = "vertex_animation_history"}
	entity:AddComponent("transform")
	entity:AddComponent("rigid_body", {Shape = SphereShape.New(0.5), MotionType = "kinematic"})
	local ok, err = pcall(function()
		local function update(time, x)
			system.SetElapsedTime(time)
			entity.rigid_body:SetPosition(Vec3(x, 10, -4))
			event.Call("LateUpdate", 0)

			for i = 0, data[0] - 1 do
				local o = 4 + i * vegetation_pushers.STRIDE * 4

				if data[o + 1] == 10 then first = o + 8 end
			end
		end

		for i = 0, 19 do
			update(i * 0.05, 0)
		end

		local sum, negative = 0, false

		for j = 0, vegetation_pushers.POSES - 1 do
			T(math.abs(data[first + j * 4]))["<"](0.01)
			sum = sum + data[first + j * 4 + 3]
			negative = negative or data[first + j * 4 + 3] < 0
		end

		T(math.abs(sum - 1))["<"](0.001)
		T(negative)["=="](true)
		update(1, 1)
		T(math.abs(data[first] - 1))["<"](0.01)
		T(math.abs(data[first + 4]))["<"](0.01)
		update(1.035, 1)
		T(math.abs(data[first + 4] - 0.3))["<"](0.05)
		T(math.abs(data[first + 8]))["<"](0.01)
	end)
	entity:Remove()
	event.Call("LateUpdate", 0)

	if not ok then error(err, 0) end
end)

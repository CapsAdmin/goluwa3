local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
import("addons/game/lua/autorun/impacts.lua")

T.TestPhysics("a physics impact fires an Impact from each side with the surface it hit", function()
	local poly = Polygon3D.New()
	poly.Vertices = {
		{pos = Vec3(-8, 0, -8)},
		{pos = Vec3(8, 0, -8)},
		{pos = Vec3(-8, 0, 8)},
		{pos = Vec3(8, 0, 8)},
	}
	poly.indices = {0, 2, 1, 1, 2, 3}
	poly:BuildBoundingBox()
	poly.material = Material.New()
	poly.material:SetSurfaceType("concrete")
	local ground = Entity.New({Name = "impact_ground"})
	ground:AddComponent("transform")
	ground:AddComponent(
		"rigid_body",
		{Shapes = {{Polygon3D = poly}}, MotionType = "static", WorldGeometry = true}
	)
	local box = Entity.New({Name = "impact_box"})
	box:AddComponent("transform")
	box.transform:SetPosition(Vec3(0, 1.5, 0))
	box:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(0.5, 0.5, 0.5))})
	local impacts = {}

	event.AddListener("Impact", "impacts_test", function(info)
		if info.Kind == "physics" and info.Speed > 3 then
			impacts[#impacts + 1] = info
		end
	end)

	test_helpers.Simulate(240)
	event.RemoveListener("Impact", "impacts_test")
	T(#impacts)["=="](2)
	local from_box = impacts[1].Entity == box and impacts[1] or impacts[2]
	local from_ground = impacts[1].Entity == ground and impacts[1] or impacts[2]
	T(from_box.Entity)["=="](box)
	T(from_box.Other)["=="](ground)
	T(from_box.Surface)["=="]("concrete")
	T(math.abs(from_box.Position.y) < 0.05)["=="](true)
	T(from_ground.Entity)["=="](ground)
	T(from_ground.Other)["=="](box)
	T(from_ground.Surface)["=="]("default")
	T(from_box.Speed)["=="](from_ground.Speed)
	box:Remove()
	ground:Remove()
end)

local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local test_helpers = import("test/physics_helpers.lua")
import("addons/game/lua/autorun/impacts.lua")

local function create_concrete_ground()
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
	return ground
end

T.TestPhysics("a physics impact fires an Impact from each side with the surface it hit", function()
	local ground = create_concrete_ground()
	local box = Entity.New({Name = "impact_box"})
	box:AddComponent("transform")
	box.transform:SetPosition(Vec3(0, 1.5, 0))
	box:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(0.5, 0.5, 0.5))})
	local impacts = {}

	event.AddListener("Impact", "impacts_test", function(info)
		if not info.Foot and info.Speed > 3 then impacts[#impacts + 1] = info end
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
	T(from_box.OtherSurface)["=="](from_ground.Surface)
	T(from_ground.OtherSurface)["=="](from_box.Surface)
	T(from_box.Speed)["=="](from_ground.Speed)
	T(from_box.Mass)["=="](box.rigid_body:GetMass())
	T(math.abs(from_box.Size - 0.5))["<"](0.01)
	T(math.abs(from_ground.Size - 0.5))["<"](0.01)
	T(from_ground.Mass)["=="](box.rigid_body:GetMass())
	box:Remove()
	ground:Remove()
end)

T.TestPhysics("a rolling ball fires a Contact from each side, rolling on the ball's side", function()
	local ground = create_concrete_ground()
	ground.rigid_body:SetFriction(0.8)
	local ball = Entity.New({Name = "contact_ball"})
	ball:AddComponent("transform")
	ball.transform:SetPosition(Vec3(-4, 0.6, 0))
	ball:AddComponent("rigid_body", {Shape = SphereShape.New(0.25), Radius = 0.25, Friction = 0.8})
	ball.rigid_body:SetVelocity(Vec3(4, -2, 0))
	local from_ball, from_ground = {}, {}

	event.AddListener("Contact", "contacts_test", function(info)
		if info.Entity == ball then from_ball[#from_ball + 1] = info end

		if info.Entity == ground then from_ground[#from_ground + 1] = info end
	end)

	test_helpers.Simulate(120)
	event.RemoveListener("Contact", "contacts_test")
	T(#from_ball > 20)["=="](true)
	T(#from_ball)["=="](#from_ground)
	T(from_ball[1].OtherSurface)["=="](from_ground[1].Surface)
	T(from_ground[1].OtherSurface)["=="](from_ball[1].Surface)
	local last_ball, last_ground = from_ball[#from_ball], from_ground[#from_ground]
	T(last_ball.Other)["=="](ground)
	T(last_ball.Surface)["=="]("concrete")
	T(last_ball.Rolling)["=="](true)
	T(last_ball.Roll > 1)["=="](true)
	T(last_ground.Other)["=="](ball)
	T(last_ground.Surface)["=="]("default")
	T(last_ground.Rolling)["=="](false)
	T(last_ground.Roll)["=="](last_ball.Roll)
	T(last_ball.Mass)["=="](ball.rigid_body:GetMass())
	ball:Remove()
	ground:Remove()
end)

T.TestPhysics("a prosthetic foot fires a second impact with the metal surface on both eli models", function()
	local ground = create_concrete_ground()
	local character = Entity.New({Name = "impact_character"})
	character:AddComponent("transform")
	character.transform:SetPosition(Vec3(0, 20, 0))
	character:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(0.3, 0.9, 0.3))})
	character.source_pose = {}
	local fired = {}

	event.AddListener("Impact", "impacts_test", function(info)
		fired[#fired + 1] = info
	end)

	local hit = {entity = ground, position = Vec3(0, 0, 0), normal = Vec3(0, 1, 0)}
	local impacts = import("lua/impacts.lua")

	for _, case in ipairs{
		{
			"models/player/eli.mdl",
			"foot_l",
			"ValveBiped.Bip01_L_Foot",
			"ValveBiped.Bip01_R_Foot",
		},
		{"models/characters/eli/eli.vmdl_c", "foot_l", "ankle_L", "ankle_R"},
	} do
		character.model = {ModelPath = case[1]}

		for _, part in ipairs{case[2], case[3]} do
			fired = {}
			impacts.FireFootstep(character, part, hit, 2)
			T(#fired)["=="](2)
			T(fired[1].Foot)["=="](part)
			T(fired[1].Entity)["=="](character)
			T(fired[1].Surface)["=="]("default")
			T(fired[2].Foot)["=="](nil)
			T(fired[2].Entity)["=="](ground)
			T(fired[2].Other)["=="](character)
			T(fired[2].Surface)["=="]("metal")
			T(fired[2].OtherSurface)["=="]("default")
			T(fired[2].Mass)["=="](character.rigid_body:GetMass())
		end

		for _, part in ipairs{"foot_r", case[4]} do
			fired = {}
			impacts.FireFootstep(character, part, hit, 2)
			T(#fired)["=="](1)
		end
	end

	event.RemoveListener("Impact", "impacts_test")
	character:Remove()
	ground:Remove()
end)

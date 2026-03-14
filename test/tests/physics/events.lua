local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local convex_shape = ConvexShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

T.Test3D("Rigid bodies support collision layers and collision events", function()
	local function spawn_pair(prefix, config_a, config_b)
		local a = Entity.New({Name = prefix .. "_a"})
		a:AddComponent("transform")
		a.transform:SetPosition(Vec3(-2, 0, 0))
		local body_a = a:AddComponent("rigid_body", config_a)
		local b = Entity.New({Name = prefix .. "_b"})
		b:AddComponent("transform")
		b.transform:SetPosition(Vec3(2, 0, 0))
		local body_b = b:AddComponent("rigid_body", config_b)
		return a, body_a, b, body_b
	end

	local no_hit_a, body_a, no_hit_b, body_b = spawn_pair(
		"rigid_layers_skip",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			Restitution = 1,
			CollisionGroup = 1,
			CollisionMask = 1,
		},
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			Restitution = 1,
			CollisionGroup = 2,
			CollisionMask = 2,
		}
	)
	local enter_count = 0

	no_hit_a:AddLocalListener("OnCollisionEnter", function()
		enter_count = enter_count + 1
	end)

	body_a:SetVelocity(Vec3(6, 0, 0))
	body_b:SetVelocity(Vec3(-6, 0, 0))
	simulate_physics(90)
	T(enter_count)["=="](0)
	T(no_hit_a.transform:GetPosition().x)[">"](1.5)
	T(no_hit_b.transform:GetPosition().x)["<"](-1.5)
	no_hit_a:Remove()
	no_hit_b:Remove()
	local hit_b = Entity.New({Name = "rigid_layers_hit_box"})
	hit_b:AddComponent("transform")
	hit_b.transform:SetPosition(Vec3(0, 1, 0))
	local hit_body_b = hit_b:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(4, 1, 4)),
			Size = Vec3(4, 1, 4),
			MotionType = "static",
			CollisionGroup = 2,
			CollisionMask = 3,
		}
	)
	local hit_a = Entity.New({Name = "rigid_layers_hit_sphere"})
	hit_a:AddComponent("transform")
	hit_a.transform:SetPosition(Vec3(0, 4, 0))
	local hit_body_a = hit_a:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			CollisionGroup = 1,
			CollisionMask = 3,
		}
	)
	local enter_hits = 0
	local stay_hits = 0
	local exit_hits = 0

	hit_a:AddLocalListener("OnCollisionEnter", function(self, other, info)
		enter_hits = enter_hits + 1
		T(self)["=="](hit_a)
		T(other)["=="](hit_b)
		T(info.other_body)["=="](hit_body_b)
		T(math.abs(info.normal.y))[">"](0.5)
	end)

	hit_a:AddLocalListener("OnCollisionStay", function(self)
		stay_hits = stay_hits + 1
		T(self)["=="](hit_a)
	end)

	hit_a:AddLocalListener("OnCollisionExit", function(self, other)
		exit_hits = exit_hits + 1
		T(self)["=="](hit_a)
		T(other)["=="](hit_b)
	end)

	simulate_physics(240)
	T(enter_hits)[">"](0)
	T(stay_hits)[">"](0)
	hit_body_a:SetCollisionMask(0)
	simulate_physics(2)
	T(exit_hits)[">"](0)
	T(hit_body_a:GetGrounded())["=="](true)
	hit_a:Remove()
	hit_b:Remove()
end)

T.Pending(
	"Rigid bodies emit enter, stay, and exit collision events for static world geometry"
)
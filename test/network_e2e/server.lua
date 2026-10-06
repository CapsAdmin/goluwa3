local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
shapes.Box{
	Name = "e2e_ground",
	Position = Vec3(0, -0.5, 0),
	Scale = Vec3(200, 1, 200),
	RigidBody = {MotionType = "static"},
	Material = {Color = Color(0.3, 0.5, 0.3, 1), Roughness = 0.9},
	Network = true,
}
shapes.Sphere{
	Name = "e2e_ball",
	Position = Vec3(5, 6, 5),
	Radius = 0.5,
	Network = true,
}
shapes.Box{
	Name = "e2e_crate",
	Position = Vec3(0, 0.5, -4),
	Size = Vec3(1, 1, 1),
	Network = true,
}
Entity.New{
	Name = "e2e_light",
	transform = {Position = Vec3(0, 5, 0)},
	light_point = {Color = Color(1, 0.5, 0.2, 1), Lumen = 500, Range = 20},
	network = {},
}
local prop = Entity.New{
	Name = "replicated_prop",
	transform = {Position = Vec3(1, 2, 3)},
	model = {ModelPath = "models/box.lua", ModelOptions = {size = Vec3(1, 2, 3)}},
	network = {},
}
prop.network:CallOnClientsPersist("transform", "SetSize", 3)
Entity.New{
	Name = "replicated_child",
	Parent = prop,
	transform = {},
	network = {},
}
import("test/network_e2e/signals.lua").Write("server.ready", "ready")
local t = 0

event.AddListener("Update", "e2e_server", function(dt)
	t = t + dt
	prop.transform:SetPosition(Vec3(math.sin(t * 2) * 2, 2, 3))
end)

if os.getenv("E2E_DEBUG") then
	local timer = import("goluwa/timer.lua")
	local system = import("goluwa/system.lua")

	timer.Repeat("e2e_server_debug", 1, function()
		for _, ent in ipairs(Entity.World:GetChildrenList()) do
			local c = ent.player_controller

			if c and c.number > 0 then
				print(
					string.format(
						"CTRL t=%.2f number=%d queue=%d target=%d starved=%d buffering=%s",
						system.GetTime(),
						c.number,
						c:GetQueueSize(),
						c.buffer_target,
						c.starved,
						tostring(c.buffering)
					)
				)
			end
		end
	end)
end

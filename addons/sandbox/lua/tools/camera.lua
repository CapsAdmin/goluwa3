local players = import("lua/players.lua")
local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
local Entity = import("goluwa/entities/entity.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function place(context, trace, target)
	local player = context:GetPlayer()
	local camera = Entity.New{
		Name = "camera",
		Transient = false,
		transform = {Position = trace.origin:Copy()},
		network = SERVER and {} or nil,
		rigid_body = {
			MotionType = "static",
			CollisionMask = 0,
			Shape = BoxShape.New(Vec3(0.18, 0.14, 0.16)),
		},
		tool_camera = {Target = target and player:GetGUID() or "", Direction = trace.forward:Copy()},
	}
	camera:SetOwnedBy(players.GetClient(player))
	context:Record(game_history.Spawned("camera", camera))
	return true
end

return toolgun.Register{
	Name = "camera",
	DisplayName = "Camera",
	Category = "Construction",
	Description = "Places a camera. Press numpad 0 to look through your newest camera.",
	Instructions = {
		Left = "place a camera aiming where you aim",
		Right = "place a camera that follows you",
	},
	LeftClick = function(context, trace)
		if not (trace.world or toolgun.IsProp(trace.entity)) then return false end

		return place(context, trace, false)
	end,
	RightClick = function(context, trace)
		if not (trace.world or toolgun.IsProp(trace.entity)) then return false end

		return place(context, trace, true)
	end,
}

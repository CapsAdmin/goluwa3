local nodes = import("lua/weapon_nodes.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local blade = {}
blade.StanceTilt = math.rad(65)

local function marker(name, distance)
	return {
		guid = name,
		parent = "grip_shift",
		properties = {Name = name},
		components = {transform = {Position = FORWARD * distance}},
	}
end

function blade.Nodes(spec)
	local pole = nodes.Cylinder(
		"replacement",
		spec.Radius,
		spec.Length,
		FORWARD * (spec.Length / 2 - spec.Pommel),
		spec.Material,
		true
	)
	pole.parent = "grip_shift"
	return {
		{
			guid = "sword",
			parent = "model",
			properties = {Name = "sword"},
			components = {
				transform = {Rotation = Quat():SetAngles(Vec3(spec.Tilt or blade.StanceTilt, 0, 0))},
			},
		},
		{
			guid = "grip_shift",
			parent = "sword",
			properties = {Name = "grip_shift"},
			components = {transform = {Position = FORWARD * spec.Grip}},
		},
		pole,
		marker("blade_base", spec.Base),
		marker("blade_tip", spec.Tip),
	}
end

function blade.SheathRotation(direction, tilt)
	local from = Quat():SetAngles(Vec3(tilt or blade.StanceTilt, 0, 0)):VecMul(FORWARD):GetNormalized()
	local to = direction:GetNormalized()
	local axis = from:GetCross(to)
	return QuatFromAxis(math.acos(math.clamp(from:Dot(to), -1, 1)), axis:GetNormalized())
end

return blade

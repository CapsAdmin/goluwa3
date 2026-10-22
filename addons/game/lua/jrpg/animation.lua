local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local CharacterPose = import("lua/components/character_pose.lua")
local animation = {}
local PIVOT = 0.45
local TURN = math.pi * 2
local offset = Vec3()
local ROLLS = {
	roll_forward = {"RotatePitch", -TURN},
	roll_back = {"RotatePitch", TURN},
	roll_left = {"RotateRoll", TURN},
	roll_right = {"RotateRoll", -TURN},
}

event.AddListener("Update", "jrpg_roll_animation", function()
	for _, pose in ipairs(CharacterPose.Instances) do
		local transform = pose.Owner.transform
		local roll = pose.action_rolls and ROLLS[pose.action]

		if roll then
			local position, rotation = transform:GetRenderPositionRotation()

			if not position then
				position, rotation = transform:GetPosition(), transform:GetRotation()
			end

			local t = pose.action_fraction
			t = t * t * (3 - 2 * t)
			local turned = rotation:Copy()
			turned[roll[1]](turned, roll[2] * t)
			offset:Set(0, -PIVOT, 0)
			transform:SetOverridePosition(position + Vec3(0, PIVOT, 0) + turned:VecMul(offset))
			transform:SetOverrideRotation(turned)
			pose.roll_override = true
		elseif pose.roll_override then
			pose.roll_override = false
			transform:SetOverridePosition(nil)
			transform:SetOverrideRotation(nil)
		end
	end
end)

return animation

local Matrix44 = import("goluwa/structs/matrix44.lua")
local biped = import("lua/biped.lua")
local aim_pose = import("lua/aim_pose.lua")
local biped_pose = {}

function biped_pose.Compute(bones, height, crouch_alpha, pose, weapon)
	local crouch = math.lerp(crouch_alpha, 1, biped.CrouchScale)

	for name, rest in pairs(biped.Rest) do
		local matrix = bones[name]

		if not matrix then
			matrix = Matrix44()
			bones[name] = matrix
		end

		matrix:Identity()
		matrix:SetTranslation(rest[1] * height, rest[2] * height * crouch, rest[3] * height)
	end

	aim_pose.Apply(bones, pose, weapon)
	return bones
end

return biped_pose

local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local motion = import("goluwa/physics/motion.lua")
local kinematic_controller = {}

function kinematic_controller.UpdateBody(body, substep, substeps, dt)
	if not body:IsKinematic() then return end

	local position = body.Position
	local rotation = body.Rotation

	if substep == 1 then
		local start_position = body.KinematicStartPosition

		if not start_position then
			start_position = Vec3()
			body.KinematicStartPosition = start_position
			body.KinematicTargetPosition = Vec3()
			body.KinematicStartRotation = Quat()
			body.KinematicTargetRotation = Quat()
		end

		start_position:CopyFrom(body.PreviousPosition)
		body.KinematicTargetPosition:CopyFrom(position)
		body.KinematicStartRotation:CopyFrom(body.PreviousRotation)
		body.KinematicTargetRotation:CopyFrom(rotation)
		body.Velocity:CopyFrom(position):Sub(start_position):Scale(1 / dt)
		body.AngularVelocity:CopyFrom(
			motion.GetAngularVelocityFromRotationDelta(body.PreviousRotation, rotation, dt)
		)
	end

	local alpha = substep / substeps
	local start_position = body.KinematicStartPosition
	local target_position = body.KinematicTargetPosition
	position.x = start_position.x + (target_position.x - start_position.x) * alpha
	position.y = start_position.y + (target_position.y - start_position.y) * alpha
	position.z = start_position.z + (target_position.z - start_position.z) * alpha
	local start_rotation = body.KinematicStartRotation
	local target_rotation = body.KinematicTargetRotation
	local sign = (
			start_rotation.x * target_rotation.x + start_rotation.y * target_rotation.y + start_rotation.z * target_rotation.z + start_rotation.w * target_rotation.w
		) < 0 and
		-1 or
		1
	rotation.x = start_rotation.x + (target_rotation.x * sign - start_rotation.x) * alpha
	rotation.y = start_rotation.y + (target_rotation.y * sign - start_rotation.y) * alpha
	rotation.z = start_rotation.z + (target_rotation.z * sign - start_rotation.z) * alpha
	rotation.w = start_rotation.w + (target_rotation.w * sign - start_rotation.w) * alpha
	rotation:Normalize()
end

return kinematic_controller

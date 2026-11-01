local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local knockout_pose = {}
knockout_pose.FullSpeed = 5.7
local RAD = math.pi / 180
local X, Y, Z = Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)
-- source bone angles in degrees at full speed (pitch, yaw, roll); the bone axes of a rig are the source axes (x, y, z) turned into (z, x, y)
local BONES = {
	{"waist", 0, 20, 0},
	{"spine", 0, 20, 0},
	{"chest", 0, 20, 0},
	{"back", 0, 20, 0},
	{"thigh_r", 0, -85, 0},
	{"thigh_l", 0, -85, 0},
	{"clavicle_l", -30, 0, 20},
	{"clavicle_r", 30, 0, -20},
	{"upperarm_l", -60, -140, 40},
	{"upperarm_r", 60, -140, -40},
	{"calf_r", 0, 12, 0},
	{"calf_l", 0, 12, 0},
}
local rotation = Quat()

function knockout_pose.New()
	return {time = 0, speed = 0, entries = nil}
end

function knockout_pose.GetFactor(speed, time)
	return math.min(speed / knockout_pose.FullSpeed, 1) * math.min(time * 2, 1)
end

function knockout_pose.Drive(state, rig, position, dt, floor)
	if rig.held then return end

	local entries = state.entries

	if not entries then
		entries = {}
		state.entries = entries
		rig:ClearBones()

		for _, bone in ipairs(BONES) do
			if biped.HasBone(rig, bone[1]) then
				entries[#entries + 1] = {
					name = biped.SourceBones[bone[1]],
					pitch = bone[2] * RAD,
					yaw = bone[3] * RAD,
					roll = bone[4] * RAD,
					matrix = Matrix44():Identity(),
				}
			end
		end
	end

	if state.position and dt > 0 then
		local raw = position:Distance(state.position) / dt
		state.speed = state.speed + (raw - state.speed) * math.min(dt * 10, 1)
	end

	state.position = position:Copy()
	state.time = state.time + dt
	local s = math.max(knockout_pose.GetFactor(state.speed, state.time), floor * math.min(state.time * 2, 1))

	for _, entry in ipairs(entries) do
		rotation:Identity()
		Quat.SetMul(rotation, QuatFromAxis(entry.yaw * s, Y), QuatFromAxis(entry.pitch * s, X))
		Quat.SetMul(rotation, rotation, QuatFromAxis(entry.roll * s, Z))
		entry.matrix:Identity()
		entry.matrix:SetRotation(rotation)
		rig:SetBone(entry.name, entry.matrix, "local")
	end

	rig:Compute()
end

function knockout_pose.Release(state, rig)
	for _, entry in ipairs(state.entries or {}) do
		rig:ClearBone(entry.name)
	end

	rig:Compute()
end

return knockout_pose

local Vec3 = import("goluwa/structs/vec3.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local actors = import("lua/actors.lua")
local character_scale = import("lua/character_scale.lua")
local camera_shots = {}
camera_shots.Battle = "battle"
camera_shots.Shots = {
	attacker_face = {Anchor = "face", Offset = {1, -0.35, 0.03}, Look = "face", Fov = 30},
	hero_low = {Anchor = "feet", Offset = {1.4, 0.9, 0.12}, Look = "face", Fov = 55},
}
local FACE_HEIGHT = 0.65

function camera_shots.Sample(keys, phase)
	local index = 0

	for i = 1, #keys do
		if keys[i][1] > phase then break end

		index = i
	end

	return index, keys[index] and keys[index][2]
end

do
	local face_world = Matrix44()

	function camera_shots.GetFace(entity)
		local armature = entity.armature
		local matrix = armature and armature:GetBoneMatrix("mouth")

		if not matrix then
			return actors.GetCenter(entity) + Vec3(0, FACE_HEIGHT * character_scale.Get(entity), 0)
		end

		matrix:GetMultiplied(entity.transform:GetWorldMatrix(), face_world)
		return Vec3(face_world:GetTranslation())
	end
end

local function get_point(part, attacker)
	if part == "face" then return camera_shots.GetFace(attacker) end

	return attacker.transform:GetPosition():Copy()
end

function camera_shots.Place(shot, attacker, forward, right)
	local offset = shot.Offset
	local scale = character_scale.Get(attacker)
	local origin = get_point(shot.Anchor, attacker) + (
			forward * offset[1] + right * offset[2]
		) * scale
	origin.y = origin.y + offset[3] * scale
	return origin, get_point(shot.Look, attacker)
end

return camera_shots

local event = import("goluwa/event.lua")
local faces = import("lua/faces.lua")
local movesets = import("lua/movesets.lua")
local CharacterPose = import("lua/components/character_pose.lua")
local victim_faces = {}

event.AddListener("Update", "faces", function()
	table.clear(victim_faces)

	for _, pose in ipairs(CharacterPose.Instances) do
		local move, phase = movesets.GetActive(pose)

		if move and move.Faces then
			local _, victim_face = faces.Sample(move.Faces, phase)
			local victim = victim_face and movesets.GetVictim(pose)

			if victim then victim_faces[victim] = victim_face end
		end
	end

	for _, pose in ipairs(CharacterPose.Instances) do
		local entity = pose.Owner
		local rig = faces.GetRig(entity)

		if rig then
			local face
			local health = entity.health

			if health and health:IsDead() then
				face = "dead"
			else
				face = victim_faces[entity]

				if not face then
					local move, phase = movesets.GetActive(pose)
					face = move and move.Faces and faces.Sample(move.Faces, phase)
				end

				if not face and pose:IsStunned() then face = "pain" end
			end

			faces.Show(rig, face)
		end
	end
end)

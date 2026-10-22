local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local vfs = import("goluwa/vfs.lua")
local outfit = import("lua/outfit.lua")
local eye_pose = import("lua/eye_pose.lua")

T.Test("The local outfit is saved with the default body and visor, stays local and keeps edits", function()
	local name = outfit.CustomName
	local path = prefab.GetPath(name)
	local backup = vfs.Read(path)
	prefab.definitions[name] = nil
	os.remove(path)
	T(outfit.Exists(name))["=="](false)
	T(outfit.LoadLocal())["=="](name)
	T(vfs.IsFile(path))["=="](true)
	T(prefab.Get(name).local_only)["=="](true)
	prefab.definitions[name] = nil
	local instance = Entity.New{prefab = {Path = outfit.LoadLocal()}}
	local eye = instance.prefab:GetNode("eye")
	local rig = instance.prefab:GetNode("rig")
	T(eye:GetParent())["=="](instance)
	T(instance.prefab:GetNode("pupil"):GetParent())["=="](eye)
	T(eye.transform:GetAttachment())["=="]("root")
	T(rig.script ~= nil)["=="](true)
	T(instance.transform:GetAttachment())["=="]("root")
	instance:Remove()
	prefab.Get(name).entities[2].properties.Name = "edited"
	outfit.LoadLocal()
	T(prefab.Get(name).entities[2].properties.Name)["=="]("edited")
	prefab.definitions[name] = nil

	if backup then vfs.Write(path, backup) else os.remove(path) end
end)

T.Test("Outfit names of other players are valid prefab names", function()
	T(outfit.GetName("127.0.0.1:5000"))["=="]("outfit_127.0.0.1_5000")
end)

T.Test("The default outfit places the eye and limbs where the pose bones are", function()
	local Matrix44 = import("goluwa/structs/matrix44.lua")
	local biped = import("lua/biped.lua")
	local bones = {}

	for _, entry in ipairs(biped.Bones) do
		bones[entry[1]] = Matrix44()
	end

	bones.neck:SetTranslation(0, 1, 0.1)
	bones.upperarm_l:SetTranslation(0.3, 1, 0)
	bones.forearm_l:SetTranslation(0.3, 0.6, 0)
	bones.foot_r:SetTranslation(-0.2, 0.05, 0)
	local player = Entity.New{transform = {}}
	player.procedural_pose = {GetBones = function() return bones end}
	player.player_avatar = {
		SetOutfitFirstPersonVisible = function(self, visible)
			self.visible = visible
		end,
	}
	prefab.Register("test_outfit_eye", outfit.GetDefault())
	local instance = Entity.New{Parent = player, prefab = {Path = "test_outfit_eye"}}
	local rig = instance.prefab:GetNode("rig")
	T(rig.script.Error)["=="](nil)
	rig.outfit_eye:OnUpdate(0.016)
	T(player.player_avatar.visible)["=="](true)
	local eye = instance.prefab:GetNode("eye").transform:GetPosition()
	T(eye.y)["~"](1, 1e-5)
	T(eye.z)["~"](0.1, 1e-5)
	local upper = instance.prefab:GetNode("arm_upper_l").transform:GetPosition()
	T(upper.x)["~"](0.3, 1e-5)
	T(upper.y)["~"](0.8, 1e-5)
	T(instance.prefab:GetNode("foot_r").transform:GetPosition().x)["~"](-0.2, 1e-5)
	instance:Remove()
	T(player.player_avatar.visible)["=="](false)
	player:Remove()
	prefab.definitions.test_outfit_eye = nil
end)

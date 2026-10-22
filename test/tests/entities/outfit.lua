local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local vfs = import("goluwa/vfs.lua")
local outfit = import("lua/outfit.lua")

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

T.Test("The default outfit swings the eye around the pupil point and keeps the feet planted", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local player = Entity.New{transform = {}}
	player.character_pose = {crouch_alpha = 0}
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
	local eye = instance.prefab:GetNode("eye").transform
	T(eye:GetPosition().y)["~"](outfit.EyeHeight, 1e-5)
	T(eye:GetPosition().z)["~"](outfit.EyeRadius, 1e-5)
	local foot = instance.prefab:GetNode("foot_l").transform:GetPosition()
	T(foot.y)["~"](outfit.FootHeight, 2e-2)
	player.character_pose.crouch_alpha = 1
	rig.outfit_eye:OnUpdate(0.016)
	T(eye:GetPosition().y)["~"](outfit.CrouchEyeHeight, 1e-5)
	instance:Remove()
	T(player.player_avatar.visible)["=="](false)
	player:Remove()
	prefab.definitions.test_outfit_eye = nil
end)

T.TestPhysics("The default outfit plants its feet on the ground found by a physics ray within a bound", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
	local physics = import("goluwa/physics.lua")
	local test_helpers = import("test/tests/physics/test_helpers.lua")
	prefab.Register("test_outfit_ground", outfit.GetDefault())
	local player = Entity.New{transform = {}}
	player.character_pose = {crouch_alpha = 0}
	player.player_avatar = {SetOutfitFirstPersonVisible = function() end}
	local expected = outfit.FootHeight - outfit.FootSink
	local cases = {{0, expected}, {outfit.GroundBound * 0.5, expected + outfit.GroundBound * 0.5}, {outfit.GroundBound * 3, expected}}

	for _, case in ipairs(cases) do
		local ground = Entity.New{Name = "outfit_foot_ground"}
		ground:AddComponent("transform")
		local poly = Polygon3D.New()
		local height = case[1]
		test_helpers.AddTriangle(poly, Vec3(-8, height, -8), Vec3(8, height, -8), Vec3(0, height, 8))
		poly:BuildBoundingBox()
		test_helpers.AttachWorldGeometryBody(ground, poly)
		local instance = Entity.New{Parent = player, prefab = {Path = "test_outfit_ground"}}
		instance.prefab:GetNode("rig").outfit_eye:OnUpdate(0.016)
		T(instance.prefab:GetNode("foot_l").transform:GetPosition().y)["~"](case[2], 1e-3)
		instance:Remove()
		ground:Remove()
		physics.Update(1 / 60)
	end

	player:Remove()
	prefab.definitions.test_outfit_ground = nil
end)

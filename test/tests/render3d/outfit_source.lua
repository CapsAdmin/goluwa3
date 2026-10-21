local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local outfit_source = import("lua/outfit_source.lua")
import("addons/game/lua/autorun/network_players.lua")
import("addons/game/lua/autorun/characters.lua")

T.Test3D("the source outfit animates a gmod player model from the movement of the player", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile(outfit_source.Model) then
		return T.Unavailable("gmod content not mounted")
	end

	pvars.SetSession("cl_outfit", outfit_source.Name)
	local player = Entity.New{transform = {Position = Vec3(0, 0, 0)}, player_avatar = {}, character_pose = {}}
	local model

	T.WaitUntil(
		function()
			local outfit = player.player_avatar.outfit
			model = outfit and outfit:GetChildren()[1]
			return model and
				model.animator and
				model.animator:GetRig() and
				model.source_pose and
				player.player_avatar.armature
		end,
		30
	)

	T(model ~= nil)["=="](true)
		T(model.source_pose.added_events.Update)["=="](true)
	local animator = model.animator

	local function step(_, velocity)
		player.transform.RenderVelocity = velocity
		player.transform.RenderVelocityFrame = system.GetFrameNumber()

		for _ = 1, 60 do
			player.character_pose:OnUpdate(1 / 60)
			model.source_pose:OnUpdate(1 / 60)
		end
	end

	step(0.5, Vec3(0, 0, 0))
	T(animator:GetSequence())["=="]("idle_all_01")
	T(player.character_pose.driver)["=="](model.source_pose)
	local standing = player.player_avatar.armature:GetBoneMatrix("head").m31
	T(standing)[">"](1)
	step(1, Vec3(0, 0, -1.5))
	T(animator:GetSequence())["=="]("walk_all")
	T(animator:GetPoseParameterByName("move_x"))[">"](0.5)
	step(1, Vec3(0, 0, -7))
	T(animator:GetSequence())["=="]("run_all_01")
	step(1, Vec3(0, 6, 0))
	T(animator:GetSequence())["=="]("jump_all")
	player:Remove()
	pvars.SetSession("cl_outfit", "player_outfit")
end)

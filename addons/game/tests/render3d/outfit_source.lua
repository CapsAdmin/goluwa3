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
Entity.RegisterComponent("player_input", import("lua/components/player_input.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))

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

T.Test3D("the head camera of the source outfit follows the head bone and stays within two capsule radii", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile(outfit_source.Model) then
		return T.Unavailable("gmod content not mounted")
	end

	pvars.SetSession("cl_outfit", outfit_source.Name)
	pvars.SetSession("cl_outfit_head_smoothing", 0)
	local player = Entity.New{
		transform = {Position = Vec3(0, 0, 0)},
		player_avatar = {},
		character_pose = {},
		player_input = {},
		player_controller = {Source = "queue"},
		character_movement = {},
	}
	local avatar = player.player_avatar

	T.WaitUntil(
		function()
			local model = avatar.outfit and avatar.outfit:GetChildren()[1]
			return model and
				model.animator and
				model.animator:GetRig() and
				model.source_pose and
				avatar.armature
		end,
		30
	)

	avatar:UpdateHeadOffset(1 / 60)
	T(avatar:GetHeadOffset():GetLength())["=="](0)
	pvars.SetSession("cl_outfit_head_camera", true)
	avatar:UpdateHeadOffset(1 / 60)
	local head = avatar.armature:GetBoneMatrix("head")
	local expected = Vec3(head.m30, head.m31, head.m32) - player.character_movement:GetEyeOffset()
	local offset = avatar:GetHeadOffset()
	local limit = player.character_movement:GetRadius() * 2
	T(offset:GetLength())["<="](limit + 1e-5)
	T(offset:GetLength())["~"](math.min(expected:GetLength(), limit), 1e-4)
	pvars.SetSession("cl_outfit_head_vertical", false)
	avatar:UpdateHeadOffset(1 / 60)
	T(avatar:GetHeadOffset().y)["=="](0)
	pvars.SetSession("cl_outfit_head_camera", false)
	pvars.SetSession("cl_outfit_head_vertical", true)
	pvars.SetSession("cl_outfit_head_smoothing", 0.05)
	player:Remove()
	pvars.SetSession("cl_outfit", "player_outfit")
end)

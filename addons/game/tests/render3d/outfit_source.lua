local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local outfit_source = import("lua/outfit_source.lua")
local outfit = import("lua/outfit.lua")
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
	T(animator:GetSpeed())["~"](1, 0.15)
	T(animator:GetPoseParameterByName("move_x"))[">"](0.5)
	step(1, Vec3(0, 0, -4))
	T(animator:GetSequence())["=="]("run_all_01")
	T(model.source_pose.sprinting)["=="](false)
	T(animator:GetSpeed())["<"](1.3)
	local forward_rate = animator:GetSpeed()
	step(1, Vec3(4, 0, 0))
	T(animator:GetSpeed() > forward_rate * 1.25)["=="](true)
	step(1, Vec3(0, 0, -7.62))
	T(animator:GetSequence())["=="]("run_all_02")
	T(model.source_pose.sprinting)["=="](true)
	T(animator:GetSpeed())[">"](1.3)
	T(animator:GetSpeed())["<"](1.7)
	local restarts = 0
	local restart = animator.Restart
	animator.Restart = function(...)
		restarts = restarts + 1
		return restart(...)
	end
	player.transform.RenderVelocity = Vec3(0, 6, 0)
	player.transform.RenderVelocityFrame = system.GetFrameNumber()

	for _ = 1, 12 do
		player.character_pose:OnUpdate(1 / 60)
		model.source_pose:OnUpdate(1 / 60)
	end

	T(animator:GetSequence())["=="]("jump_holding_jump")
	T(player.character_pose.airborne)["=="](true)
	step(1, Vec3(0, 6, 0))
	T(animator:GetSequence())["=="]("jump_holding_glide")
	step(1, Vec3(0, 0.3, 0))
	T(animator:GetSequence())["=="]("jump_holding_glide")
	step(1, Vec3(0, -3, 0))
	T(animator:GetSequence())["=="]("jump_holding_glide")
	T(restarts)["=="](2)
	animator.Restart = restart
	player.character_pose.grounded = true
	player.character_pose.vertical_speed = 0
	player.character_pose:UpdateAirborne()
	model.source_pose:OnUpdate(1 / 60)
	T(player.character_pose.airborne)["=="](false)
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
	pvars.SetSession("cl_outfit_head_forward", 0)
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
	player.character_pose.grounded = true

	for _ = 1, 5 do
		avatar.outfit:GetChildren()[1].source_pose:OnUpdate(1 / 60)
	end

	pvars.SetSession("cl_outfit_head_camera", true)
	avatar:UpdateHeadOffset(1 / 60)
	local head = avatar.armature:GetBoneMatrix("head")
	local expected = Vec3(head.m30, head.m31, head.m32) - player.character_movement:GetEyeOffset()
	local offset = avatar:GetHeadOffset()
	local limit = player.character_movement:GetRadius() * 2
	T(offset:GetLength())["<="](limit + 1e-5)
	T(offset:GetLength())["~"](math.min(expected:GetLength(), limit), 1e-4)
	T(avatar:IsHeadCameraActive())["=="](true)
	avatar.player_hidden = true
	avatar:UpdateHeadOffset(1 / 60)
	T(avatar:GetHeadOffset():GetLength())["=="](0)
	T(avatar:IsHeadCameraActive())["=="](false)
	avatar.player_hidden = false
	avatar:UpdateHeadOffset(1 / 60)
	local plain = avatar:GetHeadOffset():Copy()
	pvars.SetSession("cl_outfit_head_forward", 0.08)
	avatar:UpdateHeadOffset(1 / 60)
	local view_forward = player.player_input:GetRotation():GetForward()
	T((avatar:GetHeadOffset() - plain):Dot(view_forward))["~"](0.08, 1e-4)
	pvars.SetSession("cl_outfit_head_forward", 0)
	pvars.SetSession("cl_outfit_head_vertical", false)
	avatar:UpdateHeadOffset(1 / 60)
	T(avatar:GetHeadOffset().y)["=="](0)
	pvars.SetSession("cl_outfit_head_camera", false)
	avatar:UpdateHeadOffset(1 / 60)
	T(avatar:IsHeadCameraActive())["=="](false)
	pvars.SetSession("cl_outfit_head_vertical", true)
	pvars.SetSession("cl_outfit_head_smoothing", 0.05)
	pvars.SetSession("cl_outfit_head_forward", 0.08)
	player:Remove()
	pvars.SetSession("cl_outfit", "player_outfit")
end)

T.Test3D("source animations of two players on different frame histories sit on the same cycle of the shared distance", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile(outfit_source.Model) then
		return T.Unavailable("gmod content not mounted")
	end

	pvars.SetSession("cl_outfit", outfit_source.Name)
	local players, models = {}, {}

	for i = 1, 2 do
		players[i] = Entity.New{
			transform = {Position = Vec3(i * 3, 0, 0)},
			player_avatar = {},
			character_pose = {},
		}
	end

	T.WaitUntil(
		function()
			for i = 1, 2 do
				local outfit = players[i].player_avatar.outfit
				local model = outfit and outfit:GetChildren()[1]
				models[i] = model

				if
					not (
						model and
						model.animator and
						model.animator:GetRig() and
						model.source_pose and
						players[i].player_avatar.armature
					)
				then
					return false
				end
			end

			return true
		end,
		30
	)

	for speed, name in pairs{[0] = "idle", [1.5] = "walk"} do
		for i = 1, 2 do
			local pose = players[i].character_pose
			pose.seed = 0.3
			pose.rate_scale = 1
			pose.rate_variation = 1
			pose.forward_speed = speed
			pose.right_speed = 0
			pose.grounded = true
			pose.Distance = 10
		end

		for step = 1, 240 do
			local dt = step % 2 == 0 and 1 / 30 or 1 / 120
			models[1].source_pose:OnUpdate(1 / 60)
			models[1].animator:Animate(1 / 60)
			models[2].source_pose:OnUpdate(dt)
			models[2].animator:Animate(dt)
		end

		local first, second = models[1].animator, models[2].animator
		T(first:GetSequence())["=="](second:GetSequence())
		local duration = first.clip.Duration
		local difference = math.abs(first.time - second.time) / duration
		T(math.min(difference, 1 - difference))["<"](0.05)
	end

	for i = 1, 2 do
		players[i]:Remove()
	end

	pvars.SetSession("cl_outfit", "player_outfit")
end)

T.Test3D("the source rig sinks by the gap between the origin and the ground so the feet stand on it", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile(outfit_source.Model) then
		return T.Unavailable("gmod content not mounted")
	end

	pvars.SetSession("cl_outfit", outfit_source.Name)

	if not physics.instance then physics.Initialize() end

	local ground = Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local player = Entity.New{
		transform = {Position = Vec3(0, 0.03, 0)},
		player_avatar = {},
		character_pose = {},
	}
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

	for _ = 1, 10 do
		physics.UpdateFixed(1 / 60)
	end

	local pose = player.character_pose
	local source_pose = model.source_pose

	for _ = 1, 60 do
		pose.grounded = true
		source_pose:OnUpdate(1 / 60)
	end

	local sunk = player.player_avatar.armature:GetBoneMatrix("foot_r").m31
	T(source_pose.ground_sink)["~"](0.03, 0.002)
	player.transform:SetPosition(Vec3(0, 0, 0))

	for _ = 1, 60 do
		pose.grounded = true
		source_pose:OnUpdate(1 / 60)
	end

	T(source_pose.ground_sink)["~"](0, 0.002)
	T(player.player_avatar.armature:GetBoneMatrix("foot_r").m31 - sunk)["~"](0.03, 0.004)
	pose.grounded = false
	player.transform:SetPosition(Vec3(0, 0.03, 0))

	for _ = 1, 60 do
		source_pose:OnUpdate(1 / 60)
	end

	T(source_pose.ground_sink)["~"](0, 0.002)
	player:Remove()
	ground:Remove()
	physics.ResetState()
	pvars.SetSession("cl_outfit", "player_outfit")
end)

T.Test3D("source models without a head or a foot bone still pose, mirror and ragdoll", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile(outfit_source.Model) then
		return T.Unavailable("gmod content not mounted")
	end

	local biped = import("lua/biped.lua")
	pvars.SetSession("cl_outfit", outfit_source.Name)
	local checked = {}

	for _, path in ipairs({"models/player/zombie_classic.mdl", "models/player/eli.mdl"}) do
		pvars.SetSession("cl_outfit_model", path)
		local player = Entity.New{
			transform = {Position = Vec3(0, 0, 0)},
			player_avatar = {},
			character_pose = {},
			ragdoll = {},
		}
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

		local rig = model.animator:GetRig()
		local missing = {}

		for name in pairs(biped.SourceBones) do
			if not biped.HasBone(rig, name) then missing[#missing + 1] = name end
		end

		checked[path] = missing
		local bones = {}
		biped.ReadBones(rig, bones)

		for name in pairs(biped.SourceBones) do
			T(bones[name] ~= nil)["=="](true)
		end

		player.character_pose.grounded = true

		for _ = 1, 5 do
			model.source_pose:OnUpdate(1 / 60)
		end

		player.player_avatar:SetFirstPerson(true)
		player.player_avatar:SetFirstPerson(false)
		T(player.player_avatar.armature:GetBoneMatrix("head") ~= nil)["=="](true)
		player.ragdoll:ComputePose()
		player:Remove()
	end

	T(table.has_value(checked["models/player/zombie_classic.mdl"], "head") ~= nil)["=="](true)
	pvars.SetSession("cl_outfit_model", outfit_source.Model)
	pvars.SetSession("cl_outfit", "player_outfit")
end)

T.Test3D("citizen jump clips are added to player models with a matching bind pose only", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile(outfit_source.Model) then
		return T.Unavailable("gmod content not mounted")
	end

	local mdl_decoder = import("goluwa/render3d/model_decoders/mdl.lua")
	local bones = {
		["valvebiped.bip01_pelvis"] = true,
		["valvebiped.bip01_l_thigh"] = true,
		["valvebiped.bip01_l_upperarm"] = true,
	}

	local function is_jump(name)
		return name:starts_with("jump_holding_")
	end

	local function skeleton_of(path)
		local entity = Entity.New{transform = {Position = Vec3(0, 0, 0)}, model = {ModelPath = path}, animator = {}}
		T.WaitUntil(function()
			return entity.animator and entity.animator:GetRig() and entity.animator.skeleton
		end, 30)
		return entity.animator.skeleton, entity
	end

	local kleiner, kleiner_entity = skeleton_of("models/player/kleiner.mdl")
	T(mdl_decoder.AddAnimations(kleiner, "models/humans/male_shared", is_jump, bones))["=="](true)
	T(kleiner.ClipsByName.jump_holding_jump.Duration)["~"](0.433, 0.01)
	T(kleiner.ClipsByName.jump_holding_land ~= nil)["=="](true)
	kleiner_entity:Remove()
	local zombie, zombie_entity = skeleton_of("models/player/zombie_classic.mdl")
	T(mdl_decoder.AddAnimations(zombie, "models/humans/male_shared", is_jump, bones))["=="](false)
	T(zombie.ClipsByName.jump_holding_jump)["=="](nil)
	zombie_entity:Remove()
end)

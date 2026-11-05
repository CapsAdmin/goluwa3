local T = import("test/environment.lua")
local Color = import("goluwa/structs/color.lua")

T.Test3D("the blade trail clip follows the base and tip params and fades out when it is ended", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Color = import("goluwa/structs/color.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local clips = import("goluwa/render3d/clips.lua")
	import("lua/jrpg/effects.lua")
	local params = {
		color = Color(1, 0.5, 0.2, 1),
		overlay = "magic_generic",
		base = Vec3(0, 1, 0),
		tip = Vec3(0, 2, 0),
		position = Vec3(0, 2, 0),
	}
	local clip = clips.Play("jrpg_blade_trail", params, true)
	T(clip.states[3].entity.transform:GetPosition():Distance(params.position))["<"](0.001)

	for i = 1, 5 do
		params.tip:Set(i * 0.2, 2, 0)
		params.position:Set(i * 0.2, 2, 0)
		T(clip:Update(0, 0.016))["=="](true)
	end

	T(clip.values.release)["=="](1)
	local emitter = clip.states[3].entity.transform:GetPosition()
	T(math.abs(emitter.x - 1) < 0.001)["=="](true)
	T(clip.states[1].trail ~= nil)["=="](true)
	clip:End(0.5)
	T(clip:Update(0, 0.25))["=="](true)
	T(math.abs(clip.values.release - 0.5) < 0.001)["=="](true)
	T(clip:Update(0, 0.3))["=="](false)
	clip:Remove()

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)

T.Test3D("a swinging melee weapon plays one blade trail clip, feeds it the blade and ends it with the swing", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local movesets = import("lua/movesets.lua")
	local sounds = import("lua/sounds.lua")
	local effects = import("lua/jrpg/effects.lua")
	loadstring(import("lua/weapons/melee.lua").Source)()
	local melee = import("goluwa/objects/objects.lua").GetRegistered("weapon_melee")
	local swinging = true
	local tip = Vec3(0, 2, 0)
	local base = Vec3(0, 1, 0)

	local function node(position)
		return {
			transform = {
				GetWorldMatrix = function()
					return {GetTranslation = ||->position:Unpack()}
				end,
			},
		}
	end

	local nodes = {blade_base = node(base), blade_tip = node(tip)}
	local self = {
		Owner = {
			weapon = {IsEquipped = ||->true, IsSheathed = ||->false, Attributes = {}},
			prefab = {GetNode = |_,name|->nodes[name]},
		},
		SwingPitch = 1,
		TrailColor = Color(1, 1, 1, 1),
		EndTrail = melee.EndTrail,
	}
	local holder = {
		transform = {GetPosition = ||->Vec3()},
		character_pose = {GetActiveAction = ||->"swing", 0},
		IsValid = ||->true,
	}
	self.GetHolder = ||->holder
	local saved = {movesets.GetMove, movesets.IsSwinging, sounds.PlayRandom, effects.Visual}
	movesets.GetMove = ||->{}
	movesets.IsSwinging = ||->swinging
	sounds.PlayRandom = function() end
	effects.Visual = true
	melee.OnUpdate(self, 0.016)
	local clip = self.blade
	T(clip ~= nil)["=="](true)
	tip:Set(1, 2, 0)
	melee.OnUpdate(self, 0.016)
	T(self.blade)["=="](clip)
	T(clip.params.tip.x)["=="](1)
	T(clip.params.base.y)["=="](1)
	T(clip.params.position.x)["=="](1)
	swinging = false
	melee.OnUpdate(self, 0.016)
	T(self.blade)["=="](nil)
	T(clip.release_duration ~= nil)["=="](true)
	clip:Stop()
	movesets.GetMove, movesets.IsSwinging, sounds.PlayRandom, effects.Visual = unpack(saved)

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)

local T = import("test/environment.lua")
local clips = import("goluwa/render3d/clips.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

T.Test3D("A clip fires events once, feeds tracks to layers and releases them", function()
	local fired, setups, removed, seen = 0, 0, 0, {}
	clips.Define(
		"test_clip",
		{
			Duration = 2,
			Tracks = {grow = {{0, 0}, {0.5, 1}}},
			Events = {
				{
					0,
					function()
						fired = fired + 1
					end,
				},
				{
					0.5,
					function()
						fired = fired + 10
					end,
				},
			},
			Layers = {
				{
					Setup = function(p, state)
						setups = setups + 1
					end,
					Update = function(p, v, state)
						seen[#seen + 1] = v.grow
						seen.time = v.time
					end,
					Remove = function()
						removed = removed + 1
					end,
				},
				{
					When = "extra",
					Setup = function()
						setups = setups + 100
					end,
					Update = function() end,
					Remove = function()
						removed = removed + 100
					end,
				},
			},
		}
	)
	local clip = clips.Play("test_clip", {position = Vec3(), color = Color(1, 0, 0, 1)})
	T(fired)["=="](1)
	T(setups)["=="](1)
	clip:Update(0.25, 0.1)
	clip:Update(0.5, 0.1)
	clip.time = 1.5
	clip:Update(0.75, 0.1)
	T(fired)["=="](11)
	T(seen[1])["=="](0.5)
	T(seen[3])["=="](1)
	T(seen.time)["=="](1.5)
	clip:Remove()
	T(removed)["=="](1)
end)

T.Test3D("A sustained clip ends on Stop or when its entity is removed", function()
	local Entity = import("goluwa/entities/entity.lua")
	local removed = 0
	clips.Define(
		"test_sustained",
		{
			Duration = math.huge,
			EndWithEntity = true,
			Layers = {
				{
					Update = function() end,
					Remove = function()
						removed = removed + 1
					end,
				},
			},
		}
	)
	local entity = Entity.New{Name = "clip_target", transform = {}}
	local clip = clips.Play("test_sustained", {entity = entity, position = Vec3()})
	T(clip:Update(0, 0.1))["=="](true)
	entity:Remove()
	T(clip:Update(0, 0.1))["=="](false)
	local other_entity = Entity.New{Name = "clip_target2", transform = {}}
	local other = clips.Play("test_sustained", {entity = other_entity, position = Vec3()})
	other:Stop()
	T(other.duration)["=="](0)
	other_entity:Remove()
end)

T.Test3D("A clip defines the bursts it lists", function()
	local vfx = import("goluwa/render3d/vfx.lua")
	clips.Define(
		"test_burst",
		{
			Duration = 0,
			Bursts = {test_clip_burst = {MaxParticles = 16, Lit = false, SpeedMin = 1, SpeedMax = 2}},
			Events = {{0, Burst = "test_clip_burst", Count = 4, Direction = "normal"}},
		}
	)
	T(vfx.HasBurst("test_clip_burst"))["=="](true)
end)

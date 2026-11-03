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
			Bursts = {test_clip_burst = {MaxParticles = 16, Lit = false, Speed = {1, 2}}},
			Events = {{0, Burst = "test_clip_burst", Count = 4, Direction = "normal"}},
		}
	)
	T(vfx.HasBurst("test_clip_burst"))["=="](true)
end)

T.Test3D("A clip defined as pure data evaluates expressions and named scripts", function()
	local seen, scripted = {}, 0
	clips.RegisterScript("test_clip_script", {
		Event = function()
			scripted = scripted + 1
		end,
	})
	clips.RegisterScript(
		"test_clip_layer",
		{
			Update = function(p, v)
				seen.grow = v.grow
			end,
		}
	)
	local source = {
		Duration = 2,
		Tracks = {
			grow = {{0, 0, "1 - (1 - f) ^ 2"}, {1, 1}},
			wave = "sin(f * pi)",
		},
		Events = {{0.5, Call = "test_clip_script"}},
		Layers = {
			{Type = "custom", Script = "test_clip_layer"},
		},
	}
	clips.Define("test_data_clip", source)
	T(clips.Source.test_data_clip)["=="](source)
	T(type(source.Tracks.wave))["=="]("string")
	local clip = clips.Play("test_data_clip", {position = Vec3(), color = Color(1, 0, 0, 1), base = 1})
	clip:Update(0.25, 0.1)
	T(scripted)["=="](0)
	clip:Update(0.5, 0.1)
	T(scripted)["=="](1)
	T(math.abs(seen.grow - 0.75) < 1e-6)["=="](true)
	T(math.abs(clip.values.wave - 1) < 1e-6)["=="](true)
	T(math.abs(clip.values.grow - 0.75) < 1e-6)["=="](true)
	clip:Remove()
end)

T.Test3D("A clip plays emitters named from the registry or written inline, with inputs from its params", function()
	local Entity = import("goluwa/entities/entity.lua")
	local vfx = import("goluwa/render3d/vfx.lua")
	local emitter_data = import("goluwa/render3d/emitter_data.lua")
	emitter_data.Set(
		"test_named_emitter",
		{
			MaxParticles = 16,
			Rate = 0,
			Speed = 1,
			Inputs = {Strength = {Default = 1, Targets = {{"Speed", "set_max"}}}},
		}
	)
	clips.Define(
		"test_emitters",
		{
			Duration = 1,
			Events = {
				{
					0,
					Emitter = "test_named_emitter",
					Count = 2,
					Direction = "normal",
					Inputs = {Strength = "strength"},
				},
				{
					0,
					Emitter = {MaxParticles = 8, Rate = 0, Speed = {0.1, 1}},
					Count = 2,
					Direction = "normal",
				},
				{
					0,
					Emitter = "test_named_emitter",
					Count = 2,
					Direction = "normal",
					When = "missing",
				},
			},
			Layers = {{Type = "emitter", Emitter = {MaxParticles = 8, Rate = 5}, At = "tip"}},
		}
	)
	local clip = clips.Play(
		"test_emitters",
		{position = Vec3(), tip = Vec3(1, 2, 3), strength = 4, normal = Vec3(0, 1, 0)},
		true
	)
	T(vfx.HasBurst("test_named_emitter:Strength=4"))["=="](true)
	T(vfx.HasBurst("test_named_emitter"))["=="](false)
	T(vfx.HasBurst("test_emitters:event2"))["=="](true)
	clip:Update(0.1, 0.016)
	local position = clip.states[1].entity.transform:GetPosition()
	T(position.x)["=="](1)
	T(position.y)["=="](2)
	clip:Remove()

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)

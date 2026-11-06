local T = import("test/environment.lua")
local particle_helpers = import("test/particle_helpers.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local particles = import("goluwa/render3d/particles.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local particle_emitter_gpu = import("goluwa/render3d/particle_emitter_gpu.lua")
local particle_shaders = import("goluwa/render3d/particle_shaders.lua")
local STEP = particle_helpers.STEP
local init = particle_helpers.init
local restore = particle_helpers.restore
local step = particle_helpers.step
local add_emitter = particle_helpers.add_emitter
local step_with_update = particle_helpers.step_with_update

T.Test("size and color values take a constant, a range or a curve and reject malformed curves", function()
	local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
	particle_emitter.CheckProperties{
		Size = 0.1,
		Color = Color(1, 0, 0, 1),
	}
	particle_emitter.CheckProperties{
		Size = {0.1, 0.3},
		Color = {Color(1, 0, 0, 1), {0, 0, 1, 1}},
	}
	particle_emitter.CheckProperties{
		Size = {Keys = {{0, 0.1}, {0.5, 0.4, "smooth"}, {1, 0}}, MaxKeys = {{0, 0.2}, {1, 0.1}}},
		Color = {Keys = {{0, {1, 1, 1, 1}}, {1, Color(1, 0, 0, 0)}}},
	}

	for _, properties in ipairs{
		{Size = {Keys = {}}},
		{Size = {Keys = {{0.5, 1}, {0.2, 2}}}},
		{Size = {Keys = {{0, 1}, {2, 2}}}},
		{Size = {Keys = {{0, 1, "bounce"}}}},
		{Size = {Keys = {{0, {1, 1, 1}}}}},
		{Color = {Keys = {{0, 1}}}},
		{Color = {1, 0}},
		{Color = "red"},
	} do
		T(pcall(particle_emitter.CheckProperties, properties))["=="](false)
	end

	local entity = Entity.New{
		Name = "band_emitter_data",
		transform = {},
		particle_emitter_gpu = {Size = {Keys = {{0, 0.1}, {1, 0.4}}}},
	}
	T(entity.particle_emitter_gpu:GetSize().Keys[2][2])["=="](0.4)
	entity:Remove()
	T(
		pcall(
			Entity.New,
			{
				Name = "bad_band_emitter",
				transform = {},
				particle_emitter_gpu = {Color = {Keys = {{0, 5}}}},
			}
		)
	)["=="](false)
end)

T.Test("a curve bakes into the lookup table the shaders and the cpu sample", function()
	local ffi = require("ffi")
	local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
	local samples = particle_emitter.CURVE_SAMPLES
	local low, high = ffi.new("float[?]", samples), ffi.new("float[?]", samples)
	particle_emitter.BakeScalar(0.25, low, high)
	T(low[0])["=="](0.25)
	T(high[samples - 1])["=="](0.25)
	particle_emitter.BakeScalar({0.1, 0.3}, low, high)
	T(math.abs(low[7] - 0.1) < 1e-6)["=="](true)
	T(math.abs(high[7] - 0.3) < 1e-6)["=="](true)
	particle_emitter.BakeScalar({Keys = {{0, 0}, {1, 1}}, MaxKeys = {{0, 0}, {1, 2}}}, low, high)
	T(math.abs(particle_emitter.SampleBaked(low, high, 0.5, 0) - 0.5) < 1e-6)["=="](true)
	T(math.abs(particle_emitter.SampleBaked(low, high, 0.5, 1) - 1) < 1e-6)["=="](true)
	T(math.abs(particle_emitter.SampleBaked(low, high, 0.5, 0.5) - 0.75) < 1e-6)["=="](true)
	T(particle_emitter.SampleBaked(low, high, 2, 0))["=="](1)
	particle_emitter.BakeScalar({Keys = {{0.25, 1, "step"}, {0.75, 3}, {1, 5}}}, low, high)
	T(low[0])["=="](1)
	T(low[samples - 1])["=="](5)
	T(low[20])["=="](1)
	T(low[10])["=="](1)
	T(low[25] > 3 and low[25] < 4)["=="](true)
	particle_emitter.BakeScalar({Keys = {{0, 0}, {1, 1, "smooth"}, {1, 1}}}, low, high)
	T(math.abs(low[0]) < 1e-6)["=="](true)
	particle_emitter.BakeScalar({Keys = {{0, 0, "smooth"}, {1, 1}}}, low, high)
	T(math.abs(particle_emitter.SampleBaked(low, low, 0.25, 0) - 0.15625) < 0.01)["=="](true)
	local colors_low, colors_high = ffi.new("float[?]", samples * 4), ffi.new("float[?]", samples * 4)
	particle_emitter.BakeColor({Keys = {{0, {1, 0, 0, 1}}, {1, Color(0, 0, 1, 0)}}}, colors_low, colors_high)
	T(colors_low[0])["=="](1)
	T(colors_low[3])["=="](1)
	T(math.abs(colors_low[(samples - 1) * 4 + 2] - 1) < 1e-6)["=="](true)
	T(math.abs(colors_low[(samples - 1) * 4 + 3]) < 1e-6)["=="](true)
	particle_emitter.BakeColor({{1, 0, 0, 1}, Color(0, 1, 0, 1)}, colors_low, colors_high)
	T(colors_low[4])["=="](1)
	T(colors_high[5])["=="](1)
	particle_emitter.BakeColor({1, 0.5, 0.25}, colors_low, colors_high)
	T(colors_low[7])["=="](1)
	local scaled = particle_emitter.ScaleRange({Keys = {{0, 1}, {1, 2}}, MaxKeys = {{0, 3}, {1, 4}}}, 2)
	T(scaled.Keys[2][2])["=="](4)
	T(scaled.MaxKeys[1][2])["=="](6)
	T(particle_emitter.AddRange({Keys = {{0, 1}}}, 1).Keys[1][2])["=="](2)
	local tinted = particle_emitter.TintColor({Keys = {{0, {1, 1, 1, 1}}, {1, {1, 1, 1, 0}}}}, Color(0, 1, 0, 1), "set_last")
	T(tinted.Keys[1][2][2])["=="](1)
	T(tinted.Keys[1][2][1])["=="](1)
	T(tinted.Keys[2][2].g)["=="](1)
	T(tinted.Keys[2][2].r)["=="](0)
	T(tinted.Keys[2][2].a)["=="](0)
	local all = particle_emitter.TintColor(Color(1, 1, 1, 0.5), Color(0, 1, 0, 1), "set")
	T(all.g)["=="](1)
	T(all.a)["=="](0.5)
	local first = particle_emitter.TintColor(Color(1, 1, 1, 0.5), Color(0, 1, 0, 1), "set_first")
	T(first.Keys[1][2].r)["=="](0)
	T(first.Keys[2][2].r)["=="](1)
end)

T.Test3D("Graphics render3d gpu emitter size and alpha follow their curves over the life", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
		emitter:SetRate(100)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(4)
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetDrag(0)
		emitter:SetLit(false)
		emitter:SetSize{Keys = {{0, 0.1}, {0.5, 0.6}, {1, 0.2}}}
		emitter:SetColor{Keys = {{0, {1, 1, 1, 0}}, {1, {1, 1, 1, 1}}}}
		emitter:SetEmissive{Keys = {{0, 1000}, {1, 3000}}}
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 150)
		local records = particles.Download(particle_emitter_gpu.system)
		local checked = 0
		local gain

		for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
			local p = records[i]
			local t = p.age / p.life

			if p.life > 0 and t > 0.15 and t < 0.85 then
				checked = checked + 1
				local size = t <= 0.5 and 0.1 + t / 0.5 * 0.5 or 0.6 - (t - 0.5) / 0.5 * 0.4
				T(math.abs(p.width - size) < 0.03)["=="](true)
				T(math.abs(p.visibility - t) < 0.03)["=="](true)
				local emissive = 1000 + 2000 * t
				gain = gain or p.radiance[0] / emissive
				T(gain > 0)["=="](true)
				T(math.abs(p.radiance[0] / emissive / gain - 1) < 0.05)["=="](true)
			end
		end

		T(checked > 100)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d gpu emitter color picks a point between two colors per particle", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
		emitter:SetRate(100)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(4)
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetDrag(0)
		emitter:SetLit(false)
		emitter:SetEmissive(1000)
		emitter:SetColor{{1, 0, 0, 1}, Color(0, 0, 1, 1)}
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 100)
		local records = particles.Download(particle_emitter_gpu.system)
		local low, high, alive = 1, 0, 0

		for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 and p.visibility > 0.5 then
				alive = alive + 1
				local share = p.radiance[2] / (p.radiance[0] + p.radiance[2])
				low, high = math.min(low, share), math.max(high, share)
				T(math.abs(p.radiance[1]) < 1e-6)["=="](true)
			end
		end

		T(alive > 100)["=="](true)
		T(low < 0.2)["=="](true)
		T(high > 0.8)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d gpu emitter swirls around its axis", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 1, 0))
		emitter:SetRate(100)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(4)
		emitter:SetShape("disc")
		emitter:SetShapeSize(Vec3(2, 1, 1))
		emitter:SetSpread(0)
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetDrag(0)
		emitter:SetSwirl(4)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 60)
		local uid = emitter.gpu_range.uid
		local records = particles.Download(particle_emitter_gpu.system)
		local checked = 0
		local tangential_sum = 0

		for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
			local p = records[i]
			local x, z = p.position[0], p.position[2] + 5
			local radius = math.sqrt(x * x + z * z)

			if p.life > 0 and p.user[2] == uid and p.age > 0.5 and radius > 0.2 then
				checked = checked + 1
				local tangential = (p.velocity[0] * z - p.velocity[2] * x) / radius
				tangential_sum = tangential_sum + tangential
				T(tangential > 0)["=="](true)
				T(math.abs(p.velocity[1]) < 1e-3)["=="](true)
			end
		end

		T(checked > 20)["=="](true)
		T(tangential_sum / checked > 1)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d gpu emitter ages particles that fall below its minimum speed", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 1, 0))
		emitter:SetRate(50)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(4)
		emitter:SetSpread(0)
		emitter:SetSpeed(0.2)
		emitter:SetGravityScale(0)
		emitter:SetDrag(0)
		emitter:SetMinSpeed(1)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 20)

		local function measure()
			local before = particles.Download(particle_emitter_gpu.system)
			local ages = {}

			for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
				if
					before[i].life > 0 and
					before[i].age > 0.3 and
					before[i].age < before[i].life - 0.5
				then
					ages[i] = before[i].age
				end
			end

			step_with_update(draw, 2)
			local after = particles.Download(particle_emitter_gpu.system)
			local total, count = 0, 0

			for i, age in pairs(ages) do
				if after[i].life > 0 and after[i].age > age then
					total = total + after[i].age - age
					count = count + 1
				end
			end

			T(count > 5)["=="](true)
			return total / count / (2 * STEP)
		end

		T(math.abs(measure() - 5) < 0.2)["=="](true)
		emitter:SetMinSpeed(0)
		T(math.abs(measure() - 1) < 0.2)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d gpu emitter marks mirrored and ground oriented sprites in the particle record", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 1, 0))
		emitter:SetRate(100)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(4)
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetFlipRandom(0.5)
		emitter:SetOrientation("ground")
		emitter:SetAlphaFromColor(true)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 60)
		local uid = emitter.gpu_range.uid
		local records = particles.Download(particle_emitter_gpu.system)
		local alive, flipped, grounded, from_color = 0, 0, 0, 0

		for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 and p.user[2] == uid then
				alive = alive + 1
				flipped = flipped + (bit.band(p.spare, 2) ~= 0 and 1 or 0)
				grounded = grounded + (bit.band(p.spare, 4) ~= 0 and 1 or 0)
				from_color = from_color + (bit.band(p.spare, 8) ~= 0 and 1 or 0)
			end
		end

		T(alive > 100)["=="](true)
		T(grounded)["=="](alive)
		T(from_color)["=="](alive)
		T(flipped > alive * 0.3 and flipped < alive * 0.7)["=="](true)
		T(pcall(emitter.SetOrientation, emitter, "sideways"))["=="](false)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test("a one shot emitter still emits when its first step is longer than its duration", function()
	local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
	local emitter = {
		Playing = true,
		Loop = false,
		Duration = 0.1,
		Rate = 100,
		MaxParticles = 50,
		particle_state = {time = 0, carry = 0, burst = 0},
	}
	T(particle_emitter.Step(emitter, 2))["=="](50)
	T(particle_emitter.Step(emitter, 0.016))["=="](0)
	emitter.particle_state = {time = 0, carry = 0, burst = 0}
	T(particle_emitter.Step(emitter, 0.016))["=="](1)
	T(particle_emitter.Step(emitter, 0.05))["=="](5)
	T(particle_emitter.Step(emitter, 0.05))["=="](5)
	T(particle_emitter.Step(emitter, 0.05))["=="](0)
end)

T.Test3D("Graphics render3d gpu emitter picks a random sequence of a sprite sheet and animates inside it", function(draw)
	init()
	local sprite_sheets = import("goluwa/render3d/sprite_sheets.lua")
	local sequences = {}

	for s = 1, 4 do
		sequences[s] = {id = s - 1, time = 1, frames = {}}

		for f = 1, 3 do
			sequences[s].frames[f] = {rect = {(f - 1) / 3, (s - 1) / 4, f / 3, s / 4}}
		end
	end

	sprite_sheets.Define(
		"test_sprite_sheet",
		import("goluwa/render3d/vfx.lua").GetTexture("glow"),
		sequences
	)
	particle_shaders.Register(
		"test_sheet_sprite",
		{
			Params = {{Name = "Sprite", Type = "texture", Default = "smoke"}},
			Sprite = "Sprite",
		}
	)
	particles.Recompile()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 1, 0))
		emitter:SetShader("test_sheet_sprite")
		emitter:SetShaderParams({Sprite = "test_sprite_sheet"})
		emitter:SetRate(100)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(4)
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetDrag(0)
		emitter:SetSequence({1, 2})
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 90)
		local uid = emitter.gpu_range.uid
		local records = particles.Download(particle_emitter_gpu.system)
		local seen = {}
		local checked = 0

		for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 and p.age > 0.3 and p.age < p.life and p.user[2] == uid then
				local frame = p.sprite[2]
				local t = p.age / p.life
				checked = checked + 1
				seen[math.floor(frame / 3)] = true
				T(frame >= 3 and frame <= 8)["=="](true)
				T(frame % 3)["=="](math.min(math.floor(t * 3), 2))
			end
		end

		T(checked > 50)["=="](true)
		T(seen[1])["=="](true)
		T(seen[2])["=="](true)
		T(seen[0])["=="](nil)
		T(seen[3])["=="](nil)
	end)

	if entity then entity:Remove() end

	particle_shaders.Remove("test_sheet_sprite")
	particles.Recompile()
	restore()

	if not ok then error(err, 0) end
end)

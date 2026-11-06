local T = import("test/environment.lua")
local particle_helpers = import("test/particle_helpers.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local particles = import("goluwa/render3d/particles.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local particle_emitter_gpu = import("goluwa/render3d/particle_emitter_gpu.lua")
local particle_emitter_cpu = import("goluwa/render3d/particle_emitter_cpu.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local init = particle_helpers.init
local restore = particle_helpers.restore
local step = particle_helpers.step
local add_emitter = particle_helpers.add_emitter
local step_with_update = particle_helpers.step_with_update

local function fire_at_wall(draw, collision)
	local farthest
	local entity
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		render3d.GetCamera():SetAngles{x = 0, y = 0, z = 0}
		test_scene.Box{name = "spark_wall", pos = Vec3(0, 0, -6), size = Vec3(20, 20, 0.2)}
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -2), Vec3(0, 0, -1))
		emitter:SetRate(400)
		emitter:SetMaxParticles(1500)
		emitter:SetSpread(17)
		emitter:SetSpeed({4, 8})
		emitter:SetLifetime({1, 2.5})
		emitter:SetCollision(collision)
		step(draw, 90)
		local def = particle_emitter_gpu.system
		local records = particles.Download(def)
		farthest = 0

		for i = 0, def.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 and math.abs(p.position[1]) < 4 then
				farthest = math.max(farthest, -p.position[2] - 6)
			end
		end
	end)

	if entity then entity:Remove() end

	test_scene.GetRoot():Remove()

	if not ok then error(err, 0) end

	return farthest
end

for _, collision in ipairs{"rays", "scene_depth"} do
	local test = collision == "rays" and T.Test3DRayTracing or T.Test3D

	test("Graphics render3d particle emitter bounces off a wall with " .. collision, function(draw)
		init()
		local ok, err = pcall(function()
			T(fire_at_wall(draw, "none") > 0.5)["=="](true)
			T(fire_at_wall(draw, collision) < 0.1)["=="](true)
		end)
		restore()

		if not ok then error(err, 0) end
	end)
end

T.Test3D("Graphics render3d particle emitter in the gbuffer is queued as instances and bounces on rays", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local entity
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		render3d.GetCamera():SetAngles{x = 0, y = 0, z = 0}
		test_scene.Box{name = "debris_wall", pos = Vec3(0, 0, -6), size = Vec3(20, 20, 0.2)}
		local emitter
		emitter, entity = add_emitter("particle_emitter_cpu", Vec3(0, 0, -2), Vec3(0, 0, -1))
		emitter:SetMesh("cube")
		emitter:SetRate(60)
		emitter:SetMaxParticles(400)
		emitter:SetSpread(10)
		emitter:SetSpeed({5, 8})
		emitter:SetLifetime(20)
		emitter:SetGravityScale(0)
		emitter:SetSize(0.2)
		emitter:SetCollision("rays")
		emitter:SetOnHit("stick")
		step_with_update(draw, 45)
		local runtime = emitter.particle_state.cpu
		T(math.abs(particle_emitter_cpu.GetParticleCount(emitter) - 90) <= 2)["=="](true)
		T(gbuffer_instancing.GetStats().queued_instances)["=="](particle_emitter_cpu.GetParticleCount(emitter))
		local count = particle_emitter_cpu.GetParticleCount(emitter)
		local stuck, farthest = 0, 0

		for i = 0, count - 1 do
			local p = runtime.particles[i]
			stuck = stuck + p.stuck
			farthest = math.max(farthest, -p.z - 6)
		end

		T(stuck > 10)["=="](true)
		T(farthest < 0.1)["=="](true)
	end)

	if entity then entity:Remove() end

	test_scene.GetRoot():Remove()
	restore()

	if not ok then error(err, 0) end
end)

T.Test("Graphics render3d particle emitters differ by type in what they have", function()
	local gpu = Entity.New{Name = "gpu_emitter"}
	local cpu = Entity.New{Name = "cpu_emitter"}
	gpu:AddComponent("transform")
	cpu:AddComponent("transform")
	local a = gpu:AddComponent("particle_emitter_gpu")
	local b = cpu:AddComponent("particle_emitter_cpu")
	T(a.GetRate ~= nil and b.GetRate ~= nil and a.Burst ~= nil and b.Burst ~= nil)["=="](true)
	T(a.GetColor ~= nil and a.GetEmissive ~= nil and a.GetLit ~= nil)["=="](true)
	T(b.GetColor == nil and b.GetEmissive == nil and b.GetLit == nil)["=="](true)
	T(b.GetMesh ~= nil and b.GetMaterial ~= nil and b.GetFreezeAfter ~= nil)["=="](true)
	T(b.GetColor == nil and b.GetRoughness == nil and b.GetMetallic == nil)["=="](true)
	T(a.GetMesh == nil and a.GetMaterial == nil and a.GetFreezeAfter == nil)["=="](true)
	T(pcall(a.SetCollision, a, "scene_depth"))["=="](true)
	T(pcall(b.SetCollision, b, "scene_depth"))["=="](false)
	gpu:Remove()
	cpu:Remove()
end)

T.Test("Graphics render3d gpu emitters that do not fit the pool wait for room instead of failing", function()
	local emitters = {}

	for i = 1, 3 do
		local entity = Entity.New{Name = "pool_emitter" .. i}
		entity:AddComponent("transform")
		local emitter = entity:AddComponent("particle_emitter_gpu")
		emitter:SetMaxParticles(math.floor(particle_emitter_gpu.POOL_SIZE / 2) - 1000)
		emitters[i] = entity
	end

	local function sync()
		system.SetFrameNumber(system.GetFrameNumber() + 1)
		return particle_emitter_gpu.GetRanges()
	end

	T(#sync())["=="](2)
	T(emitters[1].particle_emitter_gpu.gpu_range ~= nil)["=="](true)
	T(emitters[2].particle_emitter_gpu.gpu_range ~= nil)["=="](true)
	T(emitters[3].particle_emitter_gpu.gpu_range == nil)["=="](true)
	emitters[1]:Remove()
	T(#sync())["=="](2)
	T(emitters[3].particle_emitter_gpu.gpu_range ~= nil)["=="](true)
	emitters[2]:Remove()
	emitters[3]:Remove()
	T(#sync())["=="](0)
end)

T.Test3D("Graphics render3d cpu emitter draws refractive materials through the translucent pass", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		render3d.GetCamera():SetAngles{x = 0, y = 0, z = 0}
		local emitter
		emitter, entity = add_emitter("particle_emitter_cpu", Vec3(0, 0, -3), Vec3(0, 0, -1))
		emitter:SetMesh("shard")
		emitter:SetMaterial(
			import("goluwa/render3d/material.lua").New{
				Refraction = 1,
				IndexOfRefraction = 1.3,
				RefractionThickness = 0.05,
				DoubleSided = true,
			}
		)
		emitter:SetRate(0)
		emitter:SetPlaying(false)
		emitter:SetMaxParticles(50)
		emitter:SetSpeed({0, 0.5})
		emitter:SetLifetime(20)
		emitter:SetGravityScale(0)
		emitter:SetSize(0.3)
		emitter:Burst(20)
		step_with_update(draw, 5)
		T(particle_emitter_cpu.GetParticleCount(emitter))["=="](20)
		T(emitter.particle_state.cpu.translucent)["=="](true)
		T(gbuffer_instancing.GetStats().queued_instances)["=="](0)
		T(render3d.translucent_depth_far > 0)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d particle emitter randomizes drag, gravity and spin per particle inside their ranges", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(1, 0, 0))
		emitter:SetRate(0)
		emitter:SetPlaying(false)
		emitter:SetMaxParticles(256)
		emitter:SetLifetime(30)
		emitter:SetSpeed(6)
		emitter:SetSpread(0)
		emitter:SetGravityScale({0, 2})
		emitter:SetDrag({0, 3})
		emitter:SetSize(0.2)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		emitter:Burst(200)
		step_with_update(draw, 3)
		step_with_update(draw, 20)
		local def = particle_emitter_gpu.system
		local records = particles.Download(def)
		local min_x, max_x, min_y, max_y = math.huge, -math.huge, math.huge, -math.huge

		for i = 0, def.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 then
				min_x = math.min(min_x, p.position[0])
				max_x = math.max(max_x, p.position[0])
				min_y = math.min(min_y, p.position[1])
				max_y = math.max(max_y, p.position[1])
			end
		end

		T(max_x - min_x > 1)["=="](true)
		T(max_y - min_y > 0.5)["=="](true)
		emitter:SetGravityScale(1)
		emitter:SetDrag(1)
		emitter:Restart()
		emitter:Burst(200)
		step_with_update(draw, 3)
		step_with_update(draw, 20)
		records = particles.Download(def)
		local fixed_min_y, fixed_max_y = math.huge, -math.huge

		for i = 0, def.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 and p.age < 1 then
				fixed_min_y = math.min(fixed_min_y, p.position[1])
				fixed_max_y = math.max(fixed_max_y, p.position[1])
			end
		end

		T(fixed_max_y - fixed_min_y < 0.05)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test("Graphics render3d particle emitter properties accept a number or a min max range", function()
	local entity = Entity.New{Name = "range_emitter"}
	entity:AddComponent("transform")
	local emitter = entity:AddComponent("particle_emitter_gpu")
	T(pcall(emitter.SetDrag, emitter, 2))["=="](true)
	T(pcall(emitter.SetDrag, emitter, {1, 3}))["=="](true)
	T(pcall(emitter.SetDrag, emitter, "x"))["=="](false)
	T(pcall(emitter.SetDrag, emitter, {1}))["=="](false)
	T(pcall(emitter.SetRate, emitter, {1, 2}))["=="](false)
	local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
	local low, high = particle_emitter.GetRange(4)
	T(low)["=="](4)
	T(high)["=="](4)
	low, high = particle_emitter.GetRange({5, 2})
	T(low)["=="](2)
	T(high)["=="](5)
	T(particle_emitter.ScaleRange({1, 2}, 3)[2])["=="](6)
	T(particle_emitter.AddRange(1, 3))["=="](4)
	entity:Remove()
	local built = Entity.New{
		Name = "range_emitter_data",
		transform = {},
		particle_emitter_gpu = {Speed = 2, Lifetime = {1, 2}, Size = {0.1, 0.2}, Drag = 3},
	}
	T(built.particle_emitter_gpu:GetSpeed())["=="](2)
	T(built.particle_emitter_gpu:GetLifetime()[2])["=="](2)
	T(built.particle_emitter_gpu:GetSize()[1])["=="](0.1)
	built:Remove()
end)

T.Test3D("Graphics render3d cpu emitter randomizes speed, lifetime, drag and size per particle inside their ranges", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		local emitter
		emitter, entity = add_emitter("particle_emitter_cpu", Vec3(0, 0, -3), Vec3(0, 0, -1))
		emitter:SetRate(0)
		emitter:SetPlaying(false)
		emitter:SetMaxParticles(100)
		emitter:SetSpread(0)
		emitter:SetSpeed({1, 5})
		emitter:SetLifetime({10, 20})
		emitter:SetGravityScale(0)
		emitter:SetDrag({0, 2})
		emitter:SetSize({0.1, 0.3})
		emitter:Burst(60)
		step_with_update(draw, 10)
		local runtime = emitter.particle_state.cpu
		local min_life, max_life, min_speed, max_speed = math.huge, -math.huge, math.huge, -math.huge

		for i = 0, runtime.count - 1 do
			local p = runtime.particles[i]
			local speed = math.sqrt(p.vx ^ 2 + p.vy ^ 2 + p.vz ^ 2)
			min_life, max_life = math.min(min_life, p.life), math.max(max_life, p.life)
			min_speed, max_speed = math.min(min_speed, speed), math.max(max_speed, speed)
		end

		T(runtime.count)["=="](60)
		T(min_life >= 10 and max_life <= 20 and max_life - min_life > 4)["=="](true)
		T(min_speed < 3 and max_speed > 3 and max_speed < 5.01)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test("Graphics render3d a gpu emitter entity that fails to construct leaves no emitter behind", function()
	local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
	local before = #particle_emitter.instances
	local ok, err = pcall(
		Entity.New,
		{
			Name = "bad_emitter",
			transform = {},
			particle_emitter_gpu = {MaxParticles = 100.5},
		}
	)
	T(ok)["=="](false)
	T(tostring(err):find("expected integer", 1, true) ~= nil)["=="](true)
	T(#particle_emitter.instances)["=="](before)
	ok = pcall(
		Entity.New,
		{
			Name = "bad_emitter_2",
			transform = {},
			particle_emitter_gpu = {MaxParticles = 8},
			particle_emitter_cpu = {MaxParticles = 8.5},
		}
	)
	T(ok)["=="](false)
	T(#particle_emitter.instances)["=="](before)
end)

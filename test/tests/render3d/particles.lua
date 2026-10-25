local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local particles = import("goluwa/render3d/particles.lua")
local precipitation = import("goluwa/render3d/precipitation.lua")
local weather = import("goluwa/render3d/weather.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Quat = import("goluwa/structs/quat.lua")
local event = import("goluwa/event.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local particle_emitter_gpu = import("goluwa/render3d/particle_emitter_gpu.lua")
local particle_emitter_cpu = import("goluwa/render3d/particle_emitter_cpu.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local STEP = 1 / 30

local function init()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/particles.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

local function restore()
	weather.SetSnow(0)
	weather.SetRain(0)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

local function step(draw, count)
	for _ = 1, count do
		system.SetElapsedTime(system.GetElapsedTime() + STEP)
		draw()
	end
end

local function luma(p)
	return 0.2126 * p.radiance[0] + 0.7152 * p.radiance[1] + 0.0722 * p.radiance[2]
end

T.Test3D("Graphics render3d particles snow falls through a box around the camera and is lit", function(draw)
	init()
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(5, 20, -3))
		weather.SetSnow(5)
		step(draw, 4)
		T(particles.IsActive())["=="](true)
		local snow = precipitation.snow
		local count = snow.GetCount()
		local before = particles.Download(snow)
		step(draw, 1)
		local after = particles.Download(snow)
		local camera = render3d.GetCamera():GetPosition()
		local visible, lit, moved, compared = 0, 0, 0, 0

		for i = 0, count - 1 do
			local p = after[i]
			T(p.life > 0)["=="](true)
			T(
				math.abs(p.position[0] - camera.x) <= 10.01 and
					math.abs(p.position[1] - camera.y) <= 10.01 and
					math.abs(p.position[2] - camera.z) <= 10.01
			)["=="](true)

			if p.visibility > 0 then
				visible = visible + 1

				if luma(p) > 0 then lit = lit + 1 end
			end

			local b = before[i]
			local dy = p.position[1] - b.position[1]

			if p.age > STEP * 1.5 and math.abs(dy) < 1 then
				compared = compared + 1
				local expected = (p.velocity[1] + b.velocity[1]) * 0.5 * STEP

				if math.abs(dy - expected) < 0.02 then moved = moved + 1 end
			end
		end

		T(visible > count * 0.5)["=="](true)
		T(lit > visible * 0.99)["=="](true)
		T(compared > count * 0.5)["=="](true)
		T(moved > compared * 0.95)["=="](true)
	end)
	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d particles pick up the light of a lamp", function(draw)
	init()
	local lamp
	local ok, err = pcall(function()
		weather.SetSunDirection(Vec3(0.3, -1, 0.2):GetNormalized())
		render3d.GetCamera():SetPosition(Vec3(0, 20, 0))
		lamp = Entity.New{Name = "particle_lamp"}
		lamp:AddComponent("transform")
		lamp.transform:SetPosition(Vec3(4, 20, 0))
		local light = lamp:AddComponent("light_point")
		light:SetColor(Color(1, 0.5, 0.2, 1))
		light:SetLumen(20000)
		weather.SetSnow(5)
		step(draw, 6)
		local snow = precipitation.snow
		local records = particles.Download(snow)
		local near, near_sum, far, far_sum = 0, 0, 0, 0

		for i = 0, snow.GetCount() - 1 do
			local p = records[i]

			if p.visibility > 0 then
				local distance = math.sqrt((p.position[0] - 4) ^ 2 + (p.position[1] - 20) ^ 2 + p.position[2] ^ 2)
				local behind = (4 - p.position[0]) / math.max(distance, 1e-4)

				if distance < 2 and behind > 0.9 then
					near, near_sum = near + 1, near_sum + luma(p)
				elseif distance > 9 then
					far, far_sum = far + 1, far_sum + luma(p)
				end
			end
		end

		T(near > 0 and far > 0)["=="](true)
		T(near_sum / near > far_sum / far * 2)["=="](true)
	end)

	if lamp and lamp:IsValid() then lamp:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d particles do nothing without precipitation", function(draw)
	init()
	local ok, err = pcall(function()
		weather.SetSnow(0)
		weather.SetRain(0)
		T(particles.IsActive())["=="](false)
		step(draw, 2)
		weather.SetRain(10)
		step(draw, 2)
		T(particles.IsActive())["=="](true)
		T(precipitation.rain.GetCount() > 0)["=="](true)
		T(precipitation.snow.IsActive())["=="](false)
	end)
	restore()

	if not ok then error(err, 0) end
end)

local function add_emitter(component, position, direction)
	local entity = Entity.New{Name = "test_emitter"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(position)
	local dir = direction:GetNormalized()
	local axis = Vec3(0, 1, 0):GetCross(dir)
	entity.transform:SetRotation(Quat(axis.x, axis.y, axis.z, 1 + dir.y):Normalize())
	return entity:AddComponent(component), entity
end

local function count_alive(records, count)
	local alive = 0

	for i = 0, count - 1 do
		if records[i].life > 0 and records[i].age < records[i].life then
			alive = alive + 1
		end
	end

	return alive
end

local function step_with_update(draw, count)
	for _ = 1, count do
		system.SetElapsedTime(system.GetElapsedTime() + STEP)
		event.Call("Update", STEP)
		draw()
	end
end

T.Test3D("Graphics render3d particle emitter spawns the number its rate and bursts ask for", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
		emitter:SetRate(0)
		emitter:SetMaxParticles(500)
		emitter:SetLifetimeMin(30)
		emitter:SetLifetimeMax(30)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step(draw, 3)
		local def = particle_emitter_gpu.system
		T(count_alive(particles.Download(def), def.GetCount()))["=="](0)
		emitter:Burst(120)
		step(draw, 2)
		T(count_alive(particles.Download(def), def.GetCount()))["=="](120)
		emitter:SetRate(60)
		emitter:SetLoop(false)
		emitter:SetDuration(0.5)
		emitter:Restart()
		step(draw, 40)
		local alive = count_alive(particles.Download(def), def.GetCount())
		T(math.abs(alive - 150) <= 3)["=="](true)
		emitter:Burst(500)
		step(draw, 2)
		T(count_alive(particles.Download(def), def.GetCount()))["=="](500)
		emitter:SetMaxParticles(200)
		step(draw, 3)
		T(count_alive(particles.Download(def), def.GetCount()) <= 200)["=="](true)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d particle emitter bursts at each queued position", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
		emitter:SetRate(0)
		emitter:SetMaxParticles(200)
		emitter:SetShape("point")
		emitter:SetSpeedMin(0)
		emitter:SetSpeedMax(0)
		emitter:SetGravityScale(0)
		emitter:SetLifetimeMin(30)
		emitter:SetLifetimeMax(30)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step(draw, 3)
		emitter:BurstAt(20, Vec3(-10, 0, -5), Vec3(0, 1, 0))
		emitter:BurstAt(30, Vec3(10, 0, -5), Vec3(0, 1, 0))
		step(draw, 4)
		local def = particle_emitter_gpu.system
		local records = particles.Download(def)
		local left, right = 0, 0

		for i = 0, def.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 then
				if math.abs(p.position[0] + 10) < 0.5 then left = left + 1 end

				if math.abs(p.position[0] - 10) < 0.5 then right = right + 1 end
			end
		end

		T(left)["=="](20)
		T(right)["=="](30)
	end)

	if entity then entity:Remove() end

	restore()

	if not ok then error(err, 0) end
end)

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
		emitter:SetSpeedMin(4)
		emitter:SetSpeedMax(8)
		emitter:SetLifetimeMin(1)
		emitter:SetLifetimeMax(2.5)
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
		emitter:SetSpeedMin(5)
		emitter:SetSpeedMax(8)
		emitter:SetLifetimeMin(20)
		emitter:SetLifetimeMax(20)
		emitter:SetGravityScale(0)
		emitter:SetSizeStart(0.2)
		emitter:SetSizeEnd(0.2)
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
	T(a.GetColorEnd ~= nil and a.GetEmissive ~= nil and a.GetLit ~= nil)["=="](true)
	T(b.GetColorEnd == nil and b.GetEmissive == nil and b.GetLit == nil)["=="](true)
	T(b.GetMesh ~= nil and b.GetMaterial ~= nil and b.GetSpin ~= nil)["=="](true)
	T(b.GetColor == nil and b.GetRoughness == nil and b.GetMetallic == nil)["=="](true)
	T(a.GetMesh == nil and a.GetMaterial == nil and a.GetSpin == nil)["=="](true)
	T(pcall(a.SetCollision, a, "scene_depth"))["=="](true)
	T(pcall(b.SetCollision, b, "scene_depth"))["=="](false)
	gpu:Remove()
	cpu:Remove()
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
		emitter:SetSpeedMin(0)
		emitter:SetSpeedMax(0.5)
		emitter:SetLifetimeMin(20)
		emitter:SetLifetimeMax(20)
		emitter:SetGravityScale(0)
		emitter:SetSizeStart(0.3)
		emitter:SetSizeEnd(0.3)
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

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
local particle_shaders = import("goluwa/render3d/particle_shaders.lua")
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
		emitter:SetLifetime(30)
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

T.Test3D("Graphics render3d particle shaders run their glsl hooks with params, draw sprites and recompile at runtime", function(draw)
	local function define(push)
		particle_shaders.Register(
			"test_shader",
			{
				Params = {
					{Name = "Push", Type = "float", Default = 1},
					{Name = "Direction", Type = "vec3", Default = {0, 0, 1}},
					{Name = "Flake", Type = "texture", Default = "glow"},
				},
				Sprite = "Flake",
				Source = "void spawn(emitters_t e, uint index, uint generation, inout Particle p) { p.sprite.z = 0.25; }\n" .. "void update(emitters_t e, uint index, float dt, float t, inout Particle p) { " .. push .. " }",
			}
		)
	end

	define("p.velocity += Direction * Push * dt;")
	particles.Recompile()
	init()
	local entity
	local ok, err = xpcall(
		function()
			local emitter
			emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
			emitter:SetRate(0)
			emitter:SetMaxParticles(64)
			emitter:SetLifetime(30)
			emitter:SetSpeed(0)
			emitter:SetGravityScale(0)
			emitter:SetDrag(0)
			emitter:SetShader("test_shader")
			emitter:SetShaderParams{Push = 6, Direction = {1, 0, 0}}
			render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
			step(draw, 3)
			emitter:Burst(32)
			step(draw, 4)
			local def = particle_emitter_gpu.system
			local records = particles.Download(def)
			local checked = 0

			for i = 0, def.GetCount() - 1 do
				local p = records[i]

				if p.life > 0 then
					checked = checked + 1
					T(p.sprite[1] > 0.5)["=="](true)
					T(math.abs(p.sprite[2] - 0.25) < 1e-4)["=="](true)
					T(p.velocity[0] > 0.5)["=="](true)
					T(math.abs(p.velocity[2]) < 1e-3)["=="](true)
				end
			end

			T(checked)["=="](32)
			define("p.velocity += vec3(0.0, 0.0, 1.0) * Push * dt;")
			particles.Recompile()
			emitter:Burst(32)
			step(draw, 4)
			records = particles.Download(def)
			local along_z = 0

			for i = 0, def.GetCount() - 1 do
				local p = records[i]

				if
					p.life > 0 and
					p.age < STEP * 6 and
					p.velocity[2] > 0.5 and
					math.abs(p.velocity[0]) < 1e-3
				then
					along_z = along_z + 1
				end
			end

			T(along_z > 0)["=="](true)
			define("p.velocity += nonsense * Push;")
			local failed, message = pcall(particles.Recompile)
			T(failed)["=="](false)
			T(particle_shaders.ParseError(message):find("test_shader line 2", 1, true) ~= nil)["=="](true)
			define("p.velocity += vec3(0.0, 0.0, 1.0) * Push * dt;")
			particles.Recompile()
			step(draw, 2)
		end,
		debug.traceback
	)

	if entity then entity:Remove() end

	particle_shaders.Remove("test_shader")
	particles.Recompile()
	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d particle sprites play flipbook frames, spin, stretch along their velocity and flatten onto a plane", function(draw)
	particle_shaders.Register(
		"test_flipbook",
		{
			Params = {{Name = "Sprite", Type = "texture", Default = "smoke"}},
			Sprite = "Sprite",
		}
	)
	particles.Recompile()
	init()
	local entity
	local ok, err = xpcall(
		function()
			local emitter
			emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
			emitter:SetRate(0)
			emitter:SetMaxParticles(64)
			emitter:SetLifetime(1)
			emitter:SetSpeed(0)
			emitter:SetGravityScale(0)
			emitter:SetDrag(0)
			emitter:SetShader("test_flipbook")
			render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
			step(draw, 3)
			emitter:Burst(32)
			step(draw, 12)
			local def = particle_emitter_gpu.system
			local records = particles.Download(def)
			local checked = 0

			for i = 0, def.GetCount() - 1 do
				local p = records[i]

				if p.life > 0 then
					checked = checked + 1
					T(math.abs(p.sprite[2] - math.floor(p.age / p.life * 64)) <= 1)["=="](true)
					T(p.sprite[2] > 8)["=="](true)
				end
			end

			T(checked)["=="](32)
			emitter:SetFlipbookFps(30)
			emitter:SetFlipbookRandomStart(true)
			emitter:Burst(32)
			step(draw, 4)
			records = particles.Download(def)
			local frames = {}

			for i = 0, def.GetCount() - 1 do
				local p = records[i]

				if p.life > 0 and p.age < STEP * 6 then
					local frame = p.sprite[2]
					T(frame >= 0 and frame < 64 and frame == math.floor(frame))["=="](true)
					frames[frame] = true
				end
			end

			T(table.count(frames) > 8)["=="](true)
			emitter:SetSpin(90)
			emitter:Burst(32)
			step(draw, 3)
			records = particles.Download(def)
			local before = {}

			for i = 0, def.GetCount() - 1 do
				if records[i].life > 0 and records[i].age < STEP * 5 then
					before[i] = records[i].sprite[0]
				end
			end

			step(draw, 6)
			records = particles.Download(def)
			local spun = 0

			for i, angle in pairs(before) do
				if records[i].life > 0 then
					spun = spun + 1
					T(math.abs(records[i].sprite[0] - angle - math.rad(90) * STEP * 6) < 1e-3)["=="](true)
				end
			end

			T(spun > 16)["=="](true)
			emitter:SetStretch(0.05)
			emitter:SetSpin(0)
			emitter:Burst(32)
			step(draw, 3)
			records = particles.Download(def)
			local stretched = 0

			for i = 0, def.GetCount() - 1 do
				local p = records[i]

				if p.life > 0 and p.age < STEP * 5 then
					stretched = stretched + 1
					T(p.sprite[1] < -0.5)["=="](true)
					T(math.abs(p.sprite[0] - 0.05) < 1e-5)["=="](true)
				end
			end

			T(stretched)["=="](32)
			emitter:SetStretch(0)
			emitter:SetSpeed(2)
			emitter:SetSpread(120)
			emitter:SetFlatten(1)
			emitter:Burst(32)
			step(draw, 2)
			records = particles.Download(def)
			local flattened = 0

			for i = 0, def.GetCount() - 1 do
				local p = records[i]

				if p.life > 0 and p.age < STEP * 4 then
					flattened = flattened + 1
					T(math.abs(p.velocity[2]) < 0.05)["=="](true)
				end
			end

			T(flattened)["=="](32)
		end,
		debug.traceback
	)

	if entity then entity:Remove() end

	particle_shaders.Remove("test_flipbook")
	particles.Recompile()
	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d particle emitter spawns along the path it moved through and randomizes the size in a range", function(draw)
	init()
	local entity
	local ok, err = pcall(function()
		local emitter
		emitter, entity = add_emitter("particle_emitter_gpu", Vec3(0, 0, -5), Vec3(0, 0, -1))
		emitter:SetRate(0)
		emitter:SetRatePerMeter(100)
		emitter:SetMaxParticles(512)
		emitter:SetLifetime(30)
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetDrag(0)
		emitter:SetSize({0.5, 1.5})
		render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
		step_with_update(draw, 3)

		for i = 1, 6 do
			entity.transform:SetPosition(Vec3(i * 0.5, 0, -5))
			step_with_update(draw, 1)
		end

		local def = particle_emitter_gpu.system
		local records = particles.Download(def)
		local alive, min_x, max_x, min_width, max_width = 0, math.huge, -math.huge, math.huge, -math.huge

		for i = 0, def.GetCount() - 1 do
			local p = records[i]

			if p.life > 0 then
				alive = alive + 1
				min_x = math.min(min_x, p.position[0])
				max_x = math.max(max_x, p.position[0])
				min_width = math.min(min_width, p.width)
				max_width = math.max(max_width, p.width)
			end
		end

		T(math.abs(alive - 300) <= 12)["=="](true)
		T(min_x < 0.7)["=="](true)
		T(max_x > 2.8)["=="](true)
		T(min_width < 0.65)["=="](true)
		T(max_width > 1.35)["=="](true)
		step_with_update(draw, 3)
		T(count_alive(particles.Download(def), def.GetCount()))["=="](alive)
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
		emitter:SetSpeed(0)
		emitter:SetGravityScale(0)
		emitter:SetLifetime(30)
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

		for i = 0, particle_emitter_gpu.system.GetCount() - 1 do
			local p = records[i]
			local x, z = p.position[0], p.position[2] + 5
			local radius = math.sqrt(x * x + z * z)

			if p.life > 0 and p.user[2] == uid and p.age > 0.5 and radius > 0.2 then
				checked = checked + 1
				local tangential = (p.velocity[0] * z - p.velocity[2] * x) / radius
				T(tangential > 1)["=="](true)
				T(math.abs(p.velocity[1]) < 1e-3)["=="](true)
			end
		end

		T(checked > 20)["=="](true)
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

	if slow_entity then slow_entity:Remove() end

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

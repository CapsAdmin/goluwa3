local T = import("test/environment.lua")
local particle_helpers = import("test/particle_helpers.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local particles = import("goluwa/render3d/particles.lua")
local precipitation = import("goluwa/render3d/precipitation.lua")
local weather = import("goluwa/render3d/weather.lua")
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


local function count_alive(records, count)
	local alive = 0

	for i = 0, count - 1 do
		if records[i].life > 0 and records[i].age < records[i].life then
			alive = alive + 1
		end
	end

	return alive
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

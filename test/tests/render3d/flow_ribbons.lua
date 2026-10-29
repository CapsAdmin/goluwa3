local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local particles = import("goluwa/render3d/particles.lua")
local flow_ribbons = import("goluwa/render3d/flow_ribbons.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local STEP = 1 / 30
local REACH = 6

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

T.Test3D("Graphics render3d flow ribbons spray particles near the ribbons and release their slots", function(draw)
	init()
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(0, 6, 8))
		step(draw, 2)
		T(flow_ribbons.IsActive())["=="](false)
		flow_ribbons.Burst{
			position = Vec3(0, 0, 0),
			color = Color(1, 0.4, 0.1, 1),
			count = 6,
			reach = REACH,
		}
		T(flow_ribbons.IsActive())["=="](true)
		step(draw, 15)
		local pool = particles.Download(flow_ribbons.spray)
		local alive, glowing, max_radius, min_height = 0, 0, 0, math.huge

		for i = 0, flow_ribbons.SPRAY_POOL - 1 do
			local p = pool[i]

			if p.life > 0 and p.age < p.life then
				alive = alive + 1
				max_radius = math.max(max_radius, math.sqrt(p.position[0] ^ 2 + p.position[2] ^ 2))
				min_height = math.min(min_height, p.position[1])

				if p.visibility > 0 and p.radiance[0] > 0 then glowing = glowing + 1 end
			end
		end

		T(max_radius < REACH * 3)["=="](true)
		T(min_height > -0.1)["=="](true)
		T(alive > 20)["=="](true)
		T(glowing > alive * 0.5)["=="](true)
		step(draw, 150)
		T(flow_ribbons.IsActive())["=="](false)
	end)
	restore()

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d flow ribbon emitters spray along the path they were moved through", function(draw)
	init()
	local ok, err = pcall(function()
		render3d.GetCamera():SetPosition(Vec3(0, 3, 8))
		step(draw, 2)
		local emitter = flow_ribbons.AcquireEmitter{color = Color(0.8, 0.9, 1, 1), density = 400}
		T(flow_ribbons.IsActive())["=="](true)

		for i = 0, 5 do
			emitter:Move(i * 0.5, 2, 0)
			step(draw, 1)
		end

		emitter:Release()
		local pool = particles.Download(flow_ribbons.spray)
		local alive, min_x, max_x, spread = 0, math.huge, -math.huge, 0

		for i = 0, flow_ribbons.SPRAY_POOL - 1 do
			local p = pool[i]

			if p.life > 0 and p.age < p.life then
				alive = alive + 1
				min_x = math.min(min_x, p.position[0])
				max_x = math.max(max_x, p.position[0])
				spread = math.max(spread, math.abs(p.position[1] - 2), math.abs(p.position[2]))
			end
		end

		T(alive > 200)["=="](true)
		T(min_x < 1)["=="](true)
		T(max_x > 2)["=="](true)
		T(spread < 0.15)["=="](true)
		step(draw, 150)
		T(flow_ribbons.IsActive())["=="](false)
	end)
	restore()

	if not ok then error(err, 0) end
end)

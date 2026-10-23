local Color = import("goluwa/structs/color.lua")
local GROW_RATE = 0.8
local SPREAD_RATE = 0.6
local SPREAD_FALLOFF = 0.82
local MELT_RATE = 0.0015
return {
	name = "frost",
	channels = {"frost"},
	Init = function(cell)
		cell.frost_target = 0
	end,
	Apply = function(sim, cell, amount)
		cell.frost_target = math.min(math.max(cell.frost_target, amount), 1)
		cell.frost = math.max(cell.frost, amount * 0.25)
	end,
	Step = function(sim, cell, dt)
		local frost = cell.frost

		if frost <= 0 and cell.frost_target <= 0 then return false end

		local melt = math.max(sim.temperature, 0) * MELT_RATE + cell.heat * 1.5

		if cell.frost_target > 0 then
			frost = frost + (cell.frost_target - frost) * math.min(dt * GROW_RATE, 1)

			if cell.frost_target > 0.15 and math.random() < dt * SPREAD_RATE then
				local tx, ty, tz = sim.RandomTangent(cell, 0, 0, 0)
				local neighbor = sim.Reach(cell, tx, ty, tz)

				if neighbor and neighbor.frost_target < cell.frost_target * SPREAD_FALLOFF then
					neighbor.frost_target = cell.frost_target * SPREAD_FALLOFF
					sim.Activate(neighbor)
				end
			end

			cell.frost_target = math.max(cell.frost_target - melt * dt, 0)
		end

		if melt > 0 and frost > 0 then
			local melted = math.min(frost, melt * dt)
			frost = frost - melted
			cell.wet = math.min(cell.wet + melted * 1.5, 1)
		end

		cell.frost = frost
		sim.Touch(cell)
		return frost > 0 or cell.frost_target > 0
	end,
	Exchange = function(sim, cell, around, dt)
		if around.frost > 0.3 and cell.frost_target < around.frost * SPREAD_FALLOFF then
			cell.frost_target = around.frost * SPREAD_FALLOFF
		end
	end,
	Site = function(cell)
		return math.smoothstep(0.3, 0.9, cell.frost) * (cell.frost_target > 0 and 1 or 0.3),
		0,
		0,
		0
	end,
	particles = {
		{
			Name = "mist",
			Inherit = 0.3,
			Count = 4096,
			Value = 0,
			Rate = 0.5,
			MaxRate = 120,
			Life = {3, 6},
			Size = {0.25, 1.1},
			Rise = {0.02, 0.12},
			Height = {0.02, 0.15},
			Jitter = 0.3,
			Buoyancy = -0.04,
			Drag = 1.4,
			Turbulence = 0.12,
			Wind = 0.6,
			ColorStart = Color(0.82, 0.9, 1, 0.06),
			ColorEnd = Color(0.9, 0.95, 1, 0),
		},
	},
	glsl = {
		weather = [[
			w.wet_scale *= 1.0 - smoothstep(0.1, 0.6, e.frost);
		]],
		surface = [[
			if (e.frost > 0.0) {
				vec4 broad = effect_noise(e.P, e.N, 0.53);
				vec4 fine = effect_noise(e.P, e.N, 3.7);
				vec4 micro = effect_noise(e.P, e.N, 11.0);
				float cover = smoothstep(0.0, 0.3, e.frost - (broad.g * 0.6 + fine.r * 0.4 - 0.5) * 0.4);
				float feather = 1.0 - abs(fine.g * 2.0 - 1.0);
				feather *= feather;
				float thick = smoothstep(0.55, 1.0, e.frost + (broad.r - 0.5) * 0.3);
				float density = cover * mix(0.4 + 0.5 * feather, 0.95, thick);
				s.albedo = mix(s.albedo, mix(vec3(0.7, 0.79, 0.9), vec3(0.93, 0.96, 1.0), feather), density);
				s.roughness_alpha = mix(s.roughness_alpha, mix(0.4, 0.06, thick * (1.0 - feather * 0.5)), cover);
				s.metallic *= 1.0 - cover;
				vec3 tilt = (micro.rgb - 0.5) * mix(0.3, 0.9, feather);
				s.N = normalize(mix(s.N, normalize(s.geometric_N + tilt - s.geometric_N * dot(tilt, s.geometric_N)), cover * 0.7));
				s.ao = mix(s.ao, 1.0, density * 0.5);
				w.rain *= 1.0 - cover;
			}

		]],
	},
}

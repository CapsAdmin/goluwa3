local Color = import("goluwa/structs/color.lua")
local BURN_TIME = 40
local THIN_SPEED = 5
local GROW_RATE = 0.7
local SMOLDER_TIME = 14
local CHAR_TIME = 9
local IGNITION_COOLING = 0.25
local SPREAD = 0.11
local CONVECTION = 0.08
local FLAME_HEIGHT = 1.5
local WIND_BIAS = 0.25
local CLIMB_BIAS = 0.9
local EXCHANGE = 2

local function flame(cell)
	return math.smoothstep(0.15, 0.55, cell.heat) * math.smoothstep(0, 0.06, cell.fuel)
end

local function ignite(sim, cell, amount)
	local damp = math.max(cell.wet, cell.frost, sim.GetWeatherWetness(cell))
	cell.ignition = cell.ignition + amount * (
			0.15 + cell.flammability
		) * (
			cell.thin and
			3 or
			1
		) * (
			1 - damp
		)
end

return {
	name = "fire",
	channels = {"heat", "burnt"},
	Init = function(cell)
		cell.fuel = cell.flammability
		cell.ignition = 0
	end,
	Apply = function(sim, cell, amount)
		cell.fuel = math.max(cell.fuel, amount * 0.35)
		cell.ignition = cell.ignition + amount * 2
		cell.heat = math.max(cell.heat, amount * 0.3)
	end,
	Step = function(sim, cell, dt)
		local heat = cell.heat
		local fuel = cell.fuel

		if cell.ignition >= 1 and fuel > 0.02 and heat < 0.1 then heat = 0.1 end

		cell.ignition = math.max(cell.ignition - IGNITION_COOLING * dt, 0)

		if heat <= 0 then
			cell.ignition = math.min(cell.ignition, 1)
			return cell.ignition > 0
		end

		local speed = cell.thin and THIN_SPEED or 1

		if cell.frost > 0 then
			cell.frost = math.max(cell.frost - heat * dt * 1.5, 0)
			cell.wet = math.min(cell.wet + heat * dt * 1.2, 1)
			heat = heat - cell.frost * dt * 2
		end

		if cell.wet > 0 then
			cell.wet = math.max(cell.wet - heat * dt * 0.4, 0)
			heat = heat - cell.wet * dt * 0.6
		end

		if fuel > 0 then
			local target = math.min(1, 0.25 + fuel * 2.5)
			heat = heat + (target - heat) * math.min(dt * GROW_RATE * speed, 1)
			cell.fuel = math.max(fuel - dt * heat * speed / BURN_TIME, 0)
			cell.burnt = math.min(cell.burnt + dt * heat * speed / CHAR_TIME, 1)
		else
			heat = heat - dt * speed / SMOLDER_TIME
		end

		heat = math.clamp(heat, 0, 1)
		cell.heat = heat
		sim.Touch(cell)

		if heat > 0.2 and fuel > 0 then
			local wind = sim.wind
			local up = math.abs(cell.ny) < 0.7 and CLIMB_BIAS or 0

			for _ = 1, math.random() < heat and 2 or 1 do
				local tx, ty, tz = sim.RandomTangent(cell, wind.x * WIND_BIAS, up, wind.z * WIND_BIAS)
				local neighbor = sim.Reach(cell, tx, ty, tz)

				if neighbor then
					ignite(sim, neighbor, heat * SPREAD * (1 + math.max(ty, 0)))
					sim.Activate(neighbor)
				end
			end

			if math.random() < heat * 0.4 then
				local above = sim.Above(cell, FLAME_HEIGHT * heat)

				if above then
					ignite(sim, above, heat * CONVECTION)
					sim.Activate(above)
				end
			end
		end

		return heat > 0 or cell.ignition > 0
	end,
	Exchange = function(sim, cell, around, dt)
		if around.heat > 0.15 then ignite(sim, cell, around.heat * EXCHANGE * dt) end
	end,
	Site = function(cell)
		local f = flame(cell)
		return f, cell.heat * (1 - f * 0.4), f * 0.8 + cell.heat * 0.05, 0
	end,
	LightPower = flame,
	light = {color = Color(1, 0.5, 0.18, 1), lumen = 300, height = 0.7, flicker = 0.3},
	sheet = {
		Count = 2,
		Height = 1.7,
		Width = 0.9,
		Lift = 0.02,
		Spread = 0.3,
		Value = 0,
		glsl = [[
			float rise = time * 2.0;
			vec2 base_uv = vec2(uv.x * 0.3 + seed * 5.31, uv.y * 0.4);
			float warp = sheet_noise(base_uv * 0.7 + vec2(seed * 2.7, -rise * 0.12)).r - 0.5;
			float coarse = sheet_noise(base_uv + vec2(warp * 0.15, -rise * 0.3)).r;
			float fine = sheet_noise(base_uv * 2.1 + vec2(warp * 0.3, -rise * 0.6)).g;
			float n = clamp(coarse * 0.6 + fine * 0.5 - 0.05, 0.0, 1.0);
			float flicker = sheet_noise(vec2(seed * 9.1, time * 0.45)).r;
			float tall = mix(0.55, 1.0, value) * mix(0.75, 1.15, flicker);
			float y = max(uv.y - 0.1, 0.0) / (0.75 * tall);
			float x = (uv.x * 1.3 + warp * 0.9 * y) / max(1.0 - y * 0.65, 0.1);
			float envelope = clamp(1.0 - y, 0.0, 1.0) * clamp(1.0 - x * x, 0.0, 1.0);
			float flame = envelope * mix(0.5, 1.7, n * n);
			float density = smoothstep(0.18, 0.5, flame) * smoothstep(0.02, 0.1 + fine * 0.3, uv.y);
			float core = smoothstep(0.45, 1.0, flame);
			float kelvin = mix(1150.0, 2300.0, core);
			float luminance = mix(900.0, 15000.0, core * core) * density;
			return vec4(effect_blackbody(kelvin) * luminance * value, density);
		]],
	},
	particles = {
		{
			Name = "smoke",
			Inherit = 0.5,
			Count = 16384,
			Value = 1,
			Rate = 2,
			MaxRate = 350,
			Life = {3, 6.5},
			Size = {0.25, 2.2},
			Rise = {0.8, 1.6},
			Height = {0.7, 1.5},
			Jitter = 0.3,
			Buoyancy = 0.35,
			Drag = 0.5,
			Turbulence = 0.5,
			Wind = 1,
			ColorStart = Color(0.06, 0.055, 0.05, 0.24),
			ColorEnd = Color(0.25, 0.24, 0.23, 0),
		},
		{
			Name = "embers",
			Inherit = 0.7,
			Count = 4096,
			Value = 2,
			Rate = 4,
			MaxRate = 250,
			Life = {1, 2.8},
			Size = {0.014, 0.004},
			Rise = {1.2, 3.5},
			Height = {0.05, 0.8},
			Jitter = 0.35,
			Buoyancy = 1.6,
			Drag = 0.9,
			Turbulence = 2.6,
			Wind = 1,
			ColorStart = Color(1, 1, 1, 1),
			ColorEnd = Color(1, 1, 1, 0),
			Temperature = {1800, 950},
			Emissive = 2e5,
			Sparkle = 0.6,
		},
	},
	glsl = {
		weather = [[
			w.snow_scale *= (1.0 - smoothstep(0.02, 0.3, e.heat)) * (1.0 - smoothstep(0.4, 1.0, e.burnt) * 0.6);
			w.wet_scale *= 1.0 - smoothstep(0.1, 0.5, e.heat);
		]],
		surface = [[
			if (e.heat > 0.0 || e.burnt > 0.0) {
				vec4 broad = effect_noise(e.P, e.N, 0.31);
				vec4 cracks = effect_noise(e.P, e.N, 1.9);
				float burnt = e.burnt * 1.2;
				float threshold = mix(0.12, 0.85, broad.r);
				float charred = smoothstep(threshold - 0.07, threshold + 0.07, burnt);
				float scorch = smoothstep(threshold - 0.5, threshold - 0.02, burnt) * (1.0 - charred);
				float crack = 1.0 - smoothstep(0.02, 0.16, cracks.b);
				float cold = 1.0 - smoothstep(0.0, 0.2, e.heat);
				float ash = smoothstep(0.7, 1.0, e.burnt) * cold * smoothstep(0.35, 0.8, cracks.a);
				vec3 charcoal = vec3(0.022, 0.019, 0.017) * mix(0.55, 1.5, cracks.a);
				s.albedo = mix(s.albedo, s.albedo * vec3(0.42, 0.3, 0.2), scorch * 0.85);
				s.albedo = mix(s.albedo, mix(charcoal, vec3(0.2, 0.19, 0.18), ash * 0.75), charred);
				s.roughness_alpha = mix(s.roughness_alpha, 0.8, charred);
				s.metallic *= 1.0 - charred;
				s.ao *= 1.0 - crack * charred * 0.6;
				vec3 crack_tilt = (vec3(cracks.a, fract(cracks.a * 7.31), fract(cracks.a * 13.7)) - 0.5) * 0.5;
				s.N = normalize(s.N + (crack_tilt - s.geometric_N * dot(crack_tilt, s.geometric_N)) * charred * (1.0 - crack));
				float pulse = effect_noise(e.P + vec3(0.0, -BLOCK.effect_time * 0.25, 0.0), e.N, 0.8).g;
				float glow = smoothstep(0.0, 0.7, e.heat) * mix(0.35, 1.0, pulse);
				float front = (1.0 - smoothstep(0.0, 0.12, abs(burnt - threshold))) * smoothstep(0.1, 0.4, e.heat);
				float embers = crack * charred * glow;
				float kelvin = mix(850.0, 1350.0, clamp(e.heat * pulse * 1.3, 0.0, 1.0));
				s.emissive += effect_blackbody(kelvin) * (embers * 2.5 + front * 5.0) * e.heat;
				consumed = max(consumed, charred * smoothstep(0.55, 0.95, e.burnt));
			}
		]],
	},
}

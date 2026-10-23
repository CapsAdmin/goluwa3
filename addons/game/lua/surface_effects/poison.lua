local Color = import("goluwa/structs/color.lua")
local DECAY_TIME = 90
local FLOW_RATE = 0.3
local FLOW_SHARE = 0.25
local BURN_OFF = 0.6
return {
	name = "poison",
	channels = {"poison"},
	Init = function(cell)
		cell.poison_volume = 0
	end,
	Apply = function(sim, cell, amount)
		cell.poison = math.min(math.max(cell.poison, amount), 1)
		cell.poison_volume = cell.poison_volume + amount
	end,
	Step = function(sim, cell, dt)
		local poison = cell.poison

		if poison <= 0 then return false end

		poison = poison - dt / DECAY_TIME - cell.heat * BURN_OFF * dt

		if cell.poison_volume > 0.3 and math.random() < dt * FLOW_RATE then
			local tx, ty, tz = sim.RandomTangent(cell, 0, -1.5, 0)
			local neighbor = sim.Reach(cell, tx, ty, tz)

			if neighbor and neighbor.py <= cell.py + 0.05 and neighbor.poison < poison then
				local moved = cell.poison_volume * FLOW_SHARE
				cell.poison_volume = cell.poison_volume - moved
				neighbor.poison_volume = neighbor.poison_volume + moved
				neighbor.poison = math.min(math.max(neighbor.poison, poison * 0.85), 1)
				sim.Activate(neighbor)
				sim.Touch(neighbor)
			end
		end

		cell.poison = math.max(poison, 0)
		sim.Touch(cell)
		return cell.poison > 0
	end,
	Site = function(cell)
		return math.smoothstep(0.1, 0.6, cell.poison) * (1 + cell.heat * 3), 0, 0, 0
	end,
	particles = {
		{
			Name = "gas",
			Inherit = 0.3,
			Count = 6144,
			Value = 0,
			Rate = 0.5,
			MaxRate = 150,
			Life = {3, 7},
			Size = {0.3, 1.3},
			Rise = {0.05, 0.3},
			Height = {0.02, 0.25},
			Jitter = 0.3,
			Buoyancy = 0.05,
			Drag = 1.2,
			Turbulence = 0.3,
			Wind = 0.8,
			ColorStart = Color(0.25, 0.55, 0.05, 0.1),
			ColorEnd = Color(0.35, 0.5, 0.12, 0),
			Glow = 4,
		},
	},
	glsl = {
		common = [[
			vec3 poison_bubbles(vec3 P, float time) {
				vec3 slope = vec3(0.0);

				for (int layer = 0; layer < 2; layer++) {
					vec2 q = P.xz / 0.11 + vec2(float(layer) * 0.43, float(layer) * 0.71);
					vec2 cell = floor(q);

					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							vec2 c = cell + vec2(x, y);
							vec3 r = pcg3d_unorm(uvec3(uvec2(ivec2(c) + 32768), uint(layer) + 5u));
							float cycle = time / mix(1.5, 4.0, r.z) + r.x * 7.0;
							float age = fract(cycle);
							vec3 r2 = pcg3d_unorm(uvec3(uvec2(ivec2(c) + 32768), uint(floor(cycle)) * 4u + uint(layer)));
							vec2 delta = q - c - (0.2 + r2.xy * 0.6);
							float radius = mix(0.05, 0.4, r2.z) * smoothstep(0.0, 0.85, age) * (1.0 - smoothstep(0.92, 1.0, age));
							float d2 = dot(delta, delta);

							if (radius <= 0.0 || d2 >= radius * radius) continue;

							float h = sqrt(radius * radius - d2);
							slope.xz += delta / max(h, radius * 0.15);
							slope.y = max(slope.y, 1.0 - sqrt(d2) / radius);
						}
					}
				}

				return slope;
			}
		]],
		surface = [[
			if (e.poison > 0.0) {
				vec4 broad = effect_noise(e.P, e.N, 0.42);
				float threshold = mix(0.1, 0.75, broad.r);
				float cover = smoothstep(threshold - 0.05, threshold + 0.05, e.poison * 1.1);
				float depth = smoothstep(threshold, threshold + 0.45, e.poison);
				vec3 sludge = mix(vec3(0.12, 0.25, 0.02), vec3(0.025, 0.07, 0.008), depth);
				s.albedo = mix(s.albedo, sludge, cover);
				s.metallic *= 1.0 - cover;
				s.roughness_alpha = mix(s.roughness_alpha, 0.25, cover);
				add_surface_film(w, cover * mix(0.6, 1.0, depth), 0.002);

				float flat_surface = smoothstep(0.6, 0.9, s.geometric_N.y);
				vec3 bubbles = poison_bubbles(e.P, BLOCK.effect_time) * depth * flat_surface;
				s.coat_smooth_N = normalize(s.coat_smooth_N - vec3(bubbles.x, 0.0, bubbles.z) * 0.6);
				float pulse = effect_noise(e.P + vec3(BLOCK.effect_time * 0.05, 0.0, 0.0), e.N, 0.7).g;
				s.emissive += vec3(0.25, 1.0, 0.06) * cover * (0.015 + 0.06 * pulse * depth + bubbles.y * 0.25);
			}
		]],
	},
}

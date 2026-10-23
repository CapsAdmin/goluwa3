local system = import("goluwa/system.lua")
local particles = import("goluwa/render3d/particles.lua")
local surface_effects = import("goluwa/render3d/surface_effects.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local surface_effect_particles = {}
local LINGER = 10
local emitters = {}
local pool_size = 0
local last_active = -math.huge

for _, kind in ipairs(surface_effects.kinds) do
	for _, def in ipairs(kind.particles or {}) do
		emitters[#emitters + 1] = {kind = kind, def = def, first = pool_size, cursor = 0, accumulated = 0}
		pool_size = pool_size + def.Count
	end
end

surface_effect_particles.emitters = emitters

local function write_color(target, color)
	target[0], target[1], target[2], target[3] = color.r, color.g, color.b, color.a
end

local function write_range(target, range)
	target[0], target[1] = range[1], range[2]
end

surface_effect_particles.system = particles.Register{
	name = "surface_effects",
	max_count = pool_size,
	scatter_g = 0.35,
	streak_time = 1 / 40,
	fade_near = 0.3,
	depth_near = 0.1,
	depth_far = 300,
	IsActive = function()
		if surface_effects.GetSiteCount() > 0 then
			last_active = system.GetElapsedTime()
			return true
		end

		return system.GetElapsedTime() - last_active < LINGER
	end,
	GetCount = function()
		return pool_size, 1
	end,
	block = {
		{"sites", "uint64_t"},
		{
			"se_emitters",
			{
				{"color_start", "vec4"},
				{"color_end", "vec4"},
				{"life", "vec2"},
				{"size", "vec2"},
				{"rise", "vec2"},
				{"height", "vec2"},
				{"temperature", "vec2"},
				{"jitter", "float"},
				{"buoyancy", "float"},
				{"drag", "float"},
				{"turbulence", "float"},
				{"wind_scale", "float"},
				{"emissive", "float"},
				{"glow", "float"},
				{"sparkle", "float"},
				{"inherit", "float"},
				{"value_index", "int"},
				{"site_first", "int"},
				{"site_count", "int"},
				{"first", "int"},
				{"count", "int"},
				{"cursor", "int"},
				{"spawn_count", "int"},
			},
			#emitters,
		},
		{"wind", "vec3"},
		{"time", "float"},
		{"frame_time", "float"},
	},
	WriteBlock = function(self, block)
		local dt = particles.GetStepTime()
		block.sites = surface_effects.GetSitesAddress()

		for i, emitter in ipairs(emitters) do
			local def = emitter.def
			local entry = block.se_emitters[i - 1]
			local site_first, site_count, sums = surface_effects.GetKindSites(emitter.kind)
			write_color(entry.color_start, def.ColorStart)
			write_color(entry.color_end, def.ColorEnd)
			write_range(entry.life, def.Life)
			write_range(entry.size, def.Size)
			write_range(entry.rise, def.Rise)
			write_range(entry.height, def.Height)
			write_range(entry.temperature, def.Temperature or {0, 0})
			entry.jitter = def.Jitter
			entry.buoyancy = def.Buoyancy
			entry.drag = def.Drag
			entry.turbulence = def.Turbulence
			entry.wind_scale = def.Wind
			entry.emissive = def.Emissive or 0
			entry.glow = def.Glow or 0
			entry.sparkle = def.Sparkle or 0
			entry.inherit = def.Inherit or 0
			entry.value_index = def.Value
			entry.site_first = site_first
			entry.site_count = block.sites == 0 and 0 or site_count
			entry.first = emitter.first
			entry.count = def.Count
			local spawn = 0

			if entry.site_count > 0 then
				emitter.accumulated = emitter.accumulated + math.min(def.Rate * sums[def.Value + 1], def.MaxRate) * dt
				spawn = math.min(math.floor(emitter.accumulated), def.Count)
				emitter.accumulated = emitter.accumulated - spawn
			else
				emitter.accumulated = 0
			end

			entry.cursor = emitter.cursor
			entry.spawn_count = spawn
			emitter.cursor = (emitter.cursor + spawn) % def.Count
		end

		atmosphere.GetWind():CopyToFloatPointer(block.wind)
		block.time = surface_effects.GetTime()
		block.frame_time = dt
		return block
	end,
	declarations = glsl_common.GetNoiseGLSL() .. surface_effects.GetBlackbodyGLSL() .. surface_effects.GetSitesGLSL() .. [[
		#define SE_EMITTER_COUNT ]] .. #emitters .. [[u

		uint se_find_emitter(uint index) {
			for (uint i = 0u; i < SE_EMITTER_COUNT; i++) {
				se_emitters_t e = surface_effects_data.se_emitters[i];

				if (index >= uint(e.first) && index < uint(e.first + e.count)) return i;
			}

			return 0u;
		}

		se_emitters_t se_get_emitter(Particle p) {
			return surface_effects_data.se_emitters[min(p.user.y, SE_EMITTER_COUNT - 1u)];
		}
	]],
	should_spawn = [[
		se_emitters_t e = surface_effects_data.se_emitters[se_find_emitter(index)];

		if (e.site_count <= 0 || e.spawn_count <= 0) return false;

		uint local_index = index - uint(e.first);
		return (local_index + uint(e.count) - uint(e.cursor)) % uint(e.count) < uint(e.spawn_count);
	]],
	spawn = [[
		uint emitter_index = se_find_emitter(index);
		se_emitters_t e = surface_effects_data.se_emitters[emitter_index];
		p.user.y = emitter_index;

		if (e.site_count <= 0) {
			p.life = 0.0;
			return;
		}

		SurfaceEffectSites sites = SurfaceEffectSites(surface_effects_data.sites);
		SurfaceEffectSite site;
		float value = 0.0;

		for (uint attempt = 0u; attempt < 4u; attempt++) {
			vec3 pick = pcg3d_unorm(uvec3(index, generation, 31u + attempt));
			site = sites.s[uint(e.site_first) + min(uint(pick.x * float(e.site_count)), uint(e.site_count) - 1u)];
			value = site.values[e.value_index];

			if (pick.y < value) break;

			value = 0.0;
		}

		if (value <= 0.0) {
			p.life = 0.0;
			return;
		}

		vec3 r = pcg3d_unorm(uvec3(index, generation, 7u));
		vec3 r2 = pcg3d_unorm(uvec3(index, generation, 13u));
		vec3 n = site.normal;
		vec3 t1 = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 t2 = cross(n, t1);
		float angle = r.x * 6.2831853;
		vec3 disc = (t1 * cos(angle) + t2 * sin(angle)) * sqrt(r.y) * e.jitter;
		p.position = site.position + n * 0.05 + disc + vec3(0.0, mix(e.height.x, e.height.y, r.z), 0.0);
		p.velocity = vec3(0.0, mix(e.rise.x, e.rise.y, r2.x), 0.0) + (t1 * (r2.y - 0.5) + t2 * (r2.z - 0.5)) * 0.4 + surface_effects_data.wind * e.wind_scale * 0.3 + site.velocity * e.inherit;
		p.position -= site.velocity * (fract(r.z * 17.3) * surface_effects_data.frame_time);
		p.life = mix(e.life.x, e.life.y, fract(r2.x * 7.31 + r.z));
		p.width = e.size.x;
		p.user.z = floatBitsToUint(min(value, 1.0));
	]],
	update = [[
		se_emitters_t e = se_get_emitter(p);
		float t = clamp(p.age / p.life, 0.0, 1.0);
		p.width = mix(e.size.x, e.size.y, pow(t, 0.6));
		vec3 q = p.position * 0.8 + vec3(0.0, -surface_effects_data.time * 0.6, float(index & 7u) * 3.1);
		vec3 swirl = vec3(value_noise3(q), value_noise3(q + 17.3), value_noise3(q + 41.7)) - 0.5;
		vec3 target = surface_effects_data.wind * e.wind_scale;
		p.velocity += (vec3(0.0, e.buoyancy, 0.0) + swirl * e.turbulence * 4.0) * dt;
		p.velocity -= (p.velocity - target) * (1.0 - exp(-e.drag * dt));
		p.position += p.velocity * dt;
	]],
	visibility = [[
		se_emitters_t e = se_get_emitter(p);
		float t = clamp(p.age / p.life, 0.0, 1.0);
		float alpha = mix(e.color_start.a, e.color_end.a, t) * smoothstep(0.0, 0.1, t) * min(uintBitsToFloat(p.user.z) * 1.5, 1.0);

		if (e.sparkle > 0.0) {
			float seed = fract(p.life * 7.123);
			float twinkle = 0.5 + 0.5 * sin(p.age * mix(14.0, 40.0, seed) + seed * 6.2831853);
			alpha *= mix(1.0, twinkle * twinkle, e.sparkle);
		}

		return alpha;
	]],
	shade = [[
		se_emitters_t e = se_get_emitter(p);
		float t = clamp(p.age / p.life, 0.0, 1.0);
		vec3 tint = mix(e.color_start.rgb, e.color_end.rgb, t);

		if (e.emissive > 0.0) {
			float kelvin = mix(e.temperature.x, e.temperature.y, t);
			float ratio = kelvin / e.temperature.x;
			p.radiance = effect_blackbody(kelvin) * e.emissive * ratio * ratio * ratio * ratio * ratio * ratio;
		} else {
			p.radiance = tint * (p.light + e.glow);
		}
	]],
}
return surface_effect_particles

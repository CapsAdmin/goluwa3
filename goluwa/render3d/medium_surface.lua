local pvars = import("goluwa/cli/pvars.lua")
local water = import("goluwa/render3d/water.lua")
local medium_surface = {}
pvars.StartGroup("Water", "Surface ripples", {store = false})
local ripple_pairs = pvars.Setup2{
	key = "r_water_ripple_pairs",
	default = 6,
	min = 1,
	max = 6,
	integer = true,
	help = "pairs of ripple waves per octave in the small ripples on top of the wave textures, fewer is a more regular ripple pattern",
}
pvars.EndGroup()
medium_surface.OCTAVES = water.DETAIL_OCTAVES
medium_surface.block = {
	{"ripple_pairs", "int"},
	{"bump_tex", "int"},
	{"bump_info", "vec4"},
}

function medium_surface.WriteBlock(self, block)
	block.ripple_pairs = ripple_pairs:Get()
	block.bump_tex = water.wave_bump and self:GetTextureIndex(water.wave_bump.texture) or -1
	block.bump_info[0] = water.wave_bump and water.wave_bump.slope_variance or 0
	return block
end

function medium_surface.GetGLSL(block_name)
	return (
		(
			"const float MEDIUM_SURFACE_GRAVITY = " .. water.GRAVITY .. ";\nconst int MEDIUM_SURFACE_OCTAVES = " .. medium_surface.OCTAVES .. [=[;
const float MEDIUM_SURFACE_LIFETIME = 10.0;
const float MEDIUM_SURFACE_UPWIND_SHARE = 0.5;

float medium_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float medium_surface_resolve(float wavelength, float footprint) {
	float x = clamp(wavelength / max(footprint, 1e-6) * 0.5 - 1.0, 0.0, 1.0);
	return x * x * (3.0 - 2.0 * x);
}

float medium_surface_ripples(vec2 p, float footprint, vec2 wind, vec2 flow, float slope_variance, float wavelength, float upwind_share, float lifetime, inout vec2 grad, inout vec3 hess) {
	float lost_variance = 0.0;
	float time = $B.time;
	float wind_angle = atan(wind.y, wind.x);
	int PAIRS = $B.ripple_pairs;
	p -= flow * time;

	for (int o = 0; o < MEDIUM_SURFACE_OCTAVES; o++) {
		for (int i = 0; i < PAIRS; i++) {
			float pair_seed = float(o * PAIRS + i);
			float length = wavelength * exp2(-(float(i) + medium_hash(vec2(pair_seed, 1.7))) / float(PAIRS));
			float k = 6.28318530718 / length;
			float resolve = medium_surface_resolve(length, footprint);
			lost_variance += slope_variance / float(PAIRS) * (1.0 - resolve);

			if (resolve <= 0.0) continue;

			float amplitude = sqrt(2.0 * slope_variance / float(PAIRS)) / k * resolve;
			float omega = sqrt(MEDIUM_SURFACE_GRAVITY * k + 0.074e-3 * k * k * k);
			float life = lifetime * 6.28318530718 / omega;
			float age = time / life + medium_hash(vec2(pair_seed, 3.1));

			for (int half_life = 0; half_life < 2; half_life++) {
				float u = age + float(half_life) * 0.5;
				float generation = floor(u);
				float seed = pair_seed * 2.0 + float(half_life) + generation * 97.0;
				float angle = wind_angle + (medium_hash(vec2(seed, 5.3)) + medium_hash(vec2(seed, 9.1)) - 1.0) * 2.0;
				if (medium_hash(vec2(seed, 7.7)) < upwind_share) angle += 3.14159265359;
				vec2 kv = vec2(cos(angle), sin(angle)) * k;
				float phase = dot(kv, p) - omega * time + medium_hash(vec2(seed, 13.9)) * 6.28318530718;
				float a = amplitude * sin(3.14159265359 * (u - generation));
				grad += kv * (a * cos(phase));
				hess -= vec3(kv.x * kv.x, kv.y * kv.y, kv.x * kv.y) * (a * sin(phase));
			}
		}

		wavelength *= 0.5;
	}

	return lost_variance;
}

float medium_surface_bump(vec2 p, float footprint, float scale, vec2 wind, float strength, inout vec2 grad, inout vec3 hess) {
	const vec4 FREQUENCIES = vec4(0.02, 0.01, 0.04, 0.02);
	const vec4 WEIGHTS = vec4(2.0, 2.0, 1.0, 1.0);
	float lost_variance = 0.0;

	for (int layer = 0; layer < 4; layer++) {
		float frequency = FREQUENCIES[layer] * scale;
		float texel = 1.0 / (frequency * 256.0);
		float speed = sqrt(MEDIUM_SURFACE_GRAVITY * 4.0 * texel / 6.28318530718);
		bool transposed = (layer & 1) == 1;
		vec2 direction = transposed ? wind.yx : wind;
		vec2 q = (transposed ? p.yx : p) - direction * (speed * $B.time);
		float lod = max(log2(footprint / texel), 0.0);
		float step_size = max(texel * 0.5, footprint * 0.5);
		vec2 step_uv = vec2(step_size * frequency, 0.0);
		float weight = WEIGHTS[layer] * 0.15 * strength;
		vec2 here = (textureLod(TEXTURE($B.bump_tex), q * frequency, lod).rg - 0.5) * weight;
		vec2 along_x = (textureLod(TEXTURE($B.bump_tex), q * frequency + (transposed ? step_uv.yx : step_uv), lod).rg - 0.5) * weight;
		vec2 along_z = (textureLod(TEXTURE($B.bump_tex), q * frequency + (transposed ? step_uv : step_uv.yx), lod).rg - 0.5) * weight;
		vec2 d_dx = (along_x - here) / step_size;
		vec2 d_dz = (along_z - here) / step_size;
		grad += here;
		hess += vec3(d_dx.x, d_dz.y, 0.5 * (d_dx.y + d_dz.x));
		float retained = 1.0 / max(footprint / texel, 1.0);
		lost_variance += weight * weight * $B.bump_info.x * (1.0 - retained * retained);
	}

	return lost_variance;
}

float medium_surface_gradient(vec4 waves, vec2 flow, vec2 world_xz, float footprint, out vec2 grad, inout vec3 hess) {
	grad = vec2(0.0);
	if (waves.x <= 0.0) return 0.0;
	float slope = waves.x * 0.25 / waves.y;

	if ($B.bump_tex != -1) {
		return medium_surface_bump(world_xz, footprint, 6.0 / waves.y, vec2(cos(waves.z), sin(waves.z)) + flow, clamp(waves.x / waves.y * 6.0, 0.0, 1.0), grad, hess);
	}

	return medium_surface_ripples(world_xz, footprint, vec2(cos(waves.z), sin(waves.z)), flow, 2.72 * slope * slope, waves.y, MEDIUM_SURFACE_UPWIND_SHARE, MEDIUM_SURFACE_LIFETIME, grad, hess);
}
]=]
		):gsub("%$B", block_name)
	)
end

function medium_surface.GetCausticGLSL(block_name, options)
	return (
		[=[vec3 NAME(PARAMS, vec3 world_pos, float footprint, int newton_steps, float fade, bool detail, float depth, vec3 sun_dir, float ior, float abbe, float caustics) {
	float blur = clamp(smoothstep(4.0 * fade * $B.view_scale, 30.0 * fade * $B.view_scale, depth) + smoothstep(0.3 * $B.view_scale, 2.0 * $B.view_scale, footprint), 0.0, 1.0);

	if (blur >= 1.0) return vec3(1.0);

	if (blur >= 0.5) {
		newton_steps = 0;
		detail = false;
	}

	vec3 s = depth * (1.0 - 1.0 / screen_refraction_dispersed_ior(ior, abbe));
	vec2 target = world_pos.xz - sun_dir.xz * (depth / max(-sun_dir.y, 0.05));
	vec2 xz = target;
	float filter_size = max(footprint, depth * 0.012);
	vec2 grad;
	vec3 hess;
	bool refiltered = false;

	for (int i = 0; i < newton_steps + 1; i++) {
		grad = vec2(0.0);
		hess = vec3(0.0);
		GRADIENT

		float focus = max(abs(s.g * hess.x), abs(s.g * hess.y));

		if (i == 0 && !refiltered && focus > 1.0) {
			refiltered = true;
			filter_size *= min(focus, 8.0);
			i--;
			continue;
		}

		if (i == newton_steps) break;

		vec2 residual = xz + s.g * grad - target;
		float a = 1.0 + s.g * hess.x;
		float d = 1.0 + s.g * hess.y;
		float b = s.g * hess.z;
		float det = a * d - b * b;
		det = abs(det) < 0.15 ? (det < 0.0 ? -0.15 : 0.15) : det;
		vec2 step = vec2(d * residual.x - b * residual.y, a * residual.y - b * residual.x) / det;
		float max_step = depth * 0.15 + filter_size;
		xz -= step * min(1.0, max_step / max(length(step), 1e-5));
	}

	vec3 jacobian = (1.0 + s * hess.x) * (1.0 + s * hess.y) - s * s * hess.z * hess.z;
	vec3 intensity = 1.0 / sqrt(jacobian * jacobian + 0.0144);
	return mix(vec3(1.0), mix(intensity, vec3(1.0), blur), clamp(caustics, 0.0, 1.0));
}]=]
	):gsub("%$B", block_name):gsub("NAME", options.name):gsub("PARAMS", options.params):gsub("GRADIENT", options.gradient)
end

return medium_surface

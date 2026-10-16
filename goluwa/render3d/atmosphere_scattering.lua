-- The light the air scatters more than once (orders 2 and up), tabulated for every camera height, view direction, sun
-- elevation and angle between the view and the sun (Bruneton and Neyret's precomputed scattering). The single scattering is
-- marched at runtime with the real clouds, fog and phase functions; everything after it is smooth enough for a table, and
-- unlike an isotropic estimate of it, the table follows the sun, the viewer's height and the aerosol without a fit.
--
-- One 2D atlas holds the four axes: x = sun * SC_A + azimuth, y = radius * 2 * SC_V + half * SC_V + elevation. The elevation
-- axis is split at the horizon of the radius (rays that hit the ground, rays that leave) and both halves are spaced with a
-- square root away from it. Interpolation is done by hand across the radius and the sun, the hardware bilinear takes the
-- azimuth and the elevation inside a block.
local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local scattering = {}
scattering.RADIUS_COUNT = 32
scattering.ELEVATION_COUNT = 32
scattering.SUN_COUNT = 32
scattering.AZIMUTH_COUNT = 16
scattering.RADIUS_POWER = 3
scattering.ORDERS = 16
scattering.WIDTH = scattering.SUN_COUNT * scattering.AZIMUTH_COUNT
scattering.HEIGHT = scattering.RADIUS_COUNT * scattering.ELEVATION_COUNT * 2
local IRRADIANCE_SIZE = 64
local Constants = ffi.typeof([[struct {
	float shape[4];
	float extinction;
	float species;
	int order;
	int tables[5];
}]])
local DECLARATIONS = [[
	layout(push_constant) uniform ScatteringConstants {
		vec4 shape;
		float extinction;
		float species;
		int order;
		int tables[5];
	} sc_pc;
]]
-- sc_lookup(table, r, mu, mu_s, nu): r is the radius, mu the cosine of the view's angle from the zenith (the sine of
-- its elevation), mu_s the sun's, nu the cosine of the angle between the view and the sun
scattering.LOOKUP_GLSL = [[
	const int SC_R = ]] .. scattering.RADIUS_COUNT .. [[;
	const int SC_V = ]] .. scattering.ELEVATION_COUNT .. [[;
	const int SC_S = ]] .. scattering.SUN_COUNT .. [[;
	const int SC_A = ]] .. scattering.AZIMUTH_COUNT .. [[;
	const float SC_W = float(SC_S * SC_A);
	const float SC_H = float(SC_R * SC_V * 2);
	const float SC_MU_S_MIN = -0.2;
	const float SC_RADIUS_POWER = ]] .. scattering.RADIUS_POWER .. [[;

	float sc_horizon(float r) {
		return -acos(clamp(PLANET_RADIUS / max(r, PLANET_RADIUS), 0.0, 1.0));
	}

	vec3 sc_fetch(int table, float sun_index, float radius_index, float x, float y) {
		vec2 uv = vec2((sun_index * float(SC_A) + x) / SC_W, (radius_index * 2.0 * float(SC_V) + y) / SC_H);
		return textureLod(TEXTURE(table), uv, 0.0).rgb;
	}

	// The sky above a point seen from the tabulated ambient (the mean radiance of the upper hemisphere, uniform in solid
	// angle, and the irradiance on a surface facing up): sun elevation across the columns of each half, radius down the rows
	void sc_ambient(int table, float r, float mu_s, out vec3 mean_radiance, out vec3 irradiance) {
		float fr = pow(clamp((r - PLANET_RADIUS) / (ATMOSPHERE_RADIUS - PLANET_RADIUS), 0.0, 1.0), 1.0 / SC_RADIUS_POWER) * float(SC_R - 1);
		float v = (fr + 0.5) / float(SC_R);
		float fs = clamp((mu_s - SC_MU_S_MIN) / (1.0 - SC_MU_S_MIN), 0.0, 1.0) * float(SC_S - 1);
		float fade = smoothstep(SC_MU_S_MIN - 0.05, SC_MU_S_MIN, mu_s);
		mean_radiance = textureLod(TEXTURE(table), vec2((fs + 0.5) / float(2 * SC_S), v), 0.0).rgb * fade;
		irradiance = textureLod(TEXTURE(table), vec2((fs + float(SC_S) + 0.5) / float(2 * SC_S), v), 0.0).rgb * fade;
	}

	vec3 sc_lookup(int table, float r, float mu, float mu_s, float nu) {
		float fr = pow(clamp((r - PLANET_RADIUS) / (ATMOSPHERE_RADIUS - PLANET_RADIUS), 0.0, 1.0), 1.0 / SC_RADIUS_POWER) * float(SC_R - 1);
		float ir0 = min(floor(fr), float(SC_R - 2));
		float wr = fr - ir0;
		float e0 = sc_horizon(r);
		float e = asin(clamp(mu, -1.0, 1.0));
		bool upper = e >= e0;
		float t = upper ?
			sqrt(clamp((e - e0) / (0.5 * PI - e0), 0.0, 1.0)) :
			sqrt(clamp((e0 - e) / (0.5 * PI + e0), 0.0, 1.0));
		float y = clamp(t * float(SC_V), 0.5, float(SC_V) - 0.5) + (upper ? float(SC_V) : 0.0);
		float fs = clamp((mu_s - SC_MU_S_MIN) / (1.0 - SC_MU_S_MIN), 0.0, 1.0) * float(SC_S - 1);
		float is0 = min(floor(fs), float(SC_S - 2));
		float ws = fs - is0;
		float cs = sqrt(max(1.0 - mu_s * mu_s, 0.0));
		float cv = sqrt(max(1.0 - mu * mu, 0.0));
		float cos_phi = cs * cv > 1e-5 ? clamp((nu - mu * mu_s) / (cs * cv), -1.0, 1.0) : 1.0;
		float x = 0.5 + acos(cos_phi) / PI * float(SC_A - 1);
		vec3 a = mix(sc_fetch(table, is0, ir0, x, y), sc_fetch(table, is0 + 1.0, ir0, x, y), ws);
		vec3 b = mix(sc_fetch(table, is0, ir0 + 1.0, x, y), sc_fetch(table, is0 + 1.0, ir0 + 1.0, x, y), ws);
		return mix(a, b, wr) * smoothstep(SC_MU_S_MIN - 0.05, SC_MU_S_MIN, mu_s);
	}
]]
local PASSES_GLSL = [[
	#define SC_T1 sc_pc.tables[1]
	#define SC_T2 sc_pc.tables[2]
	#define SC_T3 sc_pc.tables[3]
	#define SC_T4 sc_pc.tables[4]
	const int SC_STEPS = 128;
	const int SC_THETA = 16;
	const int SC_PSI = 32;
	const int SC_IRRADIANCE_SIZE = ]] .. IRRADIANCE_SIZE .. [[;

	void sc_decode(vec2 uv, out vec3 p, out vec3 view, out vec3 sun) {
		ivec2 px = clamp(ivec2(floor(uv * vec2(SC_W, SC_H))), ivec2(0), ivec2(int(SC_W) - 1, int(SC_H) - 1));
		int is = px.x / SC_A;
		int ia = px.x - is * SC_A;
		int ir = px.y / (2 * SC_V);
		int iv = px.y - ir * 2 * SC_V;
		float r = PLANET_RADIUS + (ATMOSPHERE_RADIUS - PLANET_RADIUS) * pow(float(ir) / float(SC_R - 1), SC_RADIUS_POWER);
		float mu_s = SC_MU_S_MIN + (1.0 - SC_MU_S_MIN) * float(is) / float(SC_S - 1);
		float phi = PI * float(ia) / float(SC_A - 1);
		bool upper = iv >= SC_V;
		float t = (float(iv - (upper ? SC_V : 0)) + 0.5) / float(SC_V);
		float e0 = sc_horizon(r);
		float e = upper ? e0 + (0.5 * PI - e0) * t * t : e0 - (0.5 * PI + e0) * t * t;
		p = vec3(0.0, r, 0.0);
		sun = vec3(sqrt(max(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0);
		view = vec3(cos(e) * cos(phi), sin(e), cos(e) * sin(phi));
	}

	// the transmittance of the air between o and o + dir * length, for the short paths down to the ground
	vec3 sc_path_transmittance(vec3 o, vec3 dir, float path_length) {
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;
		float step_size = path_length / 12.0;

		for (int i = 0; i < 12; i++) {
			vec3 q = o + dir * (step_size * (float(i) + 0.5));
			rayleigh_od += rayleigh_density(q) * step_size;
			mie_od += mie_density(q) * step_size;
			ozone_od += ozone_density(q) * step_size;
		}

		return exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
	}

	float sc_irradiance_x(float mu_s) {
		return (clamp((mu_s - SC_MU_S_MIN) / (1.0 - SC_MU_S_MIN), 0.0, 1.0) * float(SC_IRRADIANCE_SIZE - 1) + 0.5) / float(SC_IRRADIANCE_SIZE);
	}
]]
local SINGLE_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		vec3 p0;
		vec3 view;
		vec3 sun;
		sc_decode(uv, p0, view, sun);
		float t_near;
		float t_far;
		bool hits_ground;

		if (!get_atmosphere_segment(p0, view, t_near, t_far, hits_ground)) return vec4(0.0);

		float segment = t_far - t_near;
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;
		vec3 total = vec3(0.0);

		for (int i = 0; i < SC_STEPS; i++) {
			float s0 = float(i) / float(SC_STEPS);
			float s1 = float(i + 1) / float(SC_STEPS);
			float t0 = t_near + get_march_distance(s0, segment);
			float step_size = get_march_distance(s1, segment) - get_march_distance(s0, segment);
			vec3 q = p0 + view * (t0 + 0.5 * step_size);
			float density_r = rayleigh_density(q);
			float density_m = mie_density(q);
			rayleigh_od += density_r * step_size;
			mie_od += density_m * step_size;
			ozone_od += ozone_density(q) * step_size;
			vec3 view_t = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
			vec3 beta = sc_pc.species < 0.5 ? RAYLEIGH_BETA * density_r : MIE_BETA * density_m;
			total += beta * sample_transmittance_lut(q, sun) * view_t * step_size;
		}

		return vec4(total, 1.0);
	}
]]
-- tables: 1 single scattering by the air's molecules, 2 by the aerosol, 3 the previous order, 4 the ground's indirect irradiance
local DENSITY_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		vec3 p;
		vec3 view;
		vec3 sun;
		sc_decode(uv, p, view, sun);
		float r = p.y;
		float density_r = rayleigh_density(p);
		float density_m = mie_density(p);
		vec3 total = vec3(0.0);

		for (int i = 0; i < SC_THETA; i++) {
			float cos_t = 1.0 - 2.0 * (float(i) + 0.5) / float(SC_THETA);
			float sin_t = sqrt(max(1.0 - cos_t * cos_t, 0.0));

			for (int j = 0; j < SC_PSI; j++) {
				float psi = 2.0 * PI * (float(j) + 0.5) / float(SC_PSI);
				vec3 wi = vec3(sin_t * cos(psi), cos_t, sin_t * sin(psi));
				float nu_i = dot(wi, sun);
				vec3 radiance;

				if (sc_pc.order == 2) {
					radiance = sc_lookup(SC_T1, r, wi.y, sun.y, nu_i) * phase_rayleigh(nu_i) + sc_lookup(SC_T2, r, wi.y, sun.y, nu_i) * mie_phase(nu_i);
				} else {
					radiance = sc_lookup(SC_T3, r, wi.y, sun.y, nu_i);
				}

				vec2 ground = ray_sphere_intersect(p, wi, PLANET_RADIUS);

				if (ground.x > -1e-3 && ground.y > 1e-6) {
					float d = max(ground.x, 0.0);
					vec3 g = p + wi * d;
					float mu_sg = dot(normalize(g), sun);
					vec3 irradiance;

					if (sc_pc.order == 2) {
						irradiance = sample_transmittance_lut(g, sun) * max(mu_sg, 0.0);
					} else {
						irradiance = textureLod(TEXTURE(SC_T4), vec2(sc_irradiance_x(mu_sg), 0.5), 0.0).rgb;
					}

					radiance += sc_path_transmittance(p, wi, d) * GROUND_ALBEDO / PI * irradiance;
				}

				float nu_o = dot(wi, view);
				total += radiance * (density_r * RAYLEIGH_BETA * phase_rayleigh(nu_o) + density_m * MIE_BETA * mie_phase(nu_o));
			}
		}

		return vec4(total * (4.0 * PI / float(SC_THETA * SC_PSI)), 1.0);
	}
]]
-- tables: 3 the scattering density
local MULTI_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		vec3 p0;
		vec3 view;
		vec3 sun;
		sc_decode(uv, p0, view, sun);
		float t_near;
		float t_far;
		bool hits_ground;

		if (!get_atmosphere_segment(p0, view, t_near, t_far, hits_ground)) return vec4(0.0);

		float segment = t_far - t_near;
		float nu = dot(view, sun);
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;
		vec3 total = vec3(0.0);

		for (int i = 0; i < SC_STEPS; i++) {
			float s0 = float(i) / float(SC_STEPS);
			float s1 = float(i + 1) / float(SC_STEPS);
			float t0 = t_near + get_march_distance(s0, segment);
			float step_size = get_march_distance(s1, segment) - get_march_distance(s0, segment);
			vec3 q = p0 + view * (t0 + 0.5 * step_size);
			rayleigh_od += rayleigh_density(q) * step_size;
			mie_od += mie_density(q) * step_size;
			ozone_od += ozone_density(q) * step_size;
			float rq = length(q);
			vec3 up = q / rq;
			vec3 density = sc_lookup(SC_T1, rq, dot(up, view), dot(up, sun), nu);
			total += density * exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od)) * step_size;
		}

		return vec4(total, 1.0);
	}
]]
-- tables: 1, 2 single scattering when the order is 1, otherwise 3 the scattering of that order
local IRRADIANCE_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		float mu_s = SC_MU_S_MIN + (1.0 - SC_MU_S_MIN) * floor(uv.x * float(SC_IRRADIANCE_SIZE)) / float(SC_IRRADIANCE_SIZE - 1);
		vec3 sun = vec3(sqrt(max(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0);
		vec3 total = vec3(0.0);

		for (int i = 0; i < SC_THETA; i++) {
			float cos_t = (float(i) + 0.5) / float(SC_THETA);
			float sin_t = sqrt(max(1.0 - cos_t * cos_t, 0.0));

			for (int j = 0; j < SC_PSI; j++) {
				float psi = 2.0 * PI * (float(j) + 0.5) / float(SC_PSI);
				vec3 wi = vec3(sin_t * cos(psi), cos_t, sin_t * sin(psi));
				float nu = dot(wi, sun);
				vec3 radiance;

				if (sc_pc.order == 1) {
					radiance = sc_lookup(SC_T1, PLANET_RADIUS, wi.y, mu_s, nu) * phase_rayleigh(nu) + sc_lookup(SC_T2, PLANET_RADIUS, wi.y, mu_s, nu) * mie_phase(nu);
				} else {
					radiance = sc_lookup(SC_T3, PLANET_RADIUS, wi.y, mu_s, nu);
				}

				total += radiance * cos_t;
			}
		}

		return vec4(total * (2.0 * PI / float(SC_THETA * SC_PSI)), 1.0);
	}
]]
-- tables: 1, 2 single scattering, 3 the light of orders 2 and up. One texel per radius and sun elevation, the mean
-- radiance of the sky above in the first half of the columns, the irradiance in the second
local AMBIENT_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		ivec2 px = clamp(ivec2(floor(uv * vec2(float(2 * SC_S), float(SC_R)))), ivec2(0), ivec2(2 * SC_S - 1, SC_R - 1));
		bool irradiance = px.x >= SC_S;
		int is = px.x - (irradiance ? SC_S : 0);
		float mu_s = SC_MU_S_MIN + (1.0 - SC_MU_S_MIN) * float(is) / float(SC_S - 1);
		float r = PLANET_RADIUS + (ATMOSPHERE_RADIUS - PLANET_RADIUS) * pow(float(px.y) / float(SC_R - 1), SC_RADIUS_POWER);
		vec3 sun = vec3(sqrt(max(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0);
		vec3 total = vec3(0.0);

		for (int i = 0; i < SC_THETA; i++) {
			float cos_t = (float(i) + 0.5) / float(SC_THETA);
			float sin_t = sqrt(max(1.0 - cos_t * cos_t, 0.0));

			for (int j = 0; j < SC_PSI; j++) {
				float psi = 2.0 * PI * (float(j) + 0.5) / float(SC_PSI);
				vec3 wi = vec3(sin_t * cos(psi), cos_t, sin_t * sin(psi));
				float nu = dot(wi, sun);
				vec3 radiance = sc_lookup(SC_T1, r, wi.y, mu_s, nu) * phase_rayleigh(nu) + sc_lookup(SC_T2, r, wi.y, mu_s, nu) * mie_phase(nu) + sc_lookup(SC_T3, r, wi.y, mu_s, nu);
				total += radiance * (irradiance ? cos_t : 1.0);
			}
		}

		return vec4(total * (irradiance ? 2.0 * PI : 1.0) / float(SC_THETA * SC_PSI), 1.0);
	}
]]
local ZERO_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		return vec4(0.0);
	}
]]
local ADD_GLSL = [[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		return vec4(textureLod(TEXTURE(SC_T1), uv, 0.0).rgb + textureLod(TEXTURE(SC_T2), uv, 0.0).rgb, 1.0);
	}
]]

local function create_table(width, height)
	return Texture.New{
		width = width,
		height = height,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

-- build_prelude(extra, prefix) wraps a shader in the atmosphere's constants; the tables' atmosphere is the one the
-- transmittance texture was baked for. Returns three tables for a unit sun: the light of orders 2 to ORDERS that arrives
-- along a ray, the scattering density of those orders (per km, the source the air adds to a ray at a point) and the
-- ambient of the sky above a point (`sc_ambient`)
function scattering.Create(build_prelude, transmittance_texture, aerosol_extinction, aerosol_shape)
	local single_r = create_table(scattering.WIDTH, scattering.HEIGHT)
	local single_m = create_table(scattering.WIDTH, scattering.HEIGHT)
	local density = create_table(scattering.WIDTH, scattering.HEIGHT)
	local delta = create_table(scattering.WIDTH, scattering.HEIGHT)
	local total = create_table(scattering.WIDTH, scattering.HEIGHT)
	local total_next = create_table(scattering.WIDTH, scattering.HEIGHT)
	local source = create_table(scattering.WIDTH, scattering.HEIGHT)
	local source_next = create_table(scattering.WIDTH, scattering.HEIGHT)
	local defines = "#define ATMOSPHERE_LOG_MARCH 1\n#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX sc_pc.tables[0]\n#define ATMOSPHERE_AEROSOL_EXTINCTION sc_pc.extinction\n#define ATMOSPHERE_AEROSOL_SHAPE sc_pc.shape\n"

	local function shade(tex, body, textures, order, species)
		tex:Shade(
			build_prelude(PASSES_GLSL .. body, defines),
			{
				textures = textures,
				custom_declarations = DECLARATIONS,
				fragment_push_constants = {
					size = ffi.sizeof(Constants),
					get_data = function(_, _, pipeline)
						local data = Constants({aerosol_shape, aerosol_extinction, species or 0, order or 0, {}})

						for i, texture in ipairs(textures) do
							data.tables[i - 1] = pipeline:GetTextureIndex(texture)
						end

						return data
					end,
				},
			}
		)
	end

	shade(single_r, SINGLE_GLSL, {transmittance_texture}, 0, 0)
	shade(single_m, SINGLE_GLSL, {transmittance_texture}, 0, 1)
	shade(total, ZERO_GLSL, {transmittance_texture})
	shade(source, ZERO_GLSL, {transmittance_texture})
	-- the ground's indirect irradiance of the light of order k, the density of order k + 2 reflects it
	local irradiance = {}
	irradiance[1] = create_table(IRRADIANCE_SIZE, 1)
	shade(irradiance[1], IRRADIANCE_GLSL, {transmittance_texture, single_r, single_m}, 1)
	local previous = single_r

	for order = 2, scattering.ORDERS do
		shade(density, DENSITY_GLSL, {transmittance_texture, single_r, single_m, previous, irradiance[order - 2] or single_r}, order)
		shade(delta, MULTI_GLSL, {transmittance_texture, density}, order)
		shade(source_next, ADD_GLSL, {transmittance_texture, source, density}, 0)
		source, source_next = source_next, source
		shade(total_next, ADD_GLSL, {transmittance_texture, total, delta}, 0)
		total, total_next = total_next, total
		previous = delta

		if order + 2 <= scattering.ORDERS then
			irradiance[order] = create_table(IRRADIANCE_SIZE, 1)
			shade(irradiance[order], IRRADIANCE_GLSL, {transmittance_texture, single_r, single_m, delta}, order)
		end
	end

	local ambient = create_table(2 * scattering.SUN_COUNT, scattering.RADIUS_COUNT)
	shade(ambient, AMBIENT_GLSL, {transmittance_texture, single_r, single_m, total}, 0)

	for _, tex in pairs(irradiance) do
		tex:Remove()
	end

	for _, tex in ipairs{single_r, single_m, density, delta, total_next, source_next} do
		tex:Remove()
	end

	return total, source, ambient
end

return scattering

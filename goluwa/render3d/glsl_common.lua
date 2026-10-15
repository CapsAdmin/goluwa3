local glsl_common = {}
glsl_common.LUMINANCE_WEIGHTS = "vec3(0.2126, 0.7152, 0.0722)"

-- every block is guarded so a shader that gets one twice through different includes still compiles
function glsl_common.GetLuminanceGLSL()
	return [[
		#ifndef GLSL_COMMON_LUMINANCE
		#define GLSL_COMMON_LUMINANCE
		float luminance(vec3 color) {
			return dot(color, ]] .. glsl_common.LUMINANCE_WEIGHTS .. [[);
		}
		#endif
	]]
end

function glsl_common.GetPQGLSL()
	return [[
		#ifndef GLSL_COMMON_PQ
		#define GLSL_COMMON_PQ
		// SMPTE ST 2084 (PQ) of absolute luminance in nits
		vec3 pq_encode(vec3 nits) {
			vec3 y = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(0.1593017578125));
			return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), vec3(78.84375));
		}

		vec3 pq_decode(vec3 n) {
			vec3 np = pow(clamp(n, 0.0, 1.0), vec3(1.0 / 78.84375));
			vec3 l = max(np - 0.8359375, vec3(0.0)) / (18.8515625 - 18.6875 * np);
			return pow(l, vec3(1.0 / 0.1593017578125)) * 10000.0;
		}
		#endif
	]]
end

function glsl_common.GetOctahedralGLSL()
	return [[
		#ifndef GLSL_COMMON_OCTAHEDRAL
		#define GLSL_COMMON_OCTAHEDRAL
		// a unit vector to the octahedral square [-1, 1]^2 and back
		vec2 oct_encode(vec3 n) {
			n /= abs(n.x) + abs(n.y) + abs(n.z);
			vec2 p = n.xy;

			if (n.z < 0.0) p = (1.0 - abs(p.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);

			return p;
		}

		vec3 oct_decode(vec2 p) {
			vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));

			if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);

			return normalize(n);
		}
		#endif
	]]
end

function glsl_common.GetRaySphereGLSL()
	return [[
		#ifndef GLSL_COMMON_RAY_SPHERE
		#define GLSL_COMMON_RAY_SPHERE
		// the distances along a normalized ray to where it enters and leaves a sphere around the origin, both -1 on a miss
		vec2 ray_sphere_intersect(vec3 ray_origin, vec3 ray_dir, float sphere_radius) {
			float b = dot(ray_origin, ray_dir);
			float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
			float discriminant = b * b - c;

			if (discriminant < 0.0) {
				return vec2(-1.0, -1.0);
			}

			float sqrt_d = sqrt(discriminant);
			return vec2(-b - sqrt_d, -b + sqrt_d);
		}
		#endif
	]]
end

function glsl_common.GetConstantsGLSL()
	return [[
		#ifndef GLSL_COMMON_CONSTANTS
		#define GLSL_COMMON_CONSTANTS
		#define PI 3.14159265359
		#ifndef saturate
		#define saturate(x) clamp(x, 0.0, 1.0)
		#endif
		#endif
	]]
end

function glsl_common.GetPhaseGLSL()
	return glsl_common.GetConstantsGLSL() .. [[
		#ifndef GLSL_COMMON_PHASE
		#define GLSL_COMMON_PHASE
		float phase_rayleigh(float mu) {
			return 3.0 / (16.0 * PI) * (1.0 + mu * mu);
		}

		// mu is the cosine between the direction light travels and the direction it scatters to
		float phase_henyey_greenstein(float mu, float g) {
			float gg = g * g;
			return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
		}
		#endif
	]]
end

function glsl_common.GetBlueNoiseGLSL()
	return [[
		#ifndef GLSL_COMMON_BLUE_NOISE
		#define GLSL_COMMON_BLUE_NOISE
		// the blue noise texture tiled over the screen
		vec4 blue_noise_texel(sampler2D tex, ivec2 pixel) {
			return texelFetch(tex, pixel % textureSize(tex, 0), 0);
		}

		// moves a blue noise value on by steps of the R2 sequence, a different pattern per step for taa to average
		vec2 blue_noise_r2(vec2 xi, float steps) {
			return fract(xi + steps * vec2(0.7548776662, 0.5698402910));
		}
		#endif
	]]
end

function glsl_common.GetRemapGLSL()
	return glsl_common.GetConstantsGLSL() .. [[
		#ifndef GLSL_COMMON_REMAP
		#define GLSL_COMMON_REMAP
		float remap(float v, float l0, float h0, float l1, float h1) {
			return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
		}
		#endif
	]]
end

-- equirect_uv_to_dir and dir_to_equirect_uv are inverses, a direction written through one reads back through the other
function glsl_common.GetEquirectGLSL()
	return [[
		#ifndef GLSL_COMMON_EQUIRECT
		#define GLSL_COMMON_EQUIRECT
		vec3 equirect_uv_to_dir(vec2 uv) {
			float phi = (uv.x - 0.5) * 6.28318530718;
			float theta = (uv.y - 0.5) * 3.14159265359;
			float ct = cos(theta);
			return normalize(vec3(ct * cos(phi), sin(theta), ct * sin(phi)));
		}

		vec2 dir_to_equirect_uv(vec3 dir) {
			float phi = atan(dir.z, dir.x);
			float theta = asin(clamp(dir.y, -1.0, 1.0));
			return vec2(phi * 0.15915494309 + 0.5, theta * 0.31830988618 + 0.5);
		}
		#endif
	]]
end

function glsl_common.GetHashGLSL()
	return [[
		#ifndef GLSL_COMMON_HASH
		#define GLSL_COMMON_HASH
		// pcg3d and pcg4d (Jarzynski and Olano 2020)
		uvec3 pcg3d(uvec3 v) {
			v = v * 1664525u + 1013904223u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v ^= v >> 16u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			return v;
		}

		uvec4 pcg4d(uvec4 v) {
			v = v * 1664525u + 1013904223u;
			v.x += v.y * v.w;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v.w += v.y * v.z;
			v ^= v >> 16u;
			v.x += v.y * v.w;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v.w += v.y * v.z;
			return v;
		}

		// 24 random bits as a float in [0, 1)
		float pcg_unorm(uint h) {
			return float(h >> 8u) * (1.0 / 16777216.0);
		}

		vec3 pcg3d_unorm(uvec3 v) {
			return vec3(pcg3d(v) >> 8u) * (1.0 / 16777216.0);
		}
		#endif
	]]
end

function glsl_common.GetNoiseGLSL()
	return glsl_common.GetHashGLSL() .. [[
		#ifndef GLSL_COMMON_NOISE
		#define GLSL_COMMON_NOISE
		float value_noise3(vec3 p) {
			vec3 i = floor(p);
			vec3 f = fract(p);
			f = f * f * (3.0 - 2.0 * f);
			uvec3 c = uvec3(ivec3(i) + 32768);
			return mix(
				mix(
					mix(pcg_unorm(pcg3d(c).x), pcg_unorm(pcg3d(c + uvec3(1, 0, 0)).x), f.x),
					mix(pcg_unorm(pcg3d(c + uvec3(0, 1, 0)).x), pcg_unorm(pcg3d(c + uvec3(1, 1, 0)).x), f.x),
					f.y
				),
				mix(
					mix(pcg_unorm(pcg3d(c + uvec3(0, 0, 1)).x), pcg_unorm(pcg3d(c + uvec3(1, 0, 1)).x), f.x),
					mix(pcg_unorm(pcg3d(c + uvec3(0, 1, 1)).x), pcg_unorm(pcg3d(c + uvec3(1, 1, 1)).x), f.x),
					f.y
				),
				f.z
			);
		}

		float value_noise2(vec2 p) {
			vec2 i = floor(p);
			vec2 f = fract(p);
			f = f * f * (3.0 - 2.0 * f);
			uvec3 c = uvec3(uvec2(ivec2(i) + 32768), 0u);
			return mix(
				mix(pcg_unorm(pcg3d(c).x), pcg_unorm(pcg3d(c + uvec3(1, 0, 0)).x), f.x),
				mix(pcg_unorm(pcg3d(c + uvec3(0, 1, 0)).x), pcg_unorm(pcg3d(c + uvec3(1, 1, 0)).x), f.x),
				f.y
			);
		}
		#endif
	]]
end

return glsl_common

local glsl_common = {}

-- every block is guarded so a shader that gets one twice through different includes still compiles
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

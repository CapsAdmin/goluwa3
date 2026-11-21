local Texture = import("goluwa/render/texture.lua")
local size = 512
local tex = Texture.New{
	width = size,
	height = size,
	format = "r32g32b32a32_sfloat",
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	},
}
tex:Shade([[
	const float PI          = 3.14159265359;
	const uint  NUM_SAMPLES = 1024u;
	const float EPSILON     = 0.001;
	const uint  AVERAGE_STRATA = 32u;
	const uint  AVERAGE_SAMPLES = 256u;

	float radicalInverse(uint bits) {
		bits = (bits << 16u) | (bits >> 16u);
		bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
		bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
		bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
		bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
		return float(bits) * 2.3283064365386963e-10;
	}

	vec3 importanceSampleGGX(vec2 Xi, float roughness) {
		float a     = roughness * roughness;
		float phi   = 2.0 * PI * Xi.x;
		float cosT  = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
		float sinT  = sqrt(1.0 - cosT * cosT);
		return vec3(cos(phi) * sinT, sin(phi) * sinT, cosT);
	}

	float V_SmithGGXCorrelated(float alpha, float NdotV, float NdotL) {
		float alpha2 = alpha * alpha;
		float lambdaV = NdotL * sqrt((NdotV - alpha2 * NdotV) * NdotV + alpha2);
		float lambdaL = NdotV * sqrt((NdotL - alpha2 * NdotL) * NdotL + alpha2);
		return 0.5 / (lambdaV + lambdaL);
	}

	vec2 integrate_dfg(float NdotV, float roughness, float alpha, uint sample_count) {
		vec3 V = vec3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);
		float DFG1 = 0.0;
		float DFG2 = 0.0;

		for (uint i = 0u; i < sample_count; i++) {
			vec2 Xi = vec2(float(i) / float(sample_count), radicalInverse(i));
			vec3 H  = importanceSampleGGX(Xi, roughness);
			vec3 L  = normalize(2.0 * dot(V, H) * H - V);

			float NdotL = L.z;
			float NdotH = H.z;
			float VdotH = max(dot(V, H), 0.0);

			if (NdotL > 0.0) {
				float visibility = V_SmithGGXCorrelated(alpha, NdotV, NdotL);
				float G_Vis = visibility * NdotL * 4.0 * VdotH / max(NdotH, EPSILON);
				float Fc   = pow(1.0 - VdotH, 5.0);

				DFG1 += (1.0 - Fc) * G_Vis;
				DFG2 +=        Fc  * G_Vis;
			}
		}

		return vec2(DFG1, DFG2) / float(sample_count);
	}

	vec4 shade(vec2 uv, vec3 _cube_dir) {
		float roughness = uv.y;
		float alpha = max(roughness * roughness, EPSILON);
		vec2 dfg = integrate_dfg(max(uv.x, EPSILON), roughness, alpha, NUM_SAMPLES);
		vec2 cosine_average = vec2(0.0);

		for (uint i = 0u; i < AVERAGE_STRATA; i++) {
			cosine_average += integrate_dfg(max(sqrt((float(i) + 0.5) / float(AVERAGE_STRATA)), EPSILON), roughness, alpha, AVERAGE_SAMPLES);
		}

		return vec4(dfg, cosine_average / float(AVERAGE_STRATA));
	}
]])
return tex

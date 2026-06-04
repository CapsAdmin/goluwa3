local Texture = import("goluwa/render/texture.lua")
-- Split-sum BRDF LUT using the same height-correlated Smith GGX visibility as direct lighting
-- X axis: NdotV (0.0 = grazing, 1.0 = straight-on)
-- Y axis: roughness (0.0 = smooth at bottom, 1.0 = rough at top)
-- R channel: scale (DFG1, multiply by F0 at runtime)
-- G channel: bias  (DFG2, add as constant at runtime)
-- Usage: vec2 dfg = texture(brdf_lut, vec2(NdotV, roughness)).rg;
--        specular = F0 * dfg.r + dfg.g;
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
	const float INV_SAMPLES = 1.0 / float(NUM_SAMPLES);
	const float EPSILON     = 0.001;

	// Van der Corput radical inverse (Hammersley base-2 component)
	float radicalInverse(uint bits) {
		bits = (bits << 16u) | (bits >> 16u);
		bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
		bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
		bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
		bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
		return float(bits) * 2.3283064365386963e-10;
	}

	vec2 hammersley(uint i) {
		return vec2(float(i) * INV_SAMPLES, radicalInverse(i));
	}

	// GGX NDF importance sampling: maps Xi -> half-vector H
	vec3 importanceSampleGGX(vec2 Xi, float roughness) {
		float a     = roughness * roughness;
		float phi   = 2.0 * PI * Xi.x;
		// Invert the GGX CDF
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

	vec4 shade(vec2 uv, vec3 _cube_dir) {
		float NdotV    = max(uv.x, EPSILON);
		float roughness = uv.y;
		float alpha = max(roughness * roughness, EPSILON);

		// Tangent-space view vector (N = +Z)
		vec3 V = vec3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);

		float DFG1 = 0.0; // scale: coefficient of F0
		float DFG2 = 0.0; // bias:  constant additive term

		for (uint i = 0u; i < NUM_SAMPLES; i++) {
			vec2 Xi = hammersley(i);
			vec3 H  = importanceSampleGGX(Xi, roughness);
			// Reflect V around H to get incident direction L
			vec3 L  = normalize(2.0 * dot(V, H) * H - V);

			float NdotL = L.z;          // N = (0,0,1) so N·L = L.z
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

		return vec4(DFG1 * INV_SAMPLES, DFG2 * INV_SAMPLES, 0.0, 1.0);
	}
]])
return tex

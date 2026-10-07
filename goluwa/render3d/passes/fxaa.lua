local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
return {
	{
		name = "fxaa",
		is_enabled = function()
			return render3d.IsAntiAliasingEnabled("fxaa")
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "fxaa_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetRawSceneSourceTexture())
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("fxaa_data") .. [[

			float exposure;

			vec3 tap(vec2 uv) {
				return compress(textureLod(TEXTURE(fxaa_data.source_tex), uv, 0.0).rgb, exposure);
			}

			float brightness(vec3 c) {
				return sqrt(max(c.x, 0.0));
			}

			// the console variant of FXAA 3.11, without the search for the edge's end
			void main() {
				ivec2 size = textureSize(TEXTURE(fxaa_data.source_tex), 0);
				vec2 texel = 1.0 / vec2(size);
				vec2 uv = (gl_FragCoord.xy) * texel;
				exposure = fxaa_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec4 center = textureLod(TEXTURE(fxaa_data.source_tex), uv, 0.0);
				float luma_m = brightness(compress(center.rgb, exposure));
				float luma_nw = brightness(tap(uv + vec2(-1.0, -1.0) * texel));
				float luma_ne = brightness(tap(uv + vec2(1.0, -1.0) * texel));
				float luma_sw = brightness(tap(uv + vec2(-1.0, 1.0) * texel));
				float luma_se = brightness(tap(uv + vec2(1.0, 1.0) * texel));
				float luma_min = min(luma_m, min(min(luma_nw, luma_ne), min(luma_sw, luma_se)));
				float luma_max = max(luma_m, max(max(luma_nw, luma_ne), max(luma_sw, luma_se)));

				if (luma_max - luma_min < max(0.03, luma_max * 0.125)) {
					set_color(center);
					return;
				}

				vec2 dir = vec2(-((luma_nw + luma_ne) - (luma_sw + luma_se)), (luma_nw + luma_sw) - (luma_ne + luma_se));
				float reduce = max((luma_nw + luma_ne + luma_sw + luma_se) * 0.03125, 1.0 / 128.0);
				dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -8.0, 8.0) * texel;
				vec3 a = 0.5 * (tap(uv + dir * (1.0 / 3.0 - 0.5)) + tap(uv + dir * (2.0 / 3.0 - 0.5)));
				vec3 b = a * 0.5 + 0.25 * (tap(uv + dir * -0.5) + tap(uv + dir * 0.5));
				float luma_b = brightness(b);
				vec3 result = (luma_b < luma_min || luma_b > luma_max) ? a : b;
				set_color(vec4(decompress(result, exposure), center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}

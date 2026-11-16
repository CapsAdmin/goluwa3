local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local rcas = import("goluwa/render3d/rcas.lua")

local function is_enabled()
	return not render3d.IsJitteredAntiAliasingEnabled() and render3d.IsUpscaling()
end

return {
	{
		name = "easu",
		lazy_framebuffers = true,
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "easu_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"output_size", "vec2"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetPreUpscaleSceneTexture())
						local size = render.GetRenderImageSize()
						block.output_size[0] = size.x
						block.output_size[1] = size.y
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = post_source.GetPreExposureGLSL("easu_data") .. [[
			ivec2 input_size;
			float exposure;

			vec3 load(ivec2 p) {
				vec3 c = max(texelFetch(TEXTURE(easu_data.source_tex), clamp(p, ivec2(0), input_size - 1), 0).rgb * exposure, vec3(0.0));
				return c / (max(c.r, max(c.g, c.b)) + 1.0);
			}

			float luma(vec3 c) {
				return c.b * 0.5 + (c.r * 0.5 + c.g);
			}

			void accumulate_direction(inout vec2 dir, inout float len, float w, float a, float b, float c, float d, float e) {
				float dc = d - c;
				float cb = c - b;
				float length_x = clamp(abs(d - b) / max(max(abs(dc), abs(cb)), 1e-8), 0.0, 1.0);
				dir.x += (d - b) * w;
				len += length_x * length_x * w;
				float ec = e - c;
				float ca = c - a;
				float length_y = clamp(abs(e - a) / max(max(abs(ec), abs(ca)), 1e-8), 0.0, 1.0);
				dir.y += (e - a) * w;
				len += length_y * length_y * w;
			}

			void tap(inout vec3 color, inout float weight, vec2 offset, vec2 dir, vec2 len, float lobe, float clip, vec3 c) {
				vec2 v = vec2(offset.x * dir.x + offset.y * dir.y, offset.x * -dir.y + offset.y * dir.x) * len;
				float d2 = min(dot(v, v), clip);
				float wb = 2.0 / 5.0 * d2 - 1.0;
				float wa = lobe * d2 - 1.0;
				wb *= wb;
				wa *= wa;
				wb = 25.0 / 16.0 * wb - (25.0 / 16.0 - 1.0);
				float w = wb * wa;
				color += c * w;
				weight += w;
			}

			void main() {
				input_size = textureSize(TEXTURE(easu_data.source_tex), 0);
				exposure = easu_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 pp = (vec2(pixel) + 0.5) * vec2(input_size) / easu_data.output_size - 0.5;
				vec2 fp = floor(pp);
				pp -= fp;
				ivec2 o = ivec2(fp);
				vec3 b = load(o + ivec2(0, -1));
				vec3 c = load(o + ivec2(1, -1));
				vec3 e = load(o + ivec2(-1, 0));
				vec3 f = load(o);
				vec3 g = load(o + ivec2(1, 0));
				vec3 h = load(o + ivec2(2, 0));
				vec3 i = load(o + ivec2(-1, 1));
				vec3 j = load(o + ivec2(0, 1));
				vec3 k = load(o + ivec2(1, 1));
				vec3 l = load(o + ivec2(2, 1));
				vec3 n = load(o + ivec2(0, 2));
				vec3 oo = load(o + ivec2(1, 2));
				float bl = luma(b), cl = luma(c), el = luma(e), fl = luma(f), gl = luma(g), hl = luma(h);
				float il = luma(i), jl = luma(j), kl = luma(k), ll = luma(l), nl = luma(n), ol = luma(oo);
				vec2 dir = vec2(0.0);
				float len = 0.0;
				accumulate_direction(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bl, el, fl, gl, jl);
				accumulate_direction(dir, len, pp.x * (1.0 - pp.y), cl, fl, gl, hl, kl);
				accumulate_direction(dir, len, (1.0 - pp.x) * pp.y, fl, il, jl, kl, nl);
				accumulate_direction(dir, len, pp.x * pp.y, gl, jl, kl, ll, ol);
				float dir_r = dot(dir, dir);
				bool zero = dir_r < 1.0 / 32768.0;
				dir_r = zero ? 1.0 : inversesqrt(dir_r);
				dir.x = zero ? 1.0 : dir.x;
				dir *= dir_r;
				len = len * 0.5;
				len *= len;
				float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));
				vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
				float lobe = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
				float clip = 1.0 / lobe;
				vec3 min4 = min(min(f, g), min(j, k));
				vec3 max4 = max(max(f, g), max(j, k));
				vec3 color = vec3(0.0);
				float weight = 0.0;
				tap(color, weight, vec2(0.0, -1.0) - pp, dir, len2, lobe, clip, b);
				tap(color, weight, vec2(1.0, -1.0) - pp, dir, len2, lobe, clip, c);
				tap(color, weight, vec2(-1.0, 1.0) - pp, dir, len2, lobe, clip, i);
				tap(color, weight, vec2(0.0, 1.0) - pp, dir, len2, lobe, clip, j);
				tap(color, weight, vec2(0.0, 0.0) - pp, dir, len2, lobe, clip, f);
				tap(color, weight, vec2(-1.0, 0.0) - pp, dir, len2, lobe, clip, e);
				tap(color, weight, vec2(1.0, 1.0) - pp, dir, len2, lobe, clip, k);
				tap(color, weight, vec2(2.0, 1.0) - pp, dir, len2, lobe, clip, l);
				tap(color, weight, vec2(2.0, 0.0) - pp, dir, len2, lobe, clip, h);
				tap(color, weight, vec2(1.0, 0.0) - pp, dir, len2, lobe, clip, g);
				tap(color, weight, vec2(1.0, 2.0) - pp, dir, len2, lobe, clip, oo);
				tap(color, weight, vec2(0.0, 2.0) - pp, dir, len2, lobe, clip, n);
				vec3 result = min(max4, max(min4, color / weight));
				float alpha = texelFetch(TEXTURE(easu_data.source_tex), clamp(o + ivec2(round(pp)), ivec2(0), input_size - 1), 0).a;
				set_color(vec4(result / max(1.0 - max(result.r, max(result.g, result.b)), 1e-6) / exposure, alpha));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	rcas.BuildPass{
		name = "easu_sharpen",
		is_enabled = is_enabled,
		get_source_texture = function()
			return render3d.pipelines.easu:GetFramebuffer():GetAttachment(1)
		end,
	},
}

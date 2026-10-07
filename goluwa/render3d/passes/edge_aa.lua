local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local MAX_SEARCH = 32
pvars.StartGroup("edge_aa", {store = false})
local threshold = pvars.Setup2{
	key = "r_edge_aa_threshold",
	default = 0.08,
	min = 0.01,
	max = 0.5,
	help = "how much brighter, as perceived, a neighbouring pixel has to be to count as an edge. lower smooths fainter edges and costs detail",
}
pvars.EndGroup()

local function is_enabled()
	return render3d.IsAntiAliasingEnabled("edge_aa") or
		render3d.IsAntiAliasingEnabled("edge_aa_t")
end

local function get_edges_texture(self)
	return self:GetTextureIndex(render3d.pipelines.edge_aa_edges:GetFramebuffer():GetAttachment(1))
end

return {
	{
		name = "edge_aa_edges",
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "edge_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"threshold", "float"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetRawSceneSourceTexture())
						block.threshold = threshold:Get()
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("edge_data") .. [[

			ivec2 size;
			float exposure;

			// perceived brightness, the exposed and compressed luma with a gamma on it
			float get_brightness(ivec2 p) {
				p = clamp(p, ivec2(0), size - 1);
				return sqrt(max(compress(texelFetch(TEXTURE(edge_data.source_tex), p, 0).rgb, exposure).x, 0.0));
			}

			void main() {
				size = textureSize(TEXTURE(edge_data.source_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				exposure = edge_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;

				float c = get_brightness(pixel);
				float l = get_brightness(pixel + ivec2(-1, 0));
				float t = get_brightness(pixel + ivec2(0, -1));
				float r = get_brightness(pixel + ivec2(1, 0));
				float b = get_brightness(pixel + ivec2(0, 1));
				vec2 delta = abs(vec2(c - l, c - t));
				vec2 edges = step(vec2(edge_data.threshold), delta);

				if (dot(edges, vec2(1.0)) == 0.0) {
					set_color(vec4(0.0));
					return;
				}

				// an edge has to stand out from the strongest one around it, or a
				// texture's fine detail turns into a net of edges
				float ll = get_brightness(pixel + ivec2(-2, 0));
				float tt = get_brightness(pixel + ivec2(0, -2));
				float max_delta = max(max(delta.x, delta.y), max(max(abs(c - r), abs(c - b)), max(abs(l - ll), abs(t - tt))));
				edges *= step(max_delta, 2.0 * delta);
				set_color(vec4(edges, 0.0, 0.0));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "edge_aa_weights",
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "weights_data",
					binding_index = 2,
					block = {
						{"edges_tex", "int"},
					},
					write = function(self, block)
						block.edges_tex = get_edges_texture(self)
						return block
					end,
				},
			},
			shader = [[
			const int MAX_SEARCH = ]] .. MAX_SEARCH .. [[;
			ivec2 size;

			vec2 get_edges(ivec2 q) {
				if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) return vec2(0.0);

				return texelFetch(TEXTURE(weights_data.edges_tex), q, 0).rg;
			}

			// the part of a linear segment's height above zero and below it,
			// averaged over a width of 1
			vec2 split_area(float h0, float h1) {
				if (h0 >= 0.0 && h1 >= 0.0) return vec2(0.5 * (h0 + h1), 0.0);

				if (h0 <= 0.0 && h1 <= 0.0) return vec2(0.0, -0.5 * (h0 + h1));

				float hp = max(h0, h1);
				float hn = -min(h0, h1);
				return vec2(hp * hp, hn * hn) * 0.5 / (hp + hn);
			}

			// the line the pixels' colours stand for, as the height it is displaced
			// toward the negative side at x along a run of len pixels. each end of
			// the run either stops flat (0) or turns toward the negative (-1) or
			// positive (1) side, a flat end sits on the edge and a turn is half a
			// pixel off it
			float line_height(float x, float len, int left, int right) {
				float start = -0.5 * float(left);
				float finish = -0.5 * float(right);

				if (left == 0) return finish * x / len;

				if (right == 0) return start * (1.0 - x / len);

				if (left == right) return start * abs(1.0 - 2.0 * x / len);

				return start * (1.0 - 2.0 * x / len);
			}

			// x/y: how much this pixel takes of its neighbour on the negative side,
			// and how much that neighbour takes of this one
			vec2 line_weights(ivec2 p, bool horizontal) {
				ivec2 along = horizontal ? ivec2(1, 0) : ivec2(0, 1);
				ivec2 negative = horizontal ? ivec2(0, -1) : ivec2(-1, 0);
				int line_channel = horizontal ? 1 : 0;
				int cross_channel = horizontal ? 0 : 1;
				int behind = MAX_SEARCH;
				int ahead = MAX_SEARCH;
				int left = 0;
				int right = 0;

				for (int k = 0; k < MAX_SEARCH; k++) {
					ivec2 q = p - along * k;
					float turns_negative = get_edges(q + negative)[cross_channel];
					float turns_positive = get_edges(q)[cross_channel];

					if (turns_negative > 0.0 || turns_positive > 0.0) {
						behind = k;
						left = turns_negative > 0.0 ? (turns_positive > 0.0 ? 0 : -1) : 1;
						break;
					}

					if (get_edges(q - along)[line_channel] == 0.0) {
						behind = k;
						break;
					}
				}

				for (int k = 0; k < MAX_SEARCH; k++) {
					ivec2 q = p + along * (k + 1);
					float turns_negative = get_edges(q + negative)[cross_channel];
					float turns_positive = get_edges(q)[cross_channel];

					if (turns_negative > 0.0 || turns_positive > 0.0) {
						ahead = k;
						right = turns_negative > 0.0 ? (turns_positive > 0.0 ? 0 : -1) : 1;
						break;
					}

					if (get_edges(q)[line_channel] == 0.0) {
						ahead = k;
						break;
					}
				}

				if (left == 0 && right == 0) return vec2(0.0);

				float len = float(behind + ahead + 1);
				float x0 = float(behind);
				float x1 = x0 + 1.0;
				vec2 area;

				if (left == right && x0 < 0.5 * len && x1 > 0.5 * len) {
					float middle = 0.5 * len;
					area = (middle - x0) * split_area(line_height(x0, len, left, right), 0.0) + (x1 - middle) * split_area(0.0, line_height(x1, len, left, right));
				} else {
					area = split_area(line_height(x0, len, left, right), line_height(x1, len, left, right));
				}

				// above zero is the line displaced toward the negative side, which
				// is the negative side's pixels taking from this one
				return vec2(area.y, area.x);
			}

			void main() {
				size = textureSize(TEXTURE(weights_data.edges_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 edges = get_edges(pixel);
				vec4 weights = vec4(0.0);

				if (edges.y > 0.0) weights.xy = line_weights(pixel, true);

				if (edges.x > 0.0) weights.zw = line_weights(pixel, false);

				set_color(weights);
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "edge_aa",
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "blend_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"weights_tex", "int"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetRawSceneSourceTexture())
						block.weights_tex = self:GetTextureIndex(render3d.pipelines.edge_aa_weights:GetFramebuffer():GetAttachment(1))
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("blend_data") .. [[

			ivec2 size;

			vec4 get_weights(ivec2 q) {
				if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) return vec4(0.0);

				return texelFetch(TEXTURE(blend_data.weights_tex), q, 0);
			}

			void main() {
				size = textureSize(TEXTURE(blend_data.source_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec4 center = texelFetch(TEXTURE(blend_data.source_tex), pixel, 0);
				vec4 own = get_weights(pixel);
				float up = own.x;
				float left = own.z;
				float down = get_weights(pixel + ivec2(0, 1)).y;
				float right = get_weights(pixel + ivec2(1, 0)).w;

				// only the stronger direction, or a corner is blurred twice
				if (up + down >= left + right) {
					left = 0.0;
					right = 0.0;
				} else {
					up = 0.0;
					down = 0.0;
				}

				float total = up + down + left + right;

				if (total < 1e-4) {
					set_color(center);
					return;
				}

				float exposure = blend_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec3 mixed = compress(center.rgb, exposure) * (1.0 - min(total, 1.0));
				float scale = 1.0 / max(total, 1.0);
				mixed += compress(texelFetch(TEXTURE(blend_data.source_tex), clamp(pixel + ivec2(0, -1), ivec2(0), size - 1), 0).rgb, exposure) * up * scale;
				mixed += compress(texelFetch(TEXTURE(blend_data.source_tex), clamp(pixel + ivec2(0, 1), ivec2(0), size - 1), 0).rgb, exposure) * down * scale;
				mixed += compress(texelFetch(TEXTURE(blend_data.source_tex), clamp(pixel + ivec2(-1, 0), ivec2(0), size - 1), 0).rgb, exposure) * left * scale;
				mixed += compress(texelFetch(TEXTURE(blend_data.source_tex), clamp(pixel + ivec2(1, 0), ivec2(0), size - 1), 0).rgb, exposure) * right * scale;
				set_color(vec4(decompress(mixed, exposure), center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}

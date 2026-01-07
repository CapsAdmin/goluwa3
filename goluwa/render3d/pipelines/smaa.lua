local Vec2 = require("structs.vec2")
local system = require("system")
local SMAA = require("render3d.smaa")
local render3d = require("render3d.render3d")
return {
	{
		name = "smaa_edge",
		color_format = {{"r8g8_unorm", {"color", "rg"}}},
		fragment = {
			push_constants = {
				{
					name = "smaa",
					block = {
						{
							"tex",
							"int",
							function(self, block, key)
								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
					},
				},
			},
			shader = [[
			float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
			void main() {
				vec2 uv = in_uv;
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.tex), 0));
				float l = lum(texture(TEXTURE(pc.smaa.tex), uv).rgb);
				float l_top = lum(texture(TEXTURE(pc.smaa.tex), uv + vec2(0, -texel.y)).rgb);
				float l_left = lum(texture(TEXTURE(pc.smaa.tex), uv + vec2(-texel.x, 0)).rgb);
				vec2 delta = abs(vec2(l) - vec2(l_left, l_top));
				vec2 edges = step(0.1, delta);
				set_color(edges);
			}
		]],
		},
	},
	{
		name = "smaa_weight",
		color_format = {{"r8g8b8a8_unorm", {"color", "rgba"}}},
		fragment = {
			push_constants = {
				{
					name = "smaa",
					block = {
						{
							"edges_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_edge:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"area_tex",
							"int",
							function()
								local tex = SMAA.GenerateAreaTexture()
								return function(self, block, key)
									block[key] = self:GetTextureIndex(tex)
								end
							end,
						},
						{
							"search_tex",
							"int",
							function()
								local tex = SMAA.GenerateSearchTexture()
								return function(self, block, key)
									block[key] = self:GetTextureIndex(tex)
								end
							end,
						},
					},
				},
			},
			shader = [[
			// Simplified SMAA weight calculation
			void main() {
				vec2 edges = texture(TEXTURE(pc.smaa.edges_tex), in_uv).rg;
				if (edges.x > 0.0 || edges.y > 0.0) {
					// Placeholder for complex morphological weight calculation
					// Real SMAA would use search and area textures here
					set_color(vec4(edges, 0.0, 1.0));
				} else {
					set_color(vec4(0.0, 0.0, 0.0, 0.0));
				}
			}
		]],
		},
	},
	{
		name = "smaa_blend",
		color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			push_constants = {
				{
					name = "smaa",
					block = {
						{
							"color_tex",
							"int",
							function(self, block, key)
								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"weight_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_weight:GetFramebuffer():GetAttachment(1))
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				vec2 uv = in_uv;
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.color_tex), 0));
				vec4 weights = texture(TEXTURE(pc.smaa.weight_tex), uv);
				
				if (weights.r > 0.0 || weights.g > 0.0) {
					// Simple mix for now
					vec4 c = texture(TEXTURE(pc.smaa.color_tex), uv);
					vec4 c_left = texture(TEXTURE(pc.smaa.color_tex), uv + vec2(-texel.x, 0));
					vec4 c_top = texture(TEXTURE(pc.smaa.color_tex), uv + vec2(0, -texel.y));
					vec4 res = c;
					if (weights.r > 0.0) res = mix(c, c_left, 0.5);
					if (weights.g > 0.0) res = mix(res, c_top, 0.5);
					set_color(res);
				} else {
					set_color(texture(TEXTURE(pc.smaa.color_tex), uv));
				}
			}
		]],
		},
	},
	{
		name = "smaa_resolve",
		color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		post_draw = function()
			local cam = render3d.GetCamera()
			local s = 0.1
			local offsets = {Vec2(s, -s), Vec2(-s, s)}
			cam:SetJitter(offsets[(system.GetFrameNumber() % 2) + 1])
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "smaa_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						{
							"current_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_blend:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"history_tex",
							"int",
							function(self, block, key)
								local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
							end,
						},
						{
							"depth_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer().depth_texture)
							end,
						},
						{
							"prev_view",
							"mat4",
							function(self, block, key)
								render3d.prev_view_matrix:CopyToFloatPointer(block[key])
							end,
						},
						{
							"prev_projection",
							"mat4",
							function(self, block, key)
								render3d.prev_projection_matrix:CopyToFloatPointer(block[key])
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				vec2 uv = in_uv;
				float depth = texture(TEXTURE(smaa_data.depth_tex), uv).r;
				
				// Reprojection
				vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = smaa_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (smaa_data.inv_view * view_pos).xyz;
				
				vec4 prev_view_pos = smaa_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = smaa_data.prev_projection * prev_view_pos;
				prev_clip /= prev_clip.w;
				vec2 prev_uv = prev_clip.xy * 0.5 + 0.5;
				
				vec4 current = texture(TEXTURE(smaa_data.current_tex), uv);
				
				if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
					set_color(current);
					return;
				}
				
				vec4 history = texture(TEXTURE(smaa_data.history_tex), prev_uv);
				
				// Neighborhood clamping
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(smaa_data.current_tex), 0));
				
				// Edge artifact fix: check if we are too close to the edge
				if (prev_uv.x < texel.x || prev_uv.x > 1.0 - texel.x || prev_uv.y < texel.y || prev_uv.y > 1.0 - texel.y) {
					set_color(current);
					return;
				}

				vec4 m1 = vec4(0.0);
				vec4 m2 = vec4(0.0);
				for(int x = -1; x <= 1; x++) {
					for(int y = -1; y <= 1; y++) {
						vec4 c = texture(TEXTURE(smaa_data.current_tex), uv + vec2(x,y)*texel);
						m1 += c;
						m2 += c*c;
					}
				}
				vec4 mu = m1 / 9.0;
				vec4 sigma = sqrt(max(vec4(0.0), (m2 / 9.0) - mu*mu));
				vec4 min_c = mu - 2.0 * sigma; // Increased sigma range for stability
				vec4 max_c = mu + 2.0 * sigma;
				history = clamp(history, min_c, max_c);
				
				set_color(mix(current, history, 0.85)); // Slightly reduced history weight for less ghosting/jitter
			}
		]],
		},
	},
}

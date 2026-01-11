local render = require("render.render")
local event = require("event")
local system = require("system")
local render3d = require("render3d.render3d")
return {
	{
		name = "blit",
		fragment = {
			push_constants = {
				{
					name = "blit",
					block = {
						{
							"tex",
							"int",
							function(self, block, key)
								if render3d.pipelines.smaa_resolve and render3d.pipelines.smaa_resolve.framebuffers then
									local current_idx = system.GetFrameNumber() % 2 + 1
									block[key] = self:GetTextureIndex(render3d.pipelines.smaa_resolve:GetFramebuffer(current_idx):GetAttachment(1))
									return
								end

								if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"requires_manual_gamma",
							"int",
							function(self, block, key)
								block[key] = render.target:RequiresManualGamma() and 1 or 0
							end,
						},
						{
							"is_hdr",
							"int",
							function(self, block, key)
								block[key] = render.target:IsHDR() and 1 or 0
							end,
						},
					},
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				vec3 ACESFilm(vec3 x) {
					vec3 res = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
					return clamp(res, 0.0, 1.0);
				}

				vec3 ACESFilmHDR(vec3 x) {
					return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
				}


				vec3 jodieReinhardTonemap(vec3 c){
					float l = dot(c, vec3(0.7152, 0.7152, 0.7152));
					vec3 tc = c / (c + 1.0);
					vec3 c2 = mix(c / (l + 1.0), tc, tc);
					c2 = pow(c2*1.5, vec3(1.5));
					return c2;
				}

				vec3 LinearToSRGB(vec3 col) {
					vec3 low = col * 12.92;
					vec3 high = 1.055 * pow(col, vec3(1.0/2.4)) - 0.055;
					return mix(low, high, step(0.0031308, col));
				}

				

				vec3 tonemap(vec3 x) {
					const float a = 2.51;
					const float b = 0.03;
					const float c = 2.43;
					const float d = 0.59;
					const float e = 0.14;
					vec3 col = (x * (a * x + b)) / (x * (c * x + d) + e);

					col = pow(col*0.75, vec3(1.5))*1.25;

					return col;
				}

				void main() {
					if (pc.blit.tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}
					
					vec3 col = texture(TEXTURE(pc.blit.tex), in_uv).rgb;

					if (pc.blit.is_hdr == 1) {
						col = tonemap(pow(col*1.5, vec3(0.8)))*1.2;

					} else {
						col = ACESFilm(col);
					}
					
					if (pc.blit.requires_manual_gamma == 1) {
						col = LinearToSRGB(col);
					}
					
					frag_color = vec4(col, 1.0);
				}
		]],
		},
		rasterizer = {
			cull_mode = "none",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
		},
	},
}

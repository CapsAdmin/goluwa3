local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")

local function get_scene_source_texture(self, block, key)
	post_source.WriteSceneSourceTexture(self, block, key)
end

local function get_blit_source_texture(self, block, key)
	get_scene_source_texture(self, block, key)
end

local function get_is_debug_view(_, block, key)
	block[key] = 0
end

local r = {
	{
		name = "blit",
		RasterizationSamples = function()
			return render.target.samples
		end,
		fragment = {
			push_constants = {
				{
					name = "blit",
					block = {
						{"source_tex", "int"},
						{"is_debug_view", "int"},
						{"bloom_tex", "int"},
						{"luma_tex", "int"},
						{"requires_manual_gamma", "int"},
						{"is_hdr", "int"},
					},
					write = function(self, block)
						get_blit_source_texture(self, block, "source_tex")
						get_is_debug_view(self, block, "is_debug_view")

						if not render3d.pipelines.bloom_up0 then
							block.bloom_tex = -1
						else
							block.bloom_tex = self:GetTextureIndex(render3d.pipelines.bloom_up0:GetFramebuffer():GetAttachment(1))
						end

						if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
							block.luma_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							block.luma_tex = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(current_idx):GetAttachment(1))
						end

						block.requires_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
						block.is_hdr = render.target:IsHDR() and 1 or 0
						return block
					end,
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				vec3 ACESFilm(vec3 x) {
					vec3 res = x;

					res = res/10;
					res = pow(res, vec3(0.5));
					res *= 2.2;
					
					res *= vec3(1.09,  1.025,  1);

					res.r = pow(res.r, 0.97);
					res.b = pow(res.b, 1.05);
					res = pow(res, vec3(1.1));

					res *= mat3(
						1.0,   0.0,   0.0,    
						0.0,   1.0,   0.0,    
						0.0,   0.0, 1.0     
					);

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

				vec3 tonemap(vec3 x, float exposure) {
					x *= exposure;
					
					const float a = 2.51;
					const float b = 0.03;
					const float c = 2.43;
					const float d = 0.59;
					const float e = 0.14;
					vec3 col = (x * (a * x + b)) / (x * (c * x + d) + e);

					col = pow(col*0.75, vec3(1.5))*1.25;

					return col;
				}


				vec3 tonemap_lottes(vec3 rgb) {
					const vec3 a = vec3(1.5); // Contrast
					const vec3 d = vec3(0.91); // Shoulder contrast
					const vec3 hdr_max = vec3(8.0); // White point
					const vec3 mid_in = vec3(0.26); // Fixed midpoint x
					const vec3 mid_out = vec3(0.32); // Fixed midput y

					const vec3 b = (-pow(mid_in, a) + pow(hdr_max, a) * mid_out) /
						((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
					const vec3 c = (pow(hdr_max, a * d) * pow(mid_in, a) -
									pow(hdr_max, a) * pow(mid_in, a * d) * mid_out) /
						((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);

					return pow(rgb, a) / (pow(rgb, a * d) * b + c);
				}

				void main() {
					if (blit.source_tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}
					
					vec3 col = texture(TEXTURE(blit.source_tex), in_uv).rgb;
					if (blit.is_debug_view == 1) {
						col = clamp(col, vec3(0.0), vec3(1.0));

						if (blit.requires_manual_gamma == 1) {
							col = LinearToSRGB(col);
						}

						frag_color = vec4(col, 1.0);
						return;
					}

					vec3 bloom = vec3(0.0);
					if (blit.bloom_tex != -1) {
						bloom = texture(TEXTURE(blit.bloom_tex), in_uv).rgb;
					}
					
					// Calculate adaptive exposure
					float exposure = 1.0;
					if (blit.luma_tex != -1) {
						// Average luminance across entire screen
						float avg_log_luma = 0.0;
						vec2 luma_size = vec2(textureSize(TEXTURE(blit.luma_tex), 0));
						int samples = 0;
						
						// Sample at multiple points to get average
						for (float y = 0.125; y < 1.0; y += 0.25) {
							for (float x = 0.125; x < 1.0; x += 0.25) {
								avg_log_luma += texture(TEXTURE(blit.luma_tex), vec2(x, y)).r;
								samples++;
							}
						}
						avg_log_luma /= float(samples);
						
						// Convert back from log space and calculate exposure
						float avg_luma = exp2(avg_log_luma);
						float target_luma = 0.5; // Middle gray target
						exposure = target_luma / max(avg_luma, 0.001);
						
						// Clamp exposure to reasonable range
						exposure = clamp(exposure, 0.1, 4.0);
					}

					float bloom_luma = dot(bloom, vec3(0.2126, 0.7152, 0.0722));
					float bloom_strength = 0.03;
					float bloom_exposure_scale = clamp(1.0 / sqrt(max(exposure, 0.35)), 0.7, 1.25);
					float bloom_soft_clip = 1.0 / (1.0 + bloom_luma * 0.35);
					col += bloom * bloom_strength * bloom_exposure_scale * bloom_soft_clip;

					if (blit.is_hdr == 1) {
						col = tonemap(pow(col*1.5, vec3(0.8)), exposure)*1.2;
					} else {
						col = tonemap_lottes(col * exposure);
					}
					
					if (blit.requires_manual_gamma == 1) {
						col = LinearToSRGB(col);
					}

					vec2 vignette_uv = in_uv * 2.0 - 1.0;
					float aspect = float(textureSize(TEXTURE(blit.source_tex), 0).x) / float(textureSize(TEXTURE(blit.source_tex), 0).y);
					vignette_uv.x *= aspect;
					float vignette = smoothstep(4.0, 0.6, length(vignette_uv));
					col *= vignette;
					
					frag_color = vec4(col, 1.0);
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}

if HOTRELOAD then
	import("goluwa/timer.lua").Delay(0, function()
		render3d.Initialize()
	end)
end

return r

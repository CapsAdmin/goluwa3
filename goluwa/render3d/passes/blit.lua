local render = require("render.render")
local event = require("event")
local system = require("system")
local render3d = require("render3d.render3d")

local function get_source_texture(self, block, key)
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
end

local r = {
	-- Pass 1: Extract bright areas for bloom
	{
		name = "bloom_extract",
		color_format = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = 0.5,
		fragment = {
			push_constants = {
				{
					name = "extract",
					block = {
						{"source_tex", "int", get_source_texture},
					},
				},
			},
			shader = [[
				void main() {
					if (pc.extract.source_tex == -1) {
						set_bloom(vec4(0.0));
						return;
					}
					
					vec3 col = texture(TEXTURE(pc.extract.source_tex), in_uv).rgb;
					
					// Extract bright areas (threshold + knee)
					float threshold = 1.0;
					float knee = 0.5;
					float brightness = max(col.r, max(col.g, col.b));
					float soft = brightness - threshold + knee;
					soft = clamp(soft, 0.0, 2.0 * knee);
					soft = soft * soft / (4.0 * knee + 0.00001);
					float contribution = max(soft, brightness - threshold);
					contribution /= max(brightness, 0.00001);
					
					set_bloom(vec4(col * contribution, 1.0));
				}
			]],
		},
		rasterizer = {cull_mode = "none"},
		depth_stencil = {depth_test = false, depth_write = false},
	},
}
-- Generate downsample passes
local downsample_shader = [[
	void main() {
		if (pc.down.source_tex == -1) {
			set_bloom(vec4(0.0));
			return;
		}
		
		vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(pc.down.source_tex), 0));
		vec3 sum = vec3(0.0);
		
		// 13-tap downsampling filter
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(-2, -2) * texel_size).rgb;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(0, -2) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(2, -2) * texel_size).rgb;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(-2, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv).rgb * 4.0;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(2, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(-2, 2) * texel_size).rgb;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(0, 2) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.down.source_tex), in_uv + vec2(2, 2) * texel_size).rgb;
		
		set_bloom(vec4(sum / 16.0, 1.0));
	}
]]

for i = 1, 3 do
	local prev_name = i == 1 and "bloom_extract" or ("bloom_down" .. (i - 1))
	table.insert(
		r,
		{
			name = "bloom_down" .. i,
			color_format = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
			scale = 0.5 / (2 ^ i),
			fragment = {
				push_constants = {
					{
						name = "down",
						block = {
							{
								"source_tex",
								"int",
								function(self, block, key)
									if not render3d.pipelines[prev_name] then
										block[key] = -1
										return
									end

									block[key] = self:GetTextureIndex(render3d.pipelines[prev_name]:GetFramebuffer():GetAttachment(1))
								end,
							},
						},
					},
				},
				shader = downsample_shader,
			},
			rasterizer = {cull_mode = "none"},
			depth_stencil = {depth_test = false, depth_write = false},
		}
	)
end

-- Generate upsample passes
local upsample_shader = [[
	void main() {
		if (pc.up.source_tex == -1) {
			set_bloom(vec4(0.0));
			return;
		}
		
		vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(pc.up.source_tex), 0));
		vec3 sum = vec3(0.0);
		
		// 9-tap tent filter
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(-1, -1) * texel_size).rgb;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(0, -1) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(1, -1) * texel_size).rgb;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(-1, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv).rgb * 4.0;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(1, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(-1, 1) * texel_size).rgb;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(0, 1) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(pc.up.source_tex), in_uv + vec2(1, 1) * texel_size).rgb;
		
		vec3 result = sum / 16.0;
		
		// Merge with previous level
		if (pc.up.merge_tex != -1) {
			result += texture(TEXTURE(pc.up.merge_tex), in_uv).rgb;
		}
		
		set_bloom(vec4(result, 1.0));
	}
]]

for i = 3, 1, -1 do
	local source_name = i == 3 and "bloom_down3" or ("bloom_up" .. (i + 1))
	local merge_name = i == 1 and "bloom_extract" or ("bloom_down" .. i)
	local idx = i == 1 and 0 or i
	table.insert(
		r,
		{
			name = "bloom_up" .. idx,
			color_format = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
			scale = 0.5 / (2 ^ i),
			fragment = {
				push_constants = {
					{
						name = "up",
						block = {
							{
								"source_tex",
								"int",
								function(self, block, key)
									if not render3d.pipelines[source_name] then
										block[key] = -1
										return
									end

									block[key] = self:GetTextureIndex(render3d.pipelines[source_name]:GetFramebuffer():GetAttachment(1))
								end,
							},
							{
								"merge_tex",
								"int",
								function(self, block, key)
									if not render3d.pipelines[merge_name] then
										block[key] = -1
										return
									end

									block[key] = self:GetTextureIndex(render3d.pipelines[merge_name]:GetFramebuffer():GetAttachment(1))
								end,
							},
						},
					},
				},
				shader = upsample_shader,
			},
			rasterizer = {cull_mode = "none"},
			depth_stencil = {depth_test = false, depth_write = false},
		}
	)
end

-- Luminance pass for adaptive tonemapping
table.insert(
	r,
	{
		name = "luminance",
		color_format = {{"r16_sfloat", {"luma", "r"}}},
		scale = 0.0625, -- 1/16th resolution for fast averaging
		framebuffer_count = 2,
		fragment = {
			push_constants = {
				{
					name = "lum",
					block = {
						{"source_tex", "int", get_source_texture},
						{
							"prev_luma_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
									block[key] = -1
									return
								end

								local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(prev_idx):GetAttachment(1))
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				float luma;
				if (pc.lum.source_tex == -1) {
					luma = 0.5;
					set_luma(luma);
					return;
				}
				
				vec3 col = texture(TEXTURE(pc.lum.source_tex), in_uv).rgb;
				
				// Calculate luminance
				float current_luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
				current_luma = log2(max(current_luma, 0.0001));
				
				// Temporal smoothing
				if (pc.lum.prev_luma_tex != -1) {
					float prev_luma = texture(TEXTURE(pc.lum.prev_luma_tex), in_uv).r;
					// Smooth adaptation speed
					float adapt_speed = 0.05;
					current_luma = mix(prev_luma, current_luma, adapt_speed);
				}
				
				set_luma(current_luma);
			}
		]],
		},
		rasterizer = {cull_mode = "none"},
		depth_stencil = {depth_test = false, depth_write = false},
	}
)
-- Final blit pass
table.insert(
	r,
	{
		name = "blit",
		samples = function()
			return render.target.samples
		end,
		fragment = {
			push_constants = {
				{
					name = "blit",
					block = {
						{"source_tex", "int", get_source_texture},
						{
							"bloom_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.bloom_up0 then
									block[key] = -1
									return
								end

								block[key] = self:GetTextureIndex(render3d.pipelines.bloom_up0:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"luma_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.luminance:GetFramebuffer(current_idx):GetAttachment(1))
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

				void main() {
					if (pc.blit.source_tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}
					
					vec3 col = texture(TEXTURE(pc.blit.source_tex), in_uv).rgb;
					
					// Add bloom
					float bloom_strength = 0.04;
					if (pc.blit.bloom_tex != -1) {
						vec3 bloom = texture(TEXTURE(pc.blit.bloom_tex), in_uv).rgb;
						col += bloom * bloom_strength;
					}
					
					// Calculate adaptive exposure
					float exposure = 1.0;
					if (pc.blit.luma_tex != -1) {
						// Average luminance across entire screen
						float avg_log_luma = 0.0;
						vec2 luma_size = vec2(textureSize(TEXTURE(pc.blit.luma_tex), 0));
						int samples = 0;
						
						// Sample at multiple points to get average
						for (float y = 0.125; y < 1.0; y += 0.25) {
							for (float x = 0.125; x < 1.0; x += 0.25) {
								avg_log_luma += texture(TEXTURE(pc.blit.luma_tex), vec2(x, y)).r;
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

					if (pc.blit.is_hdr == 1) {
						col = tonemap(pow(col*1.5, vec3(0.8)), exposure)*1.2;
					} else {
						col = ACESFilm(col * exposure);
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
	}
)

if HOTRELOAD then
	require("timer").Delay(0, function()
		render3d.Initialize()
	end)
end

return r

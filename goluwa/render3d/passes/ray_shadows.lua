local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 3
local BINDING_OCCLUSION_MAP = 4
local BINDING_LIGHT_GRID = 5
local BINDING_DDGI = 12
local SCENE_BINDINGS = {scene = 6, hit = 30, materials = 8}
local FILTER_ITERATIONS = 3
pvars.StartGroup("Lighting", "Ray traced shadows", {store = false, prefix = "r_ray_shadow_"})
local denoise = pvars.Setup2{
	key = "r_ray_shadow_denoise",
	default = true,
	help = "trace the ray shadows in a pass of their own, one ray per light and pixel, and average them over frames and neighbouring pixels of the same surface before the lighting reads them. off, the lighting traces its own rays and the noise is left to the anti-aliasing",
	callback = function(value, initial)
		if initial then return end

		render3d.ReloadPasses(surface_lighting.PASS_PATHS)
	end,
}
local max_history = pvars.Setup2{
	key = "r_ray_shadow_history",
	default = 12,
	integer = true,
	help = "most frames the ray traced shadows average. more is smoother penumbrae and longer trails behind moving shadows",
}
local filter_deviations = pvars.Setup2{
	key = "r_ray_shadow_filter_deviations",
	default = 3,
	help = "how many standard deviations of a pixel's accumulated visibility a neighbour may differ by and still be averaged in. small keeps more of the noise, large blurs sharp shadow edges",
}
pvars.EndGroup()

if
	not (
		optical_rays.RAY_QUERY and
		surface_lighting.UsesRayShadows() and
		denoise:Get()
	)
then
	return {}
end

local function filter_name(i)
	return i == FILTER_ITERATIONS - 1 and "ray_shadow_filter" or "ray_shadow_filter_" .. i
end

local function attachment(name, framebuffer, index)
	return render3d.pipelines[name]:GetFramebuffer(framebuffer):GetAttachment(index)
end

local function filter_uniform(iteration)
	return {
		name = "shadow_data",
		binding_index = BINDING_UNIFORM,
		block = {
			gbuffer_layout.block,
			render3d.camera_block,
			{"source_tex", "int"},
			{"moments_tex", "int"},
			{"step", "int"},
			{"deviations", "float"},
		},
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			gbuffer_layout.WriteBlock(self, block)
			local current = system.GetFrameNumber() % 2 + 1
			block.source_tex = self:GetTextureIndex(
				iteration == 0 and
					attachment("ray_shadow_accumulate", current, 1) or
					attachment(filter_name(iteration - 1), 1, 1)
			)
			block.moments_tex = self:GetTextureIndex(attachment("ray_shadow_accumulate", current, 2))
			block.step = 2 ^ iteration
			block.deviations = filter_deviations:Get()
			return block
		end,
	}
end

local function pass_filter(iteration)
	return {
		name = filter_name(iteration),
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {filter_name(iteration), "rgba"}}},
		framebuffer_count = 1,
		LocalSize = LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {filter_uniform(iteration)},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_visibility;
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("shadow_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("shadow_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_visibility);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 center = texelFetch(TEXTURE(shadow_data.source_tex), pos, 0);
				float depth = gbuffer_depth(pos);

				if (depth <= 0.0) {
					imageStore(out_visibility, pos, center);
					return;
				}

				vec4 moments = texelFetch(TEXTURE(shadow_data.moments_tex), pos, 0);
				vec2 deviation = sqrt(max(moments.zw - center.rg * center.rg, vec2(0.0)) / max(moments.x, 1.0));
				// a few frames of history give no deviation to trust yet
				vec2 tolerance = moments.x < 4.0 ? vec2(1e3) : shadow_data.deviations * deviation + 0.02;
				vec3 P = get_world_pos((vec2(pos) + 0.5) / vec2(size), depth);
				vec3 N = gbuffer_normal(pos);
				float view_depth = distance(P, shadow_data.camera_position.xyz);
				float plane_tolerance = 0.01 + 0.01 * view_depth;
				vec4 sum = vec4(0.0);
				vec2 total = vec2(0.0);

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 q = pos + ivec2(x, y) * shadow_data.step;

						if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) continue;

						vec4 value = texelFetch(TEXTURE(shadow_data.source_tex), q, 0);
						float w = (x == 0 ? 0.5 : 0.25) * (y == 0 ? 0.5 : 0.25);

						if (q != pos) {
							float q_depth = gbuffer_depth(q);

							if (q_depth <= 0.0) continue;

							vec3 q_P = get_world_pos((vec2(q) + 0.5) / vec2(size), q_depth);
							w *= exp(-abs(dot(N, q_P - P)) / plane_tolerance) * pow(max(dot(N, gbuffer_normal(q)), 0.0), 16.0);
						}

						vec2 wv = w * value.ba * exp(-abs(value.rg - center.rg) / tolerance);
						sum.rg += value.rg * wv;
						sum.ba += value.ba * w;
						total += wv;
					}
				}

				vec2 visibility = vec2(total.x > 0.0 ? sum.r / total.x : center.r, total.y > 0.0 ? sum.g / total.y : center.g);
				imageStore(out_visibility, pos, vec4(visibility, center.ba));
			}
		]],
	}
end

return {
	{
		name = "ray_shadow_trace",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ray_shadow_raw", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = LOCAL_SIZE,
		storage_images = {{binding_index = BINDING_OUTPUT, attachment = 1, dst_stage = "compute"}},
		storage_buffers = {{binding_index = BINDING_LIGHT_GRID}},
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		on_pre_draw = function(self, cmd, frame, desc)
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
		end,
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = BINDING_UNIFORM,
				block = {surface_lighting.block, gbuffer_layout.block},
				write = function(self, block)
					surface_lighting.WriteBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					return block
				end,
			},
			scene_hits.GetDDGIUniformBuffer(BINDING_DDGI),
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_raw;
		]] .. surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. optical_rays.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. "\n" .. optical_rays.GetGLSL() .. ray_materials.GetAlphaTestGLSL() .. surface_lighting.GetGLSL("lighting_data", true) .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data") .. screen_reconstruct.GetGeometricNormalGLSL("lighting_data", {world_pos_function = "get_world_pos"}) .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_raw);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float depth = gbuffer_depth(pos);

				if (depth <= 0.0) {
					imageStore(out_raw, pos, vec4(1.0, 1.0, 0.0, 0.0));
					return;
				}

				vec3 P = get_world_pos((vec2(pos) + 0.5) / vec2(size), depth);
				vec3 V = normalize(lighting_data.camera_position.xyz - P);
				vec3 N = bend_normal_to_view(gbuffer_normal(pos), V);
				imageStore(out_raw, pos, trace_ray_shadows(P, N, get_geometric_normal(pos, P, depth, V, N), gbuffer_is_lit_from_behind(pos)));
			}
		]],
	},
	{
		name = "ray_shadow_accumulate",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"ray_shadow_accumulated", "rgba"}},
			{"r16g16b16a16_sfloat", {"ray_shadow_moments", "rgba"}},
			{"r16g16_sfloat", {"ray_shadow_normal", "rg"}},
		},
		framebuffer_count = 2,
		LocalSize = LOCAL_SIZE,
		storage_images = {
			{binding_index = BINDING_OUTPUT, attachment = 1, dst_stage = "compute"},
			{binding_index = BINDING_OUTPUT + 1, attachment = 2, dst_stage = "compute"},
			{binding_index = BINDING_OUTPUT + 2, attachment = 3, dst_stage = "compute"},
		},
		uniform_buffers = {
			{
				name = "shadow_data",
				binding_index = BINDING_UNIFORM,
				block = {
					gbuffer_layout.block,
					render3d.camera_block,
					{"raw_tex", "int"},
					{"history_tex", "int"},
					{"history_moments_tex", "int"},
					{"history_normal_tex", "int"},
					{"max_history", "float"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					block.raw_tex = self:GetTextureIndex(attachment("ray_shadow_trace", 1, 1))
					block.max_history = max_history:Get()
					local frame = system.GetFrameNumber()

					if self.history_framebuffers ~= self.framebuffers then
						self.history_framebuffers = self.framebuffers
						self.history_reset_frame = frame
					end

					if frame > self.history_reset_frame and render3d.ShouldUseLastFrameHistory() then
						local history = self:GetFramebuffer((frame + 1) % 2 + 1)
						block.history_tex = self:GetTextureIndex(history:GetAttachment(1))
						block.history_moments_tex = self:GetTextureIndex(history:GetAttachment(2))
						block.history_normal_tex = self:GetTextureIndex(history:GetAttachment(3))
					else
						block.history_tex = -1
						block.history_moments_tex = -1
						block.history_normal_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_visibility;
			layout(set = 0, binding = ]] .. (
				BINDING_OUTPUT + 1
			) .. [[, rgba16f) uniform writeonly image2D out_moments;
			layout(set = 0, binding = ]] .. (
				BINDING_OUTPUT + 2
			) .. [[, rg16f) uniform writeonly image2D out_normal;
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("shadow_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_visibility);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 current = texelFetch(TEXTURE(shadow_data.raw_tex), pos, 0);
				vec2 uv = get_screen_uv(pos, size);
				float history_length = 0.0;
				vec4 history = current;
				vec2 history_squared = current.rg * current.rg;
				vec3 N = gbuffer_normal(pos);

				if (shadow_data.history_tex != -1 && shadow_data.velocity_tex != -1 && gbuffer_depth(pos) > 0.0) {
					vec4 motion = texture(TEXTURE(shadow_data.velocity_tex), uv);
					vec2 history_pixel = (uv - motion.xy) * vec2(size) - 0.5;
					ivec2 base = ivec2(floor(history_pixel));
					vec2 f = history_pixel - vec2(base);
					float depth_tolerance = 0.05 * motion.z + 0.02 * shadow_data.view_scale;
					float total = 0.0;
					float length_sum = 0.0;
					vec2 has_sum = vec2(0.0);
					vec2 visibility_sum = vec2(0.0);
					vec2 squared_sum = vec2(0.0);
					vec2 visibility_total = vec2(0.0);

					for (int tap = 0; tap < 4; tap++) {
						ivec2 offset = ivec2(tap & 1, tap >> 1);
						ivec2 texel = base + offset;

						if (any(lessThan(texel, ivec2(0))) || any(greaterThanEqual(texel, size))) continue;

						vec4 moments = texelFetch(TEXTURE(shadow_data.history_moments_tex), texel, 0);

						if (moments.y <= 0.0 || abs(moments.y - motion.z) > depth_tolerance) continue;

						vec4 value = texelFetch(TEXTURE(shadow_data.history_tex), texel, 0);
						// a pixel on an edge shows one surface or the other as the jitter moves, and averaging both lights a crevice with the light its lip receives
						vec3 history_N = oct_decode(texelFetch(TEXTURE(shadow_data.history_normal_tex), texel, 0).rg);
						float w = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y) * smoothstep(0.8, 0.95, dot(history_N, N));
						// a pixel without a group's light holds a placeholder visibility of one, averaged in it lights a shadowed surface the jitter or motion puts there
						vec2 wv = w * value.ba;
						total += w;
						length_sum += w * moments.x;
						has_sum += w * value.ba;
						visibility_sum += wv * value.rg;
						squared_sum += wv * moments.zw;
						visibility_total += wv;
					}

					if (total > 1e-3) {
						history_length = length_sum / total;
						history.ba = has_sum / total;
						history.rg = mix(current.rg, visibility_sum / max(visibility_total, vec2(1e-6)), greaterThan(visibility_total, vec2(1e-6)));
						history_squared = mix(history.rg * history.rg, squared_sum / max(visibility_total, vec2(1e-6)), greaterThan(visibility_total, vec2(1e-6)));
					}
				}

				vec2 mean = vec2(0.0);
				vec2 mean_squared = vec2(0.0);
				vec2 count = vec2(0.0);

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec4 value = texelFetch(TEXTURE(shadow_data.raw_tex), clamp(pos + ivec2(x, y), ivec2(0), size - 1), 0);
						mean += value.rg * value.ba;
						mean_squared += value.rg * value.rg * value.ba;
						count += value.ba;
					}
				}

				mean /= max(count, vec2(1.0));
				vec2 spread = mix(vec2(1.0), 1.5 * sqrt(max(mean_squared / max(count, vec2(1.0)) - mean * mean, vec2(0.0))) + 0.3, greaterThan(count, vec2(0.0)));
				vec2 clamped = clamp(history.rg, mean - spread, mean + spread);

				if (clamped != history.rg) history_length = min(history_length, 3.0);

				history.rg = clamped;
				history_length = min(history_length + 1.0, shadow_data.max_history);
				float alpha = 1.0 / history_length;
				vec2 history_weight = history.ba * (1.0 - alpha);
				vec2 current_weight = current.ba * alpha;
				vec2 weight = max(history_weight + current_weight, vec2(1e-6));
				vec2 present = vec2(greaterThan(history_weight + current_weight, vec2(0.0)));
				vec4 visibility = vec4(
					mix(vec2(1.0), (history.rg * history_weight + current.rg * current_weight) / weight, present),
					mix(history.ba, current.ba, alpha)
				);
				vec2 squared = mix(vec2(1.0), (history_squared * history_weight + current.rg * current.rg * current_weight) / weight, present);
				float view_depth = 0.0;
				float depth = gbuffer_depth(pos);

				if (depth > 0.0) {
					vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
					vec4 view = shadow_data.inv_projection * clip;
					view_depth = -view.z / view.w;
				}

				imageStore(out_visibility, pos, visibility);
				imageStore(out_moments, pos, vec4(history_length, view_depth, squared));
				imageStore(out_normal, pos, vec4(oct_encode(N), 0.0, 0.0));
			}
		]],
	},
	pass_filter(0),
	pass_filter(1),
	pass_filter(2),
}
